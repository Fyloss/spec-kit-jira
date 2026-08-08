#!/usr/bin/env bats
# Guard for tests/bash/helpers/calls_log.bash.
#
# Every request-count claim in feature 021 — recognition is bounded, the
# unchanged re-run issues zero, the prefetch removes reads without adding
# outcomes — is read through this helper. If the helper miscounts, those tests
# pass while the product regresses, so the helper needs its own failing test
# before anything depends on it.
#
# The three cases that would actually bite are covered below: an absent log (a
# short-circuited run, which must read as zero and not as an error), a
# Windows-authored log carrying CR line endings, and a trailing line with no
# final newline.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/calls_log.bash"
  LOG="${BATS_TEST_TMPDIR}/calls.log"
}

@test "an absent calls.log counts as zero requests, not as an error" {
  run helper_calls_total "${BATS_TEST_TMPDIR}/nope.log"
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "an empty calls.log counts as zero requests" {
  : > "${LOG}"
  run helper_calls_total "${LOG}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "each request line counts once" {
  printf 'GET /rest/api/3/issue/PROJ-1\nGET /rest/api/3/issue/PROJ-2\nPOST /rest/api/3/issue\n' > "${LOG}"
  run helper_calls_total "${LOG}"
  [ "${output}" = "3" ]
}

@test "a final line without a trailing newline still counts" {
  printf 'GET /a\nGET /b' > "${LOG}"
  run helper_calls_total "${LOG}"
  [ "${output}" = "2" ]
}

@test "blank lines are not requests" {
  printf 'GET /a\n\n\nGET /b\n' > "${LOG}"
  run helper_calls_total "${LOG}"
  [ "${output}" = "2" ]
}

@test "a CRLF-authored log counts the same as an LF one" {
  printf 'GET /a\r\nGET /b\r\n' > "${LOG}"
  run helper_calls_total "${LOG}"
  [ "${output}" = "2" ]
}

@test "the carriage return is stripped from the target, so a match is not defeated by it" {
  printf 'POST /rest/api/3/issue/bulkfetch\r\n' > "${LOG}"
  run helper_calls_matching "${LOG}" "/rest/api/3/issue/bulkfetch"
  [ "${output}" = "1" ]
}

@test "helper_calls_matching counts only the lines carrying the substring" {
  printf 'GET /rest/api/3/issue/PROJ-1\nPOST /rest/api/3/issue/bulkfetch\nGET /rest/api/3/issue/PROJ-2\n' > "${LOG}"
  run helper_calls_matching "${LOG}" "bulkfetch"
  [ "${output}" = "1" ]
  run helper_calls_matching "${LOG}" "GET /rest/api/3/issue/"
  [ "${output}" = "2" ]
}

@test "helper_calls_matching returns zero for a target never requested" {
  printf 'GET /a\n' > "${LOG}"
  run helper_calls_matching "${LOG}" "bulkfetch"
  [ "${output}" = "0" ]
}

@test "helper_calls_by_path tabulates each distinct request once, with its count" {
  printf 'GET /b\nGET /a\nGET /b\n' > "${LOG}"
  run helper_calls_by_path "${LOG}"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "$(printf '1\tGET /a')" ]
  [ "${lines[1]}" = "$(printf '2\tGET /b')" ]
}

@test "helper_calls_by_path is deterministic: request order does not change its output" {
  printf 'GET /b\nGET /a\nGET /b\n' > "${LOG}"
  run helper_calls_by_path "${LOG}"
  local first="${output}"
  printf 'GET /b\nGET /b\nGET /a\n' > "${LOG}"
  run helper_calls_by_path "${LOG}"
  [ "${output}" = "${first}" ]
}
