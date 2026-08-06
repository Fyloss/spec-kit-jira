#!/usr/bin/env bats
# T008 [018] — The migration split (research R3, contract §3, data-model.md §2).
#
# `managed_section_suffix_split <managed-nodes>` is pure structural array
# comparison: no marker, no tracker vocabulary. Given the existing content-node
# array on stdin and the freshly rendered managed-node array as the argument, it
# reports whether the existing array ENDS WITH the managed array — an exact
# suffix match means the mirror's own previous output was identified
# unambiguously (FR-020a); no match means it could not be (FR-020b), and the
# whole existing array is preserved rather than any of it discarded.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE}/managed_section.sh"
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "${WORK}"; }

MANAGED='[{"type":"paragraph","content":[{"type":"text","text":"managed body"}]}]'

@test "exact match: existing equals the managed nodes yields an empty prefix" {
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${MANAGED}' | managed_section_suffix_split '${MANAGED}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.matched' <<< "$output")" = "true" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 0 ]
}

@test "match with a human prefix: the prefix is everything before the matched suffix" {
  local existing='[
    {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
    {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
  ]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_suffix_split '${MANAGED}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.matched' <<< "$output")" = "true" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.prefix[0].content[0].text' <<< "$output")" = "Human note." ]
}

@test "no match: the whole existing array is preserved as the prefix" {
  local existing='[{"type":"paragraph","content":[{"type":"text","text":"unrelated content"}]}]'
  run bash -c "source '${ENGINE}/managed_section.sh'; printf '%s' '${existing}' | managed_section_suffix_split '${MANAGED}'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.matched' <<< "$output")" = "false" ]
  [ "$(jq '.prefix | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.prefix[0].content[0].text' <<< "$output")" = "unrelated content" ]
}

@test "the split is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local existing='[
    {"type":"paragraph","content":[{"type":"text","text":"Human note."}]},
    {"type":"paragraph","content":[{"type":"text","text":"managed body"}]}
  ]'
  printf '%s' "${existing}" > "${WORK}/desc.json"
  local b p
  b="$(managed_section_suffix_split "${MANAGED}" < "${WORK}/desc.json")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/ManagedSection.psm1' -Force
    \$c = [System.IO.File]::ReadAllText('${WORK}/desc.json')
    [Console]::Out.Write((Split-JiraManagedSectionSuffix -ManagedJson '${MANAGED}' -ContentJson \$c))
  ")"
  [ "${b}" = "${p}" ]
}
