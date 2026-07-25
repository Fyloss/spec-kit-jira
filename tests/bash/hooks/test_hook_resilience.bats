#!/usr/bin/env bats
# T081 [US9] — Hook resilience (FR-046, FR-048, SC-008).
#
# A bridge failure during a hook-triggered reconcile surfaces at most one
# actionable WARNING and NEVER fails the host command: in hook context the
# non-zero exit is downgraded to 0. A hook the operator explicitly disabled stays
# disabled across every upgrade / reinstall / repair — no re-registration ever
# re-enables it. The PowerShell port behaves identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  HOOK_DIR="${ROOT}/scripts/bash/hooks"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # shellcheck source=/dev/null
  source "${HOOK_DIR}/register_hooks.sh"
  WORK="$(mktemp -d)"
  # An unreachable base makes every write fail-closed instantly (connection refused).
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
    '# Feature Specification: Resilience' '' 'A spec that mirrors to Jira.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a bridge failure outside hook context fails the reconcile (baseline)" {
  run cmd_reconcile reconcile --json "${SPEC}"
  # Not a hook: the fail-closed write surfaces a non-zero exit.
  [ "$status" -ne 0 ]
}

@test "a bridge failure IN hook context never fails the host and warns once (FR-046)" {
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile --json "${SPEC}"
  # The host command is unaffected: the mirror's failure is downgraded to exit 0.
  [ "$status" -eq 0 ]
  # Exactly one actionable WARNING is surfaced (at most one, FR-046).
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
  # The summary still reports exit_code 0.
  [ "$(jq -r '.exit_code' <<< "$(grep '^{' <<< "$output")")" = "0" ]
}

@test "an operator-disabled hook stays disabled across repeated repair (FR-048, SC-008)" {
  register_hooks_write "${SPEC_KIT_JIRA_EXTENSIONS_YML}" > /dev/null
  # Operator disables the specify hook.
  local disabled
  disabled="$(config_yaml_to_json "${SPEC_KIT_JIRA_EXTENSIONS_YML}" | jq -c '.hooks.after_specify[0].enabled = false')"
  printf '%s' "$disabled" | config_to_yaml > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
  # Simulate three upgrade/reinstall/repair cycles.
  register_hooks_write "${SPEC_KIT_JIRA_EXTENSIONS_YML}" > /dev/null
  register_hooks_write "${SPEC_KIT_JIRA_EXTENSIONS_YML}" > /dev/null
  register_hooks_write "${SPEC_KIT_JIRA_EXTENSIONS_YML}" > /dev/null
  local json
  json="$(config_yaml_to_json "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  [ "$(jq -r '.hooks.after_specify | length' <<< "$json")" -eq 1 ]
  [ "$(jq -r '.hooks.after_specify[0].enabled' <<< "$json")" = "false" ]
}

@test "the PowerShell port downgrades a hook-context failure identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local PS_CMD="${ROOT}/scripts/powershell/commands"
  local status_ps
  status_ps="$(SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1" SPEC_KIT_JIRA_SPEC_SLUG="001-feature" \
    SPEC_KIT_JIRA_PROJECT_KEY="PROJ" SPEC_KIT_JIRA_EXTENSIONS_YML="${SPEC_KIT_JIRA_EXTENSIONS_YML}" \
    SPEC_KIT_JIRA_HOOK_CONTEXT=1 JIRA_NO_SLEEP=1 JIRA_MAX_ATTEMPTS=1 \
    JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" \
    pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$sw=[System.IO.StringWriter]::new(); \$orig=[Console]::Out; [Console]::SetOut(\$sw)
      \$code = Invoke-JiraReconcile -Arguments @('reconcile','--json','${SPEC}')
      [Console]::SetOut(\$orig)
      [Console]::Out.Write(\$code)")"
  [ "${status_ps}" = "0" ]
}
