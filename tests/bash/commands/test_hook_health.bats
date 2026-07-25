#!/usr/bin/env bats
# T082 [US9] — Hook health reported in every run + one-command --repair-hooks (FR-047).
#
# Every reconcile run checks hook health and reports it in the summary; a run with
# --repair-hooks performs the one-command repair, after which the same run reports
# the hooks healthy. In dry-run --repair-hooks previews without writing. The
# PowerShell port emits an identical summary (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/commands"
  PS_CMD="${ROOT}/.specify/extensions/jira/scripts/powershell/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  WORK="$(mktemp -d)"
  # An unreachable base makes a real mirror write fail-closed instantly; the dry-run
  # cases never touch it. --repair-hooks is independent of the mirror's result.
  export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_PROJECT_KEY="PROJ"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT
  unset SPEC_KIT_JIRA_HOOK_CONTEXT

  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Health' '' 'A spec that mirrors to Jira.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "every run reports hook health in the summary, in the contract shape (FR-047)" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  # No extensions.yml yet: all six lifecycle events are missing, none present,
  # and the one-command repair hint is surfaced (run-summary.schema.json).
  [ "$(jq -r '.hook_health.missing | length' <<< "$output")" -eq 6 ]
  [ "$(jq -r '.hook_health.present | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.hook_health.disabled | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.hook_health.repair_hint' <<< "$output")" == *"repair-hooks"* ]]
}

@test "the --json summary carries NO key outside the published run-summary contract" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  # run-summary.schema.json declares additionalProperties:false — every top-level
  # key must be one the contract names (the old ad-hoc `hooks` key is gone).
  [ "$(jq -r '[keys[] | select(IN("schema_version","command","dry_run","counts","effects","drift","flags","blockers","hook_health","mutations","actions","warnings","notes","exit_code") | not)] | length' <<< "$output")" -eq 0 ]
}

@test "--repair-hooks registers the hooks and the same run then reports healthy (FR-047)" {
  run cmd_reconcile reconcile --repair-hooks --dry-run --json "${SPEC}"
  # A dry-run repair previews only — the file is not written, health still degraded.
  [ "$status" -eq 0 ]
  [ ! -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
  [ "$(jq -r '.hook_health.missing | length' <<< "$output")" -eq 6 ]

  # A real --repair-hooks run writes the file and the same run reports healthy. The
  # mirror write itself fails-closed against the unreachable base, but the repair is
  # independent of the mirror's result, so the hooks are registered regardless.
  run cmd_reconcile reconcile --repair-hooks --json "${SPEC}"
  [ -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
  [ "$(jq -r '.hook_health.present | length' <<< "$(grep '^{' <<< "$output")")" -eq 6 ]
  [ "$(jq -r '.hook_health | has("repair_hint")' <<< "$(grep '^{' <<< "$output")")" = "false" ]
}

@test "the PowerShell port reports an identical hook-health summary (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(cmd_reconcile reconcile --dry-run --json "${SPEC}")"
  p="$(SPEC_KIT_JIRA_BASE_URL='https://mock' SPEC_KIT_JIRA_SPEC_SLUG='001-feature' \
       SPEC_KIT_JIRA_PROJECT_KEY='PROJ' SPEC_KIT_JIRA_EXTENSIONS_YML="${SPEC_KIT_JIRA_EXTENSIONS_YML}" \
       pwsh -NoProfile -Command "
        Import-Module '${PS_CMD}/Reconcile.psm1' -Force
        \$null = Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','${SPEC}')")"
  [ "${b}" = "${p}" ]
}
