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

# --- adopt at maximum verbosity (003 T142, FR-025, NFR-3) --------------------

# adopt_corpus — a labelled corpus plus the adoption fixture, so the whole
# discovery/classify/apply path runs for real rather than short-circuiting.
adopt_corpus() {
  printf '%s' '{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
    "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
    "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
    "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
    "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
    "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}'
}

adopt_workdir() {
  local w
  w="$(mktemp -d)"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-adoption/." "${w}/"
  printf '%s' "${w}"
}

@test "the token never appears in a full adopt at max verbosity under set -x (T142)" {
  mock_start_json "$(adopt_corpus)"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" SPEC_KIT_JIRA_REPO="acme/app"
  local wd out
  wd="$(adopt_workdir)"
  out="$( (cd "${wd}" && bash -x "${ENTRY_BASH}" adopt --yes --verbose --json) 2>&1 || true )"
  rm -rf "${wd}"
  run grep -c "RAWSECRETXYZ0123456789" <<< "${out}"
  [ "$output" = "0" ]
}

@test "the site host never appears in adopt output at any verbosity (FR-025)" {
  mock_start_json "$(adopt_corpus)"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" SPEC_KIT_JIRA_REPO="acme/app"
  local wd out
  wd="$(adopt_workdir)"
  # stdout + stderr WITHOUT the xtrace: the trace legitimately shows the URL it
  # is about to request, but nothing the operator sees may carry the host.
  out="$( (cd "${wd}" && bash "${ENTRY_BASH}" adopt --yes --verbose --json) 2>&1 || true )"
  rm -rf "${wd}"
  run grep -c "${MOCK_BASE_URL}" <<< "${out}"
  [ "$output" = "0" ]
  run grep -c "127.0.0.1" <<< "${out}"
  [ "$output" = "0" ]
}

@test "the prose adopt output carries no credential and no host either (FR-025)" {
  mock_start_json "$(adopt_corpus)"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" SPEC_KIT_JIRA_REPO="acme/app"
  local wd out
  wd="$(adopt_workdir)"
  out="$( (cd "${wd}" && bash "${ENTRY_BASH}" adopt --dry-run --verbose) 2>&1 || true )"
  rm -rf "${wd}"
  [[ "${out}" == *"Adoption plan"* ]]
  run grep -c -e "RAWSECRETXYZ0123456789" -e "127.0.0.1" -e "user@example.com" <<< "${out}"
  [ "$output" = "0" ]
}

@test "a refusal message carries no credential and no host (FR-025)" {
  # Refusal messages name spec folders and issue keys — and nothing else.
  mock_start_json '{"projects":{"ADO":"company"},"issues":{
    "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" SPEC_KIT_JIRA_REPO="acme/app"
  local wd out
  wd="$(adopt_workdir)"
  out="$( (cd "${wd}" && bash "${ENTRY_BASH}" adopt --yes --verbose --json) 2>&1 || true )"
  rm -rf "${wd}"
  [[ "${out}" == *"several-candidates"* ]]
  run grep -c -e "RAWSECRETXYZ0123456789" -e "127.0.0.1" <<< "${out}"
  [ "$output" = "0" ]
}
