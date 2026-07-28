#!/usr/bin/env bats
# T016 [US1] — The official install alone registers the seven lifecycle events
# (FR-001, FR-005, FR-006, SC-001, SC-004).
#
# This is the regression test for the reported defect, and it is the only kind of
# test that can be: the claim is about what `specify extension add` writes, so
# nothing short of running it into a real scratch repository verifies it. Every
# other test in this repository asserts what our code does with a registry that
# already exists.
#
# It runs against the harness in tests/conformance/install-harness.sh and skips
# with a clear reason when the `specify` CLI is absent — the CLI is a developer
# tool, not a runtime dependency of this extension.

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

@test "a fresh install produces one jira entry per event, enabled (FR-001, SC-001)" {
  harness_install "${REPO}"
  local e lines
  for e in "${EVENTS[@]}"; do
    lines="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira"')"
    [ "$(wc -l <<< "${lines}" | tr -d ' ')" -eq 1 ] || {
      printf 'event %s has %s jira entries:\n%s\n' "${e}" "$(wc -l <<< "${lines}")" "${lines}" >&2
      return 1
    }
    # enabled: true, and non-optional so the agent PERFORMS rather than offers.
    [ "$(awk -F'\t' '{print $3}' <<< "${lines}")" = "true" ]
    [ "$(awk -F'\t' '{print $4}' <<< "${lines}")" = "false" ]
  done
}

@test "no configuration ceremony is needed for the hooks to be registered (SC-001)" {
  # The whole point: nothing but the install ran, and the registry is complete.
  harness_install "${REPO}"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/hooks/register_hooks.sh"
  local health
  health="$(register_hooks_health "$(harness_registry_path "${REPO}")")"
  [ "$(jq -r '.present | length' <<< "${health}")" -eq 7 ]
  [ "$(jq -r '.missing | length' <<< "${health}")" -eq 0 ]
}

@test "two further --force reinstalls produce no duplicates (FR-005, SC-004)" {
  harness_install "${REPO}"
  harness_install "${REPO}" --force
  harness_install "${REPO}" --force
  local e n
  for e in "${EVENTS[@]}"; do
    n="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira"' | wc -l | tr -d ' ')"
    [ "${n}" -eq 1 ] || {
      printf 'event %s has %s jira entries after two reinstalls\n' "${e}" "${n}" >&2
      return 1
    }
  done
}

@test "a pre-seeded foreign extension entry survives unchanged (FR-006)" {
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
  harness_install "${REPO}" --force

  # The foreign entry is still there, still enabled, still owned by `git`...
  local foreign
  foreign="$(harness_entries_for "${REPO}" after_plan | awk -F'\t' '$1 == "git"')"
  [ "$(wc -l <<< "${foreign}" | tr -d ' ')" -eq 1 ]
  [ "$(awk -F'\t' '{print $2}' <<< "${foreign}")" = "speckit.git.commit" ]
  [ "$(awk -F'\t' '{print $3}' <<< "${foreign}")" = "true" ]

  # ...and ours was added beside it, not instead of it.
  [ "$(harness_entries_for "${REPO}" after_plan | awk -F'\t' '$1 == "jira"' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the install strips nothing on reinstall (FR-005)" {
  harness_seed_registry "${REPO}" 'hooks:
  after_tasks:
    - extension: git
      command: speckit.git.commit
      enabled: true'
  harness_install "${REPO}"
  local before after
  before="$(harness_entries_for "${REPO}" after_tasks | LC_ALL=C sort)"
  harness_install "${REPO}" --force
  after="$(harness_entries_for "${REPO}" after_tasks | LC_ALL=C sort)"
  [ "${before}" = "${after}" ]
}

@test "every registered entry names a command the extension installs (FR-009, SC-002)" {
  # The other half of the reported defect, verified end to end: after the real
  # install, every command a hook entry names has a document in the installed tree.
  harness_install "${REPO}"
  local e cmd file
  for e in "${EVENTS[@]}"; do
    cmd="$(harness_entries_for "${REPO}" "${e}" | awk -F'\t' '$1 == "jira" {print $2}')"
    [ -n "${cmd}" ]
    file="${REPO}/.specify/extensions/jira/commands/${cmd}.md"
    [ -f "${file}" ] || {
      printf 'event %s names %s, which is not installed at %s\n' "${e}" "${cmd}" "${file}" >&2
      return 1
    }
  done
}
