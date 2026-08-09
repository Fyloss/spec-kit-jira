#!/usr/bin/env bats
# Guard for tests/bash/helpers/secret_store_stub.bash.
#
# SC-004 — "the operating system's secret store is consulted at most once per
# reconcile process" — is asserted by a counter this stub records. Two things
# have to be true before that assertion means anything, and both are tested
# here:
#
#   1. The stub COUNTS. A counter that silently stayed at zero would make
#      SC-004 pass on a bridge that shelled out forty times.
#   2. The stub is actually REACHED by `_cred_from_secret_manager`. It replaces
#      the tool on PATH rather than driving the `_CRED_SECRET_TOKEN` value seam,
#      precisely so the real branch executes — and that interception is the part
#      most likely to break silently, because the fallback is "the host's own
#      `security`", which on macOS exists and answers.
#
# Test isolation (Constitution XIII): the stub directory and the counter file
# both live under `${BATS_TEST_TMPDIR}`, a path this test created, and the count
# is read from that file — never from a scan of the machine.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/secret_store_stub.bash"
  BIN="${BATS_TEST_TMPDIR}/bin"
  COUNTER="${BATS_TEST_TMPDIR}/secret-store.count"
  # The bridge's own resolution order must not be short-circuited by whatever
  # the developer running the suite happens to have exported.
  unset _CRED_SECRET_TOKEN JIRA_API_TOKEN
}

@test "a freshly installed stub has been consulted zero times" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "tok"
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "an absent counter file reads as zero, not as an error" {
  run helper_secret_store_count "${BATS_TEST_TMPDIR}/never-created"
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}

@test "each invocation of the stubbed tool is recorded once" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "tok"
  PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w > /dev/null
  PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w > /dev/null
  PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w > /dev/null
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "3" ]
}

@test "the stub returns the token it was given" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "s3cret"
  run env PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w
  [ "${status}" -eq 0 ]
  [ "${output}" = "s3cret" ]
}

@test "an empty token stands for 'no entry of that name': nothing printed, exit 0" {
  helper_secret_store_install "${BIN}" "${COUNTER}" ""
  run env PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "a non-zero exit code stands for a present but failing store" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "" 1
  run env PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w
  [ "${status}" -eq 1 ]
}

@test "a failing store still counts: the attempt cost a process spawn" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "" 1
  PATH="${BIN}:${PATH}" security find-generic-password -s spec-kit-jira -w > /dev/null 2>&1 || true
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "1" ]
}

@test "secret-tool is stubbed too, so the count is the same on a host without security" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "tok"
  run env PATH="${BIN}:${PATH}" secret-tool lookup service spec-kit-jira
  [ "${status}" -eq 0 ]
  [ "${output}" = "tok" ]
}

# --- The part that proves the stub is on the path the product actually takes --

@test "_cred_from_secret_manager reaches the stub and its consultation is counted" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/credentials.sh"
  helper_secret_store_install "${BIN}" "${COUNTER}" "from-the-store"

  local got
  got="$(PATH="${BIN}:${PATH}" _cred_from_secret_manager)"

  [ "${got}" = "from-the-store" ]
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "1" ]
}

@test "cred_resolve_token resolves through the stub, and the environment still wins over it" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/credentials.sh"
  helper_secret_store_install "${BIN}" "${COUNTER}" "from-the-store"

  local got
  got="$(PATH="${BIN}:${PATH}" cred_resolve_token)"
  [ "${got}" = "from-the-store" ]

  # Rung 1 beats rung 2, and the store is not consulted at all for it — the
  # zero-consultation case US3 asserts for an environment-provided token.
  : > "${COUNTER}"
  got="$(JIRA_API_TOKEN=from-the-env PATH="${BIN}:${PATH}" cred_resolve_token)"
  [ "${got}" = "from-the-env" ]
  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}
