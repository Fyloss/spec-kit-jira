#!/usr/bin/env bats
# T041 [US1] — Deterministic config ceremony, cross-port parity (FR-003, SC-004).
#
# Drives the us1-config-idempotent scenario through the real dispatcher on both
# ports and asserts:
#   1. the run summary (stdout), exit code, Jira read-only call sequence, and the
#      written config.local.yml are byte-identical across ports (NFR-1), and
#   2. the committed config.yml is never rewritten (survives byte-for-byte), and
#   3. running the port twice in one workdir is byte-identical (idempotent
#      re-run, FR-003) — the resolved-id table is the only written artifact and
#      an unchanged project yields the same bytes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  SCENARIO="${CONF}/scenarios/us1-config-idempotent.json"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

@test "config --json produces a byte-identical summary + workdir across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${SCENARIO}" powershell "${TMP}/out-ps" > /dev/null
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/calls.log" "${TMP}/out-ps/calls.log"
  [ "$status" -eq 0 ]
}

@test "the ceremony writes the resolved-id table into config.local.yml (discovery effect)" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local localf="${TMP}/out-bash/workdir/.specify/jira/config.local.yml"
  # The resolved-id table lands in the gitignored local layer.
  source "${ROOT}/scripts/bash/lib/config.sh"
  run jq -e '.resolved_ids.COMP.issue_types.Initiative == "10100"' <<< "$(config_yaml_to_json "${localf}")"
  [ "$status" -eq 0 ]
  # The committed config.yml must be untouched by the run.
  run diff "${FIXTURE}/.specify/jira/config.yml" "${TMP}/out-bash/workdir/.specify/jira/config.yml"
  [ "$status" -eq 0 ]
}

@test "a second run in the same workdir is byte-identical (idempotent re-run, FR-003)" {
  # Prepare a persistent workdir seeded from the fixture.
  WD="${TMP}/wd"
  mkdir -p "${WD}"
  cp -R "${FIXTURE}/." "${WD}/"
  source "${ROOT}/tests/conformance/mock-jira/lib.sh"
  MOCK_CFG="$(mktemp)"
  jq '.mock' "${SCENARIO}" > "${MOCK_CFG}"
  mock_start "${MOCK_CFG}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  ENTRY="${ROOT}/scripts/bash/spec-kit-jira.sh"

  ( cd "${WD}" && bash "${ENTRY}" config --json ) > "${TMP}/run1" 2>/dev/null
  cp "${WD}/.specify/jira/config.local.yml" "${TMP}/local1"
  ( cd "${WD}" && bash "${ENTRY}" config --json ) > "${TMP}/run2" 2>/dev/null
  cp "${WD}/.specify/jira/config.local.yml" "${TMP}/local2"
  mock_stop

  # The persisted resolved-id table is byte-identical on re-run (FR-003).
  run diff "${TMP}/local1" "${TMP}/local2"
  [ "$status" -eq 0 ]
  # The second run reports discovery as unchanged (zero churn) — the idempotency signal.
  [ "$(jq -r '.effects.discovery.status' "${TMP}/run2")" = "unchanged" ]
}
