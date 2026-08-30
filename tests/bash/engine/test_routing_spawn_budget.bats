#!/usr/bin/env bats
# T014 [Phase 3, US1] — the resolution's process budget
# (contracts/routing-resolution.md C1.3, docs/11-process-budget.md).
#
# C1.3 has two halves and they are one rule: ONE external process for a whole
# resolution, and that count MUST NOT grow with the catalogue. The rank-3
# lookup 033 adds is folded into the `jq` programme that already runs, so a
# 50-team catalogue costs exactly what a 2-team one costs.
#
# This is guarded rather than assumed because `docs/11-process-budget.md`
# records the same defect class being reintroduced three times, twice by
# batching a loop without checking what the batch cost, and once by calibrating
# the guard itself to the wrong host.
#
# Bash only, deliberately: the counting harness exists in no other port
# (tests/powershell/helpers/ holds CallsLog, SecretStoreStub and SeedFixture,
# and nothing equivalent), so C7.1's byte-equivalence obligation does not reach
# this measurement.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"

  SMALL='{"routing":[],"routing_default":"ALPHA","teams":[
    {"id":"alpha","project":"ALPHA","folder_prefix":"alpha-","branch_pattern":"alpha-<ID>/<FEATURE_NAME>"},
    {"id":"beta","project":"BETA","folder_prefix":"beta-","branch_pattern":"beta-<ID>/<FEATURE_NAME>"}]}'

  # 50 teams, the last of which is the one selected — so the lookup cannot be
  # cheap merely by matching early.
  LARGE="$(jq -c '
    .teams = [range(0;50) | {
      id: ("t\(.)"),
      project: ("P\(.)"),
      folder_prefix: ("t\(.)-"),
      branch_pattern: ("t\(.)-<ID>/<FEATURE_NAME>")
    }]' <<< "${SMALL}")"
}

# The shim only counts when it is EARLIER on PATH than the real tool, and
# helper_spawn_count_setup deliberately does not touch PATH itself — the caller
# prepends it, around a child `bash -c` that does the measured work. Measuring
# in-process instead silently counts zero, and a zero that comes from a broken
# instrument is indistinguishable from a zero that comes from good news.
_count_for() {
  local cfg="$1" team="$2" shim_dir count_file
  shim_dir="${BATS_TMPDIR}/routing_shims_$$_${RANDOM}"
  count_file="${BATS_TMPDIR}/routing_count_$$_${RANDOM}.log"
  helper_spawn_count_setup "${shim_dir}" "${count_file}"
  # The count file is truncated INSIDE the child, after sourcing: loading the
  # engine costs one `jq` of its own, which is module-load cost and not part of
  # a resolution. Measuring the total would fold the two together and make the
  # budget unreadable the first time either changed.
  PATH="${shim_dir}:${PATH}" RT_CFG="${cfg}" RT_TEAM="${team}" RT_COUNT="${count_file}" bash -c '
    source "'"${ENGINE_DIR}"'/interchange.sh"
    : > "${RT_COUNT}"
    routing_resolve "007-legacy-cleanup" "[]" "${RT_CFG}" "${RT_TEAM}"
  ' > /dev/null 2>&1 || true
  helper_spawn_count_total "${count_file}"
}

@test "the instrument itself works (a zero must mean zero, not a broken shim)" {
  local shim_dir count_file n
  shim_dir="${BATS_TMPDIR}/routing_probe_shims_$$"
  count_file="${BATS_TMPDIR}/routing_probe_count_$$.log"
  helper_spawn_count_setup "${shim_dir}" "${count_file}"
  PATH="${shim_dir}:${PATH}" bash -c 'jq -n 1 > /dev/null'
  n="$(helper_spawn_count_total "${count_file}")"
  [ "${n}" -eq 1 ]
}

@test "C1.3 one resolution costs exactly one external process" {
  local n
  n="$(_count_for "${SMALL}" "beta")"
  [ "${n}" -eq 1 ]
}

@test "C1.3 the cost does not grow with the catalogue (2 teams vs 50)" {
  local small large
  small="$(_count_for "${SMALL}" "beta")"
  large="$(_count_for "${LARGE}" "t49")"
  [ "${small}" -eq "${large}" ]
}

@test "C1.3 the cost is the same with and without a selection" {
  local with without
  with="$(_count_for "${SMALL}" "beta")"
  without="$(_count_for "${SMALL}" "")"
  [ "${with}" -eq "${without}" ]
}

@test "C1.3 the 50-team resolution still resolves correctly" {
  run routing_resolve "007-legacy-cleanup" '[]' "${LARGE}" "t49"
  [ "$status" -eq 0 ]
  [ "$output" = "P49" ]
}
