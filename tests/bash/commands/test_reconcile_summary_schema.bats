#!/usr/bin/env bats
# The RECONCILE run summary declares every key and status it emits.
#
# The companion of test_run_summary_schema.bats, which covers the config
# ceremony. Both judge against one reading of the contract, shared through
# tests/bash/helpers/summary_schema.bash — two copies of that jq program would
# drift exactly the way the schema itself did.
#
# A separate file because the harnesses are not compatible: this suite needs a
# different fixture, a different mock config, and a ceremony run before every
# reconcile so the mandatory fields resolve. Merging it with the config suite
# would mean a setup() that serves neither.
#
# Three shapes, because reconcile's summary is not one object with optional
# fields — different outcomes populate genuinely different key sets:
#
#   * PLANNING (`--dry-run`)  — `actions` full, `counts.created` zero.
#   * CONFIRMED              — real creations, so the counters and any warning
#                              the sink produced are populated instead.
#   * FAIL-CLOSED            — the sink refuses, exit 2, and the summary carries
#                              the warning set that only this path produces.
#
# `effects` is config-only, so the drift class that motivated these suites cannot
# occur here. What CAN occur, and what this file is for, is a new top-level key
# added to reconcile's summary alone — which the config suite would never see.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/summary_schema.bash"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${WORK}"
  SPEC="${WORK}/specs/001-reporting/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

# _record_defaults — the ceremony run the confirming paths need first, so the
# mandatory fields resolve rather than blocking the create.
_record_defaults() {
  cmd_config config PM --issue-type "PM=story=Story" \
    --field-default 'PM=Deliverable=Business Owner=Platform Team' \
    --field-default 'PM=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
}

@test "the planning (--dry-run) reconcile summary declares every key it emits" {
  # The ceremony runs first even for a plan: this fixture records its issue
  # types and field defaults through the ceremony, and without them the
  # planning run is refused at config resolution (exit 4) before it ever
  # assembles a summary.
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults

  local summary
  summary="$(cmd_reconcile reconcile --dry-run --json "${SPEC}" 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile --dry-run"
}

@test "the confirmed-creation reconcile summary declares every key it emits" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --accept-defaults --json 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile (confirmed)"
}

@test "the fail-closed reconcile summary declares every key it emits" {
  # A refused create populates the warning set no other path produces, and
  # returns 2 rather than 0 — the summary is still a published artifact and is
  # still bound by the contract.
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults
  mock_stop

  local cfg
  cfg="${BATS_TEST_TMPDIR}/fault.json"
  printf '%s' '{"projects":{"PM":"company"},"createmetaFields":{"10101":"parent-mandatory"},"faults":{"PM":{"status":400}}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # This path returns 2, so the capture must tolerate a non-zero exit — and the
  # exit code is then asserted, because a run that silently succeeded would
  # produce a DIFFERENT summary shape and this test would pass while proving
  # nothing about the fail-closed one.
  local summary rc=0
  summary="$(cmd_reconcile reconcile "${SPEC}" --accept-defaults --json 2> /dev/null)" || rc=$?
  [ "${rc}" -eq 2 ]
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile (fail-closed)"
}
