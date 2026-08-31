#!/usr/bin/env bats
# T014 [Phase 2, 036] — the artifact privacy sweep is wired into the reconcile,
# and it sits BEFORE every Jira write
# (036 contracts/artifact-publication.md C5.1, C5.3, C5.5; FR-016).
#
# The unit-level cases in tests/bash/sink/test_privacy_guard_artifacts.bats
# prove the scan finds the shapes. These prove the only thing they cannot: that
# the run is stopped early enough for the finding to matter.
#
# C5.5 states the assertion precisely, and it is NOT "the upload was refused":
# publication runs after the description and story writes, so a guard beside the
# upload would leave those already written. The assertion is that the ticket was
# never touched — ZERO calls of EVERY write kind on the mock's own call log,
# which is what the run did rather than what its summary says it did.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  FEATURE_DIR="${WORK}/specs/001-billing-invoices"
  SPEC="${FEATURE_DIR}/spec.md"

  # The artifact set is `git ls-files` over the feature directory (research R5),
  # so the fixture has to be a repository — which every consumer tree is.
  git -C "${WORK}" init --quiet
  git -C "${WORK}" config user.email 'fixture@example.invalid'
  git -C "${WORK}" config user.name 'fixture'

  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_HOOK_CONTEXT SPEC_KIT_JIRA_BASE_URL
}

# Every write kind the sink can perform, as it appears in the mock's call log.
_write_calls() {
  mock_calls | grep -cE '^(POST|PUT|DELETE) ' || true
}

@test "C5.5 a blocked shape in research.md leaves the ticket entirely untouched" {
  printf '# Research\n\nsee https://acme-real.atlassian.net/browse/X-1\n' > "${FEATURE_DIR}/research.md"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 9 ]

  # The assertion that matters. Not "no attachment was uploaded" — no CREATE,
  # no UPDATE, no TRANSITION, nothing. The reconcile's own writes are included,
  # which is only possible because the sweep runs before them (C5.1).
  [ "$(_write_calls)" -eq 0 ]
}

@test "C5.3 the refusal names the artifact and the shape, never the value" {
  printf '# Research\n\ntoken ATATTsecretvalue00099\n' > "${FEATURE_DIR}/research.md"

  run cmd_reconcile reconcile "${SPEC}"
  [ "$status" -eq 9 ]
  [[ "$output" == *"research.md"* ]]
  [[ "$output" == *"ATATT prefix"* ]]
  ! grep -q 'ATATTsecretvalue00099' <<< "${output}"
  [ "$(_write_calls)" -eq 0 ]
}

@test "C5.2 a blocked shape inside a BINARY artifact stops the run just the same" {
  mkdir -p "${FEATURE_DIR}/assets"
  printf '\x89PNG\r\n\x1a\n' > "${FEATURE_DIR}/assets/diagram.png"
  printf 'ATATTdeadbeef99\n' >> "${FEATURE_DIR}/assets/diagram.png"

  run cmd_reconcile reconcile "${SPEC}"
  [ "$status" -eq 9 ]
  [[ "$output" == *"assets/diagram.png"* ]]
  [ "$(_write_calls)" -eq 0 ]
}

@test "C5.1 dry-run refuses on the same finding — a dry-run that lies is worse than none" {
  printf '# Research\n\nsee https://acme-real.atlassian.net/browse/X-1\n' > "${FEATURE_DIR}/research.md"

  run cmd_reconcile reconcile "${SPEC}" --dry-run
  [ "$status" -eq 9 ]
  [ "$(_write_calls)" -eq 0 ]
}

@test "C5.3 a clean feature directory is unaffected — the sweep gates nothing it should not" {
  printf '# Research\n\nnothing sensitive here at all.\n' > "${FEATURE_DIR}/research.md"

  run cmd_reconcile reconcile "${SPEC}" --json
  # Whatever this fixture's ordinary outcome is, it is NOT the privacy refusal.
  [ "$status" -ne 9 ]
  ! grep -q 'blocked shape' <<< "${output}"
}

@test "FR-053 an allowlisted host in an artifact does not stop the run" {
  printf '# Research\n\nsee https://acme-real.atlassian.net/wiki/x\n' > "${FEATURE_DIR}/research.md"
  export SPEC_KIT_JIRA_ALLOWLIST='["acme-real.atlassian.net"]'

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -ne 9 ]
  unset SPEC_KIT_JIRA_ALLOWLIST
}

@test "Constitution III the refusal still never fails the host command in hook context" {
  printf '# Research\n\ntoken ATATTabc123XYZ\n' > "${FEATURE_DIR}/research.md"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile "${SPEC}"
  # Non-blocking on hooks: the bridge returns success and warns once, and the
  # write count is still zero.
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [ "$(_write_calls)" -eq 0 ]
}
