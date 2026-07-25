#!/usr/bin/env bats
# T091 — Opt-in LIVE suite (SC-001 zero-churn + SC-008 reinstall survival).
#
# This suite talks to a REAL Jira Cloud instance, so it is opt-in and non-blocking:
# every test skips unless SPEC_KIT_JIRA_LIVE=1 and live credentials + a scratch
# project are supplied. On fork PRs (no secrets) the whole file skips, so it never
# blocks the merge gate (NFR-6). Run it locally or from a trusted branch with:
#
#   SPEC_KIT_JIRA_LIVE=1 \
#   SPEC_KIT_JIRA_BASE_URL=https://<your-site>.atlassian.net \
#   JIRA_EMAIL=you@example.com JIRA_API_TOKEN=… \
#   SPEC_KIT_JIRA_PROJECT_KEY=SCRATCH \
#   bats tests/live/test_live_zero_churn.bats
#
# SC-001: a second reconcile of an unchanged corpus performs zero writes of every
# kind. SC-008: a forced reinstall (a second config run) preserves the team config
# and the registered hooks, with self-repair on the next run and no operator step.

require_live() {
  [ "${SPEC_KIT_JIRA_LIVE:-}" = "1" ] || skip "live suite disabled (set SPEC_KIT_JIRA_LIVE=1 to enable)"
  [ -n "${SPEC_KIT_JIRA_BASE_URL:-}" ] || skip "SPEC_KIT_JIRA_BASE_URL not set"
  [ -n "${JIRA_EMAIL:-}" ] || skip "JIRA_EMAIL not set"
  [ -n "${JIRA_API_TOKEN:-}" ] || skip "JIRA_API_TOKEN not set"
  [ -n "${SPEC_KIT_JIRA_PROJECT_KEY:-}" ] || skip "SPEC_KIT_JIRA_PROJECT_KEY not set"
}

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  WORK="$(mktemp -d)"
  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Live Zero-Churn' '' 'A spec mirrored to a live Jira project.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "SC-001: a second reconcile of an unchanged corpus performs zero writes" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # First run establishes the tickets; the second must be a pure zero-churn re-run.
  cmd_reconcile reconcile --json "${SPEC}" > /dev/null
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
}

@test "SC-008: a forced reinstall preserves the team config and the registered hooks" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  export SPEC_KIT_JIRA_README="${WORK}/README.md"
  mkdir -p "${JIRA_CONFIG_DIR}"
  printf 'projects:\n  - key: %s\n    style: company_managed\n' "${SPEC_KIT_JIRA_PROJECT_KEY}" \
    > "${JIRA_CONFIG_DIR}/config.yml"

  cmd_config config --json > /dev/null
  [ -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  [ -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
  local before_cfg before_hooks
  before_cfg="$(cat "${JIRA_CONFIG_DIR}/config.local.yml")"
  before_hooks="$(cat "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"

  # A forced reinstall (a second config run) must not lose either artifact.
  cmd_config config --json > /dev/null
  [ -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  [ -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
  [ "$(cat "${JIRA_CONFIG_DIR}/config.local.yml")" = "${before_cfg}" ]
  [ "$(cat "${SPEC_KIT_JIRA_EXTENSIONS_YML}")" = "${before_hooks}" ]
}
