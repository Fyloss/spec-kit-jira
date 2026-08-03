#!/usr/bin/env bats
# T005 [Phase 2, 011] — defaultable-field extraction (research R3, contract §2.1,
# data-model.md §2). `_disc_defaultable_fields` reads a createmeta type payload's
# `fields` array and reports, for every field the bridge does not itself supply,
# whether it can be expressed as a recorded config value — required AND optional
# fields alike, since FR-004 lets an operator record a default for an optional
# field too.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
}

@test "carries logical_name, field_id, schema_type, required, defaultable, allowed_values for a required scalar field" {
  local fields='[{"fieldId":"customfield_40012","name":"Program Increment","required":true,"schema":{"type":"string"}}]'
  run _disc_defaultable_fields "${fields}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].logical_name' <<< "$output")" = "Program Increment" ]
  [ "$(jq -r '.[0].field_id' <<< "$output")" = "customfield_40012" ]
  [ "$(jq -r '.[0].schema_type' <<< "$output")" = "string" ]
  [ "$(jq -r '.[0].required' <<< "$output")" = "true" ]
  [ "$(jq -r '.[0].defaultable' <<< "$output")" = "true" ]
  [ "$(jq -r '.[0].allowed_values' <<< "$output")" = "[]" ]
}

@test "carries the same shape for an OPTIONAL field — never filtered out by requiredness (FR-004)" {
  local fields='[{"fieldId":"customfield_50001","name":"Team","required":false,"schema":{"type":"string"}}]'
  run _disc_defaultable_fields "${fields}"
  [ "$(jq -r '.[0].required' <<< "$output")" = "false" ]
  [ "$(jq -r '.[0].defaultable' <<< "$output")" = "true" ]
}

@test "an enumerated field carries its allowed values, by the value Jira presents" {
  local fields='[{"fieldId":"customfield_40012","name":"Program Increment","required":true,"schema":{"type":"option"},"allowedValues":[{"value":"PI-2026-Q2"},{"value":"PI-2026-Q3"}]}]'
  run _disc_defaultable_fields "${fields}"
  [ "$(jq -r '.[0].allowed_values | join(",")' <<< "$output")" = "PI-2026-Q2,PI-2026-Q3" ]
}

@test "an allowed value keyed by name (not value) still resolves (priority-shaped enums)" {
  local fields='[{"fieldId":"customfield_1","name":"Severity","required":false,"schema":{"type":"option"},"allowedValues":[{"name":"Critical"},{"name":"Medium"}]}]'
  run _disc_defaultable_fields "${fields}"
  [ "$(jq -r '.[0].allowed_values | join(",")' <<< "$output")" = "Critical,Medium" ]
}

@test "a shape that cannot be a scalar (attachment, array-typed) is reported undefaultable with a reason, never offered (FR-010)" {
  local fields='[{"fieldId":"attachment","name":"Attachment","required":true,"schema":{"type":"array"}}]'
  run _disc_defaultable_fields "${fields}"
  [ "$(jq -r '.[0].defaultable' <<< "$output")" = "false" ]
  [ "$(jq -r '.[0].undefaultable_reason | length > 0' <<< "$output")" = "true" ]
  [ "$(jq -r 'has("undefaultable_reason")' <<< "$(jq -c '.[0]' <<< "$output")")" = "true" ]
}

@test "a defaultable field carries NO undefaultable_reason key at all" {
  local fields='[{"fieldId":"customfield_1","name":"Team","required":false,"schema":{"type":"string"}}]'
  run _disc_defaultable_fields "${fields}"
  [ "$(jq -r '.[0] | has("undefaultable_reason")' <<< "$output")" = "false" ]
}

@test "the bridge-supplied fields never appear — they are not candidates for a default" {
  local fields='[{"fieldId":"summary","name":"Summary","required":true,"schema":{"type":"string"}},{"fieldId":"description","name":"Description","required":false,"schema":{"type":"doc"}},{"fieldId":"issuetype","name":"Issue Type","required":true,"schema":{"type":"issuetype"}},{"fieldId":"project","name":"Project","required":true,"schema":{"type":"project"}},{"fieldId":"priority","name":"Priority","required":false,"schema":{"type":"priority"}},{"fieldId":"reporter","name":"Reporter","required":false,"schema":{"type":"user"}},{"fieldId":"parent","name":"Parent","required":false,"schema":{"type":"issuelink"}}]'
  run _disc_defaultable_fields "${fields}"
  [ "$output" = "[]" ]
}

@test "a 'user' field IS defaultable — the bridge simply sends what was recorded" {
  local fields='[{"fieldId":"customfield_40011","name":"Business Owner","required":true,"schema":{"type":"user"}}]'
  run _disc_defaultable_fields "${fields}"
  [ "$(jq -r '.[0].defaultable' <<< "$output")" = "true" ]
}

@test "discover_binding emits defaultable_fields keyed by issue-type id, alongside required_fields unchanged" {
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run discover_binding PM
  [ "$status" -eq 0 ]
  [ "$(jq -r '.defaultable_fields."10101" | length' <<< "$output")" -gt 0 ]
  [ "$(jq -r '.defaultable_fields."10101"[] | select(.field_id=="customfield_40011") | .logical_name' <<< "$output")" = "Business Owner" ]
  # required_fields is untouched by this feature.
  [ "$(jq -r '.required_fields."10101" | length' <<< "$output")" -eq 3 ]
  mock_stop
}

@test "discovery_type_metadata emits defaultable_fields for the fetched type" {
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run discovery_type_metadata PM 10101
  [ "$status" -eq 0 ]
  [ "$(jq -r '.defaultable_fields | length' <<< "$output")" -gt 0 ]
  mock_stop
}
