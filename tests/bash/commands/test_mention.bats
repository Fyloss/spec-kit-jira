#!/usr/bin/env bats
# T086 [US10] — Editing an existing mentioned ticket (FR-049, FR-050, FR-051).
#
# The read-only fetch (FR-050) returns the ticket's content, acceptance criteria,
# priority, labels, status, flag, links, its linked Confluence pages (title + url
# only — page content is never fetched), its parent context one level up, and a
# one-line sibling list. The mention command (FR-049) stamps the spec's identity,
# updates only that ticket, and logs every mutation; a ticket already claimed by
# another spec (FR-051) makes zero writes and refuses with an actionable message.
# The PowerShell port is byte-identical (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/sink/jira"
  CMD_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/commands"
  PS_SINK="${ROOT}/.specify/extensions/jira/scripts/powershell/sink/jira"
  PS_CMD="${ROOT}/.specify/extensions/jira/scripts/powershell/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/mention.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-onboarding"
  export SPEC_KIT_JIRA_FLAGGED_FIELD_ID="customfield_40099"
}

teardown() {
  mock_stop
}

boot() {
  mock_start "${MOCK}/configs/${1:-mention.json}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "fetch_mentioned returns the ticket's content and context (FR-050)" {
  boot
  run fetch_mentioned MENT-1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.priority_logical' <<< "$output")" = "High" ]
  [ "$(jq -r '.status' <<< "$output")" = "In Progress" ]
  [ "$(jq -c '.labels' <<< "$output")" = '["onboarding","ux"]' ]
  [ "$(jq -r '.flagged' <<< "$output")" = "true" ]
  [[ "$(jq -r '.content' <<< "$output")" == *"onboarding checklist"* ]]
  [[ "$(jq -r '.acceptance_criteria' <<< "$output")" == *"five steps"* ]]
}

@test "fetch_mentioned returns Confluence links by title + url only (FR-050)" {
  boot
  run fetch_mentioned MENT-1
  [ "$(jq -r '.confluence_pages | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.confluence_pages[0].title' <<< "$output")" = "Onboarding design notes" ]
  [ "$(jq -r '.confluence_pages[0].url' <<< "$output")" = "https://example.test/wiki/spaces/OPS/pages/12345" ]
  # The Confluence page CONTENT is never fetched — no /wiki request is made.
  ! grep -qi 'wiki' <(mock_calls)
}

@test "fetch_mentioned returns parent context and a sibling one-liner list (FR-050)" {
  boot
  run fetch_mentioned MENT-1
  [ "$(jq -r '.parent_context.key' <<< "$output")" = "MENT-9" ]
  [ "$(jq -r '.parent_context.title' <<< "$output")" = "Onboarding epic" ]
  [ "$(jq -r '.siblings | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.siblings[1].key' <<< "$output")" = "MENT-2" ]
  [ "$(jq -r '.siblings[1].status' <<< "$output")" = "To Do" ]
  [ "$(jq -r '.links[0].key' <<< "$output")" = "MENT-4" ]
}

@test "fetch_mentioned reports flagged=false when no flagged field is configured" {
  boot
  unset SPEC_KIT_JIRA_FLAGGED_FIELD_ID
  run fetch_mentioned MENT-1
  [ "$(jq -r '.flagged' <<< "$output")" = "false" ]
}

@test "mention stamps identity, updates only that ticket, and logs the mutation (FR-049)" {
  boot
  run cmd_mention mention MENT-1 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.command' <<< "$output")" = "mention" ]
  [ "$(jq -r '.mutations | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.mutations[0].ticket' <<< "$output")" = "MENT-1" ]
  # Exactly one write, and it targets only the mentioned ticket's identity property.
  [ "$(grep -c '^PUT' <(mock_calls))" -eq 1 ]
  grep -qE '^PUT /rest/api/3/issue/MENT-1/properties/' <(mock_calls)
}

@test "mention --dry-run predicts the stamp but performs zero writes (FR-033)" {
  boot
  run cmd_mention mention MENT-1 --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mutations | length' <<< "$output")" -eq 1 ]
  ! grep -q '^PUT' <(mock_calls)
}

@test "mention on a ticket claimed by another spec makes zero writes and refuses (FR-051)" {
  boot mention-claimed.json
  run cmd_mention mention MENT-1 --json
  [ "$status" -eq 4 ]
  ! grep -q '^PUT' <(mock_calls)
}

@test "mention requires an issue key argument" {
  boot
  run cmd_mention mention --json
  [ "$status" -eq 1 ]
}

@test "the PowerShell port emits a byte-identical fetch (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  boot
  run fetch_mentioned MENT-1
  [ "$status" -eq 0 ]
  local bash_out="$output" ps_out
  ps_out="$(SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}" JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" \
    JIRA_NO_SLEEP=1 SPEC_KIT_JIRA_FLAGGED_FIELD_ID="customfield_40099" \
    pwsh -NoProfile -Command "
      Import-Module '${PS_SINK}/Discovery.psm1' -Force
      [Console]::Out.Write((Get-JiraMentionedFetch -IssueKey 'MENT-1'))
    ")"
  [ "$bash_out" = "$ps_out" ]
}
