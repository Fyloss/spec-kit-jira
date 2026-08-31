#!/usr/bin/env bats
# The CONFIG ceremony's run summary declares every key and status it emits.
#
# `contracts/run-summary.schema.json` is the published contract for `--json`
# output, and `additionalProperties: false` means a key the schema does not
# declare makes the summary INVALID — not merely undocumented. Until this file
# existed, nothing checked that: the schema was referenced in exactly one place
# in the whole suite, a comment in test_config_determinism.bats.
#
# The cost of that gap is measured, not hypothetical. The schema had drifted
# SEVEN items behind both ports across three features — `effects.personal` (030),
# `effects.field_defaults` and `effects.task_mirror` (011), the `would_create`
# and `inert` statuses, and the top-level `provisional` and `rerun_guidance`
# (030) — so every ceremony summary was invalid against its own contract on every
# run, for that whole period. It was found by reading the schema next to the
# code, which is not a process anyone can rely on.
#
# The three shapes below are covered because the ceremony assembles `effects`
# through TWO different helpers: the main path and the degraded path. They can
# drift independently, and the degraded one is where the retired hook verdict
# lived longest.
#
# Reconcile's summary is covered by its own file, test_reconcile_summary_schema.bats
# — it needs a different harness. The detection logic is shared through
# tests/bash/helpers/summary_schema.bash so the two cannot disagree about the
# contract; that helper has its own guard in ci/test_summary_schema_helper.bats.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/summary_schema.bash"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${WORK}/.specify"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

boot() {
  mock_start "${MOCK}/configs/default.json" bash
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "the config ceremony summary declares every key and status it emits" {
  boot
  local summary
  summary="$(cmd_config config --child-type COMP=Story --json 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "config"
}

@test "the --dry-run ceremony summary declares every key and status it emits" {
  # The dry-run path is where `would_create` comes from, and it was one of the
  # seven values the schema did not declare.
  boot
  local summary
  summary="$(cmd_config config --child-type COMP=Story --dry-run --json 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "config --dry-run"
}

@test "the degraded ceremony summary declares every key and status it emits" {
  # A SEPARATE effects assembly from the main path, so it drifts on its own —
  # and the only producer of the top-level `provisional` and `rerun_guidance`,
  # two of the seven undeclared items.
  unset SPEC_KIT_JIRA_BASE_URL
  local summary
  summary="$(cmd_config config --json 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "config (degraded)"
}
