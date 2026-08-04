#!/usr/bin/env bats
# T043a [US1] — §7.4's "task recorded, not mirrored yet" note is gone from
# hierarchy.sh now that the task tier ships (012, FR-012). A reintroduction
# of `role_task_recorded_note` would be a regression: the note would once
# again claim sub-tasks are not created, which is now false.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/hierarchy.sh"
}

@test "role_task_recorded_note no longer exists — the §7.4 note is retired, not merely unused" {
  run declare -f role_task_recorded_note
  [ "$status" -ne 0 ]
}
