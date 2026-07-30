#!/usr/bin/env bats
# T070 [US6] — The --dry-run report equals the real run's action set (FR-033).
#
# Drives the us6-dry-run scenario through the real dispatcher twice: once as a
# dry-run (the report lists the planned actions) and once for real (the mock
# records the actual calls). The two MUST match exactly, method + path — a
# dry-run twin that predicts precisely. Both ports honour the same guarantee.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  DRY_SCENARIO="${CONF}/scenarios/us6-dry-run.json"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

# _report_lines <stdout-file> — "METHOD url" per planned action, in order.
_report_lines() {
  jq -r '.actions[] | "\(.method) \(.url)"' "$1"
}

@test "the dry-run report predicts exactly the real run's calls (FR-033)" {
  # 1. Dry run — the report is exactly the planned action set.
  bash "${HARNESS}" "${DRY_SCENARIO}" bash "${TMP}/dry" > /dev/null
  [ "$(cat "${TMP}/dry/exit")" = "0" ]
  local reported; reported="$(_report_lines "${TMP}/dry/stdout")"
  # The scenario plans a single transition (content is zero-churn).
  [ -n "${reported}" ]

  # 2. Real run — same inputs without --dry-run; the mock records the calls.
  local real_scenario="${TMP}/us6-real.json"
  jq '.argv |= map(select(. != "--dry-run"))' "${DRY_SCENARIO}" > "${real_scenario}"
  bash "${HARNESS}" "${real_scenario}" bash "${TMP}/real" > /dev/null
  [ "$(cat "${TMP}/real/exit")" = "0" ]
  # Phase 3, US1: a real creation now stamps the identity marker immediately
  # afterward (research R5 step 6) — a write a dry run correctly never
  # predicts, since it never creates the ticket the stamp would apply to.
  # Excluded here as the one documented addendum to FR-033's guarantee.
  local performed; performed="$(grep -v '/properties/' "${TMP}/real/calls.log")"

  # 3. The report equals the real calls, line-for-line.
  [ "${reported}" = "${performed}" ]
}

@test "both ports predict-and-perform identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local real_scenario="${TMP}/us6-real.json"
  jq '.argv |= map(select(. != "--dry-run"))' "${DRY_SCENARIO}" > "${real_scenario}"

  bash "${HARNESS}" "${DRY_SCENARIO}" bash "${TMP}/dry-b" > /dev/null
  bash "${HARNESS}" "${DRY_SCENARIO}" powershell "${TMP}/dry-p" > /dev/null
  run diff "${TMP}/dry-b/stdout" "${TMP}/dry-p/stdout"
  [ "$status" -eq 0 ]

  bash "${HARNESS}" "${real_scenario}" bash "${TMP}/real-b" > /dev/null
  bash "${HARNESS}" "${real_scenario}" powershell "${TMP}/real-p" > /dev/null
  run diff "${TMP}/real-b/calls.log" "${TMP}/real-p/calls.log"
  [ "$status" -eq 0 ]
}
