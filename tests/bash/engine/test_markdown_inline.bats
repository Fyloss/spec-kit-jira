#!/usr/bin/env bats
# T006/T020-T023 [US1] — Inline tokenizer (Part C of
# specs/016-jira-markdown-rendering/contracts/markdown-subset.md): one test per
# worked example (Part E), the C9 delimiter rules, and the D1-D3 emission
# invariants. NEUTRAL layer: marks are bold/italic/monospace/strikethrough/link,
# never ADF names (Constitution VIII).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/markdown.sh"
}

# tok <input> — normalised (key-sorted) tokenize_inline output, for stable comparison.
tok() { markdown_tokenize_inline "$1" | jq -cS .; }

# --- Part E — worked examples ------------------------------------------------

@test "E1 — **FR-012** applies: one bold span" {
  [ "$(tok '**FR-012** applies')" = "$(jq -cnS '[{text:"FR-012",marks:[{kind:"bold"}]},{text:" applies",marks:[]}]')" ]
}

@test "E2 — code span protects its interior and gets monospace" {
  [ "$(tok 'run `reconcile --dry-run`')" = "$(jq -cnS '[{text:"run ",marks:[]},{text:"reconcile --dry-run",marks:[{kind:"monospace"}]}]')" ]
}

@test "E3 — a valid link renders as a link mark, target hidden" {
  [ "$(tok 'see [guide](https://ex.invalid/s)')" = "$(jq -cnS '[{text:"see ",marks:[]},{text:"guide",marks:[{href:"https://ex.invalid/s",kind:"link"}]}]')" ]
}

@test "E4 — an unsafe target degrades to label (target), no link mark (FR-006)" {
  [ "$(tok 'see [guide](../local.md)')" = "$(jq -cnS '[{text:"see guide (../local.md)",marks:[]}]')" ]
}

@test "E5 — italic (star and underscore) and strikethrough" {
  [ "$(tok '*a*, _b_, ~~c~~')" = "$(jq -cnS '[{text:"a",marks:[{kind:"italic"}]},{text:", ",marks:[]},{text:"b",marks:[{kind:"italic"}]},{text:", ",marks:[]},{text:"c",marks:[{kind:"strikethrough"}]}]')" ]
}

@test "E6 — backslash-escaped asterisks stay literal (C1)" {
  [ "$(tok '\*not bold\*')" = "$(jq -cnS '[{text:"*not bold*",marks:[]}]')" ]
}

@test "E7 — 2 * 3 * 4 stays literal (C9.1: space follows the opener)" {
  [ "$(tok '2 * 3 * 4')" = "$(jq -cnS '[{text:"2 * 3 * 4",marks:[]}]')" ]
}

@test "E8 — parse_description_blocks survives with zero marks (C9.3)" {
  [ "$(tok 'parse_description_blocks')" = "$(jq -cnS '[{text:"parse_description_blocks",marks:[]}]')" ]
}

@test "E9 — a code span nested in bold keeps both marks" {
  [ "$(tok '**bold with `code` inside**')" = "$(jq -cnS '[{text:"bold with ",marks:[{kind:"bold"}]},{text:"code",marks:[{kind:"bold"},{kind:"monospace"}]},{text:" inside",marks:[{kind:"bold"}]}]')" ]
}

@test "E10 — an unclosed bold delimiter stays fully literal (C9.4)" {
  [ "$(tok '**unclosed')" = "$(jq -cnS '[{text:"**unclosed",marks:[]}]')" ]
}

@test "E11 — asterisks inside a code span are never bold (C2)" {
  [ "$(tok '`**not bold**`')" = "$(jq -cnS '[{text:"**not bold**",marks:[{kind:"monospace"}]}]')" ]
}

@test "E12 — an image renders as its alt text, no mark (FR-010)" {
  [ "$(tok '![diagram](x.png)')" = "$(jq -cnS '[{text:"diagram",marks:[]}]')" ]
}

@test "E13 — an autolink renders the URL as a link span (C3)" {
  [ "$(tok '<https://ex.invalid>')" = "$(jq -cnS '[{text:"https://ex.invalid",marks:[{href:"https://ex.invalid",kind:"link"}]}]')" ]
}

@test "E14 — a raw HTML tag is discarded, inner text kept (C10)" {
  [ "$(tok '<b>text</b>')" = "$(jq -cnS '[{text:"text",marks:[]}]')" ]
}

@test "E15 — a table row's cells join with an em dash (B6, tokenized as a paragraph)" {
  run bash -c "source '${ENGINE_DIR}/markdown.sh'; markdown_parse_blocks '| a | b |'"
  [ "$(jq -cS . <<< "$output")" = "$(jq -cnS '[{type:"paragraph",spans:[{text:"a — b",marks:[]}]}]')" ]
}

# --- C9 delimiter rules -------------------------------------------------------

@test "C9.1 — opener must be followed by non-whitespace" {
  [ "$(tok '* not emphasis *')" = "$(jq -cnS '[{text:"* not emphasis *",marks:[]}]')" ]
}

@test "C9.2 — the nearest valid closer wins" {
  [ "$(tok '*a* b *c*')" = "$(jq -cnS '[{text:"a",marks:[{kind:"italic"}]},{text:" b ",marks:[]},{text:"c",marks:[{kind:"italic"}]}]')" ]
}

@test "C9.3 — underscore inside an identifier never opens emphasis" {
  [ "$(tok 'customfield_10011')" = "$(jq -cnS '[{text:"customfield_10011",marks:[]}]')" ]
}

@test "C9.3 — a standalone underscore-wrapped word still emphasises" {
  [ "$(tok 'a _word_ here')" = "$(jq -cnS '[{text:"a ",marks:[]},{text:"word",marks:[{kind:"italic"}]},{text:" here",marks:[]}]')" ]
}

@test "C9.4 — no closer means every delimiter char is literal" {
  [ "$(tok 'a _b')" = "$(jq -cnS '[{text:"a _b",marks:[]}]')" ]
}

@test "C9.6 — depth cap of 8 bounds pathological nesting deterministically" {
  local input="x" i
  for i in $(seq 1 9); do input="*${input}*"; done
  run bash -c "source '${ENGINE_DIR}/markdown.sh'; markdown_tokenize_inline '${input}'"
  [ "$status" -eq 0 ]
  # Bounded: the tokenizer terminates and never fails on pathological nesting (FR-005).
  [ -n "$output" ]
}

# --- D1-D3 emission invariants -----------------------------------------------

@test "D1 — adjacent equal-mark spans merge into one" {
  # Two back-to-back links to the same href, both carrying the identical
  # {kind:link, href} mark, collapse into a single merged span.
  local out
  out="$(markdown_tokenize_inline '[a](https://ex.invalid)[b](https://ex.invalid)')"
  [ "$(jq 'length' <<< "${out}")" -eq 1 ]
  [ "$(jq -r '.[0].text' <<< "${out}")" = "ab" ]
  [ "$(jq -r '.[0].marks[0].href' <<< "${out}")" = "https://ex.invalid" ]
}

@test "D2 — marks is always present and sorted alphabetically by kind" {
  local out
  out="$(markdown_tokenize_inline '**_~~x~~_**')"
  [ "$(jq -r '.[0].marks | map(.kind) | join(",")' <<< "$out")" = "bold,italic,strikethrough" ]
}

@test "D3 — an empty inline collapses to []" {
  [ "$(markdown_tokenize_inline '')" = "[]" ]
}

# --- T085 [016, Phase 8] — non-ASCII inside a formatted span (spec Edge Cases,
# "Non-ASCII content") --------------------------------------------------------

@test "T085 — accented characters, CJK and emoji inside a bold span survive byte-for-byte" {
  [ "$(tok '**café 日本語 🎉**')" = "$(jq -cnS '[{text:"café 日本語 🎉",marks:[{kind:"bold"}]}]')" ]
}

@test "T085 — non-ASCII inside a code span survives byte-for-byte" {
  [ "$(tok '`café 日本語 🎉`')" = "$(jq -cnS '[{text:"café 日本語 🎉",marks:[{kind:"monospace"}]}]')" ]
}

@test "T085 — non-ASCII inside a link label survives byte-for-byte" {
  [ "$(tok '[café 日本語 🎉](https://ex.invalid/s)')" = "$(jq -cnS '[{text:"café 日本語 🎉",marks:[{href:"https://ex.invalid/s",kind:"link"}]}]')" ]
}

# --- Cross-port parity (NFR-1) ------------------------------------------------

@test "the PowerShell port tokenizes byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local -a cases=(
    '**FR-012** applies'
    'run `reconcile --dry-run`'
    'see [guide](../local.md)'
    '*a*, _b_, ~~c~~'
    '**unclosed'
    'a **nested *and* bold** run'
    '[link with **bold** label](https://ex.invalid)'
    'customfield_10011 and parse_description_blocks'
  )
  local c b p
  for c in "${cases[@]}"; do
    b="$(markdown_tokenize_inline "${c}" | jq -cS .)"
    # printf without a trailing newline: a here-string (<<<) would append one,
    # which the tokenizer (rightly) treats as literal text and diverges on.
    p="$(printf '%s' "${c}" | pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Markdown.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraMarkdownInlineSpanList -Text ([Console]::In.ReadToEnd())))" | jq -cS .)"
    [ "${b}" = "${p}" ]
  done
}
