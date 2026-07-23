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
  CMD_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/commands"
  PS_CMD="${ROOT}/.specify/extensions/jira/scripts/powershell/commands"
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
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "the --json summary reports discovery, hooks, and readme effects separately" {
  boot
  run cmd_config config --json
  [ "$status" -eq 0 ]
  # All three effects are present as distinct, named sections.
  [ "$(jq -r '.effects | keys | sort | join(",")' <<< "$output")" = "discovery,hooks,readme" ]
  # The discovery effect performed its write this phase.
  [ "$(jq -r '.effects.discovery.status' <<< "$output")" = "written" ]
  # Every effect carries a status from the documented enumeration.
  [ "$(jq -r '.effects.hooks | has("status")' <<< "$output")" = "true" ]
  [ "$(jq -r '.effects.readme | has("status")' <<< "$output")" = "true" ]
}

@test "the prose summary names each of the three effects" {
  boot
  run cmd_config config
  [ "$status" -eq 0 ]
  [[ "$output" == *"discovery"* ]]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"readme"* ]]
}

@test "the PowerShell port reports the same three effects (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot
  run cmd_config config --json
  local bash_out="$output"

  local pswork
  pswork="$(mktemp -d)"
  cp -R "${FIXTURE}/.specify" "${pswork}/.specify"
  local ps_out
  ps_out="$(SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_CONFIG_DIR="${pswork}/.specify/jira" \
    JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Config.psm1' -Force
      [void](Invoke-JiraConfig -Arguments @('config','--json'))
    ")"
  [ "$bash_out" = "$ps_out" ]
  rm -rf "${pswork}"
}
