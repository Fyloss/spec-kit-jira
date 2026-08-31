#!/usr/bin/env bats
# T009/T011 [Phase 3, US1, 035] — routing rank 3, the specification's own record
# (contracts/marker-routing.md C2.1-C2.7).
#
# The chain is five ranks deep now, first non-empty wins:
#   1  committed `routing:` rule          evidence about the SPECIFICATION
#   2  committed teams[].folder_prefix    evidence about the SPECIFICATION
#   3  the specification's bound project  the SPECIFICATION'S OWN RECORD  <- new
#   4  the operator's selected team       evidence about the PERSON
#   5  committed routing_default          the repository's last resort
#
# Rank 3 sits BELOW ranks 1 and 2 because those are committed decisions about
# where this specification belongs, and a team must remain able to move it
# (C2.3). It sits ABOVE ranks 4 and 5 because neither knows anything about this
# specification at all — which is the defect: 033 suppressed rank 4 for a bound
# specification, citing a record it never read, so resolution fell to rank 5 and
# a bound specification planned a duplicate ticket set in the wrong project.
#
# C2.5 is the clause that makes FR-005 verifiable: with the marker input EMPTY,
# the resolver must reproduce the four-input resolver byte for byte, which is
# what leaves every existing repository untouched by construction.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"

  # A repository shaped like the one that produced the report: two projects, a
  # catalogue naming both, a default naming the SECOND, and a feature folder
  # carrying no team-specific prefix.
  CFG='{
    "projects": [{"key": "ALPHA"}, {"key": "BETA"}],
    "routing_default": "BETA",
    "teams": [
      {"id": "alpha", "project": "ALPHA", "folder_prefix": "alpha-"},
      {"id": "beta", "project": "BETA", "folder_prefix": "beta-"}
    ]
  }'
}

@test "C2.1 rank 3 wins over routing_default for a bound specification" {
  run routing_resolve "031-test-feature" '[]' "${CFG}" "" "ALPHA"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.1 rank 3 wins over the operator's selected team" {
  # The operator selects beta; the specification's own record says ALPHA. The
  # record wins, which is what makes a bound spec resolve identically for
  # everyone (FR-004).
  run routing_resolve "031-test-feature" '[]' "${CFG}" "beta" "ALPHA"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.1 two operators with different selections resolve a bound spec identically" {
  run routing_resolve "031-test-feature" '[]' "${CFG}" "alpha" "ALPHA"
  local first="$output"
  run routing_resolve "031-test-feature" '[]' "${CFG}" "beta" "ALPHA"
  [ "$output" = "${first}" ]
  [ "$output" = "ALPHA" ]
}

@test "C2.3 a committed routing rule still outranks the record" {
  # A team that commits a decision about where this specification belongs must
  # still be able to move it. What the run then DOES with the mismatch is C3.2's
  # business, not the resolver's.
  local cfg
  cfg="$(jq -c '. + {routing: [{match: {folder_prefix: "031-"}, project: "BETA"}]}' <<< "${CFG}")"
  run routing_resolve "031-test-feature" '[]' "${cfg}" "" "ALPHA"
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

@test "C2.3 a committed team folder prefix still outranks the record" {
  run routing_resolve "031-beta-thing" '[]' "${CFG}" "" "ALPHA"
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

@test "C2.1 rank 3 places a bound spec in a repository declaring NO routing_default" {
  # Today this refuses — and its refusal already tells the operator the project
  # is "fixed by its own markers" while declining to use it.
  local cfg
  cfg="$(jq -c 'del(.routing_default)' <<< "${CFG}")"
  run routing_resolve "031-test-feature" '[]' "${cfg}" "" "ALPHA"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.5 an empty marker input reproduces the four-input resolver exactly" {
  run routing_resolve "031-test-feature" '[]' "${CFG}" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

@test "C2.5 an omitted marker input reproduces the four-input resolver exactly" {
  run routing_resolve "031-test-feature" '[]' "${CFG}" ""
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

@test "C2.5 an empty marker input still lets rank 4 place an unbound spec" {
  run routing_resolve "031-test-feature" '[]' "${CFG}" "alpha" ""
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.6 no rank yields anything: refusal, exit 4, nothing on stdout" {
  local cfg='{"projects": [{"key": "ALPHA"}]}'
  run routing_resolve "031-test-feature" '[]' "${cfg}" "" ""
  [ "$status" -eq 4 ]
  [ -z "$output" ] || [[ "$output" != *"ALPHA"* ]]
}

@test "C2.7 the resolver still makes exactly ONE external process call with the fifth input" {
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  local shim_dir="${BATS_TMPDIR}/routing_marker_shims_$$"
  local count_file="${BATS_TMPDIR}/routing_marker_count_$$.log"
  helper_spawn_count_setup "${shim_dir}" "${count_file}"

  # Probe the instrument before trusting the number it is about to report.
  PATH="${shim_dir}:${PATH}" bash -c 'jq -n 1 > /dev/null'
  [ "$(helper_spawn_count_total "${count_file}")" -eq 1 ]

  PATH="${shim_dir}:${PATH}" RM_COUNT="${count_file}" ENGINE_DIR="${ENGINE_DIR}" CFG="${CFG}" bash -c '
    source "${ENGINE_DIR}/interchange.sh"
    : > "${RM_COUNT}"
    routing_resolve "031-test-feature" "[]" "${CFG}" "beta" "ALPHA" > /dev/null
  '
  [ "$(helper_spawn_count_total "${count_file}")" -eq 1 ]
}
