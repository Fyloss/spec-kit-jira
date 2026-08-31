#!/usr/bin/env bats
# T003/T005 [Phase 2, 035] — the bound project set
# (035 contracts/marker-routing.md C1.1–C1.7; data-model.md §1).
#
# Supersedes the boolean predicate this file used to cover
# (`story_marker_any_bound`, 033 C3.3/C3.4). Routing needs more than "is it
# bound": it needs WHICH project the specification's own markers record, which
# is the record 033 cited as its justification and never read.
#
# The value is a SET, and its cardinality answers three separate questions:
# empty means not bound and today's resolution applies unchanged; exactly one
# is the marker rank and the value every tier is compared against; more than
# one is a refusal.
#
# Only the ticket-bearing marker form contributes. `creating` is a run in
# flight, a bare marker is assigned-but-not-yet-created, and neither pins a
# project.
#
# C1.5 forbids a process per line, per story or per marker, which is also why
# this does not go through story_marker_parse_line (one `jq` per line).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/story_marker.sh"
}

@test "C1.1 a ticket-bearing story marker yields its project" {
  run marker_bound_projects '# Spec
<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->
body'
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C1.3 a bound PARENT alone yields its project" {
  # The deliberate widening over 033 C3.3, which read the story grammar only.
  # A bound parent pins the project exactly as a bound story does.
  run marker_bound_projects '<!-- speckit-jira spec=0123456789abcdef ticket=ALPHA-1 -->'
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C1.3 a bound task marker yields its project" {
  run marker_bound_projects '<!-- speckit-jira task=0123456789abcdef ticket=TASKP-9 -->'
  [ "$status" -eq 0 ]
  [ "$output" = "TASKP" ]
}

@test "C1.2 an in-flight (creating) marker contributes nothing" {
  run marker_bound_projects '<!-- speckit-jira story=0123456789abcdef creating -->'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.2 a bare assigned marker contributes nothing" {
  run marker_bound_projects '<!-- speckit-jira story=0123456789abcdef -->'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.2 a document with no marker at all yields the empty set" {
  run marker_bound_projects '# Spec

Just prose, no markers anywhere.'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.2 empty input yields the empty set" {
  run marker_bound_projects ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.2 a malformed marker id contributes nothing" {
  run marker_bound_projects '<!-- speckit-jira story=NOTHEX ticket=ALPHA-88 -->'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.4 a key not matching the issue-key grammar contributes nothing" {
  run marker_bound_projects '<!-- speckit-jira story=0123456789abcdef ticket=lower-1 -->'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.1 one bound story among unbound ones yields one element" {
  run marker_bound_projects '<!-- speckit-jira story=1111111111111111 -->
<!-- speckit-jira story=2222222222222222 creating -->
<!-- speckit-jira story=3333333333333333 ticket=BETA-7 -->'
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

@test "C1.1 repeated markers in one project yield ONE element" {
  run marker_bound_projects '<!-- speckit-jira spec=0000000000000001 ticket=ALPHA-1 -->
<!-- speckit-jira story=1111111111111111 ticket=ALPHA-2 -->
<!-- speckit-jira story=2222222222222222 ticket=ALPHA-3 -->'
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C1.1 markers naming two projects yield both, sorted" {
  run marker_bound_projects '<!-- speckit-jira story=1111111111111111 ticket=ZULU-9 -->
<!-- speckit-jira story=2222222222222222 ticket=ALPHA-2 -->'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ALPHA" ]
  [ "${lines[1]}" = "ZULU" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "C1.1 a parent and its stories disagreeing yields both" {
  # The state an interrupted re-route leaves behind, and the one C3.1 refuses.
  run marker_bound_projects '<!-- speckit-jira spec=0000000000000001 ticket=ALPHA-1 -->
<!-- speckit-jira story=1111111111111111 ticket=BETA-2 -->'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "ALPHA" ]
  [ "${lines[1]}" = "BETA" ]
}

@test "C1.7 a CRLF document yields the same set as an LF one" {
  run marker_bound_projects "$(printf '# Spec\r\n<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->\r\nbody\r\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C1.7 a CRLF document with only unbound markers yields the empty set" {
  run marker_bound_projects "$(printf '<!-- speckit-jira story=0123456789abcdef creating -->\r\n')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C1.5 the scan spawns no external process, on a 200-story document" {
  # The shim only counts when it is EARLIER on PATH than the real tool, and
  # helper_spawn_count_setup deliberately does not touch PATH — the caller
  # prepends it around a child that does the measured work. Measured
  # in-process, this assertion counts zero whatever the code does, which is
  # a guard that passes on a broken instrument.
  #
  # The count file is truncated inside the child, after sourcing: loading the
  # module costs `jq` calls of its own that are not part of the scan.
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  local shim_dir="${BATS_TMPDIR}/smk_bound_shims_$$"
  local count_file="${BATS_TMPDIR}/smk_bound_count_$$.log"
  helper_spawn_count_setup "${shim_dir}" "${count_file}"

  # Proof the instrument is live before trusting the zero it is about to report.
  PATH="${shim_dir}:${PATH}" bash -c 'jq -n 1 > /dev/null'
  [ "$(helper_spawn_count_total "${count_file}")" -eq 1 ]

  PATH="${shim_dir}:${PATH}" SMK_COUNT="${count_file}" ENGINE_DIR="${ENGINE_DIR}" bash -c '
    source "${ENGINE_DIR}/story_marker.sh"
    doc=""
    for i in $(seq 1 200); do
      doc="${doc}<!-- speckit-jira story=$(printf "%016d" "$i") ticket=ALPHA-${i} -->"$'"'"'\n'"'"'
    done
    : > "${SMK_COUNT}"
    marker_bound_projects "${doc}" > /dev/null
  '
  [ "$(helper_spawn_count_total "${count_file}")" -eq 0 ]
}
