#!/usr/bin/env bats
# T043 [US1] — The config run reports three effects separately (FR-054).
#
# A single `/speckit.jira.config` run has three effects — metadata discovery,
# `after_*` hook registration, and managed-README-block management — and the run
# summary reports each SEPARATELY (FR-054). At this phase only the discovery
# effect performs its write; the hooks and README effects are wired in later
# increments (T085 Phase 12, T065 Phase 8). This test asserts the summary
# STRUCTURE: all three effects appear as distinct, named sections. When those
# increments land they change the hooks/readme effect status; the sections are
# already present here.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
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
  # backend defaults to the curl shim; the NFR-1 cross-port test below opts
  # into the real pwsh server, since a native pwsh HTTP client cannot reach
  # the shim's sentinel MOCK_BASE_URL (contracts/mock-driver.md).
  mock_start "${MOCK}/configs/default.json" "${1:-bash}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "the --json summary reports discovery, hooks, and readme effects separately" {
  boot
  run cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  # All effects are present as distinct, named sections (002 adds gitignore).
  [ "$(jq -r '.effects | keys | sort | join(",")' <<< "$output")" = "discovery,gitignore,hooks,readme" ]
  # The discovery effect performed its write this phase.
  [ "$(jq -r '.effects.discovery.status' <<< "$output")" = "written" ]
  # Every effect carries a status from the documented enumeration.
  [ "$(jq -r '.effects.hooks | has("status")' <<< "$output")" = "true" ]
  [ "$(jq -r '.effects.readme | has("status")' <<< "$output")" = "true" ]
  [ "$(jq -r '.effects.gitignore | has("status")' <<< "$output")" = "true" ]
}

@test "the prose summary names each of the four effects" {
  boot
  run cmd_config config --child-type COMP=Story
  [ "$status" -eq 0 ]
  [[ "$output" == *"discovery"* ]]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"readme"* ]]
  # T093 — the gitignore effect modifies a tracked file; the default output
  # must say so, not only the --json summary.
  [[ "$output" == *"  gitignore: "* ]]
}

@test "the PowerShell port reports the same three effects (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot powershell
  run cmd_config config --child-type COMP=Story --json
  local bash_out="$output"

  local pswork
  pswork="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${pswork}/.specify"
  local ps_out
  ps_out="$(SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_CONFIG_DIR="${pswork}/.specify/jira" \
    JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Config.psm1' -Force
      [void](Invoke-JiraConfig -Arguments @('config','--child-type','COMP=Story','--json'))
    ")"
  [ "$bash_out" = "$ps_out" ]
  rm -rf "${pswork}"
}

# =============================================================================
# T025 [003 US2] — The ceremony records the operator's disable decision
# =============================================================================
#
# `specify extension add` writes `enabled: true` unconditionally on every install
# and upgrade (research R5), so the hook registry cannot carry the operator's
# decision across a reinstall. The ceremony is where the extension observes it —
# it is the only moment the extension reads the registry with intent — and it
# records it in the gitignored local binding, which survives.
#
# Three separations matter and are asserted here:
#   * the CEREMONY records; the health CLASSIFICATION writes nothing anywhere;
#   * the record goes in OUR file; the registry is not edited to match (FR-022);
#   * --dry-run predicts the record write without performing it (Constitution XI).

# seed_disabled_registry — a COMPLETE registry, as the install writes it, with
# one entry the operator turned off. Completeness matters: a registry that is
# also missing entries reports `incomplete`, which is the more severe state, and
# the held event would be reported in the detail rather than the status.
seed_disabled_registry() {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  mkdir -p "${WORK}/.specify"
  local e cmd enabled
  {
    printf 'hooks:\n'
    for e in "${HOOK_EVENTS[@]}"; do
      cmd="$(register_hooks_command_for "${e}")"
      enabled=true
      [[ "${e}" == "after_implement" ]] && enabled=false
      printf '  %s:\n  - extension: jira\n    command: %s\n    enabled: %s\n' "${e}" "${cmd}" "${enabled}"
      printf '    optional: false\n    priority: 10\n    prompt: Execute %s?\n' "${cmd}"
      printf '    description: Mirror.\n    condition: null\n'
    done
  } > "${WORK}/.specify/extensions.yml"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
}

@test "the ceremony records an observed enabled:false into the disable record (R5 step 1)" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  seed_disabled_registry
  boot '{"projects":{"COMP":"company"}}'
  run cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = '["after_implement"]' ]
  # And it is surfaced in the health object the summary carries.
  [ "$(jq -r '.hook_health.held_disabled | index("after_implement") != null' <<< "$output")" = "true" ]
}

@test "the health classification itself writes NOTHING anywhere (data-model)" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  seed_disabled_registry
  register_hooks_health "${SPEC_KIT_JIRA_EXTENSIONS_YML}" > /dev/null
  # Classifying observed the disabled entry; it recorded nothing. Only the
  # ceremony records — that separation is what keeps health a pure function.
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = "[]" ]
}

@test "--dry-run predicts the record write without performing it (Constitution XI)" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  seed_disabled_registry
  boot '{"projects":{"COMP":"company"}}'
  run cmd_config config --child-type COMP=Story --dry-run --json
  [ "$status" -eq 0 ]
  # The report names the held event...
  [[ "$(jq -r '.effects.hooks.detail' <<< "$output")" == *"after_implement"* ]]
  # ...and nothing was written.
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = "[]" ]
}

@test "the ceremony reports the hook effect with the read-only vocabulary (FR-021)" {
  seed_disabled_registry
  boot '{"projects":{"COMP":"company"}}'
  run cmd_config config --child-type COMP=Story --json
  # `held_disabled` — not a write outcome, because nothing was written.
  [ "$(jq -r '.effects.hooks.status' <<< "$output")" = "held_disabled" ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$output")" == *"--enable-hook"* ]]
}

@test "a healthy registry reports healthy and says the registry was not modified" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  mkdir -p "${WORK}/.specify"
  {
    printf 'hooks:\n'
    for e in "${HOOK_EVENTS[@]}"; do
      cmd="$(register_hooks_command_for "${e}")"
      printf '  %s:\n  - extension: jira\n    command: %s\n    enabled: true\n' "${e}" "${cmd}"
      printf '    optional: false\n    priority: 10\n    prompt: Execute %s?\n' "${cmd}"
      printf '    description: Mirror.\n    condition: null\n'
    done
  } > "${WORK}/.specify/extensions.yml"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  boot '{"projects":{"COMP":"company"}}'
  run cmd_config config --child-type COMP=Story --json
  [ "$(jq -r '.effects.hooks.status' <<< "$output")" = "healthy" ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$output")" == *"registry was not modified"* ]]
}
