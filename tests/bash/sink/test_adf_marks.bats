#!/usr/bin/env bats
# T024/T025/T047/T048 [US1/US2] — the neutral mark -> ADF mark map (research
# §1, feature 016): `bold`->`strong`, `italic`->`em`, `monospace`->`code`,
# `strikethrough`->`strike`, `link`->`link` with `href`. Also `ordered_list`
# rendering and verbatim `code` bodies (no inline interpretation, FR-007).
# ADF node names are Atlassian identifiers and live ONLY in the sink
# (Constitution VIII). The PowerShell port renders byte-identical ADF (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/adf.sh"
}

_desc_content() {
  jq -cn --argjson b "$1" '{description:{blocks:$b}}'
}

@test "bold maps to strong" {
  local blocks='[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"bold"}]}]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.content[0].content[0].marks[0].type' <<< "$output")" = "strong" ]
}

@test "italic maps to em" {
  local blocks='[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"italic"}]}]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].content[0].marks[0].type' <<< "$output")" = "em" ]
}

@test "monospace maps to code" {
  local blocks='[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"monospace"}]}]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].content[0].marks[0].type' <<< "$output")" = "code" ]
}

@test "strikethrough maps to strike" {
  local blocks='[{"type":"paragraph","spans":[{"text":"x","marks":[{"kind":"strikethrough"}]}]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].content[0].marks[0].type' <<< "$output")" = "strike" ]
}

@test "link maps to link with href" {
  local blocks='[{"type":"paragraph","spans":[{"text":"docs","marks":[{"kind":"link","href":"https://example.com/x"}]}]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].content[0].marks[0].type' <<< "$output")" = "link" ]
  [ "$(jq -r '.content[0].content[0].marks[0].attrs.href' <<< "$output")" = "https://example.com/x" ]
}

@test "a span with no marks carries no marks key at all" {
  local blocks='[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].content[0] | has("marks")' <<< "$output")" = "false" ]
}

@test "ordered_list renders as an ADF orderedList of listItem paragraphs" {
  local blocks='[{"type":"ordered_list","items":[[{"text":"first","marks":[]}],[{"text":"second","marks":[]}]]}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].type' <<< "$output")" = "orderedList" ]
  [ "$(jq -r '.content[0].content | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.content[0].content[0].type' <<< "$output")" = "listItem" ]
  [ "$(jq -r '.content[0].content[0].content[0].content[0].text' <<< "$output")" = "first" ]
  [ "$(jq -r '.content[0].content[1].content[0].content[0].text' <<< "$output")" = "second" ]
}

@test "a code block body is verbatim — no inline mark interpretation (FR-007)" {
  local blocks='[{"type":"code","text":"**not bold** and [not](a-link)"}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].type' <<< "$output")" = "codeBlock" ]
  [ "$(jq -r '.content[0].content[0].text' <<< "$output")" = "**not bold** and [not](a-link)" ]
  [ "$(jq -r '.content[0].content[0] | has("marks")' <<< "$output")" = "false" ]
}

@test "an empty code body renders no content nodes" {
  local blocks='[{"type":"code","text":""}]'
  run adf_render_description "$(_desc_content "${blocks}")"
  [ "$(jq -r '.content[0].type' <<< "$output")" = "codeBlock" ]
  [ "$(jq '.content[0].content | length' <<< "$output")" -eq 0 ]
}

@test "the PowerShell port maps every mark kind identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local blocks='[{"type":"paragraph","spans":[
    {"text":"a","marks":[{"kind":"bold"}]},
    {"text":"b","marks":[{"kind":"italic"}]},
    {"text":"c","marks":[{"kind":"monospace"}]},
    {"text":"d","marks":[{"kind":"strikethrough"}]},
    {"text":"e","marks":[{"kind":"link","href":"https://example.com"}]}
  ]}]'
  local content b p
  content="$(_desc_content "${blocks}")"
  b="$(adf_render_description "${content}")"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_SINK}/Adf.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraAdfDocument -ContentJson '$(printf '%s' "${content}")'))")"
  [ "${b}" = "${p}" ]
}

@test "the PowerShell port renders ordered_list and code bodies identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local blocks='[
    {"type":"ordered_list","items":[[{"text":"first","marks":[]}],[{"text":"second","marks":[]}]]},
    {"type":"code","text":"**literal** [x](y)"}
  ]'
  local content b p
  content="$(_desc_content "${blocks}")"
  b="$(adf_render_description "${content}")"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_SINK}/Adf.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraAdfDocument -ContentJson '$(printf '%s' "${content}")'))")"
  [ "${b}" = "${p}" ]
}
