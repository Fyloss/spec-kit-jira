#!/usr/bin/env bats
# T078 — Installing into a directory that is not a spec-kit project
# (spec.md Edge Cases).
#
# The failure this guards is a stray file. If the install (or anything of ours)
# created `.specify/extensions.yml` in a directory with no spec-kit structure, the
# operator would be left with a hook registry for a workflow that does not exist
# there — and, worse, a plausible-looking one, since a registry is exactly what a
# healthy repository has.
#
# The rule is the same one FR-022 states from the other side: this extension does
# not bring that file into existence, anywhere, ever. Whether the host install
# refuses or proceeds is the host's business; what is ours is that no stray
# registry appears because of us.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/conformance/install-harness.sh"
  harness_require || skip "${HARNESS_SKIP_REASON}"
  # A plain directory: git-initialised, but with no `specify init` run in it.
  BARE="$(mktemp -d)"
  git -C "${BARE}" init -q .
}

teardown() {
  [[ -n "${BARE:-}" ]] && rm -rf "${BARE}"
}

@test "installing into a non-spec-kit directory reports the missing structure" {
  run bash -c "cd '${BARE}' && specify extension add --dev '${ROOT}' 2>&1"
  # The install does not silently succeed against a directory with no spec-kit
  # structure — whatever it says, it must not pretend the extension is wired up.
  [ "$status" -ne 0 ] || [[ "$output" == *".specify"* ]]
}

@test "no stray hook registry is created (FR-022, Edge Cases)" {
  bash -c "cd '${BARE}' && specify extension add --dev '${ROOT}'" > /dev/null 2>&1 || true
  [ ! -f "${BARE}/.specify/extensions.yml" ]
}

@test "running the bridge from a non-spec-kit directory creates no registry either" {
  # The other way in: the operator copies the extension by hand and runs it.
  # Nothing about that path may bring the registry into existence.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"
  local spec="${BARE}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Stray' '' 'A spec.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' > "${spec}"
  (
    cd "${BARE}" || exit 1
    unset SPEC_KIT_JIRA_BASE_URL
    unset SPEC_KIT_JIRA_EXTENSIONS_YML
    cmd_reconcile reconcile --json "${spec}" > /dev/null 2>&1 || true
  )
  [ ! -f "${BARE}/.specify/extensions.yml" ]
}
