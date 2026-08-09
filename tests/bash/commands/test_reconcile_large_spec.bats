#!/usr/bin/env bats
# A specification large enough to push a plan past Linux's per-argument limit
# must still reconcile.
#
# The write plan is handed between `jq` invocations as a command-line
# argument (`--argjson`). Linux caps a SINGLE argument at MAX_ARG_STRLEN —
# 32 pages, 128 KiB — independently of the much larger total ARG_MAX; macOS
# has no per-argument cap at all. A specification of roughly a hundred user
# stories assembles a plan of ~140 KB, so the exec fails with E2BIG on Linux
# while the identical run succeeds on macOS:
#
#   plan_apply.sh: /usr/bin/jq: Argument list too long
#   reconcile: the write plan could not be assembled (zero writes)
#
# This test therefore passes on macOS whether or not the defect is present.
# It is a Linux-only defect, and it is reproduced the way this project
# reproduces platform-specific divergence: on the real platform. See the
# fix's commit message for the docker invocation.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
}

teardown() {
  mock_stop 2> /dev/null || true
}

# _write_large_spec <path> <story-count> — a specification whose assembled
# plan exceeds 128 KiB. Each story carries the Given/When/Then triple the
# engine renders into both a bullet list and an Acceptance Criteria panel,
# which is what makes the per-story plan large enough to matter.
_write_large_spec() {
  local path="$1" count="$2" i
  {
    printf '%s\n' '# Feature Specification: Widget Management' ''
    printf '%s\n' 'We need to let users manage widgets end to end.' ''
    for ((i = 1; i <= count; i++)); do
      printf '### User Story %d - Story number %d (Priority: P1)\n\n' "${i}" "${i}"
      printf '%s\n' "As a user, I want outcome ${i}." ''
      printf '%s\n' '- **Given** a precondition' '- **When** I act' \
        "- **Then** outcome ${i} happens" ''
    done
  } > "${path}"
}

@test "a 100-story specification reconciles — the plan is not passed through argv (E2BIG on Linux)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-widget"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="COMP"
  export JIRA_CONFIG_DIR="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT

  mkdir -p "${BATS_TEST_TMPDIR}/large"
  local spec="${BATS_TEST_TMPDIR}/large/spec.md"
  _write_large_spec "${spec}" 100

  run cmd_reconcile reconcile "${spec}" --json
  # The defect's signature, named explicitly so a future failure is not
  # mistaken for an unrelated plan error.
  [[ "$output" != *"Argument list too long"* ]]
  [[ "$output" != *"the write plan could not be assembled"* ]]
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 101 ]
}
