#!/usr/bin/env bats
# T008 [US1] — The stray-marker scan (FR-007, research R9):
# marker_splice_stray_files finds marker-bearing siblings of a feature
# folder's spec.md, excludes spec.md itself, ignores subdirectories, returns
# sorted bare file names, and opens nothing for writing.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/marker_splice.sh"

  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a clean folder yields nothing" {
  printf 'no markers here\n' > "${WORK}/spec.md"
  printf 'no markers here either\n' > "${WORK}/plan.md"
  run marker_splice_stray_files "${WORK}"
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "finds a marker-bearing sibling and excludes spec.md" {
  printf '%s\n' '<!-- speckit-jira spec=0123456789abcdef ticket=COMP-1 -->' > "${WORK}/spec.md"
  printf '%s\n' 'some text' '<!-- speckit-jira story=abcdef0123456789 ticket=COMP-2 -->' > "${WORK}/plan.md"
  run marker_splice_stray_files "${WORK}"
  [ "$status" -eq 0 ]
  [ "${output}" = "plan.md" ]
}

@test "sorts multiple matches as bare file names" {
  printf 'no markers\n' > "${WORK}/spec.md"
  printf '%s\n' '<!-- speckit-jira spec=0123456789abcdef -->' > "${WORK}/tasks.md"
  printf '%s\n' '<!-- speckit-jira story=abcdef0123456789 -->' > "${WORK}/plan.md"
  run marker_splice_stray_files "${WORK}"
  [ "$status" -eq 0 ]
  [ "${output}" = "plan.md, tasks.md" ]
}

@test "ignores subdirectories — no recursion" {
  printf 'no markers\n' > "${WORK}/spec.md"
  mkdir -p "${WORK}/contracts"
  printf '%s\n' '<!-- speckit-jira spec=0123456789abcdef -->' > "${WORK}/contracts/api.md"
  run marker_splice_stray_files "${WORK}"
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "opens no file for writing — mtime untouched" {
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/mtime.bash"
  printf 'no markers\n' > "${WORK}/spec.md"
  printf '%s\n' '<!-- speckit-jira spec=0123456789abcdef -->' > "${WORK}/plan.md"
  local before after
  before="$(helper_file_mtime "${WORK}/plan.md")"
  sleep 1
  run marker_splice_stray_files "${WORK}"
  after="$(helper_file_mtime "${WORK}/plan.md")"
  [ "${before}" = "${after}" ]
}
