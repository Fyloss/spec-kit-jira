#!/usr/bin/env bats
# T006 [Phase 3, US1] — the boundness predicate
# (contracts/routing-resolution.md C3.3, C3.4; spec FR-004).
#
# Routing rank 3 — the operator's own team — applies ONLY to a specification
# none of whose stories is already bound. Without that condition, routing would
# depend on a gitignored file and two developers would reroute the same spec
# back and forth, each run creating a second ticket set in the other project.
#
# Only the ticket-bearing marker form counts. `creating` is a run in flight,
# a bare marker is assigned-but-not-yet-created, and neither pins a project.
#
# C3.4 forbids a process per line, per story or per marker: the predicate is a
# pure in-shell scan, which is also why it does not go through
# story_marker_parse_line (one `jq` per line).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/story_marker.sh"
}

@test "C3.3 a ticket-bearing marker counts as bound" {
  run story_marker_any_bound '# Spec
<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->
body'
  [ "$status" -eq 0 ]
}

@test "C3.3 an in-flight (creating) marker does NOT count as bound" {
  run story_marker_any_bound '# Spec
<!-- speckit-jira story=0123456789abcdef creating -->
body'
  [ "$status" -ne 0 ]
}

@test "C3.3 a bare assigned marker does NOT count as bound" {
  run story_marker_any_bound '# Spec
<!-- speckit-jira story=0123456789abcdef -->
body'
  [ "$status" -ne 0 ]
}

@test "C3.3 a specification with no marker at all is not bound" {
  run story_marker_any_bound '# Spec

Just prose, no markers anywhere.'
  [ "$status" -ne 0 ]
}

@test "C3.3 empty input is not bound" {
  run story_marker_any_bound ''
  [ "$status" -ne 0 ]
}

@test "C3.3 one bound story among several unbound ones counts as bound" {
  run story_marker_any_bound '<!-- speckit-jira story=1111111111111111 -->
<!-- speckit-jira story=2222222222222222 creating -->
<!-- speckit-jira story=3333333333333333 ticket=BETA-7 -->'
  [ "$status" -eq 0 ]
}

@test "C3.3 a spec marker (not a story marker) does not count" {
  # The specification-level marker has its own grammar; rank 3 is bounded by
  # STORY binding, which is what pins a project for the tickets this run writes.
  run story_marker_any_bound '<!-- speckit-jira spec=0123456789abcdef ticket=ALPHA-1 -->'
  [ "$status" -ne 0 ]
}

@test "C3.3 a malformed story id is not a marker and does not count" {
  run story_marker_any_bound '<!-- speckit-jira story=NOTHEX ticket=ALPHA-88 -->'
  [ "$status" -ne 0 ]
}

@test "C3.3 a malformed ticket key does not count as bound" {
  run story_marker_any_bound '<!-- speckit-jira story=0123456789abcdef ticket=lower-1 -->'
  [ "$status" -ne 0 ]
}

@test "C7.3 a CRLF document is recognised identically" {
  run story_marker_any_bound "$(printf '# Spec\r\n<!-- speckit-jira story=0123456789abcdef ticket=ALPHA-88 -->\r\nbody\r\n')"
  [ "$status" -eq 0 ]
}

@test "C7.3 a CRLF document with only unbound markers is not bound" {
  run story_marker_any_bound "$(printf '<!-- speckit-jira story=0123456789abcdef creating -->\r\n')"
  [ "$status" -ne 0 ]
}

@test "C3.4 the predicate spawns no external process, on a 200-story document" {
  # The shim only counts when it is EARLIER on PATH than the real tool, and
  # helper_spawn_count_setup deliberately does not touch PATH — the caller
  # prepends it around a child that does the measured work. Measured
  # in-process, this assertion counts zero whatever the code does, which is
  # a guard that passes on a broken instrument.
  #
  # The count file is truncated inside the child, after sourcing: loading the
  # module costs `jq` calls of its own that are not part of the predicate.
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
      doc="${doc}<!-- speckit-jira story=$(printf "%016d" "$i") -->"$'"'"'\n'"'"'
    done
    : > "${SMK_COUNT}"
    story_marker_any_bound "${doc}" || true
  '
  [ "$(helper_spawn_count_total "${count_file}")" -eq 0 ]
}
