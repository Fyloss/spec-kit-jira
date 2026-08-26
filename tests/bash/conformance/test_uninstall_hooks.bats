#!/usr/bin/env bats
# T077 — Uninstall leaves no jira entry and no foreign entry damaged
# (spec.md Edge Cases § Uninstall).
#
# Registration moved to the manifest, so DEregistration moved with it: the host
# purges every entry whose `extension` equals our id when the extension is
# removed. That is only true for entries carrying the ownership field — which is
# the same asymmetry that makes a pre-manifest leftover undeletable (FR-028), so
# this suite checks both halves of it.
#
# It matters because an orphaned entry after uninstall is worse than a missing
# one: the agent would keep trying to dispatch a command that is no longer
# installed, on every lifecycle step, in a repository whose owner has explicitly
# removed the extension.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/conformance/install-harness.sh"
  harness_require || skip "${HARNESS_SKIP_REASON}"
  REPO="$(harness_new_repo)"
  EVENTS=(before_specify after_specify after_clarify after_plan after_tasks after_implement after_analyze)
}

teardown() {
  # `&&` as the last statement makes teardown's own exit status the [[ ]]
  # test's — bats treats that as a teardown failure whenever REPO was never
  # set (e.g. an early `skip`), even though there is genuinely nothing to
  # clean up.
  [[ -n "${REPO:-}" ]] && harness_cleanup "${REPO}"
  return 0
}

@test "after removal, zero jira-owned entries remain" {
  harness_install "${REPO}"
  harness_uninstall "${REPO}"
  local e n
  for e in "${EVENTS[@]}"; do
    n="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira"' | wc -l | tr -d ' ')"
    [ "${n}" -eq 0 ] || {
      printf 'event %s still carries %s jira entries after uninstall\n' "${e}" "${n}" >&2
      return 1
    }
  done
}

@test "every foreign entry is byte-identical after removal (FR-006)" {
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
  harness_install "${REPO}"
  local before
  before="$(harness_entries_for "${REPO}" after_plan | awk -F'\t' '$1 == "git"')"
  harness_uninstall "${REPO}"
  local after
  after="$(harness_entries_for "${REPO}" after_plan | awk -F'\t' '$1 == "git"')"
  [ "${before}" = "${after}" ]
  [ -n "${after}" ]
}

@test "the extension tree is gone, so nothing could run even if an entry survived" {
  harness_install "${REPO}"
  [ -d "${REPO}/.specify/extensions/jira-mirror" ]
  harness_uninstall "${REPO}"
  [ ! -d "${REPO}/.specify/extensions/jira-mirror" ]
}

@test "a reinstall after removal registers the seven events again (FR-005)" {
  # Removal must not leave the repository in a state the install cannot recover.
  harness_install "${REPO}"
  harness_uninstall "${REPO}"
  harness_install "${REPO}"
  local e n
  for e in "${EVENTS[@]}"; do
    n="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira"' | wc -l | tr -d ' ')"
    [ "${n}" -eq 1 ]
  done
}
