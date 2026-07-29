#!/usr/bin/env bats
# T021 [003 US2] — Hook resilience under `optional: false` (FR-015, FR-020, SC-008).
#
# Two guarantees that are easy to confuse, and this suite keeps them apart.
#
# 1. NON-BLOCKING OUTCOME survives the switch to `optional: false`. That flag
#    decides whether the agent PERFORMS the hook, not whether a failure
#    propagates (research R4). Every bridge fault must still leave the host
#    command's exit code untouched: in hook context a non-zero exit is downgraded
#    to 0 after exactly one actionable warning.
#
# 2. AN OPERATOR'S DISABLE SURVIVES A REINSTALL — as an EFFECT, not as a field.
#    `specify extension add` rewrites `enabled: true` unconditionally and this
#    extension may not correct it (FR-022), so the old assertion — that the
#    registry still reads `enabled: false` after a repair — was asserting
#    something upstream makes impossible (research R5). What is guaranteed
#    instead, and what these cases assert, is that NO BRIDGE STEP RUNS for a
#    recorded event whatever the registry currently says.
#
# The PowerShell port behaves identically (NFR-1).

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
  # 004 FR-005: the shipped placeholder is now refused outright, so this suite
  # (about hook resilience, not config resolution) is migrated to a real key
  # with a matching epic-strategy override — both bypass config.yml, which
  # this isolated work dir never has.
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export SPEC_KIT_JIRA_EPIC_STRATEGY="per_repo"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  # A minimal override supplying the issue type the assembly guard requires —
  # this suite has no persisted binding to resolve one from.
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004"}'
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

@test "every bridge fault leaves the host exit code untouched under optional:false (FR-015)" {
  # The faults reachable without a live Jira: an unreachable base (fail-closed
  # write), an unparseable spec, and a malformed lifecycle payload. Under
  # `optional: false` the agent performs the hook, so each of these now happens
  # inside a host command that must still succeed.
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]

  local bad="${WORK}/bad.md"
  printf '%s\n' 'not a specification at all' > "${bad}"
  run cmd_reconcile reconcile --json "${bad}"
  [ "$status" -eq 0 ]

  SPEC_KIT_JIRA_LIFECYCLE='{not json' run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
}

@test "a recorded event is inert at dispatch — no Jira call, no warning (FR-020)" {
  # The operator's decision lives in OUR file, so it survives the reinstall that
  # rewrote the registry to `enabled: true`.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  config_hooks_disabled_add after_specify "${JIRA_CONFIG_DIR}" > /dev/null

  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  # Inert means SILENT: no warning, no summary, nothing at all. A notice on every
  # lifecycle command for an event the operator deliberately turned off is exactly
  # the noise FR-020 forbids.
  [ -z "$output" ]
}

@test "the guard is honoured whatever the registry currently says (FR-007, SC-005)" {
  # Reproduce the state a reinstall leaves behind: the registry says enabled,
  # the record says the operator disabled it. The record wins at dispatch.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}" "$(dirname "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  printf '%s\n' \
    'hooks:' \
    '  after_specify:' \
    '    - extension: jira' \
    '      command: speckit.jira.reconcile' \
    '      enabled: true' > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
  config_hooks_disabled_add after_specify "${JIRA_CONFIG_DIR}" > /dev/null

  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # An event that is NOT recorded still runs — the guard is per event, not global.
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ -n "$output" ]
}

@test "no run of any kind brings the registry into existence (FR-022, SC-011)" {
  rm -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  cmd_reconcile reconcile --json "${SPEC}" > /dev/null 2>&1 || true
  cmd_reconcile reconcile --dry-run --json "${SPEC}" > /dev/null 2>&1 || true
  [ ! -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
}

@test "the PowerShell port downgrades a hook-context failure identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local PS_CMD="${ROOT}/scripts/powershell/commands"
  local status_ps
  status_ps="$(SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1" SPEC_KIT_JIRA_SPEC_SLUG="001-feature" \
    SPEC_KIT_JIRA_PROJECT_KEY="TEST" SPEC_KIT_JIRA_EPIC_STRATEGY="per_repo" \
    SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004"}' \
    SPEC_KIT_JIRA_EXTENSIONS_YML="${SPEC_KIT_JIRA_EXTENSIONS_YML}" \
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
