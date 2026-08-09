#!/usr/bin/env bats
# Guard: every conformance fixture file must be TRACKED by git.
#
# A fixture that exists only on the author's disk is invisible to every local
# run and missing from every CI checkout, so the suite passes on the machine
# that wrote it and fails everywhere else — the most expensive shape of green.
#
# This is not hypothetical. 021's placement fixtures pre-bake a run-state
# directory, and `run_state_record`'s own convention puts a `.gitignore`
# containing `*` beside the document. That pattern ignores the whole directory
# INCLUDING THE .gitignore ITSELF, so `git add` skipped both files silently and
# T021b's two scenarios failed on all three CI hosts while passing locally.
# `git add -f` is the fix; this guard is what makes the omission impossible to
# repeat quietly.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  FIXTURES="tests/conformance/fixtures"
}

@test "every file under tests/conformance/fixtures is tracked by git" {
  cd "${ROOT}" || return 1
  git rev-parse --git-dir > /dev/null 2>&1 || skip "not a git checkout"

  local disk tracked untracked
  disk="$(find "${FIXTURES}" -type f | sort)"
  tracked="$(git ls-files "${FIXTURES}" | sort)"
  untracked="$(comm -23 <(printf '%s\n' "${disk}") <(printf '%s\n' "${tracked}"))"

  if [[ -n "${untracked}" ]]; then
    printf 'fixture file(s) present on disk but NOT tracked by git —\n' >&2
    printf 'a fresh checkout will not have them and the suite will fail there:\n' >&2
    printf '%s\n' "${untracked}" >&2
    printf 'fix with: git add -f <path>\n' >&2
    return 1
  fi
}
