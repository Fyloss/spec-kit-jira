#!/usr/bin/env bats
# T010 [Phase 1, defect 2] — the child type does not resolve on a Jira whose
# issue-type names are not the Atlassian defaults. `_reconcile_plan_context`
# reads the literal `.issue_types.Story` (reconcile.sh), which finds no key
# in a French binding whose types are Récit/Tâche/Épopée/Sous-tâche, so the
# resolved story type reaches the plan context empty and every creation is
# refused (quickstart Step 2). RED until Phase 4 (US1) lands.
#
# T033-T037 [Phase 4, US1] — hierarchy derivation (contracts/hierarchy-
# resolution.md §2/§3/§6), in the new sink/jira/hierarchy.sh. T081-T084
# [Phase 6, US3] extend this file with the mandatory-field gate.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/hierarchy.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-french-project" "${WORK}"
  SPEC="${WORK}/specs/001-checkout/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-checkout"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "resolves the child type on a French project" {
  # Phase 5 (US2): the parent (Épopée, 10301) is created first, then every
  # story at the resolved CHILD type (Récit, 10302).
  mock_start "${MOCK}/configs/french.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  [ "$(mock_issue_field FR-1 '.fields.issuetype.id')" = "10301" ]
  [ "$(mock_issue_field FR-2 '.fields.issuetype.id')" = "10302" ]
  [ "$(mock_issue_field FR-3 '.fields.issuetype.id')" = "10302" ]
}

# --- T033 — child-level derivation (contract §2) ----------------------------

@test "T033 — child level is the minimum hierarchy_level over non-subtask types" {
  itypes='[
    {"logical_name":"Epic","id":"1","hierarchy_level":1,"subtask":false},
    {"logical_name":"Story","id":"2","hierarchy_level":0,"subtask":false},
    {"logical_name":"Sub-task","id":"3","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_child_level "${itypes}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "T033 — child level ignores subtask types even at a lower level" {
  itypes='[
    {"logical_name":"Story","id":"2","hierarchy_level":0,"subtask":false},
    {"logical_name":"Ghost","id":"9","hierarchy_level":-5,"subtask":true}
  ]'
  run hierarchy_child_level "${itypes}"
  [ "$output" -eq 0 ]
}

# --- T034 — parent-level derivation, every row of contract §3 --------------

@test "T034 — default Scrum: Epic 1 / Story 0 / Sub-task -1 -> parent Epic" {
  itypes='[
    {"logical_name":"Epic","id":"1","hierarchy_level":1,"subtask":false},
    {"logical_name":"Story","id":"2","hierarchy_level":0,"subtask":false},
    {"logical_name":"Sub-task","id":"3","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_derive COMP "${itypes}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  [ "$(jq -r '.parent.logical_name' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.child_level' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.parent_level' <<< "$output")" -eq 1 ]
}

@test "T034 — company-managed fixture: Initiative 2 / Deliverable 1 / Story+Defect 0 -> parent Deliverable" {
  itypes='[
    {"logical_name":"Initiative","id":"10100","hierarchy_level":2,"subtask":false},
    {"logical_name":"Deliverable","id":"10101","hierarchy_level":1,"subtask":false},
    {"logical_name":"Story","id":"10102","hierarchy_level":0,"subtask":false},
    {"logical_name":"Defect","id":"10103","hierarchy_level":0,"subtask":false},
    {"logical_name":"Sub-task","id":"10104","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_derive COMP "${itypes}"
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  [ "$(jq -r '.parent.logical_name' <<< "$output")" = "Deliverable" ]
}

@test "T034 — SAFe: Epic 2 / Feature 1 / Story 0 -> parent Feature" {
  itypes='[
    {"logical_name":"Epic","id":"10401","hierarchy_level":2,"subtask":false},
    {"logical_name":"Feature","id":"10402","hierarchy_level":1,"subtask":false},
    {"logical_name":"Story","id":"10403","hierarchy_level":0,"subtask":false},
    {"logical_name":"Sub-task","id":"10404","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_derive SAFE "${itypes}"
  [ "$(jq -r '.parent.logical_name' <<< "$output")" = "Feature" ]
}

@test "T034 — Latin-diacritic project: Épopée 1 / Récit+Tâche 0 -> parent Épopée" {
  itypes='[
    {"logical_name":"Épopée","id":"10301","hierarchy_level":1,"subtask":false},
    {"logical_name":"Récit","id":"10302","hierarchy_level":0,"subtask":false},
    {"logical_name":"Tâche","id":"10303","hierarchy_level":0,"subtask":false},
    {"logical_name":"Sous-tâche","id":"10304","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_derive FR "${itypes}"
  [ "$(jq -r '.parent.logical_name' <<< "$output")" = "Épopée" ]
}

@test "T034 — non-Latin project: エピック 1 / ストーリー+Задача (QA) 0 -> parent エピック" {
  itypes='[
    {"logical_name":"エピック","id":"10501","hierarchy_level":1,"subtask":false},
    {"logical_name":"ストーリー","id":"10502","hierarchy_level":0,"subtask":false},
    {"logical_name":"Задача (QA)","id":"10503","hierarchy_level":0,"subtask":false},
    {"logical_name":"サブタスク","id":"10504","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_derive NL "${itypes}"
  [ "$(jq -r '.parent.logical_name' <<< "$output")" = "エピック" ]
}

# --- T035 — no-parent-level refusal -----------------------------------------

@test "T035 — a flat project (Story alone) refuses no-parent-level, never falls back" {
  itypes='[
    {"logical_name":"Story","id":"1","hierarchy_level":0,"subtask":false},
    {"logical_name":"Sub-task","id":"2","hierarchy_level":-1,"subtask":true}
  ]'
  run hierarchy_derive FLAT "${itypes}"
  [ "$(jq -r '.status' <<< "$output")" = "no-parent-level" ]
  [ "$(jq -r 'has("parent")' <<< "$output")" = "false" ]
  [[ "$(jq -r '.message' <<< "$output")" == *"FLAT"* ]]
  [[ "$(jq -r '.message' <<< "$output")" == *"Story"* ]]
}

# --- T036 — parent-level-ambiguous refusal ----------------------------------

@test "T036 — two candidates at the parent tier refuses, naming every candidate" {
  itypes='[
    {"logical_name":"Capability","id":"1","hierarchy_level":1,"subtask":false},
    {"logical_name":"Feature","id":"2","hierarchy_level":1,"subtask":false},
    {"logical_name":"Story","id":"3","hierarchy_level":0,"subtask":false}
  ]'
  run hierarchy_derive AMBIG "${itypes}"
  [ "$(jq -r '.status' <<< "$output")" = "parent-level-ambiguous" ]
  [ "$(jq -r 'has("parent")' <<< "$output")" = "false" ]
  [[ "$(jq -r '.message' <<< "$output")" == *"Capability"* ]]
  [[ "$(jq -r '.message' <<< "$output")" == *"Feature"* ]]
}

# --- T037 — child-type-unresolved (spec FR-001a) ----------------------------

@test "T037 — a binding with no recorded child_type refuses child-type-unresolved" {
  mock_start "${MOCK}/configs/french.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # Strip child_type from the persisted binding by hand.
  # shellcheck disable=SC1090
  source "${ROOT}/scripts/bash/lib/config.sh"
  local localj
  localj="$(jq -c 'del(.resolved_ids.FR.child_type)' <<< "$(config_yaml_to_json "${JIRA_CONFIG_DIR}/config.local.yml")")"
  printf '%s' "${localj}" | config_to_yaml > "${JIRA_CONFIG_DIR}/config.local.yml"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"no recorded issue type for user stories"* ]]

  run mock_calls
  [ -z "$output" ]
}

# --- T081-T084 [Phase 6, US3]: the mandatory-field gate (contract §5) ------

BINDING_MANDATORY='{
  "child_type": {"logical_name":"Story", "id":"10102"},
  "parent_type": {"logical_name":"Deliverable", "id":"10101"},
  "parent_link_available": {"10102": true},
  "required_fields": {
    "10101": [
      {"logical_name":"Summary", "field_id":"summary"},
      {"logical_name":"Business Owner", "field_id":"customfield_40011"},
      {"logical_name":"Program Increment", "field_id":"customfield_40012"}
    ],
    "10102": [
      {"logical_name":"Summary", "field_id":"summary"}
    ]
  }
}'

@test "T081: the satisfaction table — summary/description/issuetype/project/priority/reporter are always satisfiable" {
  local fields='[{"logical_name":"Summary","field_id":"summary"},{"logical_name":"Description","field_id":"description"},{"logical_name":"Issue Type","field_id":"issuetype"},{"logical_name":"Project","field_id":"project"},{"logical_name":"Priority","field_id":"priority"},{"logical_name":"Reporter","field_id":"reporter"}]'
  run hierarchy_unsatisfiable_fields "${fields}" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "T081: parent is satisfiable on the child type only when the link is available" {
  local fields='[{"logical_name":"Parent","field_id":"parent"}]'
  run hierarchy_unsatisfiable_fields "${fields}" "true"
  [ "$output" = "[]" ]
  run hierarchy_unsatisfiable_fields "${fields}" "false"
  [ "$output" = '["Parent"]' ]
}

@test "T081: any other field is not satisfiable" {
  local fields='[{"logical_name":"Business Owner","field_id":"customfield_40011"}]'
  run hierarchy_unsatisfiable_fields "${fields}" "true"
  [ "$output" = '["Business Owner"]' ]
}

@test "T082: the gate reports every unsatisfiable field of every written type in ONE refusal, named by Jira's own field name" {
  run hierarchy_mandatory_gate "${BINDING_MANDATORY}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "unsatisfiable" ]
  local msg; msg="$(jq -r '.message' <<< "$output")"
  [[ "${msg}" == *'"Deliverable"'* ]]
  [[ "${msg}" == *'"Business Owner"'* ]]
  [[ "${msg}" == *'"Program Increment"'* ]]
  # Never a customfield_NNNNN id in the message.
  [[ "${msg}" != *"customfield_"* ]]
}

@test "T082: a non-ASCII field name survives the refusal intact" {
  local binding; binding="$(jq -c '.required_fields."10101" += [{"logical_name":"Équipe propriétaire","field_id":"customfield_40099"}]' <<< "${BINDING_MANDATORY}")"
  run hierarchy_mandatory_gate "${binding}"
  [[ "$(jq -r '.message' <<< "$output")" == *"Équipe propriétaire"* ]]
}

@test "T083: the refusal is a named mandatory-field reason, never a transport error" {
  run hierarchy_mandatory_gate "${BINDING_MANDATORY}"
  [ "$(jq -r '.status' <<< "$output")" = "unsatisfiable" ]
  [ "$(jq -r '.reason' <<< "$output")" = "mandatory-fields-unsatisfiable" ]
}

@test "T083: the gate fires for the child type as well as the parent" {
  local binding; binding="$(jq -c '.required_fields."10102" += [{"logical_name":"Team","field_id":"customfield_50001"}]' <<< "${BINDING_MANDATORY}")"
  run hierarchy_mandatory_gate "${binding}"
  [[ "$(jq -r '.message' <<< "$output")" == *'"Story"'* ]]
  [[ "$(jq -r '.message' <<< "$output")" == *'"Team"'* ]]
}

@test "T083: a hierarchy with no unsatisfiable fields passes the gate cleanly" {
  local binding; binding="$(jq -c '.required_fields."10101" = [{"logical_name":"Summary","field_id":"summary"}]' <<< "${BINDING_MANDATORY}")"
  run hierarchy_mandatory_gate "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
}

@test "T084: parent-link-unavailable when the child type's create metadata offers no parent field" {
  local binding; binding="$(jq -c '.parent_link_available."10102" = false | .required_fields."10102" = [{"logical_name":"Summary","field_id":"summary"}]' <<< "${BINDING_MANDATORY}")"
  run hierarchy_mandatory_gate "${binding}" "COMP"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "parent-link-unavailable" ]
  [[ "$(jq -r '.message' <<< "$output")" == *"Story"* ]]
  [[ "$(jq -r '.message' <<< "$output")" == *"COMP"* ]]
}

@test "T083/T084: the gate runs BEFORE recognition — zero writes, driven end to end through cmd_reconcile" {
  local work="${BATS_TEST_TMPDIR}/repo-mandatory"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${work}"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # A bare invocation now stops at the consolidated field-defaults question
  # (011, contract §3.3's second trigger) before reaching the gate at all —
  # exit 0, confirmation-pending, zero writes. --accept-defaults declares
  # this an unreachable-operator run (contract §3.10) and reaches the
  # surviving refusal this test was written to prove.
  run cmd_reconcile reconcile "${work}/specs/001-reporting/spec.md" --json --accept-defaults
  [ "$status" -eq 4 ]
  [[ "$output" == *"Deliverable"* ]]
  [[ "$output" == *"Business Owner"* ]]
  [[ "$output" == *"Program Increment"* ]]

  run mock_calls
  [ -z "$output" ]
}

@test "T084 [Phase 9] — the mandatory-field gate runs at CONFIG time too, over a role the resolver derived (010, contract §4 checks 5/6)" {
  # shellcheck disable=SC1090
  source "${CMD_DIR}/config.sh"
  local work="${BATS_TEST_TMPDIR}/repo-mandatory-config"
  mkdir -p "${work}/.specify/jira"
  {
    printf 'projects:\n'
    printf '  - key: PM\n'
    printf 'routing_default: PM\n'
  } > "${work}/.specify/jira/config.yml"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # story is ambiguous (Story/Defect at level 0) so it must be answered; the
  # specification role is NOT declared or answered by the operator anywhere
  # in this run — it is left to derive to Deliverable (the single level-1
  # candidate), and Deliverable is the type carrying the unsatisfiable
  # fields. The gate must still catch it.
  run cmd_config config --issue-type PM=story=Story --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"Deliverable"* ]]
  [[ "$output" == *"Business Owner"* ]]
  [[ "$output" == *"Program Increment"* ]]
  # Zero writes: neither Jira nor the local binding.
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

@test "records required_fields for both types when the whole hierarchy is unambiguous" {
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run discover_binding SAFE
  [ "$status" -eq 0 ]
  [ "$(jq -r '.required_fields | keys | sort | join(",")' <<< "$output")" = "10402,10403" ]
  [ "$(jq -r '.required_fields."10402"[0].logical_name' <<< "$output")" = "Summary" ]
  [ "$(jq -r '.required_fields."10403"[0].logical_name' <<< "$output")" = "Summary" ]
}

# --- T097 [Phase 8]: the diagnostics catalogue, matched verbatim ------------
# Every new reason code and message template from contracts/parent-marker.md
# §"Diagnostics" and contracts/hierarchy-resolution.md §6, matched exactly —
# not by substring — and checked for a leaked host/token (never present).

SPEC_REF='{"repo":"acme/app","spec_slug":"001-checkout"}'

@test "T097: parent-marker-malformed reason and message match the contract verbatim" {
  local minfo='{"state":"malformed","lines":[3]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "specs/001-checkout/spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.reason' <<< "$output")" = "parent-marker-malformed" ]
  [ "$(jq -r '.detail' <<< "$output")" = 'specs/001-checkout/spec.md line 3: malformed speckit-jira parent marker; nothing was written for this specification. Expected `<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->`.' ]
}

@test "T097: parent-marker-duplicate reason and message match the contract verbatim" {
  local minfo='{"state":"duplicate","lines":[2,7]}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "specs/001-checkout/spec.md"
  [ "$(jq -r '.reason' <<< "$output")" = "parent-marker-duplicate" ]
  [ "$(jq -r '.detail' <<< "$output")" = 'specs/001-checkout/spec.md carries 2 speckit-jira parent markers (lines 2, 7); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others.' ]
}

@test "T097: the parent's creating state is parent-key-unrecorded, distinct from a story's key-unrecorded" {
  local minfo='{"state":"creating","id":"3f2a91c04b7e6d18"}'
  run recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "specs/001-checkout/spec.md"
  [ "$(jq -r '.reason' <<< "$output")" = "parent-key-unrecorded" ]
  [[ "$(jq -r '.detail' <<< "$output")" == *"3f2a91c04b7e6d18"* ]]
  [[ "$(jq -r '.detail' <<< "$output")" == *"COMP"* ]]
}

@test "T097: no diagnostic message in this catalogue leaks a host, URL scheme or credential" {
  local msgs=(
    'specs/001-checkout/spec.md line 3: malformed speckit-jira parent marker; nothing was written for this specification. Expected `<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->`.'
    'specs/001-checkout/spec.md carries 2 speckit-jira parent markers (lines 2, 7); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others.'
    "$(hierarchy_parent_link_unavailable_message "COMP" "Story")"
    "$(hierarchy_child_type_unresolved_message "COMP")"
    "$(hierarchy_binding_shape_stale_message "COMP")"
  )
  local m
  for m in "${msgs[@]}"; do
    [[ "${m}" != *"http://"* ]]
    [[ "${m}" != *"https://"* ]]
    [[ "${m}" != *"RAWSECRET"* ]]
  done
}

@test "T097: the PowerShell port emits the same parent-key-unrecorded reason (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local minfo='{"state":"creating","id":"3f2a91c04b7e6d18"}'
  local b p
  b="$(recognition_parent_run "${minfo}" "${SPEC_REF}" "COMP" "specs/001-checkout/spec.md")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/sink/jira/Recognition.psm1' -Force
    \$r = Invoke-JiraRecognitionParentRun -MarkerInfoJson '${minfo}' -SpecRefJson '${SPEC_REF}' -ProjectKey 'COMP' -SpecPath 'specs/001-checkout/spec.md'
    [Console]::Out.Write(\$r.Json)")"
  [ "${b}" = "${p}" ]
}

# --- T021 [Phase 2, 011] — satisfiability, one predicate, defaults-aware ----
# (contract §1). hierarchy_unsatisfiable_fields gains a third input: the
# recorded-or-answered defaults for the type being checked, keyed by field_id.
# A field with an entry there is satisfiable; without one it is not; a
# required `parent` on the PARENT type stays unsatisfiable whatever is
# recorded (contract §1.2); the bridge-supplied list is unchanged.

@test "T021: a required field with a recorded default is satisfiable" {
  local fields='[{"logical_name":"Business Owner","field_id":"customfield_40011"}]'
  local defaults='{"customfield_40011":"Platform Team"}'
  run hierarchy_unsatisfiable_fields "${fields}" "true" "${defaults}"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "T021: without a recorded default the same field is still unsatisfiable" {
  local fields='[{"logical_name":"Business Owner","field_id":"customfield_40011"}]'
  run hierarchy_unsatisfiable_fields "${fields}" "true" "{}"
  [ "$output" = '["Business Owner"]' ]
}

@test "T021: omitting the third argument entirely still works (backward compatible)" {
  local fields='[{"logical_name":"Business Owner","field_id":"customfield_40011"}]'
  run hierarchy_unsatisfiable_fields "${fields}" "true"
  [ "$output" = '["Business Owner"]' ]
}

@test "T021: a required parent field on the PARENT type stays unsatisfiable regardless of any recorded default (contract §1.2)" {
  local fields='[{"logical_name":"Parent","field_id":"parent"}]'
  local defaults='{"parent":"whatever"}'
  run hierarchy_unsatisfiable_fields "${fields}" "false" "${defaults}"
  [ "$output" = '["Parent"]' ]
}

@test "T021: the bridge-supplied list is unchanged — those fields need no default to be satisfiable" {
  local fields='[{"logical_name":"Summary","field_id":"summary"},{"logical_name":"Description","field_id":"description"}]'
  run hierarchy_unsatisfiable_fields "${fields}" "false" "{}"
  [ "$output" = "[]" ]
}

@test "T021: hierarchy_mandatory_gate accepts a per-type defaults map and clears the refusal once both fields are recorded" {
  local defaults_by_type; defaults_by_type='{"10101":{"customfield_40011":"Platform Team","customfield_40012":"PI-2026-Q3"}}'
  run hierarchy_mandatory_gate "${BINDING_MANDATORY}" "PM" "${defaults_by_type}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
}

@test "T021: hierarchy_mandatory_gate still refuses when only ONE of the two required fields is recorded" {
  local defaults_by_type; defaults_by_type='{"10101":{"customfield_40011":"Platform Team"}}'
  run hierarchy_mandatory_gate "${BINDING_MANDATORY}" "PM" "${defaults_by_type}"
  [ "$(jq -r '.status' <<< "$output")" = "unsatisfiable" ]
  [[ "$(jq -r '.message' <<< "$output")" == *"Program Increment"* ]]
  [[ "$(jq -r '.message' <<< "$output")" != *"Business Owner"* ]]
}

@test "T021: hierarchy_mandatory_gate defaults the third argument to no recorded defaults (backward compatible)" {
  run hierarchy_mandatory_gate "${BINDING_MANDATORY}" "PM"
  [ "$(jq -r '.status' <<< "$output")" = "unsatisfiable" ]
}

# --- T077 [Phase 5, 011 US3] — a non-defaultable field is reported by label -
@test "T077: a non-defaultable field is reported with its reason, by label, and the pre-existing refusal is unchanged" {
  local fields='[{"logical_name":"Attachment","field_id":"attachment","required":true,"defaultable":false,"undefaultable_reason":"a list of values cannot be expressed as a single recorded value"}]'
  run hierarchy_undefaultable_required_fields "${fields}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].logical_name' <<< "$output")" = "Attachment" ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "a list of values cannot be expressed as a single recorded value" ]
}
