#!/usr/bin/env bats
# T043/T045 [US2] — Block segmentation (Part B of
# specs/016-jira-markdown-rendering/contracts/markdown-subset.md): rules
# B1-B8, plus the B9 selection cap's worked example (data-model.md §4). The
# cap itself is applied by the caller (parse.sh); this module only segments.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/markdown.sh"
}

blocks() { markdown_parse_blocks "$1" | jq -cS .; }

@test "B1 — a fenced code block is verbatim, no inline tokenization (FR-007)" {
  local doc; doc="$(printf '%s\n' '```bash' 'echo **not bold**' '```')"
  [ "$(blocks "${doc}")" = "$(jq -cnS '[{type:"code",text:"echo **not bold**"}]')" ]
}

@test "B1 — an unclosed fence still emits its content" {
  local doc; doc="$(printf '%s\n' '```' 'line one' 'line two')"
  [ "$(blocks "${doc}")" = "$(jq -cnS '[{type:"code",text:"line one\nline two"}]')" ]
}

@test "B2 — an ATX heading carries its level and tokenized text" {
  [ "$(blocks '### Design **Notes**')" = "$(jq -cnS '[{type:"heading",level:3,spans:[{text:"Design ",marks:[]},{text:"Notes",marks:[{kind:"bold"}]}]}]')" ]
}

@test "B3 — bullet items accumulate into one bullet_list, nesting flattened" {
  local doc; doc="$(printf '%s\n' '- a' '  - nested b' '- c')"
  local out; out="$(blocks "${doc}")"
  [ "$(jq -r '.[0].type' <<< "${out}")" = "bullet_list" ]
  [ "$(jq '.[0].items | length' <<< "${out}")" -eq 3 ]
}

@test "B4 — ordered items accumulate into ordered_list; source numbering is discarded" {
  local doc; doc="$(printf '%s\n' '5. first' '1. second')"
  local out; out="$(blocks "${doc}")"
  [ "$(jq -r '.[0].type' <<< "${out}")" = "ordered_list" ]
  [ "$(jq -r '.[0].items[0][0].text' <<< "${out}")" = "first" ]
  [ "$(jq -r '.[0].items[1][0].text' <<< "${out}")" = "second" ]
}

@test "B5 — a blockquote's prefix is stripped and the remainder re-segments" {
  [ "$(blocks '> a quoted paragraph')" = "$(jq -cnS '[{type:"paragraph",spans:[{text:"a quoted paragraph",marks:[]}]}]')" ]
}

@test "B5 — a blockquoted heading still segments as a heading" {
  [ "$(blocks '> ## Quoted Heading')" = "$(jq -cnS '[{type:"heading",level:2,spans:[{text:"Quoted Heading",marks:[]}]}]')" ]
}

@test "B6 — a table's delimiter row is dropped; cells join with an em dash" {
  local doc; doc="$(printf '%s\n' '| H1 | H2 |' '| --- | --- |' '| a | b |')"
  [ "$(blocks "${doc}")" = "$(jq -cnS '[{type:"paragraph",spans:[{text:"H1 — H2",marks:[]}]},{type:"paragraph",spans:[{text:"a — b",marks:[]}]}]')" ]
}

@test "B7 — a blank line closes the open block; consecutive blanks collapse" {
  local doc; doc="$(printf '%s\n' 'para one' '' '' 'para two')"
  [ "$(blocks "${doc}")" = "$(jq -cnS '[{type:"paragraph",spans:[{text:"para one",marks:[]}]},{type:"paragraph",spans:[{text:"para two",marks:[]}]}]')" ]
}

@test "B8 — paragraph lines join with a single space" {
  local doc; doc="$(printf '%s\n' 'line one' 'line two')"
  [ "$(blocks "${doc}")" = "$(jq -cnS '[{type:"paragraph",spans:[{text:"line one line two",marks:[]}]}]')" ]
}

@test "B8 — a list ends at the first non-matching line (no lazy continuation)" {
  local doc; doc="$(printf '%s\n' '- item a' 'not a list item')"
  local out; out="$(blocks "${doc}")"
  [ "$(jq -r '.[0].type' <<< "${out}")" = "bullet_list" ]
  [ "$(jq '.[0].items | length' <<< "${out}")" -eq 1 ]
  [ "$(jq -r '.[1].type' <<< "${out}")" = "paragraph" ]
}

# --- B9 selection cap worked example (data-model.md §4) ----------------------

@test "B9 worked example — a heading rides free, does not consume cap budget" {
  local doc; doc="$(printf '%s\n' '## Overview' 'Some intro prose.' '- item a' '- item b')"
  local out; out="$(blocks "${doc}")"
  # All three blocks emitted; the CALLER's cap keeps the first two CONTENT
  # blocks (paragraph + bullet_list) and carries the heading through free.
  [ "$(jq 'length' <<< "${out}")" -eq 3 ]
  [ "$(jq -r '.[0].type' <<< "${out}")" = "heading" ]
  [ "$(jq -r '.[1].type' <<< "${out}")" = "paragraph" ]
  [ "$(jq -r '.[2].type' <<< "${out}")" = "bullet_list" ]
}

# --- T086 [016, Phase 8] — CRLF equals LF at the block layer (FR-015, spec
# Edge Cases "Windows line endings") -------------------------------------------

@test "T086 — a CRLF document yields the same blocks as the LF original" {
  local lf crlf
  lf="$(blocks "$(printf '## Overview\nSome intro prose.\n- item a\n- item b')")"
  crlf="$(blocks "$(printf '## Overview\r\nSome intro prose.\r\n- item a\r\n- item b')")"
  [ "${lf}" = "${crlf}" ]
}

# --- Cross-port parity (NFR-1) ------------------------------------------------

@test "the PowerShell port segments byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local -a docs=(
    "$(printf '%s\n' '## Overview' 'Some intro prose.' '- item a' '- item b')"
    "$(printf '%s\n' '1. first' '2. second' '10. tenth')"
    "$(printf '%s\n' '```bash' 'echo hi' '```')"
    "$(printf '%s\n' '> quoted line')"
    "$(printf '%s\n' '| H1 | H2 |' '| --- | --- |' '| a | b |')"
  )
  local d b p
  for d in "${docs[@]}"; do
    b="$(markdown_parse_blocks "${d}" | jq -cS .)"
    p="$(printf '%s' "${d}" | pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Markdown.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraMarkdownBlockList -Text ([Console]::In.ReadToEnd())))" | jq -cS .)"
    [ "${b}" = "${p}" ]
  done
}
