#!/usr/bin/env bats
# T034/T037/T038 [US2] — Team-managed (next-gen) discovery.
#
# Team-managed projects expose PROJECT-OWNED objects (research §3): the hierarchy
# is limited to Epic (parent) / Sub-task (child), and the estimation field is the
# project's own field located by the documented ranking heuristic — never the
# global Story Points custom field, and never a literal name compiled in
# (FR-006). Discovery follows its own per-style path, distinct from the company-
# managed path, and the PowerShell port stays byte-identical (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/.specify/extensions/jira/scripts/powershell/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

boot() {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "detects the next-gen project style as team_managed (research §1)" {
  boot
  run discover_binding TEAM
  [ "$status" -eq 0 ]
  [ "$(jq -r .style <<< "$output")" = "team_managed" ]
}

@test "the hierarchy is Epic (parent) / Sub-task (child) only (research §3)" {
  boot
  run discover_binding TEAM
  [ "$(jq -r '.issue_types | length' <<< "$output")" -eq 3 ]
  # The top non-subtask parent is Epic at hierarchy level 1 — nothing above it.
  [ "$(jq -r '[.issue_types[] | select(.subtask==false) | .hierarchy_level] | max' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.issue_types[] | select(.hierarchy_level==1) | .logical_name' <<< "$output")" = "Epic" ]
}

@test "ranks the project's OWN estimation field, never the global Story Points (research §3)" {
  boot
  run discover_binding TEAM
  [ "$(jq -r '.estimation_candidates[0].id' <<< "$output")" = "customfield_30044" ]
  [ "$(jq -r '.estimation_candidates[0].logical_name' <<< "$output")" = "Effort Points" ]
  # It is the project-scoped field, distinct from the company-managed one.
  [ "$(jq -r '.estimation_candidates[0].id' <<< "$output")" != "customfield_20011" ]
}

@test "team-managed discovery follows its own path (distinct results from company)" {
  boot
  run discover_binding TEAM
  # This project has no flagged/impediment field of its own.
  [ "$(jq -r '.flagged_field' <<< "$output")" = "null" ]
  [ "$(jq -r '.statuses[] | select(.name=="Won'\''t Do") | .status_category' <<< "$output")" = "done" ]
}

@test "the PowerShell port emits a byte-identical binding (NFR-1)" {
  boot
  run discover_binding TEAM
  [ "$status" -eq 0 ]
  local bash_out="$output"
  local ps_out
  ps_out="$(SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${PS_SINK}/Discovery.psm1' -Force
      [Console]::Out.Write((Get-JiraDiscoveryBinding -ProjectKey 'TEAM'))
    ")"
  [ "$bash_out" = "$ps_out" ]
}
