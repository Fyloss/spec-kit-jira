#!/usr/bin/env bats
# T004 [019] — The ownership decision (contracts/ownership-decision.md §1).
#
# `managed_section_ownership_split <marker> <managed-nodes> <ownership>` decides
# whose text an UNBOUNDED description belongs to. It owns the whole decision
# table — marker count first, ownership second — so every caller (story, parent,
# task) routes through one place. `self` is the fix (019, FR-002): a ticket the
# mirror created has no human text to protect, so the whole existing description
# is replaced rather than preserved above a fresh boundary.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE}/managed_section.sh"
  MARKER='Synced from spec-kit — do not edit below this line'
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "${WORK}"; }

MANAGED='[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'

@test "row 1: marker occurs more than once is malformed regardless of ownership" {
  local existing="[
    {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"${MARKER}\",\"marks\":[{\"type\":\"strong\"}]}]},
    {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"${MARKER}\",\"marks\":[{\"type\":\"strong\"}]}]}
  ]"
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' self"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "malformed" ]
  [ "$(jq 'has("prefix")' <<< "$output")" = "false" ]
}

@test "row 2: marker occurs exactly once keeps the prefix above it, status ok" {
  local existing="[
    {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"Human note.\"}]},
    {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"${MARKER}\",\"marks\":[{\"type\":\"strong\"}]}]},
    {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"old managed body\"}]}
  ]"
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' other"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.prefix[0].content[0].text' <<< "$output")" = "Human note." ]
}

@test "row 3: marker absent, ownership self yields an empty prefix, status ok" {
  local existing='[{"type":"paragraph","content":[{"type":"text","text":"whatever the mirror wrote before"}]}]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' self"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 0 ]
}

@test "row 4a: marker absent, ownership other, suffix matches — prefix is the human text before it, status ok" {
  local existing='[
    {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
    {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
  ]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' other"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.prefix[0].content[0].text' <<< "$output")" = "Human note." ]
}

@test "row 4b: marker absent, ownership other, suffix does not match — whole content preserved, status migrated-warned" {
  local existing='[{"type":"paragraph","content":[{"type":"text","text":"unrelated content"}]}]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' other"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "migrated-warned" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.prefix[0].content[0].text' <<< "$output")" = "unrelated content" ]
}

@test "row 5: marker absent, ownership unknown — whole content preserved, status migrated-warned, regardless of match" {
  local existing='[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' unknown"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "migrated-warned" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
}

@test "an unrecognised ownership string is treated as unknown" {
  local existing='[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_ownership_split '${MARKER}' '${MANAGED}' bogus"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "migrated-warned" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
}

@test "the decision is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local existing='[
    {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
    {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
  ]'
  printf '%s' "${existing}" > "${WORK}/desc.json"
  for ownership in self other unknown; do
    local b p
    b="$(managed_section_ownership_split "${MARKER}" "${MANAGED}" "${ownership}" < "${WORK}/desc.json")"
    p="$(pwsh -NoProfile -Command "
      Import-Module '${PS_ENGINE}/ManagedSection.psm1' -Force
      \$c = [System.IO.File]::ReadAllText('${WORK}/desc.json')
      [Console]::Out.Write((Split-JiraManagedSectionOwnership -Marker '${MARKER}' -ManagedJson '${MANAGED}' -Ownership '${ownership}' -ExistingJson \$c))
    ")"
    [ "${b}" = "${p}" ]
  done
}
