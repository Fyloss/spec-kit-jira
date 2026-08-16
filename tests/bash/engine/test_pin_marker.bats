#!/usr/bin/env bats
# T037/T042/T044/T046 [027] — The pinning marker (contracts/pin-marker.md).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/pin_marker.sh"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/story_marker.sh"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/spec_marker.sh"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/task_marker.sh"
}

# --- §2 written form ----------------------------------------------------------

@test "pin_marker_format produces the exact written form" {
  run pin_marker_format "PROJ-142"
  [ "$status" -eq 0 ]
  [ "$output" = "<!-- speckit-jira pin=PROJ-142 -->" ]
}

# --- P-1: pin= parses as none in the other three parsers, and vice versa ----

@test "P-1: pin= parses as none in the story parser" {
  run story_marker_parse_line "<!-- speckit-jira pin=PROJ-1 -->"
  [ "$output" = '{"kind":"none"}' ]
}

@test "P-1: pin= parses as none in the spec parser" {
  run spec_marker_parse_line "<!-- speckit-jira pin=PROJ-1 -->"
  [ "$output" = '{"kind":"none"}' ]
}

@test "P-1: pin= parses as none in the task parser" {
  run task_marker_parse_line "<!-- speckit-jira pin=PROJ-1 -->"
  [ "$output" = '{"kind":"none"}' ]
}

@test "P-1: story= parses as none in the pin parser" {
  run pin_marker_parse_line "<!-- speckit-jira story=7f3a9c1e40b2d85a -->"
  [ "$output" = '{"kind":"none"}' ]
}

@test "P-1: spec= parses as none in the pin parser" {
  run pin_marker_parse_line "<!-- speckit-jira spec=COMP-1 -->"
  [ "$output" = '{"kind":"none"}' ]
}

@test "P-1: task= parses as none in the pin parser" {
  run pin_marker_parse_line "<!-- speckit-jira task=T001 ticket=COMP-1 -->"
  [ "$output" = '{"kind":"none"}' ]
}

@test "pin_marker_parse_line accepts a well-formed pin= body" {
  run pin_marker_parse_line "<!-- speckit-jira pin=PROJ-142 -->"
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-142" ]
}

@test "pin_marker_parse_line rejects an empty pin= body as malformed" {
  run pin_marker_parse_line "<!-- speckit-jira pin= -->"
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
}

@test "pin_marker_parse_line rejects a pin= body carrying embedded whitespace as malformed" {
  run pin_marker_parse_line "<!-- speckit-jira pin=PROJ-1 extra -->"
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
}

@test "pin_marker_parse_line returns none for an unrelated line" {
  run pin_marker_parse_line "just some prose"
  [ "$output" = '{"kind":"none"}' ]
}

# --- P-2: placement at ###, ##, #### and the H1 fallback --------------------

@test "P-2: pin_marker_anchors finds a ### heading" {
  local spec
  spec=$'# Feature\n\n### User Story 1 - Thing (Priority: P1)\n\nBody\n'
  run pin_marker_anchors "${spec}"
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$output" = "3" ]
}

@test "P-2: pin_marker_anchors finds ##, ###, #### mixed" {
  local spec
  spec=$'# Feature\n\n## User Story 1 - A (Priority: P1)\n\nBody\n\n#### User Story 2 - B (Priority: P1)\n\nBody\n'
  run pin_marker_anchors "${spec}"
  [ "$(echo "$output" | sed -n '1p')" = "3" ]
  [ "$(echo "$output" | sed -n '2p')" = "7" ]
}

@test "P-2: falls back to the document's first H1 when no story heading exists" {
  local spec
  spec=$'# Feature Title\n\nSome prose, no story headings.\n'
  run pin_marker_anchors "${spec}"
  [ "$output" = "1" ]
}

# --- P-3/P-4: the four properties, independently and together ----------------

_spec_two_stories_both_pinned() {
  printf '%s\n' \
    '# Feature' '' \
    '### User Story 1 - A (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' '' \
    'Body A' '' \
    '### User Story 2 - B (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-12 -->' '' \
    'Body B'
}

@test "P-3/P-4: a clean file with both properties satisfied reports zero violations" {
  local spec dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  _spec_two_stories_both_pinned > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11","PROJ-12"]'
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
  rm -rf "${dir}"
}

@test "P-3: a dropped key (no marker at all) is reported independently, naming the key" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  printf '%s\n' '# Feature' '' '### User Story 1 - A (Priority: P1)' '<!-- speckit-jira pin=PROJ-11 -->' '' 'Body' > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11","PROJ-12"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.kind=="missing") | .key' <<< "$output")" = "PROJ-12" ]
  rm -rf "${dir}"
}

@test "P-3: an orphan marker (names no designated key) is reported independently, naming the key and line" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  _spec_two_stories_both_pinned > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.kind=="orphan") | .key' <<< "$output")" = "PROJ-12" ]
  [ "$(jq -r '.[] | select(.kind=="orphan") | .lines[0]' <<< "$output")" -gt 0 ]
  rm -rf "${dir}"
}

@test "P-3: a split (same key in two markers) is reported independently, naming the key and both lines" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  printf '%s\n' '# Feature' '' \
    '### User Story 1 - A (Priority: P1)' '<!-- speckit-jira pin=PROJ-11 -->' '' 'Body A' '' \
    '### User Story 2 - B (Priority: P1)' '<!-- speckit-jira pin=PROJ-11 -->' '' 'Body B' > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.kind=="split") | .key' <<< "$output")" = "PROJ-11" ]
  [ "$(jq -r '.[] | select(.kind=="split") | .lines | length' <<< "$output")" -eq 2 ]
  rm -rf "${dir}"
}

@test "P-3: a merge (two markers under one story) is reported independently" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  printf '%s\n' '# Feature' '' \
    '### User Story 1 - A (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' \
    '<!-- speckit-jira pin=PROJ-12 -->' '' 'Body A' > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11","PROJ-12"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.kind=="merge")] | length' <<< "$output")" -eq 1 ]
  rm -rf "${dir}"
}

@test "P-3: a reordered marker is reported independently" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  printf '%s\n' '# Feature' '' \
    '### User Story 1 - A (Priority: P1)' '<!-- speckit-jira pin=PROJ-12 -->' '' 'Body A' '' \
    '### User Story 2 - B (Priority: P1)' '<!-- speckit-jira pin=PROJ-11 -->' '' 'Body B' > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11","PROJ-12"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.kind=="reorder")] | length' <<< "$output")" -eq 1 ]
  rm -rf "${dir}"
}

@test "P-4: all four violation kinds at once are reported together, not one at a time" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  printf '%s\n' '# Feature' '' \
    '### User Story 1 - A (Priority: P1)' '<!-- speckit-jira pin=PROJ-99 -->' '' 'Body A' '' \
    '### User Story 2 - B (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' \
    '<!-- speckit-jira pin=PROJ-11 -->' '' 'Body B' > "${file}"
  # Designated: PROJ-11 (dropped nowhere, but doubled = split within one
  # section = also a merge), PROJ-12 (missing), plus PROJ-99 is an orphan.
  run pin_marker_validate "${file}" '["PROJ-11","PROJ-12"]'
  [ "$status" -eq 0 ]
  local kinds
  kinds="$(jq -r '[.[].kind] | unique | sort | join(",")' <<< "$output")"
  [[ "${kinds}" == *"missing"* ]]
  [[ "${kinds}" == *"orphan"* ]]
  [[ "${kinds}" == *"split"* || "${kinds}" == *"merge"* ]]
  rm -rf "${dir}"
}

# --- P-5: an edit that leaves the four properties intact passes silently ----

@test "P-5: a prose rewrite, a new scenario, a renamed heading, and a new unpinned story all pass" {
  local dir file
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  printf '%s\n' '# Feature — renamed' '' \
    '### User Story 1 - A, rewritten (Priority: P1)' '<!-- speckit-jira pin=PROJ-11 -->' '' \
    'Totally different prose.' '- **Given** x' '- **When** y' '- **Then** z' '' \
    '### User Story 2 - B (Priority: P1)' '<!-- speckit-jira pin=PROJ-12 -->' '' 'Body B' '' \
    '### User Story 3 - New, unpinned (Priority: P2)' '' 'Brand new story, no marker.' > "${file}"
  run pin_marker_validate "${file}" '["PROJ-11","PROJ-12"]'
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
  rm -rf "${dir}"
}

# --- P-9: 100 markers, functional at scale (spawn-count pinned in Phase 10) --

@test "P-9: validating 100 markers succeeds and reports zero violations" {
  local dir file i keys="["
  dir="$(mktemp -d)"
  file="${dir}/spec.md"
  {
    printf '# Feature\n\n'
    for i in $(seq 1 100); do
      printf '### User Story %d - S%d (Priority: P1)\n<!-- speckit-jira pin=PROJ-%d -->\n\nBody %d\n\n' "${i}" "${i}" "${i}" "${i}"
      [[ "${i}" != "1" ]] && keys+=","
      keys+="\"PROJ-${i}\""
    done
  } > "${file}"
  keys+="]"
  run pin_marker_validate "${file}" "${keys}"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<< "$output")" -eq 0 ]
  rm -rf "${dir}"
}

# --- §6 consumption at binding (P-7) -----------------------------------------

@test "P-7: consumption replaces the pin marker in place, preserving every other byte" {
  local content new
  content=$'### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-142 -->\n\nBody, unchanged.\n'
  new="$(pin_marker_consume "${content}" "PROJ-142" "<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->" $'\n')"
  [[ "${new}" == *"story=7f3a9c1e40b2d85a ticket=PROJ-142"* ]]
  [[ "${new}" != *"pin=PROJ-142"* ]]
  [[ "${new}" == *"Body, unchanged."* ]]
}

@test "P-7: consumption preserves CRLF line endings" {
  local content new
  content=$'### User Story 1 - A (Priority: P1)\r\n<!-- speckit-jira pin=PROJ-142 -->\r\n\r\nBody.\r\n'
  new="$(pin_marker_consume "${content}" "PROJ-142" "<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->" $'\r\n')"
  [[ "${new}" == *$'story=7f3a9c1e40b2d85a ticket=PROJ-142 -->\r\n'* ]]
}
