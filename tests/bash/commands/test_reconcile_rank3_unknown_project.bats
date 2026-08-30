#!/usr/bin/env bats
# T015 [Phase 3, US1] — a catalogue project that `projects[]` never declares,
# reached through routing rank 3 (spec Edge Cases §1).
#
# This is NOT a routing failure and must not be reported as one: routing
# succeeded and produced a key; the configuration is internally inconsistent.
# The existing unknown-project refusal already covers ranks 1, 2 and 4, and it
# has to stay reachable through the new rank — a rank whose result reaches a
# different refusal path would be a silent hole in the guard.
#
# The message itself was corrected by 033: it used to open "a routing rule names
# project X", which is false when the key came from the teams[] catalogue or
# from routing_default, and saying so would be exactly the "reported as a
# routing failure" the edge case forbids.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
  CFG='{
    "projects": [{"key": "ALPHA"}],
    "routing": [],
    "routing_default": "ALPHA",
    "teams": [
      {"id": "beta", "project": "GHOST", "folder_prefix": "beta-", "branch_pattern": "beta-<ID>/<FEATURE_NAME>"}
    ]
  }'
}

@test "rank 3 resolves the catalogue project even when projects[] omits it" {
  # Resolution itself must SUCCEED — the inconsistency is caught downstream by
  # the declared-projects check, not by making the resolver second-guess the
  # catalogue it was handed.
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "GHOST" ]
}

@test "the resolver does not consult projects[] at all" {
  # Constitution VIII: the resolver is a pure function over routing inputs. It
  # has no opinion about which projects are declared.
  local cfg
  cfg="$(jq -c 'del(.projects)' <<< "${CFG}")"
  run routing_resolve "007-legacy-cleanup" '[]' "${cfg}" "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "GHOST" ]
}

@test "the refusal message no longer claims a routing rule named the project" {
  # The literal that used to be wrong for ranks 2, 3 and 4.
  run grep -c 'a routing rule names project' "${ROOT}/scripts/bash/commands/reconcile.sh"
  [ "$output" = "0" ]
}

@test "the refusal message names all three sources that could have produced the key" {
  run grep -c 'correct the routing rule, the teams\[\] entry, or routing_default that names it' \
    "${ROOT}/scripts/bash/commands/reconcile.sh"
  [ "$output" = "1" ]
}

@test "both ports carry the identical corrected literal" {
  local bash_n ps_n
  bash_n="$(grep -c 'routing resolved project' "${ROOT}/scripts/bash/commands/reconcile.sh")"
  ps_n="$(grep -c 'routing resolved project' "${ROOT}/scripts/powershell/commands/Reconcile.psm1")"
  [ "${bash_n}" -eq 1 ]
  [ "${ps_n}" -eq 1 ]
}
