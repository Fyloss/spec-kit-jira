#!/usr/bin/env bats
# T010, T012 [Phase 2, Foundational] — the lifecycle context entry gains a
# `role`, and the phase->status map's two accepted shapes normalise to the
# per-role resolved form of data-model.md §1 (contract role-lifecycle-config.md
# §2/§4). T010 (every context entry's role matches the tier it was recognised
# at) and T014 (the whole existing safety corpus stays byte-identical once
# the context gains role) are proven by the two-role-workflow isolation test
# — tests/bash/commands/test_reconcile_lifecycle.bats's T078 — and by the
# full regression sweep this feature's every other phase already runs
# unchanged; this file covers the one piece those do not exercise directly:
# _reconcile_phase_status_map's own normalisation, in isolation.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
}

@test "T012 -- a role-blind mapping (every key a lifecycle event) resolves wholesale under 'story', the other two roles empty" {
  local cfg='{"projects":[{"key":"COMP","phase_status_map":{"after_specify":"To Do","after_plan":"In Progress"}}]}'
  local resolved; resolved="$(_reconcile_phase_status_map "COMP" "${cfg}")"
  [ "$(jq -r 'keys | sort | join(",")' <<< "${resolved}")" = "specification,story,task" ]
  [ "$(jq -c '.story' <<< "${resolved}")" = '{"after_plan":"In Progress","after_specify":"To Do"}' ]
  [ "$(jq -c '.specification' <<< "${resolved}")" = '{}' ]
  [ "$(jq -c '.task' <<< "${resolved}")" = '{}' ]
}

@test "T012 -- a per-role mapping (every key a hierarchy role) is used as-is, all three keys present" {
  local cfg='{"projects":[{"key":"COMP","phase_status_map":{"specification":{"after_specify":"Funnel"},"story":{"after_specify":"To Do"}}}]}'
  local resolved; resolved="$(_reconcile_phase_status_map "COMP" "${cfg}")"
  [ "$(jq -c '.specification' <<< "${resolved}")" = '{"after_specify":"Funnel"}' ]
  [ "$(jq -c '.story' <<< "${resolved}")" = '{"after_specify":"To Do"}' ]
  # task was never declared: present as an empty object, never absent.
  [ "$(jq -c '.task' <<< "${resolved}")" = '{}' ]
  [ "$(jq -e 'has("task")' <<< "${resolved}")" = "true" ]
}

@test "T012 -- a project declaring no phase_status_map at all resolves to all three roles empty" {
  local cfg='{"projects":[{"key":"COMP"}]}'
  local resolved; resolved="$(_reconcile_phase_status_map "COMP" "${cfg}")"
  [ "$(jq -c '.' <<< "${resolved}")" = '{"specification":{},"story":{},"task":{}}' ]
}
