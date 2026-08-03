#!/usr/bin/env bats
# T038 [US1] — The config ceremony's field-defaults ceremony (011, contract §2).
#
# T044/T045: the managed-region splice that writes the resolved field_defaults
# map into config.yml, through the existing managed_section_splice (research
# R1) — the same byte-preserving, host-line-ending, malformed-marker-refusing
# machinery the README block already uses.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${DIR}"
}

# --- T044/T045 — the managed-region splice -----------------------------------

@test "T044 — a non-empty map creates the region in an absent file" {
  local path="${DIR}/config.yml"
  run _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "created" ]
  grep -qF 'spec-kit-jira:field_defaults:begin' "${path}"
  grep -qF '"Business Owner": "Platform Team"' "${path}"
}

@test "T044 — an empty map with no pre-existing region is left untouched (FR-028, research R6)" {
  local path="${DIR}/config.yml"
  printf 'projects:\n  - key: FD\nrouting_default: FD\n' > "${path}"
  local before; before="$(cat "${path}")"
  run _config_field_defaults_write "${path}" '{}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "inert" ]
  [ "$(cat "${path}")" = "${before}" ]
}

@test "T044 — a second run with the same map reports unchanged and leaves the file byte-identical (FR-007)" {
  local path="${DIR}/config.yml"
  _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false" > /dev/null
  cp "${path}" "${DIR}/before"
  run _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  run cmp "${DIR}/before" "${path}"
  [ "$status" -eq 0 ]
}

@test "T044 — a changed map rewrites only the region, preserving bytes outside it" {
  local path="${DIR}/config.yml"
  printf '# a comment the operator wrote\nprojects:\n  - key: FD\nrouting_default: FD\n' > "${path}"
  _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false" > /dev/null
  run _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Override Team"}}}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "written" ]
  grep -qF '# a comment the operator wrote' "${path}"
  grep -qF '"Override Team"' "${path}"
  ! grep -qF '"Platform Team"' "${path}"
}

@test "T044 — an already-present region that becomes empty is still rewritten (§5.2 removal is the off switch)" {
  local path="${DIR}/config.yml"
  _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false" > /dev/null
  run _config_field_defaults_write "${path}" '{}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "written" ]
  grep -qF 'field_defaults": {}' "${path}"
}

@test "T044 — malformed markers refuse with exit 4 and zero writes" {
  local path="${DIR}/config.yml"
  printf '# --- spec-kit-jira:field_defaults:begin ---\nstray\n' > "${path}"
  local before; before="$(cat "${path}")"
  run _config_field_defaults_write "${path}" '{"FD":{"ask":true}}' "false"
  [ "$status" -eq 4 ]
  [[ "$output" == *"refused" ]]
  [ "$(cat "${path}")" = "${before}" ]
}

@test "T044 — --dry-run computes the status without touching the file" {
  local path="${DIR}/config.yml"
  run _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "true"
  [ "$status" -eq 0 ]
  [ "$output" = "created" ]
  [ ! -f "${path}" ]
}

# --- T040 — the managed region write: appended once, host line ending -------

@test "T040 — the region is appended once into a pre-existing file, never duplicated across writes" {
  local path="${DIR}/config.yml"
  printf 'projects:\n  - key: FD\nrouting_default: FD\n' > "${path}"
  _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false" > /dev/null
  _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Changed Team"}}}' "false" > /dev/null
  local n
  n="$(grep -cF "${_CONFIG_FIELD_DEFAULTS_BEGIN}" "${path}")"
  [ "${n}" -eq 1 ]
  n="$(grep -cF "${_CONFIG_FIELD_DEFAULTS_END}" "${path}")"
  [ "${n}" -eq 1 ]
}

@test "T040 — the host's dominant CRLF line ending is respected" {
  local path="${DIR}/config.yml"
  printf 'projects:\r\n  - key: FD\r\nrouting_default: FD\r\n' > "${path}"
  _config_field_defaults_write "${path}" '{"FD":{"ask":true,"Epic":{"Business Owner":"Platform Team"}}}' "false" > /dev/null
  local content; content="$(cat "${path}"; printf x)"; content="${content%x}"
  [[ "${content}" == *$'\r\n'"${_CONFIG_FIELD_DEFAULTS_BEGIN}"$'\r\n'* ]]
}

# --- T046/T048 — validating this run's answers (contract §2.4) ---------------

ITYPES='[{"logical_name":"Epic","id":"10101"},{"logical_name":"Story","id":"10102"}]'
DEFAULTABLE='{"10101":[
  {"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]},
  {"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"option","required":true,"defaultable":true,"allowed_values":["PI-2026-Q2","PI-2026-Q3"]},
  {"logical_name":"Impediment","field_id":"customfield_40013","schema_type":"array","required":false,"defaultable":false,"undefaultable_reason":"a list of values cannot be expressed as a single recorded value"}
]}'

@test "T048 — a well-formed answer produces no problem" {
  local answers='[{"type":"Epic","label":"Business Owner","value":"Platform Team"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
}

@test "T048 — an unknown issue-type name lists the discovered types (FR-026)" {
  local answers='[{"type":"NoSuchType","label":"Team","value":"X"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq -r '.[0].kind' <<< "$output")" = "unknown_type" ]
  [ "$(jq -r '.[0].candidates | sort | join(",")' <<< "$output")" = "Epic,Story" ]
}

@test "T048 — an unknown field label lists the defaultable fields of that type" {
  local answers='[{"type":"Epic","label":"Nonexistent","value":"X"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq -r '.[0].kind' <<< "$output")" = "unknown_label" ]
  [ "$(jq -r '.[0].candidates | sort | join(",")' <<< "$output")" = "Business Owner,Impediment,Program Increment" ]
}

@test "T048 — an empty value is refused (FR-008)" {
  local answers='[{"type":"Epic","label":"Business Owner","value":""}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq -r '.[0].kind' <<< "$output")" = "empty_value" ]
}

@test "T048 — a value outside allowed_values lists the accepted values (FR-003)" {
  local answers='[{"type":"Epic","label":"Program Increment","value":"PI-2020-Q1"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq -r '.[0].kind' <<< "$output")" = "outside_allowed" ]
  [ "$(jq -r '.[0].candidates | join(",")' <<< "$output")" = "PI-2026-Q2,PI-2026-Q3" ]
}

@test "T048 — a value inside allowed_values passes" {
  local answers='[{"type":"Epic","label":"Program Increment","value":"PI-2026-Q3"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
}

@test "T048 — a field whose shape cannot be defaulted is refused, naming the reason (US3 scenario 3)" {
  local answers='[{"type":"Epic","label":"Impediment","value":"X"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq -r '.[0].kind' <<< "$output")" = "undefaultable" ]
  [[ "$(jq -r '.[0].reason' <<< "$output")" == *"list of values"* ]]
}

@test "T048 — a credential-shaped value is refused before any splice (FR-024, Principle IV)" {
  local answers='[{"type":"Epic","label":"Business Owner","value":"person@example.com"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq -r '.[0].kind' <<< "$output")" = "credential" ]
  [[ "$output" != *"person@example.com"* ]]
}

@test "T048 — every kind of problem is batched into one report, not one refusal per answer" {
  local answers='[{"type":"Epic","label":"Business Owner","value":""},{"type":"Epic","label":"Program Increment","value":"PI-2020-Q1"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${DEFAULTABLE}" "${answers}"
  [ "$(jq 'length' <<< "$output")" -eq 2 ]
}

# --- T042/T046 — merging recorded entries with this run's answers (§2.6) ----

@test "T046 — an answer overwrites the matching recorded entry" {
  local recorded='{"ask":true,"Epic":{"Business Owner":"Platform Team"}}'
  local answers='[{"type":"Epic","label":"Business Owner","value":"Override Team"}]'
  run _config_field_default_merge "${recorded}" "${answers}"
  [ "$(jq -r '.Epic."Business Owner"' <<< "$output")" = "Override Team" ]
}

@test "T046 — an unrelated recorded entry is carried forward unchanged" {
  local recorded='{"ask":true,"Epic":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q2"}}'
  local answers='[{"type":"Epic","label":"Business Owner","value":"Override Team"}]'
  run _config_field_default_merge "${recorded}" "${answers}"
  [ "$(jq -r '.Epic."Program Increment"' <<< "$output")" = "PI-2026-Q2" ]
}

@test "T046 — the merge never carries the 'ask' switch as a type entry" {
  local recorded='{"ask":false,"Epic":{"Business Owner":"Platform Team"}}'
  run _config_field_default_merge "${recorded}" "[]"
  [ "$(jq -r 'has("ask")' <<< "$output")" = "false" ]
}

@test "T046 — an answer for a field with nothing recorded is applied on its own" {
  local answers='[{"type":"Story","label":"Team","value":"Payments"}]'
  run _config_field_default_merge "{}" "${answers}"
  [ "$(jq -r '.Story.Team' <<< "$output")" = "Payments" ]
}

# --- T046 — pending questions and reporting (orphaned / not-yet-consumed) ---

@test "T046 — a required defaultable field with no recorded value and no answer is pending" {
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic"]' '{}' '["10101"]'
  [ "$(jq -r '.pending | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.pending | map(.label) | sort | join(",")' <<< "$output")" = "Business Owner,Program Increment" ]
}

@test "T046 — a required defaultable field with a recorded value is not pending" {
  local merged='{"Epic":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q2"}}'
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic"]' "${merged}" '["10101"]'
  [ "$(jq -r '.pending | length' <<< "$output")" -eq 0 ]
}

@test "T046 — a required undefaultable field is reported once, never pending (contract §2.3)" {
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic"]' '{}' '["10101"]'
  [ "$(jq -r '.undefaultable_required | length' <<< "$output")" -eq 0 ]
}

# --- The pending question's `answer with …` hint is copy-pasteable ----------
# The hint tells the operator exactly what to type, so its KEY=Type=Label=Value
# token must survive a shell round-trip: labels routinely carry a space and the
# placeholder is spelled `<value>`, which an unquoted token would turn into an
# input redirection.

@test "the pending hint quotes the --field-default token, with and without an allowed-value list" {
  local report='{"orphaned":[],"not_yet_consumed":[],"undefaultable_required":[],
    "pending":[{"type":"Deliverable","label":"Business Owner","allowed_values":[]},
               {"type":"Deliverable","label":"Program Increment","allowed_values":["PI-2026-Q2","PI-2026-Q3"]}]}'
  run _config_field_default_notes "PM" "${report}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(answer with --field-default 'PM=Deliverable=Business Owner=<value>')"* ]]
  [[ "$output" == *"(answer with --field-default 'PM=Deliverable=Program Increment=<value>')"* ]]
  [[ "$output" == *"choose one of: PI-2026-Q2, PI-2026-Q3"* ]]
}

@test "T050 — an entry recorded for a type the project no longer offers is orphaned" {
  local merged='{"Retired Type":{"Team":"Payments"}}'
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic"]' "${merged}" '["10101"]'
  [ "$(jq -r '.orphaned | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.orphaned[0].kind' <<< "$output")" = "orphaned_type" ]
}

@test "T050 — an entry recorded for a field the type no longer offers is orphaned" {
  local merged='{"Epic":{"Retired Field":"X"}}'
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic"]' "${merged}" '["10101"]'
  [ "$(jq -r '.orphaned | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.orphaned[0].kind' <<< "$output")" = "orphaned_label" ]
}

@test "T050 — an entry recorded for a type the bridge does not write is reported not yet consumed (FR-027)" {
  local merged='{"Story":{"Team":"Payments"}}'
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic","Story"]' "${merged}" '["10101"]'
  [ "$(jq -r '.not_yet_consumed | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.not_yet_consumed[0].type' <<< "$output")" = "Story" ]
}

@test "T050 — a normal recorded entry for a bridge-written type is neither orphaned nor not-yet-consumed" {
  local merged='{"Epic":{"Business Owner":"Platform Team"}}'
  run _config_field_default_report "${ITYPES}" "${DEFAULTABLE}" '["Epic"]' "${merged}" '["10101"]'
  [ "$(jq -r '.orphaned | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.not_yet_consumed | length' <<< "$output")" -eq 0 ]
}

# --- T038 — an optional defaultable field is never asked about, but an -----
# --- answer for it is still validated and carried forward (FR-002/FR-004) --

@test "T038 — an optional defaultable field never appears in the pending question" {
  local optional_df='{"10101":[
    {"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]},
    {"logical_name":"Slack Channel","field_id":"customfield_40099","schema_type":"string","required":false,"defaultable":true,"allowed_values":[]}
  ]}'
  run _config_field_default_report "${ITYPES}" "${optional_df}" '["Epic"]' '{}' '["10101"]'
  [ "$(jq -r '.pending | map(.label) | join(",")' <<< "$output")" = "Business Owner" ]
}

@test "T038 — an answer given for an optional defaultable field is validated and merged" {
  local optional_df='{"10101":[
    {"logical_name":"Slack Channel","field_id":"customfield_40099","schema_type":"string","required":false,"defaultable":true,"allowed_values":[]}
  ]}'
  local answers='[{"type":"Epic","label":"Slack Channel","value":"#platform"}]'
  run _config_field_default_answer_problems "${ITYPES}" "${optional_df}" "${answers}"
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
  run _config_field_default_merge '{}' "${answers}"
  [ "$(jq -r '.Epic."Slack Channel"' <<< "$output")" = "#platform" ]
}

# --- End-to-end: the full ceremony against the mock (T035/T037 spirit) ------

setup_e2e() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-field-defaults"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${WORK}/.specify"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mock_start "${MOCK}/configs/field-defaults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown_e2e() {
  mock_stop
  rm -rf "${WORK}"
}

@test "E2E — recording both required fields via --field-default writes the managed region and satisfies the gate" {
  setup_e2e
  run cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.field_defaults.status' <<< "$output")" = "written" ]
  grep -qF 'spec-kit-jira:field_defaults:begin' "${JIRA_CONFIG_DIR}/config.yml"
  grep -qF '"Business Owner": "Platform Team"' "${JIRA_CONFIG_DIR}/config.yml"
  teardown_e2e
}

@test "E2E — a second run with no new answers reports unchanged and leaves config.yml byte-identical (FR-007)" {
  setup_e2e
  cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
  cp "${JIRA_CONFIG_DIR}/config.yml" "${WORK}/before.yml"
  run cmd_config config FD --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.field_defaults.status' <<< "$output")" = "unchanged" ]
  run cmp "${WORK}/before.yml" "${JIRA_CONFIG_DIR}/config.yml"
  [ "$status" -eq 0 ]
  teardown_e2e
}

@test "T038/FR-009 — degraded mode asks nothing and writes nothing" {
  setup_e2e
  local before; before="$(cat "${JIRA_CONFIG_DIR}/config.yml")"
  unset SPEC_KIT_JIRA_BASE_URL
  run --separate-stderr cmd_config config FD --field-default 'FD=Deliverable=Business Owner=Platform Team' --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects | has("field_defaults")' <<< "$output")" = "false" ]
  [ "$(cat "${JIRA_CONFIG_DIR}/config.yml")" = "${before}" ]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  teardown_e2e
}

@test "T041a — a credential-shaped --field-default is refused before any splice; config.yml is byte-for-byte unchanged and the value never appears in output (FR-024, Principle IV)" {
  setup_e2e
  printf 'projects:\n  - key: FD\n    style: company_managed\n    hierarchy:\n      specification: Deliverable\n      story: Story\nrouting_default: FD\n' > "${JIRA_CONFIG_DIR}/config.yml"
  local before; before="$(cat "${JIRA_CONFIG_DIR}/config.yml")"
  run --separate-stderr cmd_config config FD --field-default 'FD=Deliverable=Business Owner=person@example.com' --json
  [ "$status" -eq 4 ]
  [ "$(cat "${JIRA_CONFIG_DIR}/config.yml")" = "${before}" ]
  [[ "${stderr}" == *"Business Owner"* ]]
  [[ "${stderr}" != *"person@example.com"* ]]
  ! grep -qF 'person@example.com' "${JIRA_CONFIG_DIR}/config.yml"
  teardown_e2e
}

@test "T041c — a hand-written entry for an opted-in type survives a run that answers only the required fields of the written types" {
  setup_e2e
  cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
  # Simulate a hand edit within the managed region: an entry for a type
  # this run never names via --field-default.
  local path="${JIRA_CONFIG_DIR}/config.yml"
  local hand_edited_map
  hand_edited_map='{"FD":{"ask":true,"Deliverable":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q3"},"Story":{"Team":"Payments"}}}'
  _config_field_defaults_write "${path}" "${hand_edited_map}" "false" > /dev/null
  run cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --json
  [ "$status" -eq 0 ]
  grep -qF '"Team": "Payments"' "${path}"
  teardown_e2e
}

@test "T041c — an entry written outside the managed region is refused as a duplicate top-level key, with zero writes" {
  setup_e2e
  cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
  local path="${JIRA_CONFIG_DIR}/config.yml"
  printf '\nfield_defaults:\n  FD:\n    ask: true\n' >> "${path}"
  local before; before="$(cat "${path}")"
  run cmd_config config FD --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"duplicate key"* ]]
  [ "$(cat "${path}")" = "${before}" ]
  teardown_e2e
}

@test "E2E — with nothing recorded and no answer, the ceremony still refuses — via the pre-existing, unchanged mandatory-field/parent-link gate (plan.md Summary), not field_defaults' own pending report" {
  # field_defaults' own "pending question" report is non-blocking (contract
  # §6). The OLDER structural gate (T050/T051, "pulled to configuration
  # time"), unchanged by this feature beyond gaining recorded defaults as a
  # satisfier, still refuses here because nothing was recorded — the same
  # refusal it has always produced, now defaults-aware.
  setup_e2e
  run cmd_config config FD --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"Business Owner"* ]]
  [[ "$output" == *"Program Increment"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  teardown_e2e
}
