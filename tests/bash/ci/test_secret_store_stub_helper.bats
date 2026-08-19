#!/usr/bin/env bats
# Guard for tests/bash/helpers/secret_store_stub.bash (030, C7.1 — repurposed,
# not deleted, from feature 021).
#
# Two stand-ins, two claims:
#
#   1. helper_pat_command_install COUNTS, and cred_resolve_token actually
#      REACHES it through JIRA_PAT_COMMAND (C2.6 — at most once per run).
#   2. helper_secret_store_install COUNTS, and cred_resolve_token NEVER
#      reaches it (C1.3a — the hardcoded probe is gone; a `security` /
#      `secret-tool` on PATH that would return a token must stay uninvoked).
#
# Test isolation (Constitution XIII): the stub directory and the counter file
# both live under `${BATS_TEST_TMPDIR}`, a path this test created, and the
# count is read from that file — never from a scan of the machine.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/secret_store_stub.bash"
  BIN="${BATS_TEST_TMPDIR}/bin"
  COUNTER="${BATS_TEST_TMPDIR}/pat-command.count"
  # The bridge's own resolution order must not be short-circuited by whatever
  # the developer running the suite happens to have exported.
  unset _CRED_SECRET_TOKEN JIRA_API_TOKEN JIRA_PAT_COMMAND
}

# --- helper_pat_command_install: counts, and is reached -----------------

@test "a freshly installed pat-command stub has been consulted zero times" {
  helper_pat_command_install "${BIN}" "${COUNTER}" "tok"
  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "an absent counter file reads as zero, not as an error" {
  run helper_pat_command_count "${BATS_TEST_TMPDIR}/never-created"
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "each invocation of the stubbed command is recorded once" {
  local prog
  prog="$(helper_pat_command_install "${BIN}" "${COUNTER}" "tok")"
  "${prog}" > /dev/null
  "${prog}" > /dev/null
  "${prog}" > /dev/null
  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "3" ]
}

@test "the stub prints the token it was given" {
  local prog
  prog="$(helper_pat_command_install "${BIN}" "${COUNTER}" "s3cret")"
  run "${prog}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "s3cret" ]
}

@test "an empty token stands for C3.7: nothing printed, exit 0" {
  local prog
  prog="$(helper_pat_command_install "${BIN}" "${COUNTER}" "")"
  run "${prog}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "a non-zero exit code stands for C3.5, and the attempt still counts" {
  local prog
  prog="$(helper_pat_command_install "${BIN}" "${COUNTER}" "" 1)"
  run "${prog}"
  [ "${status}" -eq 1 ]
  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "1" ]
}

@test "cred_resolve_token reaches the stub through JIRA_PAT_COMMAND, and the count is exactly one" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/credentials.sh"
  helper_pat_command_install "${BIN}" "${COUNTER}" "from-the-command"

  local got
  got="$(cred_resolve_token)"
  [ "${got}" = "from-the-command" ]
  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "1" ]
}

@test "cred_resolve_token: the environment still wins over a declared command, uninvoked" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/credentials.sh"
  helper_pat_command_install "${BIN}" "${COUNTER}" "from-the-command"

  local got
  got="$(JIRA_API_TOKEN=from-the-env cred_resolve_token)"
  [ "${got}" = "from-the-env" ]
  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "0" ]
}

# --- helper_secret_store_install: counts, and is NEVER reached (C1.3a) --

@test "a freshly installed secret-store stub has been consulted zero times" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "tok"
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "each invocation of the stubbed store tool is recorded once" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "tok"
  PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w > /dev/null
  PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w > /dev/null
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "2" ]
}

@test "secret-tool is stubbed too, so the count is the same on a host without security" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "tok"
  run env PATH="${BIN}:${PATH}" secret-tool lookup service spec-kit-jira
  [ "${status}" -eq 0 ]
  [ "${output}" = "tok" ]
}

@test "C1.3a: cred_resolve_token with a security stand-in on PATH and no JIRA_PAT_COMMAND still fails, uninvoked" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/credentials.sh"
  helper_secret_store_install "${BIN}" "${COUNTER}" "from-the-store"

  run env PATH="${BIN}:${PATH}" bash -c "source '${ROOT}/scripts/bash/lib/credentials.sh'; cred_resolve_token"
  [ "${status}" -ne 0 ]
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}
