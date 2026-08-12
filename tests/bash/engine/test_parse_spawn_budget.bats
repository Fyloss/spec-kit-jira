#!/usr/bin/env bats
# T022-T023 — the two per-line spawn sources research R5 measured as
# dominant in the parse phase (contracts/spawn-budget.md C1.2, C1.4):
# `_parse_strip_marker_lines` (two marker-parser calls per line, each with
# its own sed trims and a jq `.kind` extraction) and `_parse_lines_to_json`
# (one jq per line, re-parsing the accumulator — O(n) spawns, O(n²) data).
#
# Scoped to these two functions directly rather than through the whole
# `parse_spec` surface: several OTHER call sites in parse.sh also spawn per
# item (parse_acceptance_criteria's per-clause accumulation,
# spec_marker_document_info's per-line classification, and parse_story's six
# per-story pipelines, T027) and are not touched by this pass — a test
# through the full integration surface would not reach zero growth yet and
# would misrepresent what T025/T026 actually fix.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/spawn_count.bash"
  SHIM_DIR="${BATS_TMPDIR}/parse_spawn_shims_$$"
  COUNT_FILE="${BATS_TMPDIR}/parse_spawn_count_$$.log"
  helper_spawn_count_setup "${SHIM_DIR}" "${COUNT_FILE}"
}

teardown() {
  rm -rf "${SHIM_DIR}" "${COUNT_FILE}"
}

# _gen_prose_lines <n> — <n> ordinary, non-marker prose lines (what the
# overwhelming majority of a real specification's lines look like).
_gen_prose_lines() {
  local n="$1" i out=""
  for ((i = 1; i <= n; i++)); do
    out+="This is an ordinary prose line number ${i} with no marker in it."$'\n'
  done
  printf '%s' "${out}"
}

# Sources parse.sh, THEN truncates the count file, so lib/output.sh's
# one-time Windows-CRLF jq probe (unconditional at source/module-load time,
# never per-call) is excluded from what gets measured — a per-process setup
# cost is not what C1.2's "does not grow with line count" is asking about.
_spawn_count_for() {
  local fn="$1" doc="$2" n
  PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${ENGINE_DIR}"'/parse.sh"
    : > "'"${COUNT_FILE}"'"
    printf "%s" "$2" | "$1" > /dev/null
  ' _ "${fn}" "${doc}"
  n="$(helper_spawn_count_total "${COUNT_FILE}")"
  printf '%s' "${n}"
}

@test "T022: _parse_strip_marker_lines spawns nothing extra as line count doubles (C1.2)" {
  local c50 c100
  c50="$(_spawn_count_for _parse_strip_marker_lines "$(_gen_prose_lines 50)")"
  c100="$(_spawn_count_for _parse_strip_marker_lines "$(_gen_prose_lines 100)")"
  [ "${c50}" = "0" ]
  [ "${c100}" = "0" ]
}

@test "T022: _parse_lines_to_json spawns a bounded, non-growing count as line count doubles (C1.2)" {
  local c50 c100
  c50="$(_spawn_count_for _parse_lines_to_json "$(_gen_prose_lines 50)")"
  c100="$(_spawn_count_for _parse_lines_to_json "$(_gen_prose_lines 100)")"
  [ "${c50}" -gt 0 ]
  [ "${c100}" = "${c50}" ]
}

@test "T023: _parse_strip_marker_lines reaches the zero floor on empty input (C1.4)" {
  local c0
  c0="$(_spawn_count_for _parse_strip_marker_lines "")"
  [ "${c0}" = "0" ]
}

@test "T023: _parse_lines_to_json's empty-input floor is no worse than its populated-input floor (C1.4)" {
  local c0 c50
  c0="$(_spawn_count_for _parse_lines_to_json "")"
  c50="$(_spawn_count_for _parse_lines_to_json "$(_gen_prose_lines 50)")"
  [ "${c0}" -le "${c50}" ]
}

@test "_parse_strip_marker_lines spawns bounded by marker-line count, not document line count" {
  # Two real marker lines (a valid story= and a valid spec=), each costing
  # two jq calls to encode its OWN classification (the `jq -cn` that builds
  # the JSON plus json_canonical's own `jq -cS .`) — proportional to how
  # many markers exist, never to how many ordinary lines surround them. A
  # third line looks like an attempt but has an invalid (non-hex) id, which
  # story_marker.sh classifies as "none" by its own grammar (not this
  # function's concern) and costs nothing extra.
  local doc
  doc="### User Story 1 - First (Priority: P1)"$'\n'
  doc+="<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->"$'\n'
  doc+="<!-- speckit-jira spec=3f2a91c04b7e6d18 -->"$'\n'
  doc+="Body text."$'\n'
  doc+="<!-- speckit-jira story=badid -->"$'\n'
  local c
  c="$(_spawn_count_for _parse_strip_marker_lines "${doc}")"
  [ "${c}" = "4" ]
}

# --- Beyond T025/T026: per-item jq loops found while implementing them -----
#
# parse_acceptance_criteria, parse_design, parse_description_blocks, and the
# marker section-info readers all had their own per-item jq accumulation,
# not named by research R5 but discovered wiring T025/T026 through. Fixed
# the same way: native accumulation, one jq call at the boundary that
# actually needs one (a scenario, a whole item list, a whole block list) —
# never one per item.

_gen_ac_and_clauses() {
  local n="$1" i out="- **Given** a starting thing"$'\n'
  for ((i = 1; i <= n; i++)); do
    out+="- **And** extra condition ${i}"$'\n'
  done
  out+="- **When** it happens"$'\n'"- **Then** it works"$'\n'
  printf '%s' "${out}"
}

@test "parse_acceptance_criteria spawns the same count regardless of clause count within one scenario" {
  local c10 c20
  c10="$(_spawn_count_for parse_acceptance_criteria "$(_gen_ac_and_clauses 10)")"
  c20="$(_spawn_count_for parse_acceptance_criteria "$(_gen_ac_and_clauses 20)")"
  [ "${c10}" -gt 0 ]
  [ "${c20}" = "${c10}" ]
}

# T027 (2026-08-11) — the clause-count test above holds SCENARIO count fixed
# at 1 throughout; it cannot see `_parse_ac_flush`'s own cost, which scales
# with the number of SCENARIOS, not clauses within one. The same gap-shape
# T033 found in T037: one dimension tested, a different one left growing.
_gen_ac_scenarios() {
  local n="$1" i out=""
  for ((i = 1; i <= n; i++)); do
    out+="- **Given** starting thing ${i}"$'\n'"- **When** it happens"$'\n'"- **Then** it works"$'\n'
  done
  printf '%s' "${out}"
}

@test "T027: parse_acceptance_criteria spawns a bounded, non-growing count as SCENARIO count doubles (C1.2)" {
  local c10 c20
  c10="$(_spawn_count_for parse_acceptance_criteria "$(_gen_ac_scenarios 10)")"
  c20="$(_spawn_count_for parse_acceptance_criteria "$(_gen_ac_scenarios 20)")"
  [ "${c10}" -gt 0 ]
  [ "${c20}" = "${c10}" ]
}

_gen_design_guidance() {
  local n="$1" i out="#### Design"$'\n\n'
  for ((i = 1; i <= n; i++)); do
    out+="- Guidance line ${i} for the design."$'\n'
  done
  printf '%s' "${out}"
}

@test "parse_design spawns the same count regardless of guidance-item count" {
  local c10 c20
  c10="$(_spawn_count_for parse_design "$(_gen_design_guidance 10)")"
  c20="$(_spawn_count_for parse_design "$(_gen_design_guidance 20)")"
  [ "${c10}" -gt 0 ]
  [ "${c20}" = "${c10}" ]
}

@test "parse_design reaches the zero floor when there is nothing to find" {
  local c
  c="$(_spawn_count_for parse_design "Just some prose with no design section.")"
  [ "${c}" = "0" ]
}

_gen_description_paragraphs() {
  local n="$1" i out=""
  for ((i = 1; i <= n; i++)); do
    out+="Paragraph number ${i} of the overview."$'\n\n'
  done
  printf '%s' "${out}"
}

@test "parse_description_blocks spawns the same count regardless of paragraph count" {
  local c10 c20
  c10="$(_spawn_count_for parse_description_blocks "$(_gen_description_paragraphs 10)")"
  c20="$(_spawn_count_for parse_description_blocks "$(_gen_description_paragraphs 20)")"
  [ "${c10}" -gt 0 ]
  [ "${c20}" = "${c10}" ]
}

@test "spec_marker_document_info spawns nothing extra as line count doubles" {
  local c50 c100
  c50="$(_spawn_count_for spec_marker_document_info "$(_gen_prose_lines 50)")"
  c100="$(_spawn_count_for spec_marker_document_info "$(_gen_prose_lines 100)")"
  [ "${c50}" -gt 0 ]
  [ "${c100}" = "${c50}" ]
}

@test "story_marker_section_info spawns nothing extra as line count doubles" {
  local doc100
  doc100="$(_gen_prose_lines 100)"
  local c50 c100
  c50="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${ENGINE_DIR}"'/parse.sh"
    : > "'"${COUNT_FILE}"'"
    story_marker_section_info "$1" 1 50 > /dev/null
  ' _ "${doc100}"; helper_spawn_count_total "${COUNT_FILE}")"
  c100="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${ENGINE_DIR}"'/parse.sh"
    : > "'"${COUNT_FILE}"'"
    story_marker_section_info "$1" 1 100 > /dev/null
  ' _ "${doc100}"; helper_spawn_count_total "${COUNT_FILE}")"
  [ "${c50}" -gt 0 ]
  [ "${c100}" = "${c50}" ]
}

# T027 (2026-08-11) — `_parse_epic_extra_blocks` (the epic's Success
# Criteria / Out of Scope sections) has the same per-item jq-merge shape
# `_parse_ac_flush` had: one `. + [$v]` call per bullet item. It takes the
# whole document as an ARGUMENT, not stdin, so it needs its own harness
# rather than `_spawn_count_for`.
_gen_epic_sc_items() {
  local n="$1" i out="## Success Criteria"$'\n\n'"### Measurable Outcomes"$'\n\n'
  for ((i = 1; i <= n; i++)); do
    out+="- **SC-$(printf '%03d' "${i}")**: Outcome number ${i} is measurable."$'\n'
  done
  printf '%s' "${out}"
}

@test "T027: _parse_epic_extra_blocks spawns a bounded, non-growing count as Success-Criteria item count doubles (C1.2)" {
  local doc10 doc20 c10 c20
  doc10="$(_gen_epic_sc_items 10)"
  doc20="$(_gen_epic_sc_items 20)"
  c10="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${ENGINE_DIR}"'/parse.sh"
    : > "'"${COUNT_FILE}"'"
    _parse_epic_extra_blocks "$1" > /dev/null
  ' _ "${doc10}"; helper_spawn_count_total "${COUNT_FILE}")"
  c20="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${ENGINE_DIR}"'/parse.sh"
    : > "'"${COUNT_FILE}"'"
    _parse_epic_extra_blocks "$1" > /dev/null
  ' _ "${doc20}"; helper_spawn_count_total "${COUNT_FILE}")"
  # Unlike every other function in this file, this one forks NOTHING at all
  # (no `json_canonical` call at its own boundary either) — a stricter floor
  # than "flat but nonzero", so the assertion is equality alone, not `-gt 0`.
  [ "${c10}" = "0" ]
  [ "${c20}" = "${c10}" ]
}
