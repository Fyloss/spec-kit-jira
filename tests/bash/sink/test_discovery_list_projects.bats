#!/usr/bin/env bats
# T019 [US2] — Accessible-projects listing (FR-004c, research §3).
#
# `discovery_list_projects` paginates GET /rest/api/3/project/search through the
# existing transport (honouring startAt/maxResults with isLast/total), extracts
# key/name/style per page into ONE canonical array (style mapped by the same
# three-valued rules as discovery — null when ambiguous), and fails closed with
# the "no visible project" error on zero results.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
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
  # boot <mock-config-json>
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "lists the accessible projects with key, name, and mapped style" {
  boot '{"projects":{"COMP":"company","TEAM":"team"}}'
  run discovery_list_projects
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].key' <<< "$output")" = "COMP" ]
  [ "$(jq -r '.[0].name' <<< "$output")" = "COMP project" ]
  [ "$(jq -r '.[0].style' <<< "$output")" = "company_managed" ]
  [ "$(jq -r '.[1].key' <<< "$output")" = "TEAM" ]
  [ "$(jq -r '.[1].style' <<< "$output")" = "team_managed" ]
}

@test "an ambiguous project's style is null in the list (three-valued mapping)" {
  boot '{"projects":{"AMBI":"ambiguous"}}'
  run discovery_list_projects
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].style' <<< "$output")" = "null" ]
}

@test "pagination walks every page (pageSize-capped mock, 3 projects over 2 pages)" {
  boot '{"projects":{"AAA":"company","BBB":"team","CCC":"company"},"pageSize":2}'
  run discovery_list_projects
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '.[2].key' <<< "$output")" = "CCC" ]
  # Two paginated calls reached the mock.
  [ "$(mock_calls | grep -c 'project/search')" -eq 2 ]
}

@test "zero visible projects fails closed with the no-visible-project error" {
  boot '{"projects":{}}'
  run discovery_list_projects
  [ "$status" -eq 2 ]
  [[ "$output" == *"no visible project"* ]]
}

@test "the PowerShell port emits a byte-identical list (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot '{"projects":{"AAA":"company","BBB":"team","CCC":"company"},"pageSize":2}'
  run discovery_list_projects
  [ "$status" -eq 0 ]
  local bash_out="$output" ps_out
  ps_out="$(SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${ROOT}/scripts/powershell/sink/jira/Discovery.psm1' -Force
      [Console]::Out.Write((Get-JiraDiscoveryProjectList).List)
    ")"
  [ "$bash_out" = "$ps_out" ]
}
