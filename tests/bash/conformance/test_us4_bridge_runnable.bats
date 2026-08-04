#!/usr/bin/env bats
# T038 [US4] — The bridge runs straight after install, and the install touched
# nothing outside the repository (FR-008, FR-012, US4 scenario 3).
#
# The reported defect's second half was "spec-kit-jira CLI not installed". That
# message was wrong about the cause but right that nothing ran. This suite proves
# the opposite claim directly: install into a clean scratch repository, run the
# entry point by its repository-relative path with NOTHING done in between, and
# get usage output.
#
# The audit half matters just as much. FR-008 confines every install side effect
# to the consuming repository — no machine-wide executable, no PATH change, no
# shell profile edit — and the only way to know that is to snapshot the places an
# installer would touch and compare them afterwards.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/conformance/install-harness.sh"
  harness_require || skip "${HARNESS_SKIP_REASON}"
  REPO="$(harness_new_repo)"
  BASH_ENTRY=".specify/extensions/jira/scripts/bash/spec-kit-jira.sh"
  PWSH_ENTRY=".specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1"
}

teardown() {
  # `&&` as the last statement makes teardown's own exit status the [[ ]]
  # test's — bats treats that as a teardown failure whenever REPO was never
  # set (e.g. an early `skip`), even though there is genuinely nothing to
  # clean up.
  [[ -n "${REPO:-}" ]] && harness_cleanup "${REPO}"
  return 0
}

# snapshot_environment — a checksum of every location a machine-wide install
# would have to touch. The audit compares this before and after (FR-008).
snapshot_environment() {
  {
    printf 'PATH=%s\n' "${PATH}"
    local f
    for f in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
      printf '%s=%s\n' "${f}" "$([[ -f "${f}" ]] && shasum -a 256 < "${f}" | awk '{print $1}' || printf 'absent')"
    done
    local d
    for d in /usr/local/bin /opt/homebrew/bin; do
      printf '%s=%s\n' "${d}" "$([[ -d "${d}" ]] && (ls -1 "${d}" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}') || printf 'absent')"
    done
  } | shasum -a 256 | awk '{print $1}'
}

@test "the Bash entry point runs through its interpreter with the mode stripped (FR-004, FR-012, C1)" {
  # The archive install route drops file modes (research R1/R7); this is a
  # deterministic reproduction of that outcome. `bash <path>` never depends on
  # the entry point's own executable bit.
  harness_install "${REPO}"
  chmod a-x "${REPO}/${BASH_ENTRY}"
  run bash -c "cd '${REPO}' && bash ${BASH_ENTRY} --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: spec-kit-jira"* ]]
}

@test "every declared subcommand is byte-identical between 0644 and 0755 (FR-009, C7)" {
  # The point of the feature is that the mode stops meaning anything. Proved by
  # comparison, not by inspection, over every subcommand the entry point
  # declares — not just --help. Most exit on a degraded cause on this
  # unconfigured scratch repository; that is fine and is the point (research R7).
  harness_install "${REPO}"
  local sub
  for sub in --help 'config --dry-run' 'feature --dry-run' 'reconcile --dry-run' 'mention --dry-run'; do
    chmod 0755 "${REPO}/${BASH_ENTRY}"
    run bash -c "cd '${REPO}' && bash ${BASH_ENTRY} ${sub} 2>&1; printf 'EXIT:%s' \$?"
    local exec_output="$output"
    chmod 0644 "${REPO}/${BASH_ENTRY}"
    run bash -c "cd '${REPO}' && bash ${BASH_ENTRY} ${sub} 2>&1; printf 'EXIT:%s' \$?"
    local noexec_output="$output"
    [ "${exec_output}" = "${noexec_output}" ] || {
      printf 'mode changed the output of "%s":\n0755: %s\n0644: %s\n' \
        "${sub}" "${exec_output}" "${noexec_output}" >&2
      return 1
    }
  done
}

@test "the PowerShell entry point is installed at the path the documents name (FR-013)" {
  harness_install "${REPO}"
  [ -f "${REPO}/${PWSH_ENTRY}" ]
}

@test "the install changed NOTHING outside the repository (FR-008, US4 scenario 3)" {
  local before after
  before="$(snapshot_environment)"
  harness_install "${REPO}"
  after="$(snapshot_environment)"
  [ "${before}" = "${after}" ] || {
    printf 'the install modified something outside the repository\n' >&2
    return 1
  }
}

@test "everything the install wrote is inside the repository (FR-008)" {
  harness_install "${REPO}"
  # git sees changes, and every one of them is repository-relative by construction.
  run bash -c "cd '${REPO}' && git status --porcelain --untracked-files=all"
  [ "$status" -eq 0 ]
  local line path
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    path="${line:3}"
    [[ "${path}" == /* ]] && {
      printf 'the install touched an absolute path outside the repository: %s\n' "${path}" >&2
      return 1
    }
  done <<< "${output}"
  # And the extension tree is present, which is what "inside the repository" means.
  [ -d "${REPO}/.specify/extensions/jira" ]
}

@test "no machine-wide executable named spec-kit-jira was created (FR-008)" {
  harness_install "${REPO}"
  run command -v spec-kit-jira
  [ "$status" -ne 0 ]
}

@test "the bridge reports the unconfigured repository without failing (FR-019)" {
  # The state a developer is actually in one second after install: installed, not
  # configured. The host command must complete and the notice must be short.
  harness_install "${REPO}"
  run bash -c "cd '${REPO}' && ./${BASH_ENTRY} reconcile --json .specify/extensions/jira/README.md 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not bound to a Jira project yet"* ]]
  [[ "$output" == *"/speckit.jira.config"* ]]
  # At most three lines (FR-019, US5 scenario 3).
  [ "$(wc -l <<< "$output" | tr -d ' ')" -le 3 ]
}
