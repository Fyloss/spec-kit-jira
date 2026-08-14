#!/usr/bin/env bats
# T0xx [026] — a fixture-dependent test file reports ok/skip, never a
# failure, when `specify` is absent from PATH.
#
# The reported defect: `test_surface_matches_dev_install.bats`'s teardown
# ends with `[ -n "${REPO}" ] && fixture_cleanup "${REPO}"`. When setup()
# skips before REPO is ever assigned a real value, that line evaluates
# `[ -n "" ]` — false, exit 1 — and because it is teardown's LAST command,
# bats reports the whole (correctly skipped) test as FAILED. This is
# invisible locally wherever `specify` happens to be installed, and only
# shows up on a host where it genuinely is not — exactly what surfaced it
# on CI. `test_bridge_runs_without_exec_bit.bats` masks the same pattern by
# accident: its teardown ends with `rm -rf "${WORK}"`, and `rm -rf ""`
# exits 0, so the bug was silent there.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  RUN_BASH="${ROOT}/tests/run-bash.sh"
  SAFE_PATH=""
  while IFS= read -r d; do
    [[ -z "${d}" ]] && continue
    [[ -e "${d}/specify" ]] && continue
    SAFE_PATH="${SAFE_PATH:+${SAFE_PATH}:}${d}"
  done < <(printf '%s' "${PATH}" | tr ':' '\n')
}

@test "every consumer_fixture.bash-dependent file reports ok/skip, not failure, with specify absent" {
  for f in tests/bash/packaging/test_surface_matches_dev_install.bats \
           tests/bash/packaging/test_bridge_runs_without_exec_bit.bats; do
    run env PATH="${SAFE_PATH}" "${RUN_BASH}" "${ROOT}/${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'FAILED'* ]]
  done
}
