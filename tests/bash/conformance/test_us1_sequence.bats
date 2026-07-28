#!/usr/bin/env bats
# T079 — Ten operations in mixed order never duplicate or lose an entry (SC-004).
#
# Idempotency is easy to demonstrate for the sequence a developer happens to run
# and easy to break for the one they actually run. The install, the `--force`
# reinstall and the configuration ceremony all touch the same subject from
# different angles, and the ceremony is the one that used to WRITE the registry —
# which is exactly how duplicates appeared in the first place.
#
# So the check is a mixed sequence, not a repetition: install, reinstall,
# ceremony, in an order chosen to interleave them, with the invariant asserted
# after EVERY step rather than at the end. A sequence that ends correct after
# passing through a wrong state would pass an end-state check and still have lost
# an operator's entry along the way.
#
# The starting registry has no leftover pre-manifest entry, which is deliberate:
# that case is not idempotent by design (the host cannot purge what it cannot
# recognise) and is covered separately by FR-028.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/conformance/install-harness.sh"
  harness_require || skip "${HARNESS_SKIP_REASON}"
  REPO="$(harness_new_repo)"
  EVENTS=(before_specify after_specify after_clarify after_plan after_tasks after_implement after_analyze)
}

teardown() {
  [[ -n "${REPO:-}" ]] && harness_cleanup "${REPO}"
}

# assert_invariant <step> — at most one jira entry per event, none ever lost, and
# the foreign entry still present.
assert_invariant() {
  local step="$1" e n
  for e in "${EVENTS[@]}"; do
    n="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira"' | wc -l | tr -d ' ')"
    [ "${n}" -le 1 ] || {
      printf 'after step %s: event %s has %s jira entries\n' "${step}" "${e}" "${n}" >&2
      return 1
    }
  done
  # The foreign entry is never collateral damage.
  local foreign
  foreign="$(harness_entries_for "${REPO}" after_plan | awk -F'\t' '$1 == "git"' | wc -l | tr -d ' ')"
  [ "${foreign}" -eq 1 ] || {
    printf 'after step %s: the foreign entry is gone\n' "${step}" >&2
    return 1
  }
}

# run_ceremony — the configuration ceremony, against the installed extension.
# It is degraded (no credentials), which is the state it runs in most often and
# the one in which it still reads and reports the registry.
run_ceremony() {
  (
    cd "${REPO}" || exit 1
    unset SPEC_KIT_JIRA_BASE_URL
    ./.specify/extensions/jira/scripts/bash/spec-kit-jira.sh config --json > /dev/null 2>&1 || true
  )
}

@test "ten mixed install / reinstall / ceremony operations keep the invariant (SC-004)" {
  harness_seed_registry "${REPO}" 'hooks:
  after_plan:
    - extension: git
      command: speckit.git.commit
      enabled: true
      optional: true
      priority: 10
      prompt: Execute speckit.git.commit?
      description: Commit the plan.
      condition: null'

  harness_install "${REPO}";        assert_invariant "1 install"
  run_ceremony;                     assert_invariant "2 ceremony"
  harness_install "${REPO}" --force; assert_invariant "3 reinstall"
  harness_install "${REPO}" --force; assert_invariant "4 reinstall"
  run_ceremony;                     assert_invariant "5 ceremony"
  run_ceremony;                     assert_invariant "6 ceremony"
  harness_install "${REPO}" --force; assert_invariant "7 reinstall"
  run_ceremony;                     assert_invariant "8 ceremony"
  harness_install "${REPO}" --force; assert_invariant "9 reinstall"
  run_ceremony;                     assert_invariant "10 ceremony"

  # And at the end every event is genuinely there — "at most one" must not have
  # been satisfied by having none.
  local e n
  for e in "${EVENTS[@]}"; do
    n="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira"' | wc -l | tr -d ' ')"
    [ "${n}" -eq 1 ]
  done
}

@test "the ceremony never changes the registry between two installs (FR-023, SC-007)" {
  harness_install "${REPO}"
  local before after
  before="$(harness_registry_checksum "${REPO}")"
  run_ceremony
  run_ceremony
  after="$(harness_registry_checksum "${REPO}")"
  [ "${before}" = "${after}" ]
}
