#!/usr/bin/env bats
# T019/T020 — the portable cause-detector for the oversized-argument defect
# (contracts/argument-size.md §3 A3.1-A3.4).
#
# tests/bash/commands/test_reconcile_large_spec.bats already proves a large
# specification reconciles — but it does so by detecting the SYMPTOM (`exec`
# failing with E2BIG), which only Linux enforces. Its own header says it
# "passes on macOS whether or not the defect is present": the maintainer's
# own development machine gets no signal from it at all.
#
# This test measures the CAUSE instead — the byte length of every argument
# any call site produces during a whole run, against Linux's MAX_ARG_STRLEN
# (128 KiB, inclusive — 131072 bytes exactly already fails, see A2.4) — so the
# verdict is the same on macOS, Linux and Windows. It is
# the portable complement to the existing end-to-end proof, not a
# replacement: that test remains the proof reconcile succeeds on Linux;
# this one is the proof nothing oversized was ever routed through argv, on
# every host.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  ENGINE="${ROOT}/scripts/bash/engine"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # shellcheck source=/dev/null
  source "${HELPERS}/spec_fixture.bash"
  # shellcheck source=/dev/null
  source "${HELPERS}/argv_size.bash"
}

teardown() {
  mock_stop 2> /dev/null || true
}

@test "a 100-story specification reconciles with no single argument reaching 128 KiB, on this host" {
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
  helper_make_spec "${BATS_TEST_TMPDIR}/large" 100 unbound 0
  local spec="${BATS_TEST_TMPDIR}/large/spec.md"

  local shim_dir="${BATS_TEST_TMPDIR}/argv_shim" report="${BATS_TEST_TMPDIR}/argv_report.log"
  helper_argv_size_setup "${shim_dir}" "${report}"

  PATH="${shim_dir}:${PATH}" run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 101 ]
  [ ! -s "${report}" ]
}

# `tasks_parse_document`'s own `tasks` array (engine/tasks_parse.sh) is a
# SECOND, independent json_build call site — its own comment already names
# it ("024, T053 real-machine finding: `tasks` grows with task count").
# Covered directly, unit-style (matching test_plan_apply_spawn_budget.bats'
# existing shape), rather than through a whole reconcile: no mock, no
# project binding, no story content is relevant to what this call site does.
@test "a large tasks.md parses with no single argument reaching 128 KiB" {
  local shim_dir="${BATS_TEST_TMPDIR}/argv_shim2" report="${BATS_TEST_TMPDIR}/argv_report2.log"
  helper_argv_size_setup "${shim_dir}" "${report}"

  PATH="${shim_dir}:${PATH}" run bash -c '
    source "'"${ENGINE}"'/tasks_parse.sh"
    n=700
    for ((i = 1; i <= n; i++)); do
      printf -- "- [ ] T%04d [US1] Task number %d: a moderately long task description so the accumulated tasks array crosses the 128 KiB single-argument threshold once enough of them are present\n" "${i}" "${i}"
    done | tasks_parse_document > /dev/null
  '
  [ "${status}" -eq 0 ]
  [ ! -s "${report}" ]
}
