#!/usr/bin/env bash
# T008 — Bash helper for the mocked Jira double.
#
# Sourced by bats suites (and the conformance harness) to start/stop the
# PowerShell mock server and read its recorded call sequence. The mock is
# pwsh-only by design; both ports drive it over HTTP via its base URL.
#
# Usage:
#   source lib.sh
#   mock_start "<config.json>"     # sets MOCK_PID, MOCK_BASE_URL, MOCK_CALLLOG
#   curl "$MOCK_BASE_URL/rest/api/3/project/COMP"
#   mock_calls                     # prints the LF-separated "METHOD target" log
#   mock_stop

_MOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Startup failures are otherwise mute: the mock's own diagnostics now land in
# files rather than on the caller's stderr, so quote them here.
mock_died() {
  echo "mock process ${1}" >&2
  [ -s "${MOCK_TMPDIR}/mock.err" ] && sed 's/^/  mock: /' "${MOCK_TMPDIR}/mock.err" >&2
  [ -s "${MOCK_TMPDIR}/mock.out" ] && sed 's/^/  mock: /' "${MOCK_TMPDIR}/mock.out" >&2
  return 0
}

mock_start() {
  local config="${1:-}"
  MOCK_TMPDIR="$(mktemp -d)"
  MOCK_CALLLOG="${MOCK_TMPDIR}/calls.log"
  local ready="${MOCK_TMPDIR}/ready"
  : > "${MOCK_CALLLOG}"

  local args=(-NoProfile -File "${_MOCK_LIB_DIR}/mock-server.ps1"
    -CallLogPath "${MOCK_CALLLOG}" -ReadyFile "${ready}"
    -FixtureDir "${_MOCK_LIB_DIR}/fixtures")
  [ -n "${config}" ] && args+=(-ConfigPath "${config}")

  # The mock inherits no descriptor from its caller. A background child that
  # holds one open blocks whoever reads the other end until it dies — bats' fd
  # 3, a `run` pipe, or kcov's trace pipe, which is how the Bash coverage job
  # spent a whole CI step waiting for an EOF that could not arrive.
  pwsh "${args[@]}" < /dev/null > "${MOCK_TMPDIR}/mock.out" 2> "${MOCK_TMPDIR}/mock.err" 3>&- &
  MOCK_PID=$!

  local i=0
  while [ ! -s "${ready}" ] && [ "${i}" -lt 200 ]; do
    kill -0 "${MOCK_PID}" 2> /dev/null || { mock_died "exited before ready"; return 1; }
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "${ready}" ] || { mock_died "failed to become ready within 10s"; return 1; }

  MOCK_PORT="$(cat "${ready}")"
  MOCK_BASE_URL="http://127.0.0.1:${MOCK_PORT}"
  export MOCK_BASE_URL
}

mock_stop() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "${MOCK_PID}" 2> /dev/null || true
    wait "${MOCK_PID}" 2> /dev/null || true
    MOCK_PID=""
  fi
}

mock_calls() {
  [ -f "${MOCK_CALLLOG:-}" ] && cat "${MOCK_CALLLOG}"
}

# mock_write_config <json> — writes an ad hoc mock config (e.g. per-issue-type
# createmeta overrides via "createmetaFields") to a temp file and prints its
# path, so a test can build one inline instead of maintaining a static file
# under configs/ (T003).
mock_write_config() {
  local json="$1" f
  f="$(mktemp)"
  printf '%s' "${json}" > "${f}"
  printf '%s' "${f}"
}

# mock_issue_field <key> <jq-path> — read back a field of an issue the mock
# already holds (e.g. `.fields.parent.key`), for parent-link assertions
# (T002/T003) without every caller re-deriving the GET and the jq filter.
mock_issue_field() {
  local key="$1" path="$2"
  curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/${key}" | jq -r "${path}"
}
