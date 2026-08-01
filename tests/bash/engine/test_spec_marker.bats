#!/usr/bin/env bats
# T049/T050/T051 [Phase 5, US2] — The parent marker: grammar, non-collision
# with the story marker, and the byte-preserving splice
# (contracts/parent-marker.md).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/story_marker.sh"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/spec_marker.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/mtime.bash"
}

# --- Grammar: valid / ignored / malformed -----------------------------------

@test "valid form: spec= alone" {
  run spec_marker_parse_line '<!-- speckit-jira spec=3f2a91c04b7e6d18 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "assigned" ]
  [ "$(jq -r '.id' <<< "$output")" = "3f2a91c04b7e6d18" ]
}

@test "valid form: spec= + creating" {
  run spec_marker_parse_line '<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "creating" ]
}

@test "valid form: spec= + ticket=" {
  run spec_marker_parse_line '<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=COMP-412 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "bound" ]
  [ "$(jq -r '.ticket' <<< "$output")" = "COMP-412" ]
}

@test "ignored: a story= body is not a spec marker" {
  run spec_marker_parse_line '<!-- speckit-jira story=3f2a91c04b7e6d18 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "ignored: not a speckit-jira comment at all" {
  run spec_marker_parse_line '<!-- some other comment -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "malformed: a spec= body with an unrecognisable tail" {
  run spec_marker_parse_line '<!-- speckit-jira spec=3f2a91c04b7e6d18 bogus -->'
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
  [ "$(jq -r '.id' <<< "$output")" = "3f2a91c04b7e6d18" ]
}

@test "malformed: ticket key fails the shape" {
  run spec_marker_parse_line '<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=comp-412 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
}

# --- Non-collision with the story marker — normative ------------------------

@test "story_marker_parse_line returns none for a spec= body" {
  run story_marker_parse_line '<!-- speckit-jira spec=3f2a91c04b7e6d18 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "spec_marker_parse_line returns none for a story= body" {
  run spec_marker_parse_line '<!-- speckit-jira story=3f2a91c04b7e6d18 ticket=COMP-1 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "T050: an H1 with no User Story headings and a spec= marker still gets its own story= marker" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  local doc out
  doc=$'# Only A Title\n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->\n\nSome prose.\n'
  out="$(printf '%s' "${doc}" | story_marker_assign; printf x)"; out="${out%x}"
  # The implicit story is not silently dropped: its marker line is present
  # right after the H1 anchor, and the pre-existing spec= line was never
  # counted as satisfying it (both markers survive, in one document).
  [[ "${out}" == *$'# Only A Title\n<!-- speckit-jira story=1111111111111111 -->\n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->'* ]]
}

# --- Placement / duplicate detection over the whole document ---------------

@test "spec_marker_document_info: absent when no spec= line exists" {
  local doc; doc=$'# Title\n\nBody.\n'
  run spec_marker_document_info "${doc}"
  [ "$(jq -r '.state' <<< "$output")" = "absent" ]
}

@test "spec_marker_document_info: assigned for a single bare marker" {
  local doc; doc=$'# Title\n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->\n\nBody.\n'
  run spec_marker_document_info "${doc}"
  [ "$(jq -r '.state' <<< "$output")" = "assigned" ]
  [ "$(jq -r '.id' <<< "$output")" = "3f2a91c04b7e6d18" ]
  [ "$(jq -r '.lines[0]' <<< "$output")" = "2" ]
}

@test "spec_marker_document_info: duplicate for two spec= lines anywhere in the file" {
  local doc; doc=$'# Title\n<!-- speckit-jira spec=1111111111111111 -->\n\nBody.\n\n<!-- speckit-jira spec=2222222222222222 -->\n'
  run spec_marker_document_info "${doc}"
  [ "$(jq -r '.state' <<< "$output")" = "duplicate" ]
  [ "$(jq '.lines | length' <<< "$output")" = "2" ]
}

# --- Splice: assignment -------------------------------------------------------

@test "spec_marker_assign inserts the marker line immediately after the H1" {
  export SPEC_KIT_JIRA_ID_SOURCE="3f2a91c04b7e6d18"
  local doc out
  doc=$'# Feature Specification: X\n\nSome text.\n'
  out="$(printf '%s' "${doc}" | spec_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == "# Feature Specification: X"$'\n''<!-- speckit-jira spec=3f2a91c04b7e6d18 -->'$'\n\n''Some text.'$'\n' ]]
}

@test "spec_marker_assign inserts as line 1 when there is no H1" {
  export SPEC_KIT_JIRA_ID_SOURCE="3f2a91c04b7e6d18"
  local doc out
  doc=$'Some text with no heading.\n'
  out="$(printf '%s' "${doc}" | spec_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == '<!-- speckit-jira spec=3f2a91c04b7e6d18 -->'$'\n''Some text with no heading.'$'\n' ]]
}

@test "spec_marker_assign is idempotent: a document already carrying spec= is byte-identical" {
  local doc out
  doc=$'# Title\n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | spec_marker_assign; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

@test "spec_marker_assign never disturbs a byte outside the inserted line" {
  export SPEC_KIT_JIRA_ID_SOURCE="3f2a91c04b7e6d18"
  local doc out
  doc=$'# Title\n\n  Indented body.\n\ttab body.\n'
  out="$(printf '%s' "${doc}" | spec_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *$'  Indented body.\n\ttab body.'* ]]
}

@test "spec_marker_assign adopts CRLF when the file is dominantly CRLF" {
  export SPEC_KIT_JIRA_ID_SOURCE="3f2a91c04b7e6d18"
  local doc out
  doc=$'# Title\r\n\r\nBody.\r\n'
  out="$(printf '%s' "${doc}" | spec_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira spec=3f2a91c04b7e6d18 -->"$'\r\n'* ]]
}

# --- Splice: state transitions ------------------------------------------------

@test "spec_marker_mark_creating replaces a bare assigned line with the creating state" {
  local doc out
  doc=$'# Title\n<!-- speckit-jira spec=3f2a91c04b7e6d18 -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | spec_marker_mark_creating "3f2a91c04b7e6d18"; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->"* ]]
  [[ "${out}" != *"<!-- speckit-jira spec=3f2a91c04b7e6d18 -->"* ]]
}

@test "spec_marker_record_ticket replaces a creating line with the bound state" {
  local doc out
  doc=$'# Title\n<!-- speckit-jira spec=3f2a91c04b7e6d18 creating -->\n\nBody.\n'
  out="$(printf '%s' "${doc}" | spec_marker_record_ticket "3f2a91c04b7e6d18" "COMP-412"; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=COMP-412 -->"* ]]
}

@test "spec_marker file write is not opened when nothing changes" {
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

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port assigns a byte-identical parent marker (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  export SPEC_KIT_JIRA_ID_SOURCE="3f2a91c04b7e6d18"
  local doc b p
  doc=$'# Feature Specification: X\n\nSome text.\n'
  b="$(printf '%s' "${doc}" | spec_marker_assign)"
  p="$(printf '%s' "${doc}" | SPEC_KIT_JIRA_ID_SOURCE='3f2a91c04b7e6d18' pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/SpecMarker.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((Set-JiraSpecMarkerAssign -Text \$doc))")"
  [ "${b}" = "${p}" ]
}
