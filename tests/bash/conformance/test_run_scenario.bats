#!/usr/bin/env bats
# T009 — Smoke tests for the conformance harness plumbing.
# The real dispatcher (T024) does not exist yet, so we pin a stub entry point
# via SPEC_KIT_JIRA_ENTRY_BASH to prove the harness wiring end-to-end: mock
# startup, base-URL injection, argv/env passing, and capture of stdout / exit /
# call-log / post-run workdir.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"

  TMP="$(mktemp -d)"

  # A stub entry point standing in for spec-kit-jira.sh: it reads the injected
  # base URL, calls the mock, and writes a file into the (isolated) workdir.
  STUB="${TMP}/entry.sh"
  cat > "${STUB}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "arg1=${1:-}"
echo "env_marker=${SCENARIO_MARKER:-}"
curl -s "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/project/COMP" > project.json
echo "wrote project.json"
EOF
  chmod +x "${STUB}"

  SCENARIO="${TMP}/scenario.json"
  cat > "${SCENARIO}" << 'EOF'
{
  "name": "harness-smoke",
  "mock": { "projects": { "COMP": "company" } },
  "argv": ["hello"],
  "env": { "SCENARIO_MARKER": "present" }
}
EOF

  export SPEC_KIT_JIRA_ENTRY_BASH="${STUB}"
  OUT="${TMP}/out"
}

teardown() {
  # A mock the harness failed to reap would otherwise outlive the whole suite.
  pkill -f "${TMP}" 2> /dev/null || true
  rm -rf "${TMP}"
}

@test "harness runs the entry point and captures a zero exit" {
  run bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  [ "$status" -eq 0 ]
  [ "$(cat "${OUT}/exit")" = "0" ]
}

@test "harness passes argv and scenario env through to the entry point" {
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  run cat "${OUT}/stdout"
  [[ "$output" == *"arg1=hello"* ]]
  [[ "$output" == *"env_marker=present"* ]]
}

@test "harness injects the mock base URL and records the call sequence" {
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  run cat "${OUT}/calls.log"
  [[ "$output" == *"GET /rest/api/3/project/COMP"* ]]
}

@test "harness snapshots files written into the workdir" {
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  [ -f "${OUT}/workdir/project.json" ]
  [ "$(jq -r .style "${OUT}/workdir/project.json")" = "classic" ]
}

@test "harness stops the mock when the run aborts after the mock started" {
  # A surviving mock holds every fd it inherited, which under kcov is the
  # tracer's own pipe — the coverage run then never sees EOF and burns the CI
  # step's whole budget. An invalid branch name aborts the harness after
  # mock_start, which is where the leak used to happen.
  cat > "${TMP}/abort.json" << 'EOF'
{
  "name": "abort-after-mock",
  "mock": { "projects": { "COMP": "company" } },
  "git_branch": "bad..name"
}
EOF

  # Every inherited fd is closed or pointed at a file on purpose. `run` would
  # hand the harness a pipe, and bats keeps its diagnostic fd 3 open across the
  # test; a surviving mock holds either of them open, so the assertions below
  # would never be reached — the test would hang instead of failing.
  status=0
  bash "${HARNESS}" "${TMP}/abort.json" bash "${OUT}" \
    < /dev/null > "${TMP}/abort.out" 2>&1 3>&- || status=$?
  [ "${status}" -ne 0 ]
  grep -q 'not a valid branch name' "${TMP}/abort.out"

  # Identified by the exact PID the harness recorded — a name-pattern scan
  # (pgrep -f mock-server.ps1) would also catch every OTHER scenario's mock
  # running concurrently under a parallel test suite (--jobs).
  mock_pid="$(cat "${OUT}/mock.pid")"
  [ -n "${mock_pid}" ]

  # Termination is asynchronous; poll rather than assume the kill has landed.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "${mock_pid}" 2> /dev/null || break
    sleep 0.3
  done
  ! kill -0 "${mock_pid}" 2> /dev/null || {
    printf 'the aborted run left mock pid %s behind\n' "${mock_pid}"
    false
  }
}

@test "harness fails clearly when the entry point is missing" {
  SPEC_KIT_JIRA_ENTRY_BASH="${TMP}/does-not-exist.sh" run bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"entry point not found"* ]]
}
