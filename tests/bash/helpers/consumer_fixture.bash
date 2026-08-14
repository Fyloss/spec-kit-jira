#!/usr/bin/env bash
# tests/bash/helpers/consumer_fixture.bash — T005 (026): a throwaway spec-kit
# consumer repository plus a loopback artifact server, for install
# end-to-end tests.
#
# Constitution XIII forbids identifying test state by a fixed well-known port
# or by a machine-wide process scan: every port and PID handed back here is
# one this helper just recorded from the process it started, never assumed
# or pattern-matched. `file://` is rejected by the host (research R7), so a
# real loopback HTTP server is the only way to drive an install in a test.
#
#   source tests/bash/helpers/consumer_fixture.bash
#   fixture_require || skip "${FIXTURE_SKIP_REASON}"
#   repo="$(fixture_new_repo)"
#   read -r port pid < <(fixture_serve "${dir_containing_the_artifact}")
#   printf 'y\n' | (cd "${repo}" && specify extension add jira \
#     --from "http://127.0.0.1:${port}/spec-kit-jira.zip")
#   fixture_stop_server "${pid}"
#   fixture_cleanup "${repo}"
#
# Run directly (not sourced), it self-tests that two concurrent instances are
# handed different ports.

[[ -n ${_JIRA_CONSUMER_FIXTURE:-} ]] && return 0
_JIRA_CONSUMER_FIXTURE=1

# Set by fixture_require when the fixture cannot run.
FIXTURE_SKIP_REASON=''

# fixture_require — 0 when everything the fixture needs is on PATH, 1
# otherwise with a clear reason in FIXTURE_SKIP_REASON.
fixture_require() {
  FIXTURE_SKIP_REASON=''
  if ! command -v specify > /dev/null 2>&1; then
    FIXTURE_SKIP_REASON="the 'specify' CLI is not installed — install it with: uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
    return 1
  fi
  if ! command -v python3 > /dev/null 2>&1; then
    FIXTURE_SKIP_REASON="python3 is not installed (needed for the loopback artifact server)"
    return 1
  fi
  return 0
}

# fixture_new_repo — create a scratch consumer repository and run `specify
# init --here` inside it. Prints its absolute path. The caller owns the
# directory and removes it with fixture_cleanup.
fixture_new_repo() {
  local repo
  repo="$(mktemp -d)"
  (
    cd "${repo}" || exit 1
    git init -q . > /dev/null 2>&1 || true
    specify init --here --force --integration claude --script sh --ignore-agent-tools \
      > "${repo}/.fixture-init.log" 2>&1
  ) || {
    printf 'consumer_fixture: specify init failed; see %s/.fixture-init.log\n' "${repo}" >&2
    printf '%s' "${repo}"
    return 1
  }
  printf '%s' "${repo}"
}

# fixture_serve <dir> — start a loopback HTTP server rooted at <dir>, bound to
# a port the OPERATING SYSTEM assigns (bind 0), never a fixed one. On success
# prints "<port> <pid>" on one line, once the server is confirmed listening.
fixture_serve() {
  local dir="$1" log pid port tries=0
  log="$(mktemp)"
  (cd "${dir}" && exec python3 -u -m http.server 0 --bind 127.0.0.1) > "${log}" 2>&1 &
  pid=$!

  port=''
  while ((tries < 50)); do
    port="$(sed -nE 's/.*[Pp]ort ([0-9]+).*/\1/p' "${log}" | head -n1)"
    [[ -n "${port}" ]] && break
    kill -0 "${pid}" 2> /dev/null || break
    sleep 0.1
    tries=$((tries + 1))
  done

  if [[ -z "${port}" ]]; then
    printf 'consumer_fixture: server did not report a listening port; log:\n' >&2
    cat "${log}" >&2
    kill "${pid}" 2> /dev/null || true
    rm -f "${log}"
    return 1
  fi

  rm -f "${log}"
  printf '%s %s\n' "${port}" "${pid}"
}

# fixture_stop_server <pid> — stop a server started by fixture_serve,
# identified by the PID that call recorded. Never a pattern match or a
# machine-wide scan (Constitution XIII).
fixture_stop_server() {
  local pid="$1"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" 2> /dev/null || true
  wait "${pid}" 2> /dev/null || true
}

# fixture_cleanup <repo> — remove a scratch consumer repository.
fixture_cleanup() {
  local repo="$1"
  [[ -n "${repo}" && -d "${repo}" && "${repo}" == /* ]] || return 0
  rm -rf "${repo}"
}

# Standalone self-test: two concurrent fixture_serve calls are handed
# different, OS-assigned ports.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  d1="$(mktemp -d)"
  d2="$(mktemp -d)"
  read -r port1 pid1 < <(fixture_serve "${d1}")
  read -r port2 pid2 < <(fixture_serve "${d2}")
  status=0
  if [[ -z "${port1}" || -z "${port2}" || "${port1}" == "${port2}" ]]; then
    printf 'consumer_fixture self-test FAILED: ports were "%s" and "%s"\n' "${port1}" "${port2}" >&2
    status=1
  else
    printf 'consumer_fixture self-test OK: %s != %s\n' "${port1}" "${port2}"
  fi
  fixture_stop_server "${pid1}"
  fixture_stop_server "${pid2}"
  rm -rf "${d1}" "${d2}"
  exit "${status}"
fi
