#!/usr/bin/env bats
# T003 — Guard for tests/bash/helpers/spec_fixture.bash. A fixture generator
# that silently emits unrecognised markers, or the wrong number of tasks,
# would make a scenario built on it measure the wrong thing while still
# looking green — this is the self-test that rules that out.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/scripts/bash/engine"
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/spec_fixture.bash"
  # shellcheck source=/dev/null
  source "${ENGINE}/parse.sh"
  # shellcheck source=/dev/null
  source "${ENGINE}/tasks_parse.sh"
  WORK="${BATS_TEST_TMPDIR}/fixture"
}

@test "a bound document parses to the expected story count with every story recognised" {
  helper_make_spec "${WORK}/bound" 5 bound 0
  local stories n_stories n_bound
  stories="$(parse_spec "widget" < "${WORK}/bound/spec.md")"
  n_stories="$(jq '.stories | length' <<< "${stories}")"
  n_bound="$(jq '[.stories[] | select(.marker.state == "bound")] | length' <<< "${stories}")"
  [ "${n_stories}" = "5" ]
  [ "${n_bound}" = "5" ]
}

@test "an unbound document parses to the same story count with none recognised" {
  helper_make_spec "${WORK}/unbound" 5 unbound 0
  local stories n_stories n_bound
  stories="$(parse_spec "widget" < "${WORK}/unbound/spec.md")"
  n_stories="$(jq '.stories | length' <<< "${stories}")"
  n_bound="$(jq '[.stories[] | select(.marker.state == "bound")] | length' <<< "${stories}")"
  [ "${n_stories}" = "5" ]
  [ "${n_bound}" = "0" ]
}

@test "the task count is story-count times tasks-per-story" {
  helper_make_spec "${WORK}/tasked" 4 unbound 3
  local tasks n_tasks
  tasks="$(tasks_parse_document < "${WORK}/tasked/tasks.md")"
  n_tasks="$(jq '.tasks | length' <<< "${tasks}")"
  [ "${n_tasks}" = "12" ]
}

@test "tasks-per-story 0 writes no tasks.md at all" {
  helper_make_spec "${WORK}/notasks" 3 unbound 0
  [ ! -f "${WORK}/notasks/tasks.md" ]
}
