#!/usr/bin/env bats
# T006 [US1] — The target guard (contracts/target-guard.md §5 T1–T6, T10–T12):
# only a feature folder's own spec.md is ever mirrored. A target whose file
# name is not spec.md refuses before any configuration read, any network call
# and any file write; the message names the sibling spec.md when one exists.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"

  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-target"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004","parent_type_id":"10101"}'
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
  unset SPEC_KIT_JIRA_HOOK_EVENT

  mkdir -p "${WORK}/specs/001-test-page"
  SPEC="${WORK}/specs/001-test-page/spec.md"
  printf '%s\n' \
    '# Feature Specification: Target Guard' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${SPEC}"
  PLAN="${WORK}/specs/001-test-page/plan.md"
  printf '%s\n' 'Some plan content.' > "${PLAN}"

  mock_start '{}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # Credentials so the duplicate probe (017, US4) reaches the mock and
  # verdicts "clear" instead of degrading to "unavailable" — this file
  # tests the target guard, not the probe's own degradation path.
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

@test "reconcile plan.md refuses before any request, exit 1, plan.md untouched (§5 T1, T2)" {
  local before after
  before="$(cat "${PLAN}")"
  run cmd_reconcile reconcile --json "${PLAN}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a feature specification"* ]]
  [[ "$output" == *"\"${PLAN}\""* ]]
  [[ "$output" == *"the target for this folder is \"${SPEC}\""* ]]
  [ -z "$(mock_calls)" ]
  after="$(cat "${PLAN}")"
  [ "${before}" = "${after}" ]
}

@test "every non-spec.md sibling artifact refuses (§5 T3)" {
  local name
  for name in tasks.md research.md data-model.md quickstart.md spec.md.bak my-spec.md; do
    printf 'content\n' > "${WORK}/specs/001-test-page/${name}"
    run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page/${name}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a feature specification"* ]]
  done
}

@test "contracts/api.md refuses — no spec.md in that folder (§5 T3)" {
  mkdir -p "${WORK}/specs/001-test-page/contracts"
  printf 'content\n' > "${WORK}/specs/001-test-page/contracts/api.md"
  run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page/contracts/api.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a feature specification"* ]]
  [[ "$output" == *"no spec.md exists in that folder"* ]]
}

@test "SPEC.MD refuses — the comparison is case-sensitive (§5 T4)" {
  printf 'content\n' > "${WORK}/specs/001-test-page/SPEC.MD"
  run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page/SPEC.MD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a feature specification"* ]]
}

@test "under each of the six lifecycle events the refusal returns 0, wrapped (§5 T5, SC-001)" {
  local event
  for event in after_specify after_clarify after_plan after_tasks after_analyze after_implement; do
    export SPEC_KIT_JIRA_HOOK_CONTEXT=1
    export SPEC_KIT_JIRA_HOOK_EVENT="${event}"
    run cmd_reconcile reconcile --json "${PLAN}"
    [ "$status" -eq 0 ]
    [[ "$output" == "WARNING: "*"is not a feature specification"*"This spec-kit command completed normally."* ]]
    [ -z "$(mock_calls)" ]
  done
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
  unset SPEC_KIT_JIRA_HOOK_EVENT
}

@test "a disabled event silences even the rejected-target refusal (§5 T6, research R1)" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  config_hooks_disabled_add after_plan "${JIRA_CONFIG_DIR}" > /dev/null
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile --json "${PLAN}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(mock_calls)" ]
  unset SPEC_KIT_JIRA_HOOK_EVENT
}

@test "a valid spec.md run behaves exactly as before this feature (§5 T7)" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].role' <<< "$output")" = "parent" ]
  [ "$(jq 'has("warnings")' <<< "$output")" = "false" ]
}

@test "stray markers in plan.md produce one warning and plan.md stays untouched (§5 T9)" {
  printf '%s\n' 'Some plan content.' '<!-- speckit-jira spec=0123456789abcdef ticket=COMP-1 -->' > "${PLAN}"
  local before after
  before="$(cat "${PLAN}")"
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '(.warnings // []) | length' <<< "$output")" -ge 1 ]
  [[ "$(jq -r '(.warnings // []) | join(",")' <<< "$output")" == *"plan.md"* ]]
  after="$(cat "${PLAN}")"
  [ "${before}" = "${after}" ]
}

@test "--dry-run refuses identically to a real run (§5 T10)" {
  run cmd_reconcile reconcile --dry-run --json "${PLAN}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a feature specification"* ]]
  [ -z "$(mock_calls)" ]
}

@test "a directory target keeps today's readability message (§5 T11)" {
  run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a readable spec file argument is required"* ]]
  [[ "$output" != *"is not a feature specification"* ]]
}

@test "a non-existent path keeps today's readability message (§5 T11)" {
  run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page/nope.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a readable spec file argument is required"* ]]
  [[ "$output" != *"is not a feature specification"* ]]
}

@test "a symlink not named spec.md refuses even though it resolves to spec.md (§5 T11)" {
  ln -s "${SPEC}" "${WORK}/specs/001-test-page/renamed-link.md"
  run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page/renamed-link.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a feature specification"* ]]
}

@test "a path carrying trailing whitespace refuses (§5 T11)" {
  printf 'content\n' > "${WORK}/specs/001-test-page/spec.md "
  run cmd_reconcile reconcile --json "${WORK}/specs/001-test-page/spec.md "
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a feature specification"* ]]
}

@test "a symlink named spec.md passes the guard (§5 T12)" {
  mkdir -p "${WORK}/other"
  ln -s "${SPEC}" "${WORK}/other/spec.md"
  run cmd_reconcile reconcile --dry-run --json "${WORK}/other/spec.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"is not a feature specification"* ]]
}

@test "the relative spelling ./specs/001-test-page/spec.md passes the guard (§5 T12)" {
  cd "${WORK}"
  run cmd_reconcile reconcile --dry-run --json "./specs/001-test-page/spec.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"is not a feature specification"* ]]
}
