#!/usr/bin/env bats
# T014 [Phase 2] — the story marker line is excluded from every content
# extraction, and stories[].local_id carries the marker's identifier (or is
# empty when absent). contracts/story-marker.md "Reading rules".

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/parse.sh"
}

_parse_wrapper() {
  printf '%s' "$1" | parse_spec 001-x
}

@test "local_id is the marker's identifier when present" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->\n\nBody.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
}

@test "local_id is empty when the story has no marker at all" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n\nBody.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "" ]
  [ "$(jq -r '.stories[0].marker.state' <<< "$output")" = "absent" ]
}

@test "the marker line never lands in the title, description, or acceptance criteria" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->\n\nAs a user I want X.\n\n- **Given** a thing\n- **When** it happens\n- **Then** it works\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"speckit-jira"* ]]
  [[ "$output" != *"7f3a9c1e40b2d85a"* ]] || [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
}

@test "the marker line never lands in the design section" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=7f3a9c1e40b2d85a -->\n\nBody.\n\n#### Design\n\nSome guidance here.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.stories[0].design' <<< "$output")" = '[{"kind":"guidance","value":"Some guidance here."}]' ]
}

@test "the marker line never lands in priority or estimation extraction" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=7f3a9c1e40b2d85a -->\n\nEstimation: 5\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].priority_logical' <<< "$output")" = "P1" ]
  [ "$(jq -r '.stories[0].estimation' <<< "$output")" = "5" ]
}

@test "a malformed marker still carries its own identifier as local_id and is marked malformed" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=proj-142 -->\n\nBody.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
  [ "$(jq -r '.stories[0].marker.state' <<< "$output")" = "malformed" ]
}

@test "two marker lines in one story section: local_id is a fresh generated id, marker.state is duplicate, both line numbers recorded" {
  local doc
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 -->\n<!-- speckit-jira story=2222222222222222 -->\n\nBody.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].marker.state' <<< "$output")" = "duplicate" ]
  [ -n "$(jq -r '.stories[0].local_id' <<< "$output")" ]
  [ "$(jq -c '.stories[0].marker.lines' <<< "$output")" = "[2,3]" ]
}

@test "the implicit single story (no headings) reads its marker after the H1" {
  local doc
  doc=$'# Only A Title\n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-9 -->\n\nSome prose.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
  [[ "$output" != *"speckit-jira"* ]]
}

@test "reordering and retitling stories keeps each ticket bound to the same local_id" {
  local doc
  doc=$'### User Story 2 - Second (Priority: P2)\n<!-- speckit-jira story=2222222222222222 ticket=PROJ-2 -->\n\nSecond body.\n\n### User Story 1 - First Renamed (Priority: P1)\n<!-- speckit-jira story=1111111111111111 ticket=PROJ-1 -->\n\nFirst body.\n'
  run _parse_wrapper "${doc}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].local_id' <<< "$output")" = "2222222222222222" ]
  [ "$(jq -r '.stories[0].title' <<< "$output")" = "Second" ]
  [ "$(jq -r '.stories[1].local_id' <<< "$output")" = "1111111111111111" ]
  [ "$(jq -r '.stories[1].title' <<< "$output")" = "First Renamed" ]
}

# --- Cross-port parity ------------------------------------------------------

@test "the PowerShell port parses markers identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local doc b p
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->\n\nBody.\n'
  b="$(printf '%s' "${doc}" | parse_spec 001-x)"
  p="$(printf '%s' "${doc}" | pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/Parse.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((Get-JiraParsedSpec -Text \$doc -FolderSlug '001-x'))")"
  [ "${b}" = "${p}" ]
}
