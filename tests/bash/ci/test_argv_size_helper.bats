#!/usr/bin/env bats
# T018b — Guard for tests/bash/helpers/argv_size.bash (contracts/argument-
# size.md §2 A2.1, §3 A3.1). Without this, T019's "the report file is empty"
# is satisfied equally by a correct run and by a shim that never fired —
# wrong PATH order, wrong report path, or a non-executable shim would all
# produce an empty file just as silently as a genuinely passing run.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/argv_size.bash"
  SHIM_DIR="${BATS_TMPDIR}/argv_size_shims_$$"
  REPORT_FILE="${BATS_TMPDIR}/argv_size_$$.log"
  helper_argv_size_setup "${SHIM_DIR}" "${REPORT_FILE}"
}

teardown() {
  rm -rf "${SHIM_DIR}" "${REPORT_FILE}"
}

_arg_of() {
  local n="$1"
  printf 'a%.0s' $(seq 1 "${n}")
}

@test "an argument of 131073 bytes is recorded" {
  local val; val="$(_arg_of 131073)"
  PATH="${SHIM_DIR}:${PATH}" jq -n --arg v "${val}" '$v | length' > /dev/null
  [ "$(wc -l < "${REPORT_FILE}" | tr -d '[:space:]')" = "1" ]
  [ "$(cat "${REPORT_FILE}")" = "131073" ]
}

@test "an argument of 131071 bytes is not recorded" {
  local val; val="$(_arg_of 131071)"
  PATH="${SHIM_DIR}:${PATH}" jq -n --arg v "${val}" '$v | length' > /dev/null
  [ ! -s "${REPORT_FILE}" ]
}

@test "the boundary value 131072 bytes is not recorded (limit is 32 pages inclusive)" {
  local val; val="$(_arg_of 131072)"
  PATH="${SHIM_DIR}:${PATH}" jq -n --arg v "${val}" '$v | length' > /dev/null
  [ ! -s "${REPORT_FILE}" ]
}

@test "the shim delegates stdout transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n '1 + 1'
  [ "${status}" -eq 0 ]
  [ "${output}" = "2" ]
}

@test "the shim delegates a non-zero exit code transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n 'error("boom")'
  [ "${status}" -ne 0 ]
}

@test "the shim delegates stderr transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n 'error("boom-marker")'
  [[ "${output}" == *"boom-marker"* ]]
}

@test "an unfired shim leaves the report file empty" {
  [ ! -s "${REPORT_FILE}" ]
}
