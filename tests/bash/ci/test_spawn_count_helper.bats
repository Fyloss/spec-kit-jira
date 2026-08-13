#!/usr/bin/env bats
# T003 — Guard for tests/bash/helpers/spawn_count.bash (contracts/spawn-budget.md
# §4 C4.1). The helper counts a known number of invocations exactly, and the
# shim delegates transparently: the real tool's stdout, stderr, and exit code
# are unchanged.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/spawn_count.bash"
  SHIM_DIR="${BATS_TMPDIR}/spawn_count_shims_$$"
  COUNT_FILE="${BATS_TMPDIR}/spawn_count_$$.log"
  helper_spawn_count_setup "${SHIM_DIR}" "${COUNT_FILE}"
}

teardown() {
  rm -rf "${SHIM_DIR}" "${COUNT_FILE}"
}

@test "the helper counts a known number of jq invocations exactly" {
  PATH="${SHIM_DIR}:${PATH}" bash -c 'for i in 1 2 3 4 5; do jq -n 1 > /dev/null; done'
  [ "$(helper_spawn_count_total "${COUNT_FILE}")" = "5" ]
  [ "$(helper_spawn_count_for "${COUNT_FILE}" jq)" = "5" ]
}

@test "the helper counts distinct tools separately and sums them in the total" {
  PATH="${SHIM_DIR}:${PATH}" bash -c '
    jq -n 1 > /dev/null
    jq -n 1 > /dev/null
    printf "x" | sed "s/x/y/" > /dev/null
    printf "x" | awk "{print}" > /dev/null
  '
  [ "$(helper_spawn_count_for "${COUNT_FILE}" jq)" = "2" ]
  [ "$(helper_spawn_count_for "${COUNT_FILE}" sed)" = "1" ]
  [ "$(helper_spawn_count_for "${COUNT_FILE}" awk)" = "1" ]
  [ "$(helper_spawn_count_for "${COUNT_FILE}" curl)" = "0" ]
  [ "$(helper_spawn_count_total "${COUNT_FILE}")" = "4" ]
}

@test "the shim delegates stdout transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n '1 + 1'
  [ "${status}" -eq 0 ]
  [ "${output}" = "2" ]
}

@test "the shim delegates a non-zero exit code transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n 'error("boom")'
  [ "${status}" -ne 0 ]
}

@test "the shim delegates stderr transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n 'error("boom-marker")'
  [[ "${output}" == *"boom-marker"* ]]
}

@test "an uncounted invocation leaves the count file at zero" {
  [ "$(helper_spawn_count_total "${COUNT_FILE}")" = "0" ]
}

# The same gap `tests/bash/helpers/argv_size.bash` closes, and it bites harder
# here: an unresolvable tool bakes `exec "" "$@"` into the shim, so the count
# file stays empty and an empty count file reads as "0 spawns" — the budget
# looks respected by an instrument that never worked. PATH is curated down to
# the externals the helper itself needs plus three of the four shimmed tools,
# so `jq` is the only thing missing.
@test "the helper refuses to build a shim for a tool it cannot resolve" {
  local fake="${BATS_TEST_TMPDIR}/fakepath" t
  mkdir -p "${fake}"
  for t in bash mkdir cat chmod sed awk curl; do
    ln -s "$(command -v "${t}")" "${fake}/${t}"
  done
  run env -i PATH="${fake}" bash -c '
    source "'"${HELPERS}"'/spawn_count.bash"
    helper_spawn_count_setup "'"${BATS_TEST_TMPDIR}"'/absent_shims" "'"${BATS_TEST_TMPDIR}"'/absent.log"
  '
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"jq"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/absent_shims/sed" ]
}
