#!/usr/bin/env bats
# T043a/T044 [US1] — Now that the task tier ships (012), a recorded field
# default for the task role's type is CONSUMED by the bridge, not merely
# recorded: the ceremony's §2.8 "recorded, not yet consumed" report (FR-027)
# must stop naming it (FR-012), and the §7.4 "not mirrored yet" status line
# must stop firing at all.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-field-defaults"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"

  WORK="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${WORK}/.specify"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  mock_start "${MOCK}/configs/field-defaults.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  printf 'projects:\n  - key: FD\n    style: company_managed\n    hierarchy:\n      specification: Deliverable\n      story: Story\n      task: "Sub-task"\nrouting_default: FD\n' > "${JIRA_CONFIG_DIR}/config.yml"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

@test "a task role declared: a recorded field default for its type is never reported not-yet-consumed (012, FR-012)" {
  run cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --field-default 'FD=Sub-task=T-Shirt Estimate=5' \
    --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"recorded, not yet consumed"* ]]
}

@test "a declared task role no longer emits the §7.4 'not mirrored yet' note (012, FR-012)" {
  run cmd_config config FD \
    --field-default 'FD=Deliverable=Business Owner=Platform Team' \
    --field-default 'FD=Deliverable=Program Increment=PI-2026-Q3' \
    --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"is not mirrored yet"* ]]
}
