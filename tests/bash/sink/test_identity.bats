#!/usr/bin/env bats
# T057 [US3] — Ticket identity marker (entity property, research §5). Identity is
# a server-side entity property (never a user-editable label, Constitution II),
# recording origin + spec ref and surviving spec-folder renames. Reads distinguish
# an unclaimed ticket (404 => no identity) from a fail-closed error. The
# discriminator for claimed-by-other (US10/FR-051) is the recorded spec ref.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/identity.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

SPEC_A='{"repo":"acme/app","spec_slug":"001-feature-a","folder":"specs/001-feature-a"}'
SPEC_B='{"repo":"acme/app","spec_slug":"002-feature-b","folder":"specs/002-feature-b"}'

# --- Pure marker + claim logic ---------------------------------------------

@test "identity_marker records origin and the spec ref" {
  run identity_marker "${SPEC_A}" bridge-created
  [ "$status" -eq 0 ]
  [ "$(jq -r '.origin' <<< "$output")" = "bridge-created" ]
  [ "$(jq -r '.spec_slug' <<< "$output")" = "001-feature-a" ]
  [ "$(jq -r '.repo' <<< "$output")" = "acme/app" ]
}

@test "identity_claimed_by_other is true for a different spec, false for the same" {
  local marker
  marker="$(identity_marker "${SPEC_A}" bridge-created)"
  run identity_claimed_by_other "${marker}" "${SPEC_B}"
  [ "$status" -eq 0 ]   # claimed by another spec
  run identity_claimed_by_other "${marker}" "${SPEC_A}"
  [ "$status" -ne 0 ]   # same spec => not claimed by other
}

# --- Transport-backed read / write -----------------------------------------

@test "identity_read on an unclaimed ticket returns empty (404 is not a failure)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run identity_read ABC-1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "identity_write stamps the marker via an entity property (PUT)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run identity_write ABC-1 "${SPEC_A}" bridge-created
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"PUT /rest/api/3/issue/ABC-1/properties/spec-kit-jira"* ]]
}

# --- Cross-port parity ------------------------------------------------------

@test "the PowerShell port builds an identical marker (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(identity_marker "${SPEC_A}" human)"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_SINK}/Identity.psm1' -Force; [Console]::Out.Write((Get-JiraIdentityMarker -SpecRefJson '${SPEC_A}' -Origin 'human'))")"
  [ "${b}" = "${p}" ]
}
