#!/usr/bin/env bats
# T050 [US3] — Engine parser: title ladder + never-empty description (FR-013,
# FR-014, SC-002), plus Gherkin / Design / priority / estimation extraction
# (FR-015–FR-018). The parser is NEUTRAL: zero Jira identifiers, never sources
# sink/. The PowerShell port produces byte-identical output (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/parse.sh"
}

# --- Title ladder (FR-013) --------------------------------------------------

@test "title ladder: an explicit Title: line wins over everything" {
  run bash -c "printf '%s\n' 'Title: The Chosen Title' '# An H1 Heading' | { source '${ENGINE_DIR}/parse.sh'; parse_title 001-some-slug; }"
  [ "$status" -eq 0 ]
  [ "$output" = "The Chosen Title" ]
}

@test "title ladder: falls back to the first H1 when no Title: line" {
  run bash -c "printf '%s\n' '# Feature Specification: Rich Tickets' '## Summary' 'ignore me' | { source '${ENGINE_DIR}/parse.sh'; parse_title 001-some-slug; }"
  [ "$status" -eq 0 ]
  [ "$output" = "Rich Tickets" ]
}

@test "title ladder: falls back to a user-story section title" {
  run bash -c "printf '%s\n' '### User Story 3 - Rich, reliable content (Priority: P1)' 'body' | { source '${ENGINE_DIR}/parse.sh'; parse_title 001-some-slug; }"
  [ "$status" -eq 0 ]
  [ "$output" = "Rich, reliable content" ]
}

@test "title ladder: falls back to the first non-empty paragraph" {
  run bash -c "printf '%s\n' '' 'A plain sentence of need.' 'more' | { source '${ENGINE_DIR}/parse.sh'; parse_title 001-some-slug; }"
  [ "$status" -eq 0 ]
  [ "$output" = "A plain sentence of need." ]
}

@test "title ladder: falls back to the humanised folder slug last" {
  run bash -c "printf '%s' '' | { source '${ENGINE_DIR}/parse.sh'; parse_title 001-jira-reconcile-engine; }"
  [ "$status" -eq 0 ]
  [ "$output" = "jira reconcile engine" ]
}

@test "title NEVER comes from a ## Summary section (FR-013)" {
  run bash -c "printf '%s\n' '# Real Title' '## Summary' 'Summary derived title' | { source '${ENGINE_DIR}/parse.sh'; parse_title 001-slug; }"
  [ "$output" = "Real Title" ]
  [[ "$output" != *"Summary"* ]]
}

# --- Never-empty description (FR-014, SC-002) -------------------------------

@test "description is a non-empty structured block tree" {
  run bash -c "printf '%s\n' '# T' '' 'We need a reconcile bridge for specs.' | { source '${ENGINE_DIR}/parse.sh'; parse_description_blocks; }"
  [ "$status" -eq 0 ]
  n="$(printf '%s' "$output" | jq '.blocks | length')"
  [ "$n" -ge 1 ]
  [[ "$output" == *"reconcile bridge"* ]]
}

@test "description is never empty even with NO ## Summary and no prose" {
  run bash -c "printf '%s\n' '# Only A Title' | { source '${ENGINE_DIR}/parse.sh'; parse_description_blocks; }"
  [ "$status" -eq 0 ]
  n="$(printf '%s' "$output" | jq '.blocks | length')"
  [ "$n" -ge 1 ]
  # A first non-empty paragraph field is always present (feature 016: text
  # lives on span[0].text within the paragraph's spans array).
  empty="$(printf '%s' "$output" | jq '[.blocks[] | select(.type=="paragraph") | .spans[0].text] | map(select(length>0)) | length')"
  [ "$empty" -ge 1 ]
}

# --- Gherkin extraction (FR-015) --------------------------------------------
# Feature 016: each clause is an inline sequence of spans, not a plain string
# — .given[0] is now the FIRST clause's span array; .given[0][0].text is that
# clause's (unmarked, in these plain-text fixtures) literal text.

@test "extracts a Given/When/Then scenario from one-clause-per-line" {
  run bash -c "printf '%s\n' '- **Given** a signed-in user' '- **When** they open the board' '- **Then** widgets load' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].given[0][0].text')" = "a signed-in user" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].when[0][0].text')" = "they open the board" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].then[0][0].text')" = "widgets load" ]
}

@test "an inline triple keeps a Given clause containing the word 'when' intact" {
  run bash -c "printf '%s\n' 'Given the user logs in when prompted, When they click, Then it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "the user logs in when prompted" ]
  [ "$(jq -r '.[0].when[0][0].text' <<< "$output")" = "they click" ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "it opens" ]
}

@test "extracts an inline Given/When/Then scenario on one line" {
  run bash -c "printf '%s\n' 'Given a user When they click Then it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].then[0][0].text')" = "it opens" ]
}

@test "no Gherkin present yields an empty array" {
  run bash -c "printf '%s\n' 'just prose here' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$output" = "[]" ]
}

# --- Design extraction (FR-016) --------------------------------------------

@test "extracts a Figma link and UX guidance for the Design section" {
  run bash -c "printf '%s\n' '## Design' 'Use the blue accent.' 'See https://www.figma.com/file/abc/Board' | { source '${ENGINE_DIR}/parse.sh'; parse_design; }"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.kind=="figma_link")] | length')" -ge 1 ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.kind=="guidance")] | length')" -ge 1 ]
}

# --- Priority (FR-017) ------------------------------------------------------

@test "extracts the P1/P2/P3 priority" {
  run bash -c "printf '%s\n' '### User Story 3 (Priority: P1)' | { source '${ENGINE_DIR}/parse.sh'; parse_priority; }"
  [ "$output" = "P1" ]
}

@test "priority defaults to P2 when unspecified" {
  run bash -c "printf '%s\n' 'no priority here' | { source '${ENGINE_DIR}/parse.sh'; parse_priority; }"
  [ "$output" = "P2" ]
}

# --- Estimation (FR-018) ----------------------------------------------------

@test "extracts a declared estimation as a number" {
  run bash -c "printf '%s\n' 'Estimation: 5' | { source '${ENGINE_DIR}/parse.sh'; parse_estimation; }"
  [ "$output" = "5" ]
}

@test "estimation is null when not declared" {
  run bash -c "printf '%s\n' 'no estimate' | { source '${ENGINE_DIR}/parse.sh'; parse_estimation; }"
  [ "$output" = "null" ]
}

# --- Cross-port parity (NFR-1) ---------------------------------------------

@test "the PowerShell port parses identically (title, description, gherkin)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local spec
  spec="$(printf '%s\n' '# Feature Specification: Rich Tickets' '' 'We need a reconcile bridge.' '' '### User Story 1 - The story (Priority: P2)' '- **Given** a user' '- **When** they act' '- **Then** it works')"

  local bt bd bg
  bt="$(printf '%s' "${spec}" | parse_title 001-rich-tickets)"
  bd="$(printf '%s' "${spec}" | parse_description_blocks)"
  bg="$(printf '%s' "${spec}" | parse_acceptance_criteria)"

  local pt pd pg
  pt="$(pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Parse.psm1' -Force; [Console]::Out.Write((Get-JiraParsedTitle -Text ([Console]::In.ReadToEnd()) -FolderSlug '001-rich-tickets'))" <<< "${spec}")"
  pd="$(pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Parse.psm1' -Force; [Console]::Out.Write((Get-JiraParsedDescription -Text ([Console]::In.ReadToEnd())))" <<< "${spec}")"
  pg="$(pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Parse.psm1' -Force; [Console]::Out.Write((Get-JiraParsedAcceptance -Text ([Console]::In.ReadToEnd())))" <<< "${spec}")"

  [ "${bt}" = "${pt}" ]
  [ "${bd}" = "${pd}" ]
  [ "${bg}" = "${pg}" ]
}
