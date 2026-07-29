#!/usr/bin/env bats
# T039 [US4] — Per-project priority availability (research R4, FR-030/FR-031):
# `discover_binding` derives `priorities` from the resolved project's OWN
# create metadata against the site-wide identifier catalogue, never from the
# catalogue alone. Three branches, matching the repository's own mock fixtures.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  FIX="${ROOT}/tests/conformance/mock-jira/fixtures"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/discovery.sh"
  CATALOGUE='[{"id":"1","name":"Critical"},{"id":"2","name":"High"},{"id":"3","name":"Medium"},{"id":"4","name":"Low"}]'
}

@test "branch 1 — priority field absent from create metadata yields {} (empty)" {
  local fields
  fields="$(jq -c '.fields' "${FIX}/createmeta-fields-team.json")"
  run discovery_priorities_for_project "${fields}" "${CATALOGUE}"
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<< "$output")" = "[]" ]
}

@test "branch 2 — priority field WITH allowedValues yields only those, resolved against the catalogue" {
  local fields
  fields="$(jq -c '.fields' "${FIX}/createmeta-fields-company-allowed.json")"
  run discovery_priorities_for_project "${fields}" "${CATALOGUE}"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'sort_by(.id)' <<< "$output")" = "$(jq -cS 'sort_by(.id)' <<< '[{"logical_name":"Critical","id":"1"},{"logical_name":"Medium","id":"3"}]')" ]
}

@test "branch 3 — priority field WITHOUT allowedValues yields the site-wide catalogue (today's behaviour)" {
  local fields
  fields="$(jq -c '.fields' "${FIX}/createmeta-fields-company.json")"
  run discovery_priorities_for_project "${fields}" "${CATALOGUE}"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'sort_by(.id)' <<< "$output")" = "$(jq -cS 'sort_by(.id)' <<< "${CATALOGUE}" | jq -c 'map({logical_name:.name, id:.id})' | jq -cS 'sort_by(.id)')" ]
}
