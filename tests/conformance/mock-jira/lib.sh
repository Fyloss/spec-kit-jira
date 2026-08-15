#!/usr/bin/env bash
# T008 (008) / T006 (009) — Bash helper for the mocked Jira double.
#
# Sourced by bats suites (and the conformance harness) to start/stop the mock
# and read its recorded call sequence. Two backends live behind the same
# `mock_start`/`mock_stop`/`mock_calls` contract (Decision 2,
# contracts/mock-driver.md):
#   bash       -> the curl shim (curl-shim.sh): no process, no port, pure
#                 bash+jq — the default, used by all 35 Bash test files.
#   powershell -> the real socket server (mock-server.ps1), unchanged; used
#                 only by run-scenario.sh when exercising the PowerShell port.
#
# Usage:
#   source lib.sh
#   mock_start "<config.json>" ["bash"|"powershell"]   # backend defaults to bash
#   curl "$MOCK_BASE_URL/rest/api/3/project/COMP"
#   mock_calls                     # prints the LF-separated "METHOD target" log
#   mock_stop

_MOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Startup failures are otherwise mute: the mock's own diagnostics now land in
# files rather than on the caller's stderr, so quote them here.
mock_died() {
  # The shim backend has no process to die; it always reports "alive"
  # (contracts/mock-driver.md "Surface added by 008").
  [[ "${_MOCK_BACKEND:-bash}" == "bash" ]] && return 0
  echo "mock process ${1}" >&2
  [ -s "${MOCK_TMPDIR}/mock.err" ] && sed 's/^/  mock: /' "${MOCK_TMPDIR}/mock.err" >&2
  [ -s "${MOCK_TMPDIR}/mock.out" ] && sed 's/^/  mock: /' "${MOCK_TMPDIR}/mock.out" >&2
  return 0
}

mock_start() {
  local config="${1:-}"
  _MOCK_BACKEND="${2:-bash}"
  MOCK_TMPDIR="$(mktemp -d)"
  MOCK_CALLLOG="${MOCK_TMPDIR}/calls.log"
  : > "${MOCK_CALLLOG}"

  if [[ "${_MOCK_BACKEND}" == "powershell" ]]; then
    _mock_start_pwsh "${config}"
  else
    _mock_start_shim "${config}"
  fi
}

# _mock_start_shim <config.json> — install the curl shim first on PATH and
# seed its per-run issue store (contracts/curl-shim.md § Session state).
_mock_start_shim() {
  local config="$1"
  local bindir="${MOCK_TMPDIR}/bin"
  mkdir -p "${bindir}"
  cp "${_MOCK_LIB_DIR}/curl-shim.sh" "${bindir}/curl"
  chmod +x "${bindir}/curl"

  MOCK_CONFIG_PATH="${MOCK_TMPDIR}/config.json"
  if [[ -n "${config}" && -f "${config}" ]]; then
    cp "${config}" "${MOCK_CONFIG_PATH}"
  else
    printf '{}' > "${MOCK_CONFIG_PATH}"
  fi

  MOCK_STATE_PATH="${MOCK_TMPDIR}/state.json"
  jq -n --slurpfile cfg "${MOCK_CONFIG_PATH}" '
    def default_status(pk):
      (($cfg[0].issueTypeStyle // {})[pk]) as $style
      | if $style == "french" then {name: "À faire", statusCategory: {key: "new"}}
        else {name: "To Do", statusCategory: {key: "new"}}
        end;
    ($cfg[0].issues // {}) as $seed
    | { issues: ($seed | to_entries | map({
          key: .key,
          value: {
            fields: (
              {
                summary: (.value.summary // ""),
                description: (.value.description // null),
                priority: (.value.priority // null),
                status: (.value.status // default_status(.key | sub("-[0-9]+$"; ""))),
                issuelinks: (.value.issuelinks // []),
                parent: (.value.parent // null),
                issuetype: (.value.issuetype // null),
                project: (.value.project // null),
                assignee: (.value.assignee // null),
                reporter: (.value.reporter // null),
                labels: (.value.labels // [])
              }
              + (if (.value.flagged // false) then {Flagged: [{value: "Impediment"}]} else {} end)
            ),
            properties: (.value.properties // {})
          }
        }) | from_entries),
        counters: {} }
  ' > "${MOCK_STATE_PATH}"

  MOCK_FIXTURE_DIR="${_MOCK_LIB_DIR}/fixtures"
  # A loopback address, not a hostname: a stray real HTTP client (never the
  # shimmed curl, but e.g. a native pwsh Invoke-RestMethod some cross-port
  # test forgets to route through the real server) gets an instant
  # ECONNREFUSED here instead of a DNS lookup that can hang for minutes.
  MOCK_BASE_URL="http://127.0.0.1:1"
  MOCK_PID=""
  export MOCK_BASE_URL MOCK_CONFIG_PATH MOCK_STATE_PATH MOCK_FIXTURE_DIR MOCK_CALLLOG MOCK_TMPDIR

  _MOCK_ORIG_PATH="${PATH}"
  PATH="${bindir}:${PATH}"
  export PATH
}

# _mock_start_pwsh <config.json> — the real socket server (unchanged), for the
# PowerShell port's conformance runs.
_mock_start_pwsh() {
  local config="$1"
  local ready="${MOCK_TMPDIR}/ready"

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

# mock_stop — tears down exactly what mock_start created: the recorded
# MOCK_TMPDIR (contracts/mock-driver.md), the recorded pwsh PID when present,
# and the PATH prepend the shim backend installed. Idempotent.
mock_stop() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "${MOCK_PID}" 2> /dev/null || true
    wait "${MOCK_PID}" 2> /dev/null || true
    MOCK_PID=""
  fi
  if [ -n "${_MOCK_ORIG_PATH:-}" ]; then
    PATH="${_MOCK_ORIG_PATH}"
    export PATH
    _MOCK_ORIG_PATH=""
  fi
  if [ -n "${MOCK_TMPDIR:-}" ] && [ -d "${MOCK_TMPDIR}" ]; then
    rm -rf "${MOCK_TMPDIR}"
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
