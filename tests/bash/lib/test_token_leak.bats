#!/usr/bin/env bats
# T092 — Dedicated SC-007 leak test (ELIMINATORY NFR-3). Drives a FULL command
# end-to-end at MAXIMUM verbosity — the whole dispatcher under `bash -x` with
# --verbose — and asserts the resolved token never appears in stdout, stderr, an
# error message, or the xtrace, on either port. This is the belt-and-braces
# complement to the unit-level credential trace test (test_credentials.bats).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENTRY_BASH="${ROOT}/scripts/bash/spec-kit-jira.sh"
  ENTRY_PWSH="${ROOT}/scripts/powershell/spec-kit-jira.ps1"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  WORK="$(mktemp -d)"
  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Leak Guard' '' 'A spec that mirrors to Jira.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ0123456789"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_PROJECT_KEY="PROJ"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

@test "the token never appears in a full reconcile at max verbosity under set -x (SC-007)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # `bash -x` traces every command to stderr; --verbose asks for maximal output.
  # 2>&1 folds the xtrace, diagnostics, and errors into one captured stream.
  local out
  out="$(bash -x "${ENTRY_BASH}" reconcile --verbose --json "${SPEC}" 2>&1 || true)"
  run grep -c "RAWSECRETXYZ0123456789" <<< "${out}"
  [ "$output" = "0" ]
}

@test "the token never appears on the PowerShell port at max verbosity (SC-007, NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local out
  out="$(pwsh -NoProfile -File "${ENTRY_PWSH}" reconcile --verbose --json "${SPEC}" 2>&1 || true)"
  run grep -c "RAWSECRETXYZ0123456789" <<< "${out}"
  [ "$output" = "0" ]
}
