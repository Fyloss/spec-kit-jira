#!/usr/bin/env bats
# T008/T010/T012 [Phase 2] — The durable story identifier: generation, grammar,
# and the byte-preserving splice (contracts/story-marker.md).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/story_marker.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/mtime.bash"
}

# --- Identifier generation ---------------------------------------------------

@test "story_marker_generate_id has the shape ^[0-9a-f]{16}\$" {
  run story_marker_generate_id
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{16}$ ]]
}

@test "story_marker_generate_id is unique across calls" {
  local a b
  a="$(story_marker_generate_id)"
  b="$(story_marker_generate_id)"
  [ "${a}" != "${b}" ]
}

@test "SPEC_KIT_JIRA_ID_SOURCE yields a fixed, cycling sequence" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222"
  [ "$(story_marker_generate_id)" = "1111111111111111" ]
  [ "$(story_marker_generate_id)" = "2222222222222222" ]
  [ "$(story_marker_generate_id)" = "1111111111111111" ]
}

# T028 (Phase 7 Convergence): a stale cursor file left behind at a
# PID-only-keyed path — exactly what an unrelated, already-dead process
# reusing this same PID would leave — must never be adopted by a fresh
# SPEC_KIT_JIRA_ID_SOURCE sequence. Reproduces the race without relying on
# genuine PID reuse: plant the stale file the OLD PID-only scheme would read,
# then assert the sequence still starts at index 0.
@test "a stale PID-only cursor file left by an unrelated process must not leak into a fresh id sequence (T028)" {
  local stale="${TMPDIR:-/tmp}/.speckit-jira-id-index.$$"
  printf '5' > "${stale}"
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222"
  [ "$(story_marker_generate_id)" = "1111111111111111" ]
  rm -f "${stale}"
}

# --- Grammar: valid / ignored / malformed -----------------------------------

@test "valid form: story= alone" {
  run story_marker_parse_line '<!-- speckit-jira story=7f3a9c1e40b2d85a -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "assigned" ]
  [ "$(jq -r '.id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
}

@test "valid form: story= + ticket=" {
  run story_marker_parse_line '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "bound" ]
  [ "$(jq -r '.ticket' <<< "$output")" = "PROJ-142" ]
}

@test "valid form: story= + creating" {
  run story_marker_parse_line '<!-- speckit-jira story=7f3a9c1e40b2d85a creating -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "creating" ]
}

@test "ignored: identifier fails the shape" {
  run story_marker_parse_line '<!-- speckit-jira story=NOTHEX -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "ignored: wrong prefix" {
  run story_marker_parse_line '<!-- speckit_jira story=7f3a9c1e40b2d85a -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "ignored: no identifier to bind" {
  run story_marker_parse_line '<!-- speckit-jira ticket=PROJ-142 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "malformed: ticket key fails the shape (lowercase)" {
  run story_marker_parse_line '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=proj-142 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
  [ "$(jq -r '.id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
}

@test "malformed: ticket key fails the shape (leading zero)" {
  run story_marker_parse_line '<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-0 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
}

@test "reading tolerates extra whitespace" {
  run story_marker_parse_line '<!--   speckit-jira   story=7f3a9c1e40b2d85a   ticket=PROJ-142   -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.ticket' <<< "$output")" = "PROJ-142" ]
}

# --- Splice: assignment -------------------------------------------------------

@test "assign inserts a marker line immediately after each story heading" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222"
  local doc out
  doc=$'# Feature Specification: X\n\nSome text.\n\n### User Story 1 - First (Priority: P1)\n\nBody one.\n\n### User Story 2 - Second (Priority: P2)\n\nBody two.\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 -->\n\nBody one.'* ]]
  [[ "${out}" == *$'### User Story 2 - Second (Priority: P2)\n<!-- speckit-jira story=2222222222222222 -->\n\nBody two.'* ]]
}

@test "assign inserts after the H1 for the implicit single story" {
  export SPEC_KIT_JIRA_ID_SOURCE="3333333333333333"
  local doc out
  doc=$'# Only A Title\n\nSome prose.\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == "# Only A Title"$'\n''<!-- speckit-jira story=3333333333333333 -->'$'\n\n''Some prose.'$'\n' ]]
}

@test "assign is idempotent: a fully-marked document is returned byte-identical" {
  local doc out
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

@test "assign never disturbs a byte outside the inserted lines" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  local doc out
  doc=$'### User Story 1 - Weird   spacing (Priority: P1)\n\n  Indented body.\n\ttab body.\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *$'  Indented body.\n\ttab body.'* ]]
}

@test "assign adopts CRLF when the file is dominantly CRLF" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  local doc out
  doc=$'### User Story 1 - First (Priority: P1)\r\n\r\nBody.\r\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira story=1111111111111111 -->"$'\r\n'* ]]
}

# --- Splice: state transitions ------------------------------------------------

@test "mark_creating replaces a bare assigned line with the creating state" {
  local doc out
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | story_marker_mark_creating '["1111111111111111"]'; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira story=1111111111111111 creating -->"* ]]
  [[ "${out}" != *"<!-- speckit-jira story=1111111111111111 -->"* ]]
}

@test "record_ticket replaces a creating line with the bound state" {
  local doc out
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 creating -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | story_marker_record_ticket "1111111111111111" "PROJ-142"; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira story=1111111111111111 ticket=PROJ-142 -->"* ]]
}

@test "record_ticket preserves the retitled and reordered story's surrounding bytes" {
  local doc out
  doc=$'### User Story 2 - Retitled (Priority: P1)\n<!-- speckit-jira story=2222222222222222 creating -->\n\nMoved body.\n\n### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | story_marker_record_ticket "2222222222222222" "PROJ-9"; printf x)"; out="${out%x}"
  [[ "${out}" == *"### User Story 2 - Retitled (Priority: P1)"$'\n'"<!-- speckit-jira story=2222222222222222 ticket=PROJ-9 -->"* ]]
  [[ "${out}" == *"### User Story 1 - First (Priority: P1)"$'\n'"<!-- speckit-jira story=1111111111111111 -->"* ]]
}

@test "a section with two marker attempts is left untouched by assign (blocked upstream, not silently fixed)" {
  local doc out
  doc=$'### User Story 1 - First (Priority: P1)\n<!-- speckit-jira story=1111111111111111 -->\n<!-- speckit-jira story=2222222222222222 -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

# --- File write: idempotence + atomicity --------------------------------------

@test "marker_splice_write_file does not touch the file when content is unchanged" {
  local f; f="${BATS_TEST_TMPDIR}/spec.md"
  printf 'unchanged content' > "${f}"
  local before after
  before="$(helper_file_mtime "${f}")"
  sleep 1.1
  run marker_splice_write_file "${f}" "unchanged content"
  [ "$output" = "unchanged" ]
  after="$(helper_file_mtime "${f}")"
  [ "${before}" = "${after}" ]
}

@test "marker_splice_write_file writes changed content" {
  local f; f="${BATS_TEST_TMPDIR}/spec2.md"
  printf 'old' > "${f}"
  run marker_splice_write_file "${f}" "new"
  [ "$output" = "written" ]
  [ "$(cat "${f}")" = "new" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port generates an identical id sequence under the seam (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local p
  p="$(SPEC_KIT_JIRA_ID_SOURCE='1111111111111111 2222222222222222' pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/StoryMarker.psm1' -Force
    [Console]::Out.Write((New-JiraStoryMarkerId) + ',' + (New-JiraStoryMarkerId))")"
  [ "${p}" = "1111111111111111,2222222222222222" ]
}

@test "the PowerShell port assigns byte-identical markers (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222"
  local doc b p
  doc=$'### User Story 1 - First (Priority: P1)\n\nBody one.\n\n### User Story 2 - Second (Priority: P2)\n\nBody two.\n'
  b="$(printf '%s' "${doc}" | story_marker_assign)"
  p="$(printf '%s' "${doc}" | SPEC_KIT_JIRA_ID_SOURCE='1111111111111111 2222222222222222' pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/StoryMarker.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((Set-JiraStoryMarkerAssign -Text \$doc))")"
  [ "${b}" = "${p}" ]
}
