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

# --- T020 [018, Phase 3/US1] — reduced-spawn harness (D4, R10, FR-003) -------
#
# Measured (research.md §2.1): jq_lines pipes EVERY jq call through sed
# unconditionally, and the post-run workdir snapshot spawns one mkdir + one
# cp PER FILE. Written and observed to FAIL before the harness was changed
# (Constitution XIII TDD) — counting wrappers on PATH prove the reduction
# directly, per the same technique as test_mock_shim_contract.bats's T019.

_install_counter() {
  local exe="$1" var="$2"
  eval "${var}_DIR=\"\$(mktemp -d)\""
  eval "local dir=\"\${${var}_DIR}\""
  eval "${var}_FILE=\"\${dir}/count\""
  eval "local file=\"\${${var}_FILE}\""
  : > "${file}"
  local real
  real="$(command -v "${exe}")"
  cat > "${dir}/${exe}" << EOF
#!/usr/bin/env bash
printf 'x' >> "${file}"
exec "${real}" "\$@"
EOF
  chmod +x "${dir}/${exe}"
  PATH="${dir}:${PATH}"
}

_counter_count() {
  local var="$1" file
  eval "file=\"\${${var}_FILE}\""
  wc -c < "${file}" | tr -d '[:space:]'
}

@test "R10/D4: jq_lines never spawns sed on a host whose jq already emits LF" {
  _install_counter sed SED
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  # This test host's own jq (whatever CI or the developer's machine ships)
  # is the one under test here, matching jq_lines' own detection — on any
  # LF-emitting jq the count must be exactly 0, never "close to 0".
  if [[ "$(command jq -rn '"a\nb"' 2> /dev/null)" != *$'\r'* ]]; then
    [ "$(_counter_count SED)" -eq 0 ]
  else
    skip "this host's jq emits CRLF — sed is genuinely needed here"
  fi
}

@test "R10/D4: the workdir snapshot's cp count does not scale with file count" {
  # The harness makes a small, FIXED number of its own cp calls regardless of
  # this test (mock_start's own one-time setup, stdout/stderr/exit, calls.log)
  # — the property this test isolates is that the WORKDIR SNAPSHOT itself
  # contributes ONE cp call (a single `cp -R`) no matter how many files are
  # in it, not one mkdir+cp PER FILE as before. Proved by writing 3 files vs
  # 12 and confirming the harness's total cp count is IDENTICAL both times.
  _write_n_file_stub() {
    local n="$1" i
    { printf '#!/usr/bin/env bash\nset -euo pipefail\n'
      for ((i = 1; i <= n; i++)); do printf 'printf "file %%s\\n" %d > "f%d.txt"\n' "${i}" "${i}"; done
    } > "${STUB}"
    chmod +x "${STUB}"
  }

  _write_n_file_stub 3
  _install_counter cp CP3
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  count_3="$(_counter_count CP3)"

  rm -rf "${OUT}"
  _write_n_file_stub 12
  _install_counter cp CP12
  bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  count_12="$(_counter_count CP12)"

  [ "${count_3}" -eq "${count_12}" ]
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(cat "${OUT}/workdir/f${i}.txt")" = "file ${i}" ]
  done
}
