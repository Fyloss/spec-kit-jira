#!/usr/bin/env bats
# T043 [US1] — The config run reports its effects separately (FR-054).
#
# A `/speckit.jira-mirror.config` run has several effects and the run summary
# reports each SEPARATELY (FR-054). The set has grown and shrunk over time —
# 002 added gitignore, 011 added field_defaults and task_mirror, 030 added
# personal, and 034 REMOVED hooks — so what this file pins is the summary
# STRUCTURE: every effect the ceremony performs appears as its own named
# section, and nothing else does.
#
# 034: the hooks effect is gone because the extension no longer reads the hook
# registry (FR-001, FR-002). The two assertions that it is absent are not
# redundant with each other — the JSON summary and the human-rendered
# `Effects:` block are separate consumers of the same object, and the renderer
# iterates its own fixed order.

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

@test "the --json summary reports each effect separately, and no hooks effect (034 FR-002)" {
  boot
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  # All effects are present as distinct, named sections (002 adds gitignore;
  # 011 adds field_defaults; 030 adds personal; 034 removes hooks).
  [ "$(jq -r '.effects | keys | sort | join(",")' <<< "$output")" = "discovery,field_defaults,gitignore,personal,readme,task_mirror" ]
  # 034 FR-002: the ceremony no longer reports on the hook registry at all.
  # `additionalProperties: false` in run-summary.schema.json makes a summary
  # still carrying this key invalid, not merely unexpected.
  [ "$(jq -r '.effects | has("hooks")' <<< "$output")" = "false" ]
  # The discovery effect performed its write this phase.
  [ "$(jq -r '.effects.discovery.status' <<< "$output")" = "written" ]
  # Every remaining effect carries a status from the documented enumeration.
  [ "$(jq -r '.effects.readme | has("status")' <<< "$output")" = "true" ]
  [ "$(jq -r '.effects.gitignore | has("status")' <<< "$output")" = "true" ]
}

@test "the prose summary names each effect, and never the word hooks (034 FR-002)" {
  boot
  run cmd_config config --child-type COMP=Story
  [ "$status" -eq 0 ]
  [[ "$output" == *"discovery"* ]]
  [[ "$output" == *"readme"* ]]
  # T093 — the gitignore effect modifies a tracked file; the default output
  # must say so, not only the --json summary.
  [[ "$output" == *"  gitignore: "* ]]
  # The human path is a separate consumer of the effects object from the JSON
  # one, and it renders from its own fixed order — so it needs its own
  # assertion (034 FR-008).
  [[ "$output" != *"  hooks: "* ]]
}

@test "the PowerShell port reports the same effects (NFR-1)" {
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
