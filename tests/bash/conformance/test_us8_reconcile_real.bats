#!/usr/bin/env bats
# T058 [004] — The config-resolution path's dry-run report predicts exactly
# the real run's Jira calls (SC-006), extending T070's US6 guarantee to
# routing + creation-context resolved from config rather than from an
# explicit plan-context override.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  DRY_SCENARIO="${CONF}/scenarios/us8-reconcile-company-managed.json"
  REAL_SCENARIO="${CONF}/scenarios/us8-reconcile-real.json"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

_report_lines() {
  jq -r '.actions[] | "\(.method) \(.url)"' "$1"
}

@test "the config-resolved dry-run report predicts exactly the real run's calls (SC-006)" {
  bash "${HARNESS}" "${DRY_SCENARIO}" bash "${TMP}/dry" > /dev/null
  [ "$(cat "${TMP}/dry/exit")" = "0" ]
  local reported; reported="$(_report_lines "${TMP}/dry/stdout")"
  [ -n "${reported}" ]

  bash "${HARNESS}" "${REAL_SCENARIO}" bash "${TMP}/real" > /dev/null
  [ "$(cat "${TMP}/real/exit")" = "0" ]
  # Phase 3, US1: a real creation now stamps the identity marker immediately
  # afterward (research R5 step 6) — a write a dry run correctly never
  # predicts, since it never creates the ticket the stamp would apply to.
  local performed; performed="$(grep -v '/properties/' "${TMP}/real/calls.log")"

  [ "${reported}" = "${performed}" ]
}

@test "both ports predict-and-perform identically through config resolution (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi

  bash "${HARNESS}" "${DRY_SCENARIO}" bash "${TMP}/dry-b" > /dev/null
  bash "${HARNESS}" "${DRY_SCENARIO}" powershell "${TMP}/dry-p" > /dev/null
  run diff "${TMP}/dry-b/stdout" "${TMP}/dry-p/stdout"
  [ "$status" -eq 0 ]

  bash "${HARNESS}" "${REAL_SCENARIO}" bash "${TMP}/real-b" > /dev/null
  bash "${HARNESS}" "${REAL_SCENARIO}" powershell "${TMP}/real-p" > /dev/null
  run diff "${TMP}/real-b/calls.log" "${TMP}/real-p/calls.log"
  [ "$status" -eq 0 ]
}
