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

@test "harness fails clearly when the entry point is missing" {
  SPEC_KIT_JIRA_ENTRY_BASH="${TMP}/does-not-exist.sh" run bash "${HARNESS}" "${SCENARIO}" bash "${OUT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"entry point not found"* ]]
}
