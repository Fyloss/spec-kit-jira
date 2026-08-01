#!/usr/bin/env bats
# T012 [Phase 1, defect 4] — `discover_binding` fetches create metadata for
# `.issueTypes[0].id` — whichever type the project happened to list first —
# once, and never for a second issue type. On the (unambiguous) SAFe fixture
# that first type is "Epic" (10401), which is neither the parent type this
# feature writes (Feature, 10402) nor the child type (Story, 10403). RED
# until Phase 2 (T017/T018) fetches per written type.
#
# T017/T019 [Phase 2] extend this file with the per-type fetch and the
# parent-link-availability tests once discovery reads it from metadata.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

@test "fetches create metadata for each written issue type, not just the first" {
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  discover_binding SAFE > /dev/null

  run mock_calls
  # Today's defect: only the arbitrary first type (Epic, 10401) is ever
  # fetched — never the parent (Feature, 10402) or the child (Story, 10403).
  [ "$(grep -c '^GET /rest/api/3/issue/createmeta/SAFE/issuetypes/10402$' <<< "$output")" -ge 1 ]
  [ "$(grep -c '^GET /rest/api/3/issue/createmeta/SAFE/issuetypes/10403$' <<< "$output")" -ge 1 ]
}

@test "records required_fields keyed by issue-type id, naming fields by their Jira name (T017)" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # PM's child level (0) holds two candidates (Story, Defect) — genuinely
  # ambiguous, so only the unambiguous parent level (1: Deliverable, 10101)
  # is resolvable without the ceremony. required_fields is keyed on what
  # discovery could actually resolve at this point (research R1/R2).
  run discover_binding PM
  [ "$status" -eq 0 ]
  [ "$(jq -r '.required_fields."10101" | length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '.required_fields."10101"[] | select(.field_id=="customfield_40011") | .logical_name' <<< "$output")" = "Business Owner" ]
  # Never a customfield_NNNNN id in place of the name.
  [[ "$(jq -r '[.required_fields[][].logical_name] | join(",")' <<< "$output")" != *customfield* ]]
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

@test "reports whether a type's create metadata offers a parent field — read, never assumed (T019)" {
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run discover_binding SAFE
  [ "$status" -eq 0 ]
  # createmeta-fields-safe.json declares a "parent" field for every type it serves.
  [ "$(jq -r '.parent_link_available."10403"' <<< "$output")" = "true" ]
}

@test "a type whose create metadata offers no parent field is reported false, never assumed true" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # createmeta-fields-parent-mandatory.json (PM's parent type, 10101) declares
  # no "parent" field at all.
  run discover_binding PM
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent_link_available."10101"' <<< "$output")" = "false" ]
}
