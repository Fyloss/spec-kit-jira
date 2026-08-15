#!/usr/bin/env bats
# T042 [US3] — Ticket sink: validate (read) and create (guarded write)
# (FR-013, contracts/jira-endpoints-delta.md).
#
# `ticket_validate` reads GET /issue/{key}?fields=project through the existing
# transport (fail-closed codes for a mentioned key). `ticket_create` POSTs with
# fields.project.key = the team project and fields.issuetype.id = the caller's
# resolved story-type id (never a literal type name); the PASS-1 privacy guard
# runs BEFORE the POST (BLOCK => exit 9, zero writes); the created ticket is
# identity-stamped like any bridge-created artifact.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/ticket.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "ticket_validate reads the mentioned key's project (fields=project)" {
  boot '{"projects":{"IJT":"team"}}'
  run ticket_validate "IJT-42"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "IJT-42" ]
  [ "$(jq -r '.project' <<< "$output")" = "IJT" ]
  mock_calls | grep -q 'GET /rest/api/3/issue/IJT-42?fields=project'
}

@test "ticket_validate fails closed on an unknown mentioned key (exit 2)" {
  boot '{"projects":{"IJT":"team"}}'
  run ticket_validate "NOPE-1"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "jira_create_fields_base returns exactly {project,issuetype,summary} (FR-025)" {
  run jira_create_fields_base "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'keys' <<< "$output")" = '["issuetype","project","summary"]' ]
  [ "$(jq -r '.project.key' <<< "$output")" = "IJT" ]
  [ "$(jq -r '.issuetype.id' <<< "$output")" = "10201" ]
  [ "$(jq -r '.summary' <<< "$output")" = "invoice export" ]
}

@test "jira_create_fields_base tolerates an empty issue-type id — validation is the CALLER's job (regression, Phase 5 US2)" {
  # The parent's own creation path (scripts/bash/sink/jira/plan_apply.sh,
  # _plan_writes_parent) calls this builder before any mandatory-field gate
  # exists (that gate is Phase 6, US3) — an empty parent_type_id must not
  # make the shared builder itself fail, exactly as it already tolerates an
  # empty project or summary. The PowerShell port must not throw either
  # (NFR-1): a prior defect had its parameters reject an empty string at
  # the binding level, a stricter behaviour bash's jq-based builder does
  # not share.
  run jira_create_fields_base "TEST" "The Epic" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issuetype.id' <<< "$output")" = "" ]
}

@test "_ticket_create_body is built from jira_create_fields_base, unchanged (FR-025)" {
  local base
  base="$(jira_create_fields_base "IJT" "invoice export" "10201")"
  run _ticket_create_body "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.fields' <<< "$output")" = "$(jq -c . <<< "${base}")" ]
}

@test "the create body carries the team project and the resolved story-type id" {
  run _ticket_create_body "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.project.key' <<< "$output")" = "IJT" ]
  [ "$(jq -r '.fields.issuetype.id' <<< "$output")" = "10201" ]
  [ "$(jq -r '.fields.summary' <<< "$output")" = "invoice export" ]
  # The id arrives from the caller (the binding) — never a literal type name.
  [ "$(jq -r '.fields.issuetype | has("name")' <<< "$output")" = "false" ]
}

@test "T024b, T12 [017] — jira_create_fields_base sends the provenance label as its fifth argument (union with recorded labels default)" {
  run jira_create_fields_base "IJT" "invoice export" "10201" '{}' "speckit-001-x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.labels | join(",")' <<< "$output")" = "speckit-001-x" ]
}

@test "T024b, T12 [017] — the feature ceremony's _ticket_create_body carries NO labels key — in particular never speckit-spec — while its base stays byte-identical to the mirror's" {
  local base_no_prov base_with_prov
  base_no_prov="$(jira_create_fields_base "IJT" "invoice export" "10201")"
  base_with_prov="$(jira_create_fields_base "IJT" "invoice export" "10201" '{}' "speckit-spec")"
  # The mirror's own path (labelled) differs ONLY by the labels key — the
  # shared base underneath is byte-identical (FR-025).
  [ "$(jq -c 'del(.labels)' <<< "${base_with_prov}")" = "$(jq -c . <<< "${base_no_prov}")" ]

  run _ticket_create_body "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields | has("labels")' <<< "$output")" = "false" ]
  [ "$(jq -c '.fields' <<< "$output")" = "$(jq -c . <<< "${base_no_prov}")" ]
}

@test "ticket_create POSTs, prints the created key, and identity-stamps it" {
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run ticket_create "IJT" "invoice export" "10201" '[]' '[]' '{"repo":"acme/app","spec_slug":"003-x"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "IJT-123" ]
  mock_calls | grep -q 'POST /rest/api/3/issue'
  # Identity stamp (entity property PUT) follows the create.
  mock_calls | grep -q 'PUT /rest/api/3/issue/IJT-123/properties/spec-kit-jira'
}

@test "027, FR-023: an optional 7th argument stamps the identity's role — a created parent's identity is recognisable as role:parent" {
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run ticket_create "IJT" "Payment webhooks rollout" "10000" '[]' '[]' '{"repo":"acme/app","spec_slug":"003-x"}' "parent"
  [ "$status" -eq 0 ]
  local stored
  stored="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/IJT-123/properties/spec-kit-jira" | jq -c '.value')"
  [ "$(jq -r '.role' <<< "${stored}")" = "parent" ]
  [ "$(jq -r '.summary' <<< "${stored}")" = "Payment webhooks rollout" ]
}

@test "the 7th argument is entirely optional — omitting it behaves exactly as before (regression)" {
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run ticket_create "IJT" "invoice export" "10201" '[]' '[]' '{"repo":"acme/app","spec_slug":"003-x"}'
  [ "$status" -eq 0 ]
  local stored
  stored="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/IJT-123/properties/spec-kit-jira" | jq -c '.value')"
  [ "$(jq -r 'has("role")' <<< "${stored}")" = "false" ]
}

@test "the PASS-1 privacy guard blocks BEFORE the POST (exit 9, zero writes)" {
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run ticket_create "IJT" "summary with token ATATT3xFfGF0abcdef" "10201"
  [ "$status" -eq 9 ]
  # Zero writes: nothing reached the mock.
  [ -z "$(mock_calls)" ]
}

# --- T029/T029a [Phase 2, 011] — the payload merge (research R2) -----------
# jira_create_fields_base gains a fourth, OPTIONAL argument: the plan
# context's field_defaults map, {type_id: {field_id: value}}. The function
# itself scopes the merge to the type being created (its own 3rd argument),
# so a caller cannot get FR-018 wrong by passing the whole map.

@test "T029 — merges the defaults for the type being created" {
  local defaults_by_type='{"10101":{"customfield_40011":"Platform Team"}}'
  run jira_create_fields_base "IJT" "invoice export" "10101" "${defaults_by_type}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.customfield_40011' <<< "$output")" = "Platform Team" ]
  [ "$(jq -r '.project.key' <<< "$output")" = "IJT" ]
}

@test "T029 — merges nothing when the map is empty (FR-028, absence is the off switch)" {
  run jira_create_fields_base "IJT" "invoice export" "10101" "{}"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'keys' <<< "$output")" = '["issuetype","project","summary"]' ]
}

@test "T029 — the fourth argument is entirely optional — omitting it behaves exactly as before (regression)" {
  run jira_create_fields_base "IJT" "invoice export" "10101"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'keys' <<< "$output")" = '["issuetype","project","summary"]' ]
}

@test "T029 — merges NOTHING recorded against a DIFFERENT issue type (FR-018 negative)" {
  # A default recorded for the specification type (10101) is absent from a
  # story payload (10102) — the edge case \"mandatory on one type, absent from
  # another\".
  local defaults_by_type='{"10101":{"customfield_40011":"Platform Team"}}'
  run jira_create_fields_base "IJT" "a story" "10102" "${defaults_by_type}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("customfield_40011")' <<< "$output")" = "false" ]
}

@test "T029a — the defaulted value reaches the privacy guard's scan, proving the merge happens before it, at plan time" {
  local defaults_by_type='{"10201":{"customfield_99999":"RAWSECRET-shaped-value ATATT3xFfGF0abcdef"}}'
  local body; body="$(_ticket_create_body "IJT" "invoice export" "10201")"
  # _ticket_create_body itself does not merge defaults (only plan_writes'
  # create branch does, per research R2) — this test proves the BUILDER can
  # carry a defaulted value through to a body the guard scans, by building
  # the body from the merged fields directly.
  local merged; merged="$(jira_create_fields_base "IJT" "invoice export" "10201" "${defaults_by_type}")"
  local guarded_body; guarded_body="$(jq -cn --argjson f "${merged}" '{fields:$f}')"
  run privacy_guard_scan "${guarded_body}" "[]" "[]"
  [ "$status" -eq 9 ]
}

@test "T029a — an allowlisted defaulted value passes the guard silently" {
  local defaults_by_type='{"10201":{"customfield_1":"support.example.atlassian.net"}}'
  local merged; merged="$(jira_create_fields_base "IJT" "invoice export" "10201" "${defaults_by_type}")"
  local guarded_body; guarded_body="$(jq -cn --argjson f "${merged}" '{fields:$f}')"
  run privacy_guard_scan "${guarded_body}" "[]" '["support.example.atlassian.net"]'
  [ "$status" -eq 0 ]
}

# --- 015 FR-017 regression: a recorded field default is sent in the shape --
# its field accepts. Written first, red against today's code (a select-list
# field carried as a bare string): a mandatory single-select default must
# reach jira_create_fields_base as {"value": v}, and a plain string default
# must reach it unchanged — the exact payload both creation paths build.

@test "015 FR-017 — a select-list default reaches jira_create_fields_base as {value: v}, a string default unchanged" {
  local itypes='[{"logical_name":"Story","id":"10102"}]'
  local df='{"10102":[
    {"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]},
    {"logical_name":"Team","field_id":"customfield_2","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}
  ]}'
  local recorded='{"Story":{"Region":"EMEA","Team":"Payments"}}'
  local resolved; resolved="$(plan_resolve_field_defaults "${itypes}" "${df}" "${recorded}" "[]")"
  local encoded; encoded="$(jq -c '.field_defaults_encoded' <<< "${resolved}")"
  local base; base="$(jira_create_fields_base "IJT" "a story" "10102" "${encoded}")"
  [ "$(jq -c '.customfield_1' <<< "${base}")" = '{"value":"EMEA"}' ]
  [ "$(jq -r '.customfield_2' <<< "${base}")" = "Payments" ]
}

# --- 015 FR-008: the same recorded default, through both creation paths — --
# the hook-driven reconcile (plan_writes' CREATE branch) and the planned
# write for the parent (_plan_writes_parent) — produces a byte-identical
# payload for the defaulted field, because both read the SAME
# field_defaults_encoded map from the plan context (data-model.md §3).

@test "015 FR-008 — the story CREATE branch and the parent CREATE branch encode the same recorded default identically" {
  local itypes='[{"logical_name":"Story","id":"10102"},{"logical_name":"Epic","id":"10101"}]'
  local df='{"10102":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}],
             "10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}]}'
  local recorded='{"Story":{"Region":"EMEA"},"Epic":{"Region":"EMEA"}}'
  local resolved; resolved="$(plan_resolve_field_defaults "${itypes}" "${df}" "${recorded}" "[]")"
  local encoded; encoded="$(jq -c '.field_defaults_encoded' <<< "${resolved}")"

  local doc='{
    "routing": {"project_key": "CONSUMER"},
    "epic": {"local_id":"E1","title":"New epic","description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
    "stories": [ {"local_id":"S1","title":"New story","priority_logical":null,"estimation":null} ]
  }'
  local ctx; ctx="$(jq -cn --argjson fd "${encoded}" \
    '{base_url:"https://example.atlassian.net","story_type_id":"10102","parent_type_id":"10101",field_defaults:$fd}')"
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.stories[0].body.fields.customfield_1' <<< "$output")" = '{"value":"EMEA"}' ]
  [ "$(jq -c '.parent.body.fields.customfield_1' <<< "$output")" = '{"value":"EMEA"}' ]
}
