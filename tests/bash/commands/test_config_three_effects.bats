#!/usr/bin/env bats
# T043 [US1] — The config run reports three effects separately (FR-054).
#
# A single `/speckit.jira-mirror.config` run has three effects — metadata discovery,
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
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  # All effects are present as distinct, named sections (002 adds gitignore;
  # 011 adds field_defaults; 030 adds personal).
  [ "$(jq -r '.effects | keys | sort | join(",")' <<< "$output")" = "discovery,field_defaults,gitignore,hooks,personal,readme,task_mirror" ]
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
  run --separate-stderr cmd_config config --child-type COMP=Story --json
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
      printf '  %s:\n  - extension: jira-mirror\n    command: %s\n    enabled: %s\n' "${e}" "${cmd}" "${enabled}"
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
  run --separate-stderr cmd_config config --child-type COMP=Story --json
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
  run --separate-stderr cmd_config config --child-type COMP=Story --dry-run --json
  [ "$status" -eq 0 ]
  # The report names the held event...
  [[ "$(jq -r '.effects.hooks.detail' <<< "$output")" == *"after_implement"* ]]
  # ...and nothing was written.
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = "[]" ]
}

@test "the ceremony reports the hook effect with the read-only vocabulary (FR-021)" {
  seed_disabled_registry
  boot '{"projects":{"COMP":"company"}}'
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  # `held_disabled` — not a write outcome, because nothing was written.
  [ "$(jq -r '.effects.hooks.status' <<< "$output")" = "held_disabled" ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$output")" == *"--enable-hook"* ]]
}

# =============================================================================
# T083 [Phase 9] — the §7.1 per-role audit and the §7.3 promotion note
# (010, contracts/role-mapping.md). SAFE (Epic 2 / Feature 1 / Story 0 /
# Sub-task -1) is unambiguous at every level, so declaring `specification`
# and answering `task` while leaving `story` alone gives one role resolved
# from each of the three sources in a SINGLE run.
# =============================================================================

@test "T083 — the §7.1 per-role audit reports one role from each source, in prose and --json" {
  local sw="${WORK}/.specify/jira"
  mkdir -p "${sw}"
  {
    printf 'projects:\n'
    printf '  - key: SAFE\n'
    printf '    hierarchy:\n'
    printf '      specification: Epic\n'
    printf 'routing_default: SAFE\n'
  } > "${sw}/config.yml"
  export JIRA_CONFIG_DIR="${sw}"
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run --separate-stderr cmd_config config --issue-type SAFE=task=Sub-task --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.discovery.projects.SAFE.roles.specification.logical_name' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.effects.discovery.projects.SAFE.roles.specification.source' <<< "$output")" = "declared" ]
  [ "$(jq -r '.effects.discovery.projects.SAFE.roles.story.logical_name' <<< "$output")" = "Story" ]
  [ "$(jq -r '.effects.discovery.projects.SAFE.roles.story.source' <<< "$output")" = "derived" ]
  [ "$(jq -r '.effects.discovery.projects.SAFE.roles.task.logical_name' <<< "$output")" = "Sub-task" ]
  [ "$(jq -r '.effects.discovery.projects.SAFE.roles.task.source' <<< "$output")" = "operator" ]

  run cmd_config config --issue-type SAFE=task=Sub-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"specification: Epic (declared)"* ]]
  [[ "$output" == *"story: Story (derived)"* ]]
  [[ "$output" == *"task: Sub-task (operator)"* ]]
}

@test "T083 — the §7.3 promotion note names the role that resolved from an operator answer, as a note, exit still 0" {
  local sw="${WORK}/.specify/jira"
  mkdir -p "${sw}"
  {
    printf 'projects:\n'
    printf '  - key: SAFE\n'
    printf 'routing_default: SAFE\n'
  } > "${sw}/config.yml"
  export JIRA_CONFIG_DIR="${sw}"
  mock_start "${MOCK}/configs/safe.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run --separate-stderr cmd_config config --issue-type SAFE=task=Sub-task --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *'config: project SAFE: commit this so your team mirrors identically —'* ]]
  [[ "$stderr" == *'    task: "Sub-task"'* ]]
  # Never an escalation: exit 0, no WARNING line.
  [ "$(grep -c '^WARNING: ' <<< "$stderr")" -eq 0 ]
}

@test "a healthy registry reports healthy and says the registry was not modified" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  mkdir -p "${WORK}/.specify"
  {
    printf 'hooks:\n'
    for e in "${HOOK_EVENTS[@]}"; do
      cmd="$(register_hooks_command_for "${e}")"
      printf '  %s:\n  - extension: jira-mirror\n    command: %s\n    enabled: true\n' "${e}" "${cmd}"
      printf '    optional: false\n    priority: 10\n    prompt: Execute %s?\n' "${cmd}"
      printf '    description: Mirror.\n    condition: null\n'
    done
  } > "${WORK}/.specify/extensions.yml"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  boot '{"projects":{"COMP":"company"}}'
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$(jq -r '.effects.hooks.status' <<< "$output")" = "healthy" ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$output")" == *"registry was not modified"* ]]
}

# =============================================================================
# T075 [Phase 5, US3, 022] — the task-mirror per-project effect line, all
# three forms (contract §6, FR-013): recorded, unchanged, not recorded.
# =============================================================================

@test "T075 — the task-mirror effect line reports all three forms: recorded, unchanged, not recorded" {
  boot
  # Run 1: no answer this run for COMP -> "not recorded".
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Task mirror: COMP — not recorded; today's behaviour applies"* ]]

  # Run 2: answered this run -> "recorded".
  run --separate-stderr cmd_config config --child-type COMP=Story --task-mirror COMP=checklist --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Task mirror: COMP — checklist (recorded)"* ]]

  # Run 3: already recorded, no new answer -> "unchanged".
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Task mirror: COMP — checklist (unchanged)"* ]]
}

# =============================================================================
# T060 [030, US3] — the personal effect statuses: created, unchanged,
# would_create (contracts/personal-config-creation.md)
# =============================================================================

@test "T060 — personal reports created on a fresh repository, with the catalogue ids in the comment" {
  boot
  export JIRA_EMAIL="op@example.com"
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.personal.status' <<< "$output")" = "created" ]
  [ -f "${JIRA_CONFIG_DIR}/personal.yml" ]
  grep -qx 'email: op@example.com' "${JIRA_CONFIG_DIR}/personal.yml"
  grep -qx '# team: alpha' "${JIRA_CONFIG_DIR}/personal.yml"
}

@test "T060 — personal reports unchanged when the file already exists, byte-identical" {
  boot
  mkdir -p "${JIRA_CONFIG_DIR}"
  printf 'email: kept@example.com\n# custom comment\n' > "${JIRA_CONFIG_DIR}/personal.yml"
  cp "${JIRA_CONFIG_DIR}/personal.yml" "${WORK}/before-personal.yml"
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.personal.status' <<< "$output")" = "unchanged" ]
  run cmp "${WORK}/before-personal.yml" "${JIRA_CONFIG_DIR}/personal.yml"
  [ "$status" -eq 0 ]
}

@test "T060 — personal reports would_create under --dry-run, and writes nothing" {
  boot
  run --separate-stderr cmd_config config --child-type COMP=Story --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.effects.personal.status' <<< "$output")" = "would_create" ]
  [ ! -f "${JIRA_CONFIG_DIR}/personal.yml" ]
}
