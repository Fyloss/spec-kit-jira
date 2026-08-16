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

# --- 028: the template's own single-line emphasised triple (contract §4) ---
# clause-recognition.md §4 rows 1, 2, 5, 6, 9 plus rule T3. Every row asserts
# clause DISJOINTNESS (§6 invariant 1) — not merely non-emptiness — and for
# FR-011, that concatenating the three clause texts reproduces the source
# line minus its keywords, wrappers and clause delimiters: a truncation at
# either end fails the join comparison rather than passing as "disjoint".

@test "contract §4 row 1: emphasised delimited triple yields three disjoint clauses" {
  run bash -c "printf '%s\n' '**Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  g="$(jq -r '.[0].given[0][0].text' <<< "$output")"
  w="$(jq -r '.[0].when[0][0].text' <<< "$output")"
  t="$(jq -r '.[0].then[0][0].text' <<< "$output")"
  [ "$g" = "a user arrives on the Homepage" ]
  [ "$w" = "they click Login" ]
  [ "$t" = "the login form appears." ]
  [[ "$g" != Given* && "$g" != *When* && "$g" != *Then* ]]
  [[ "$w" != When* && "$w" != *Given* && "$w" != *Then* ]]
  [[ "$t" != Then* && "$t" != *Given* && "$t" != *When* ]]
  [ "${g}, ${w}, ${t}" = "a user arrives on the Homepage, they click Login, the login form appears." ]
}

@test "contract §4 row 2: plain delimited triple yields three disjoint clauses" {
  run bash -c "printf '%s\n' 'Given a user arrives on the Homepage, When they click Login, Then the login form appears.' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  g="$(jq -r '.[0].given[0][0].text' <<< "$output")"
  w="$(jq -r '.[0].when[0][0].text' <<< "$output")"
  t="$(jq -r '.[0].then[0][0].text' <<< "$output")"
  [ "$g" = "a user arrives on the Homepage" ]
  [ "$w" = "they click Login" ]
  [ "$t" = "the login form appears." ]
  [ "${g}, ${w}, ${t}" = "a user arrives on the Homepage, they click Login, the login form appears." ]
}

@test "contract §4 row 5: emphasised delimiter-free triple yields three disjoint clauses" {
  run bash -c "printf '%s\n' '**Given** a user **When** they click **Then** it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  g="$(jq -r '.[0].given[0][0].text' <<< "$output")"
  w="$(jq -r '.[0].when[0][0].text' <<< "$output")"
  t="$(jq -r '.[0].then[0][0].text' <<< "$output")"
  [ "$g" = "a user" ]
  [ "$w" = "they click" ]
  [ "$t" = "it opens" ]
  [ "${g} ${w} ${t}" = "a user they click it opens" ]
}

@test "contract §4 row 6: emphasis inside a clause body survives as marks, wrapper around the keyword does not" {
  run bash -c "printf '%s\n' '__Given__ a **bold** thing, __When__ x, __Then__ y' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  given_text="$(jq -r '[.[0].given[0][].text] | join("")' <<< "$output")"
  [ "$given_text" = "a bold thing" ]
  [ "$(jq -r '[.[0].given[0][] | select(.text=="bold")] | .[0].marks[0].kind' <<< "$output")" = "bold" ]
  [ "$(jq -r '.[0].when[0][0].text' <<< "$output")" = "x" ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "y" ]
  # the wrapper around Given/When/Then never reaches a clause's own text
  [[ "$(jq -r '[.[0].given[0][].text, .[0].when[0][0].text, .[0].then[0][0].text] | join("")' <<< "$output")" != *"__"* ]]
}

@test "contract §4 row 9: the greedy delimiter-free split pins the last When" {
  run bash -c "printf '%s\n' 'Given a When b When c Then d' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  g="$(jq -r '.[0].given[0][0].text' <<< "$output")"
  w="$(jq -r '.[0].when[0][0].text' <<< "$output")"
  t="$(jq -r '.[0].then[0][0].text' <<< "$output")"
  [ "$g" = "a When b" ]
  [ "$w" = "c" ]
  [ "$t" = "d" ]
  [ "${g} ${w} ${t}" = "a When b c d" ]
}

@test "contract §2 rule T3: keywords present but out of grammar order emit nothing (fail closed)" {
  run bash -c "printf '%s\n' 'Then it opens, When they click, Given a user' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- 028 US2: no clause body ever repeats its own keyword (contract §6 invariant 2) ---

@test "US2: no clause body opens with a keyword, on the per-line, delimited and delimiter-free forms" {
  run bash -c "printf '%s\n' '- **Given** a signed-in user' '- **When** they open the board' '- **Then** widgets load' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [[ "$(jq -r '.[0].given[0][0].text' <<< "$output")" != Given* ]]
  [[ "$(jq -r '.[0].when[0][0].text' <<< "$output")" != When* ]]
  [[ "$(jq -r '.[0].then[0][0].text' <<< "$output")" != Then* ]]

  run bash -c "printf '%s\n' '**Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [[ "$(jq -r '.[0].given[0][0].text' <<< "$output")" != Given* ]]
  [[ "$(jq -r '.[0].when[0][0].text' <<< "$output")" != When* ]]
  [[ "$(jq -r '.[0].then[0][0].text' <<< "$output")" != Then* ]]

  run bash -c "printf '%s\n' '**Given** a user **When** they click **Then** it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [[ "$(jq -r '.[0].given[0][0].text' <<< "$output")" != Given* ]]
  [[ "$(jq -r '.[0].when[0][0].text' <<< "$output")" != When* ]]
  [[ "$(jq -r '.[0].then[0][0].text' <<< "$output")" != Then* ]]
}

@test "US2: an emphasised And/But continuation joins the correct bucket without repeating a keyword" {
  run bash -c "printf '%s\n' '- **Given** a signed-in user' '- **And** an active session' '- **When** they open the board' '- **But** the network is slow' '- **Then** widgets load' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq '.[0].given | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].given[1][0].text' <<< "$output")" = "an active session" ]
  [ "$(jq '.[0].when | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].when[1][0].text' <<< "$output")" = "the network is slow" ]
  [[ "$(jq -r '.[0].given[1][0].text' <<< "$output")" != And* ]]
  [[ "$(jq -r '.[0].when[1][0].text' <<< "$output")" != But* ]]
}

@test "US2: a clause body containing the word 'then' survives unsplit (FR-007)" {
  run bash -c "printf '%s\n' 'Given the report only loads then only if cached, When they refresh, Then it reloads' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "the report only loads then only if cached" ]
  [ "$(jq -r '.[0].when[0][0].text' <<< "$output")" = "they refresh" ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "it reloads" ]
}

@test "US2: a one-sided emphasis wrapper never reaches the clause body" {
  run bash -c "printf '%s\n' '**Given a user, When they click, Then it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "a user" ]
  [[ "$(jq -r '.[0].given[0][0].text' <<< "$output")" != *"*"* ]]

  run bash -c "printf '%s\n' 'Given** a user, When they click, Then it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "a user" ]
  [[ "$(jq -r '.[0].given[0][0].text' <<< "$output")" != *"*"* ]]
}

@test "US2: a mixed emphasis form on one line yields one scenario with all three clauses correct (contract §5)" {
  run bash -c "printf '%s\n' '**Given** a user, When they click, **Then** it opens' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "a user" ]
  [ "$(jq -r '.[0].when[0][0].text' <<< "$output")" = "they click" ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "it opens" ]
}

# --- 028 US4: a scenario wrapped across several lines is read whole (contract §3) ---

@test "US4: a scenario wrapped inside a clause, followed by a second scenario, is read whole" {
  run bash -c "printf '%s\n' \
    '1. **Given** a user who has been sitting on the homepage for a' \
    '   very long while without any interaction at all, **When** they' \
    '   finally click the Login button, **Then** the login form appears' \
    '   on the screen right away.' \
    '2. **Given** another scenario, **When** something else happens, **Then** it also works.' \
    | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "a user who has been sitting on the homepage for a very long while without any interaction at all" ]
  [ "$(jq -r '.[0].when[0][0].text' <<< "$output")" = "they finally click the Login button" ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "the login form appears on the screen right away." ]
  [ "$(jq -r '.[1].given[0][0].text' <<< "$output")" = "another scenario" ]
  [ "$(jq -r '.[1].when[0][0].text' <<< "$output")" = "something else happens" ]
  [ "$(jq -r '.[1].then[0][0].text' <<< "$output")" = "it also works." ]
}

@test "US4: the existing per-line form passes through the join pre-pass unchanged (§3 identity invariant)" {
  run bash -c "printf '%s\n' '- **Given** a signed-in user' '- **When** they open the board' '- **Then** widgets load' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "a signed-in user" ]
  [ "$(jq -r '.[0].when[0][0].text' <<< "$output")" = "they open the board" ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "widgets load" ]
}

@test "US4: an unindented prose line immediately after a scenario is not joined" {
  run bash -c "printf '%s\n' 'Given a user, When they click, Then it opens' 'This is unrelated prose that happens to follow immediately.' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].then[0][0].text' <<< "$output")" = "it opens" ]
  [[ "$(jq -c '.' <<< "$output")" != *"unrelated prose"* ]]
}

@test "US4, FR-022: a scenario wrapped at a clause boundary emits nothing (pinned, not fixed — real shape from 019 spec.md:93-95)" {
  run bash -c "printf '%s\n' \
    '1. **Given** a parent whose recorded origin is the mirror'\''s own and whose description carries no boundary,' \
    '   **When** \`plan.md\`'\''s summary changes and reconcile is run, **Then** the parent'\''s description carries the' \
    '   new summary exactly once and no part of the previous one.' \
    | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- 028 US5: text that is not a scenario is still not turned into one ---

@test "US5, FR-012: prose containing given/when/then mid-sentence yields no clause" {
  run bash -c "printf '%s\n' 'The system checks whether login was given, when it happened, and then updates the log.' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "US5, FR-014: an absent or empty acceptance-scenario section yields [] with no warning" {
  run bash -c "printf '%s\n' '**Acceptance Scenarios**:' '' 'Nothing here yet.' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  # $output merges stdout and stderr (default `run` behaviour) — exactly "[]"
  # proves no warning text was printed alongside the empty array.
  [ "$output" = "[]" ]
}

@test "US5, FR-013: a scenario that never reaches a Then is not emitted" {
  run bash -c "printf '%s\n' '- **Given** a user' '- **When** they act' | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "US5/US4: a story section mixing prose (Why this priority / Independent Test) with scenarios joins no prose into a clause" {
  run bash -c "printf '%s\n' \
    '### User Story 1 - Homepage login (Priority: P1)' \
    '' \
    'As a visitor, I want to sign in from the homepage.' \
    '' \
    '**Why this priority**: This is the primary entry point for every returning user.' \
    '' \
    '**Independent Test**: Can be fully tested by visiting the homepage and signing in.' \
    '' \
    '**Acceptance Scenarios**:' \
    '' \
    '1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears.' \
    | { source '${ENGINE_DIR}/parse.sh'; parse_acceptance_criteria; }"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].given[0][0].text' <<< "$output")" = "a user arrives on the Homepage" ]
  [[ "$(jq -c '.' <<< "$output")" != *"Why this priority"* ]]
  [[ "$(jq -c '.' <<< "$output")" != *"Independent Test"* ]]
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
  # 028: the per-line form AND the spec-kit template's own emphasised
  # single-line triple, in the same document — the corpus gap that let the
  # two ports diverge on the template's own default output.
  spec="$(printf '%s\n' '# Feature Specification: Rich Tickets' '' 'We need a reconcile bridge.' '' '### User Story 1 - The story (Priority: P2)' '- **Given** a user' '- **When** they act' '- **Then** it works' '' '### User Story 2 - The template form (Priority: P2)' '1. **Given** a visitor, **When** they act, **Then** it works too')"

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
