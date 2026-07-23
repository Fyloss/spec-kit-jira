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

  pwsh "${args[@]}" &
  MOCK_PID=$!

  local i=0
  while [ ! -s "${ready}" ] && [ "${i}" -lt 200 ]; do
    kill -0 "${MOCK_PID}" 2> /dev/null || { echo "mock process exited before ready" >&2; return 1; }
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "${ready}" ] || { echo "mock failed to become ready" >&2; return 1; }

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
