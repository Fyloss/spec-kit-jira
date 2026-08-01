#!/usr/bin/env bats
# T059 [003 US6] — Hook health reported in every run, and NEVER repaired (FR-021,
# FR-022, FR-025, FR-028).
#
# Every reconcile run READS the consuming repository's hook registry, classifies
# all seven declared events, and reports the result in the summary. It does not
# repair anything: `--repair-hooks` existed only to perform a registry write
# FR-022 now forbids, and the flag is gone rather than kept as a no-op.
#
# The classification covers three partitions (present / missing / disabled) and
# three cross-cutting facts (held_disabled, duplicated, unreadable). `repair_hint`
# appears only when something is not `present`, and names the RIGHT remedy for
# each case — which differ in kind: the official install for a missing entry, the
# release flag for a held one, and a manual edit for a leftover the install
# cannot purge. The PowerShell port emits an identical summary (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  WORK="$(mktemp -d)"
  # An unreachable base makes a real mirror write fail-closed instantly; the dry-run
  # cases never touch it. --repair-hooks is independent of the mirror's result.
  export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  # 004 FR-005: the shipped placeholder is now refused outright, so this suite
  # (about hook health, not config resolution) is migrated to a real key with
  # a matching epic-strategy override — both bypass config.yml, which this
  # isolated work dir never has.
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
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
    '# Feature Specification: Health' '' 'A spec that mirrors to Jira.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

# canonical_registry — write a registry in exactly the shape the host install
# produces: one eight-field entry per declared event, owned by `jira`.
canonical_registry() {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  mkdir -p "$(dirname "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  {
    printf 'hooks:\n'
    local e cmd
    for e in "${HOOK_EVENTS[@]}"; do
      cmd="$(register_hooks_command_for "${e}")"
      printf '  %s:\n' "${e}"
      printf '    - extension: jira\n'
      printf '      command: %s\n' "${cmd}"
      printf '      enabled: true\n'
      printf '      optional: false\n'
      printf '      priority: 10\n'
      printf '      prompt: Execute %s?\n' "${cmd}"
      printf '      description: A human-readable sentence.\n'
      printf '      condition: null\n'
    done
  } > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
}

@test "every run reports hook health in the summary, in the contract shape (FR-047)" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  # No extensions.yml yet: every declared event is missing, none present, and
  # the hint names the ONE command that registers them — the official install,
  # which this extension cannot perform for the operator (FR-025).
  [ "$(jq -r '.hook_health.missing | length' <<< "$output")" -eq 7 ]
  [ "$(jq -r '.hook_health.present | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.hook_health.disabled | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.hook_health.unreadable' <<< "$output")" = "false" ]
  [[ "$(jq -r '.hook_health.repair_hint' <<< "$output")" == *"specify extension add"* ]]
}

@test "a registry the install wrote reports healthy, with NO repair hint (FR-021)" {
  canonical_registry
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hook_health.present | length' <<< "$output")" -eq 7 ]
  [ "$(jq -r '.hook_health | has("repair_hint")' <<< "$output")" = "false" ]
}

@test "the run leaves the registry byte-identical — every state, every run (FR-023, SC-007)" {
  canonical_registry
  before="$(shasum -a 256 < "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  cmd_reconcile reconcile --dry-run --json "${SPEC}" > /dev/null
  cmd_reconcile reconcile --json "${SPEC}" > /dev/null 2>&1 || true
  [ "$(shasum -a 256 < "${SPEC_KIT_JIRA_EXTENSIONS_YML}")" = "${before}" ]
}

@test "repair_hint appears ONLY when something is not present (FR-021)" {
  canonical_registry
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$(jq -r '.hook_health | has("repair_hint")' <<< "$output")" = "false" ]

  # Disabled counts as "not present", so the hint returns and names the release
  # flag rather than the install command — the remedies are different in kind.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  disabled="$(config_yaml_to_json "${SPEC_KIT_JIRA_EXTENSIONS_YML}" | jq -c '.hooks.after_implement[0].enabled = false')"
  printf '%s' "$disabled" | config_to_yaml > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$(jq -r '.hook_health.disabled[0]' <<< "$output")" = "after_implement" ]
  [[ "$(jq -r '.hook_health.repair_hint' <<< "$output")" == *"--enable-hook"* ]]
}

@test "a leftover pre-manifest entry is reported as duplicated, with the manual edit (FR-028)" {
  canonical_registry
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  seeded="$(config_yaml_to_json "${SPEC_KIT_JIRA_EXTENSIONS_YML}" \
    | jq -c '.hooks.after_plan += [{"command":"speckit.jira.reconcile","enabled":true}]')"
  printf '%s' "$seeded" | config_to_yaml > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hook_health.duplicated[0]' <<< "$output")" = "after_plan" ]
  [[ "$(jq -r '.hook_health.repair_hint' <<< "$output")" == *"extension: jira"* ]]
}

@test "an unreadable registry reports unreadable, never missing hooks (FR-024)" {
  mkdir -p "$(dirname "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  printf '%s\n' 'hooks:' '  after_plan:' '   - broken' > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hook_health.unreadable' <<< "$output")" = "true" ]
  [ "$(jq -r '.hook_health.missing | length' <<< "$output")" -eq 0 ]
}

@test "the --json summary carries NO key outside the published run-summary contract" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  # run-summary.schema.json declares additionalProperties:false — every top-level
  # key must be one the contract names (the old ad-hoc `hooks` key is gone).
  [ "$(jq -r '[keys[] | select(IN("schema_version","command","dry_run","counts","effects","drift","flags","blockers","hook_health","mutations","actions","warnings","notes","exit_code") | not)] | length' <<< "$output")" -eq 0 ]
}

@test "--repair-hooks is gone: no run can create the registry (T073, FR-022, SC-011)" {
  # The flag existed only to write the registry. It is removed rather than kept
  # as a no-op — a flag named "repair" that no longer repairs would be worse than
  # none (Principle XV, XVI) — and no run of any kind may bring the file into
  # existence, which is the strongest form of "we never write it".
  run cmd_reconcile reconcile --repair-hooks --dry-run --json "${SPEC}"
  [ "$status" -eq 1 ]
  [ ! -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]

  run cmd_reconcile reconcile --json "${SPEC}"
  [ ! -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
}

@test "the PowerShell port reports an identical hook-health summary (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(cmd_reconcile reconcile --dry-run --json "${SPEC}")"
  p="$(SPEC_KIT_JIRA_BASE_URL='https://mock' SPEC_KIT_JIRA_SPEC_SLUG='001-feature' \
       SPEC_KIT_JIRA_PROJECT_KEY='TEST' SPEC_KIT_JIRA_EXTENSIONS_YML="${SPEC_KIT_JIRA_EXTENSIONS_YML}" \
       pwsh -NoProfile -Command "
        Import-Module '${PS_CMD}/Reconcile.psm1' -Force
        \$null = Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','${SPEC}')")"
  [ "${b}" = "${p}" ]
}
