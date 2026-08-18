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

@test "the bash port's shim backend records no mock.pid (no process to leak)" {
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  [ ! -f "${OUT}/mock.pid" ]
}

@test "harness stops the mock when the run aborts after the mock started" {
  # A surviving mock holds every fd it inherited, which under kcov is the
  # tracer's own pipe — the coverage run then never sees EOF and burns the CI
  # step's whole budget. An invalid branch name aborts the harness after
  # mock_start, which is where the leak used to happen.
  #
  # This is a real-process test by construction: the Bash port's mock backend
  # is the curl shim (no process, contracts/mock-driver.md), so only the
  # "powershell" port backend has a PID that could leak. The git_branch abort
  # happens before the harness ever reaches the entry point, so pinning
  # SPEC_KIT_JIRA_ENTRY_BASH (a bash stub) has no bearing on this run.
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
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
  bash "${HARNESS}" "${TMP}/abort.json" powershell "${OUT}" \
    < /dev/null > "${TMP}/abort.out" 2>&1 3>&- || status=$?
  [ "${status}" -ne 0 ]
  grep -q 'not a valid branch name' "${TMP}/abort.out"

  # Identified by the exact PID the harness recorded — a name-pattern scan
  # (pgrep -f mock-server.ps1) would also catch every OTHER scenario's mock
  # running concurrently under a parallel test suite (--jobs).
  mock_pid="$(cat "${OUT}/mock.pid")"
  [ -n "${mock_pid}" ]

  # Termination is asynchronous; poll rather than assume the kill has landed.
  # A generous bound: under tests/run-bash.sh's full-suite parallel fan-out,
  # dozens of pwsh processes can be exiting concurrently, and OS-level reaping
  # of THIS one can take longer than a lightly-loaded host's 3s would suggest.
  for _ in $(seq 1 50); do
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

# =============================================================================
# T002 [030] — the @MOCK_BASE_URL@ and @PAT_HANG_COMMAND@ sentinel
# substitutions (research.md §R6, §R11)
# =============================================================================

@test "T002 — @MOCK_BASE_URL@ is replaced in the copied workdir's config.yml (bash backend)" {
  local stub="${TMP}/base-url-stub.sh"
  cat > "${stub}" << 'EOF'
#!/usr/bin/env bash
cat .specify/jira/config.yml
EOF
  chmod +x "${stub}"
  local scenario="${TMP}/base-url.json"
  cat > "${scenario}" << 'EOF'
{
  "name": "mock-base-url-sub",
  "mock": { "projects": { "IJT": "company" } },
  "fixture": "tests/conformance/fixtures/repo-030-base-url"
}
EOF
  SPEC_KIT_JIRA_ENTRY_BASH="${stub}" bash "${HARNESS}" "${scenario}" bash "${OUT}"
  run cat "${OUT}/stdout"
  [[ "$output" != *"@MOCK_BASE_URL@"* ]]
  [[ "$output" == *"base_url: \"http://127.0.0.1:"* ]]
}

@test "T002 — @MOCK_BASE_URL@ is replaced identically for the powershell backend" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local stub="${TMP}/base-url-stub.ps1"
  cat > "${stub}" << 'EOF'
Get-Content .specify/jira/config.yml
EOF
  local scenario="${TMP}/base-url.json"
  cat > "${scenario}" << 'EOF'
{
  "name": "mock-base-url-sub-ps",
  "mock": { "projects": { "IJT": "company" } },
  "fixture": "tests/conformance/fixtures/repo-030-base-url"
}
EOF
  SPEC_KIT_JIRA_ENTRY_PWSH="${stub}" bash "${HARNESS}" "${scenario}" powershell "${OUT}"
  run cat "${OUT}/stdout"
  [[ "$output" != *"@MOCK_BASE_URL@"* ]]
  [[ "$output" == *"base_url: \"http://127.0.0.1:"* ]]
}

@test "T002 — a fixture with neither the sentinel nor the file is copied byte-identically" {
  # repo-with-config carries no .specify/jira/config.yml with the sentinel —
  # the substitution's grep guard must be a no-op, not an error.
  local scenario="${TMP}/no-sentinel.json"
  cat > "${scenario}" << 'EOF'
{
  "name": "no-sentinel",
  "mock": { "projects": { "COMP": "company" } },
  "fixture": "tests/conformance/fixtures/repo-with-config"
}
EOF
  run bash "${HARNESS}" "${scenario}" bash "${OUT}"
  [ "$status" -eq 0 ]
  run diff -r "${ROOT}/tests/conformance/fixtures/repo-with-config/.specify" "${OUT}/workdir/.specify"
  [ "$status" -eq 0 ]
}

@test "T002 — @PAT_HANG_COMMAND@ resolves in an env value to something that actually blocks" {
  local stub="${TMP}/hang-stub.sh"
  cat > "${stub}" << 'EOF'
#!/usr/bin/env bash
echo "resolved=${JIRA_PAT_COMMAND}"
EOF
  chmod +x "${stub}"
  local scenario="${TMP}/hang.json"
  cat > "${scenario}" << 'EOF'
{
  "name": "pat-hang-sub",
  "mock": { "projects": { "COMP": "company" } },
  "env": { "JIRA_PAT_COMMAND": "@PAT_HANG_COMMAND@" }
}
EOF
  SPEC_KIT_JIRA_ENTRY_BASH="${stub}" bash "${HARNESS}" "${scenario}" bash "${OUT}"
  run cat "${OUT}/stdout"
  [[ "$output" != *"@PAT_HANG_COMMAND@"* ]]
  local resolved="${output#resolved=}"
  [ -n "${resolved}" ]

  # The resolved command must actually block: run it directly with a short
  # bound and confirm it is still alive when the bound expires (POSIX-only —
  # the harness resolves a .cmd on Windows, unrunnable from this bats suite).
  case "$(uname -s)" in
    Linux | Darwin)
      IFS=' ' read -ra hang_argv <<< "${resolved}"
      "${hang_argv[@]}" &
      local hang_pid=$!
      sleep 1
      run kill -0 "${hang_pid}"
      [ "$status" -eq 0 ]
      kill -TERM "${hang_pid}" 2> /dev/null
      wait "${hang_pid}" 2> /dev/null || true
      ;;
  esac
}

@test "T002 — @PAT_HANG_COMMAND@ resolves to the SAME string for both ports in one run-scenario.sh invocation" {
  # Recorded via two separate harness runs (each port its own process), so this
  # asserts determinism of the resolution, not a single shared value — the
  # actual byte-diff comparison across ports is ci-conformance.sh's job.
  local stub_bash="${TMP}/hang-stub.sh"
  cat > "${stub_bash}" << 'EOF'
#!/usr/bin/env bash
echo "resolved=${JIRA_PAT_COMMAND}"
EOF
  chmod +x "${stub_bash}"
  local scenario="${TMP}/hang.json"
  cat > "${scenario}" << 'EOF'
{
  "name": "pat-hang-sub-repeat",
  "mock": { "projects": { "COMP": "company" } },
  "env": { "JIRA_PAT_COMMAND": "@PAT_HANG_COMMAND@" }
}
EOF
  SPEC_KIT_JIRA_ENTRY_BASH="${stub_bash}" bash "${HARNESS}" "${scenario}" bash "${TMP}/out1"
  SPEC_KIT_JIRA_ENTRY_BASH="${stub_bash}" bash "${HARNESS}" "${scenario}" bash "${TMP}/out2"
  [ "$(cat "${TMP}/out1/stdout")" = "$(cat "${TMP}/out2/stdout")" ]
}
