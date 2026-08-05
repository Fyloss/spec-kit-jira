#!/usr/bin/env bats
# T072 [016, US1] — FR-017: a task's own text is author prose, so the neutral
# reader must emit its description as marked spans (the feature-016 block
# shape), not as the raw string feature 012 shipped. Without this, every
# backtick-quoted path in a tasks.md line reaches the Jira reader as literal
# punctuation — the exact defect this feature exists to remove, on the one
# tier that landed after the spec was written.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/tasks_parse.sh"
}

# _blocks <tasks.md text> — the first task's description blocks.
_blocks() {
  printf '%s' "$1" | tasks_parse_document | jq -c '.tasks[0].description.blocks'
}

@test "a task description block is a paragraph carrying spans, never a raw string" {
  local doc blocks
  doc=$'- [ ] T001 Plain text with no markup at all\n'
  blocks="$(_blocks "${doc}")"
  [ "$(jq -r '.[0].type' <<< "${blocks}")" = "paragraph" ]
  [ "$(jq -r '.[0] | has("spans")' <<< "${blocks}")" = "true" ]
  [ "$(jq -r '.[0] | has("text")' <<< "${blocks}")" = "false" ]
}

@test "a backtick-quoted path in a task line becomes a monospace span (FR-017)" {
  local doc blocks
  doc=$'- [ ] T014 Implement the parser in `scripts/bash/engine/tasks_parse.sh`\n'
  blocks="$(_blocks "${doc}")"
  [ "$(jq -r '[.[0].spans[] | select(.marks[]?.kind == "monospace")] | length' <<< "${blocks}")" = "1" ]
  [ "$(jq -r '[.[0].spans[] | select(.marks[]?.kind == "monospace")][0].text' <<< "${blocks}")" = "scripts/bash/engine/tasks_parse.sh" ]
}

@test "no Markdown delimiter survives in any span's text (FR-002, SC-001)" {
  local doc blocks joined
  doc=$'- [ ] T002 Render **bold** and `code` and ~~gone~~ and [guide](https://example.invalid/g)\n'
  blocks="$(_blocks "${doc}")"
  joined="$(jq -r '[.[0].spans[].text] | join("")' <<< "${blocks}")"
  [[ "${joined}" != *'**'* ]]
  [[ "${joined}" != *'`'* ]]
  [[ "${joined}" != *'~~'* ]]
  [[ "${joined}" != *']('* ]]
}

@test "bold, strikethrough and link marks all reach the task description" {
  local doc blocks
  doc=$'- [ ] T003 Render **bold** and ~~gone~~ and [guide](https://example.invalid/g)\n'
  blocks="$(_blocks "${doc}")"
  [ "$(jq -r '[.[0].spans[] | select(.marks[]?.kind == "bold")] | length' <<< "${blocks}")" = "1" ]
  [ "$(jq -r '[.[0].spans[] | select(.marks[]?.kind == "strikethrough")] | length' <<< "${blocks}")" = "1" ]
  [ "$(jq -r '[.[0].spans[] | select(.marks[]?.kind == "link")][0].marks[0].href' <<< "${blocks}")" = "https://example.invalid/g" ]
}

@test "the title field keeps its raw markup — summaries are plain text (FR-018)" {
  local doc out
  doc=$'- [ ] T004 Implement the parser in `engine/tasks_parse.sh`\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks[0].title' <<< "${out}")" = "Implement the parser in \`engine/tasks_parse.sh\`" ]
}

@test "an unbalanced delimiter degrades to literal text without failing (FR-005)" {
  local doc blocks
  doc=$'- [ ] T005 A lone ** delimiter and an unclosed [label( here\n'
  blocks="$(_blocks "${doc}")"
  [ "$(jq -r '.[0].spans | length' <<< "${blocks}")" != "0" ]
  [[ "$(jq -r '[.[0].spans[].text] | join("")' <<< "${blocks}")" == *'**'* ]]
}

@test "a CRLF tasks.md yields the same blocks as the LF original (FR-015)" {
  local lf crlf
  lf="$(_blocks $'- [ ] T006 Implement `a/b.sh` with **bold**\n')"
  crlf="$(_blocks $'- [ ] T006 Implement `a/b.sh` with **bold**\r\n')"
  [ "${lf}" = "${crlf}" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port emits byte-identical task description blocks (FR-015)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local doc b p tmp
  doc=$'## Phase 3: User Story 1\n\n- [ ] T014 [US1] Implement `engine/tasks_parse.sh` with **bold** and [g](https://example.invalid/g)\n'
  b="$(printf '%s' "${doc}" | tasks_parse_document | jq -c '.tasks[0].description')"
  tmp="${BATS_TEST_TMPDIR}/tasks.md"
  printf '%s' "${doc}" > "${tmp}"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/TasksParse.psm1' -Force
    \$doc = Get-Content -Raw '${tmp}'
    \$r = ConvertTo-JiraTasksParseDocument -Text \$doc | ConvertFrom-Json -Depth 100
    [Console]::Out.Write((\$r.tasks[0].description | ConvertTo-Json -Depth 100 -Compress))")"
  [ "$(jq -cS '.' <<< "${b}")" = "$(jq -cS '.' <<< "${p}")" ]
}
