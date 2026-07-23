#!/usr/bin/env bats
# T074 [US7] — Origin-discriminated managed-panel splice (engine, neutral).
#
# `managed_section_panel_split` splits an existing description's content-node array
# at the managed-panel marker: everything before the first node that carries the
# marker is the human-authored prefix (preserved verbatim), everything from it
# onward is the previously-written managed section (FR-038/FR-039). The marker is a
# PARAMETER — the engine treats the nodes as opaque JSON and searches every string
# value, so no Jira/panel vocabulary leaks into the neutral layer. The split is
# byte-identical across ports (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/.specify/extensions/jira/scripts/bash/engine"
  PS_ENGINE="${ROOT}/.specify/extensions/jira/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE}/managed_section.sh"
  MARKER='Synced from spec-kit — do not edit below this line'
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "${WORK}"; }

# A description with two human paragraphs above the managed panel. The managed
# section begins with the marker node itself (the first node carrying the marker).
HUMAN_DESC='[
  {"type":"paragraph","content":[{"type":"text","text":"Human intro line."}]},
  {"type":"paragraph","content":[{"type":"text","text":"Second human note."}]},
  {"type":"paragraph","content":[{"type":"text","text":"Synced from spec-kit — do not edit below this line","marks":[{"type":"strong"}]}]},
  {"type":"paragraph","content":[{"type":"text","text":"MANAGED BODY"}]}
]'

@test "splits an existing description into human prefix and managed section at the marker" {
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${HUMAN_DESC}' | managed_section_panel_split '${MARKER}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.had_marker' <<< "$output")" = "true" ]
  # The two human paragraphs are the prefix; the marker node onward is managed.
  [ "$(jq '.prefix | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.prefix[0].content[0].text' <<< "$output")" = "Human intro line." ]
  [ "$(jq -r '.prefix[1].content[0].text' <<< "$output")" = "Second human note." ]
  [ "$(jq '.managed | length' <<< "$output")" -eq 2 ]
  [[ "$(jq -r '.managed[0].content[0].text' <<< "$output")" == *"do not edit below this line"* ]]
}

@test "with no marker present, the whole array is the human prefix (had_marker false)" {
  local plain='[{"type":"paragraph","content":[{"type":"text","text":"only human text"}]}]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${plain}' | managed_section_panel_split '${MARKER}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.had_marker' <<< "$output")" = "false" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
  [ "$(jq '.managed | length' <<< "$output")" -eq 0 ]
}

@test "an empty description yields an empty prefix and no managed section" {
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '[]' | managed_section_panel_split '${MARKER}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.had_marker' <<< "$output")" = "false" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 0 ]
}

@test "the split is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  printf '%s' "${HUMAN_DESC}" > "${WORK}/desc.json"
  local b p
  b="$(managed_section_panel_split "${MARKER}" < "${WORK}/desc.json")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/ManagedSection.psm1' -Force
    \$c = [System.IO.File]::ReadAllText('${WORK}/desc.json')
    [Console]::Out.Write((Split-JiraManagedSectionPanel -Marker '${MARKER}' -ContentJson \$c))
  ")"
  [ "${b}" = "${p}" ]
}
