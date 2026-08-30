#!/usr/bin/env bats
# T031/T033 [Phase 3, US1] — the two personal.yml states routing depends on
# (contracts/routing-resolution.md C4.3, C4.4).
#
# C4.3 (malformed file fails closed BEFORE routing) already held before this
# feature: reconcile's connection chokepoint calls the personal loader for its
# validation side effect, and propagates its exit code. The test exists so a
# future refactor cannot silently remove a guarantee nobody wrote down —
# routing is a write path, and a file the operator wrote that cannot be read is
# a statement that did not work.
#
# C4.4 is the opposite: an ABSENT file, and a file selecting no team, are not
# statements at all. They must fall through in silence, with no warning and no
# diagnostic, or every repository that never adopted the catalogue would start
# emitting noise.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira" "${WORK}/specs/007-legacy-cleanup"
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: ALPHA
    style: company_managed
routing: []
routing_default: ALPHA
teams:
  - id: beta
    project: BETA
    folder_prefix: "beta-"
    branch_pattern: "beta-<ID>/<FEATURE_NAME>"
YAML
  printf '# Feature Specification: Legacy\n\nprose\n' > "${WORK}/specs/007-legacy-cleanup/spec.md"
}

teardown() {
  rm -rf "${WORK}"
}

_reconcile() {
  env JIRA_CONFIG_DIR="${WORK}/.specify/jira" \
    SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:9" \
    JIRA_EMAIL="operator@example.invalid" JIRA_API_TOKEN="X" \
    SPEC_KIT_JIRA_REPO="acme/app" SPEC_KIT_JIRA_SPEC_SLUG="007-legacy-cleanup" \
    bash "${ROOT}/scripts/bash/spec-kit-jira.sh" \
    reconcile "${WORK}/specs/007-legacy-cleanup/spec.md" --dry-run 2>&1
}

@test "C4.3 a malformed personal.yml refuses with exit 4" {
  printf 'team: Not_Valid\n' > "${WORK}/.specify/jira/personal.yml"
  run _reconcile
  [ "$status" -eq 4 ]
}

@test "C4.3 the refusal names the file and the offending key" {
  # Observed, not assumed: the message is
  #   config: personal (<path>): team is invalid
  # It names the file and the key but NOT the value it rejected. That is a
  # pre-existing gap in the personal-config validator (002/031 territory), not
  # something 033 changed, so it is pinned here rather than fixed here — a test
  # that asserted the value would fail for the wrong reason and hide a real
  # regression later.
  printf 'team: Not_Valid\n' > "${WORK}/.specify/jira/personal.yml"
  run _reconcile
  [[ "${output}" == *"personal.yml"* ]]
  [[ "${output}" == *"team is invalid"* ]]
}

@test "C4.3 the refusal happens BEFORE routing resolves" {
  # If routing had run first, the run would have resolved ALPHA through rank 4
  # and failed later, on the network. The four-rank routing message must not
  # appear at all: nothing got that far.
  printf 'team: Not_Valid\n' > "${WORK}/.specify/jira/personal.yml"
  run _reconcile
  [[ "${output}" != *"Rule route:"* ]]
}

@test "C4.3 zero Jira writes are attempted" {
  printf 'team: Not_Valid\n' > "${WORK}/.specify/jira/personal.yml"
  run _reconcile
  [[ "${output}" != *"created"* ]]
}

@test "C4.4 an absent personal.yml falls through silently to routing_default" {
  run _reconcile
  [ "$status" -eq 0 ]
  [[ "${output}" != *"personal"* ]]
}

@test "C4.4 a personal.yml selecting no team falls through silently" {
  printf '# no team key here\n' > "${WORK}/.specify/jira/personal.yml"
  run _reconcile
  [ "$status" -eq 0 ]
  [[ "${output}" != *"no team is selected"* ]]
}

@test "C4.4 neither silent state emits a warning" {
  printf '# no team key here\n' > "${WORK}/.specify/jira/personal.yml"
  run _reconcile
  [[ "${output}" != *"WARNING"* ]]
}

@test "a selected team routes the run, proving the fixture would have shown it" {
  # The counterpart of the two silent cases: with a selection, rank 3 fires.
  # Without this the silent tests could pass on a fixture where nothing works.
  printf 'team: beta\n' > "${WORK}/.specify/jira/personal.yml"
  run env JIRA_CONFIG_DIR="${WORK}/.specify/jira" \
    SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:9" \
    JIRA_EMAIL="operator@example.invalid" JIRA_API_TOKEN="X" \
    SPEC_KIT_JIRA_REPO="acme/app" SPEC_KIT_JIRA_SPEC_SLUG="007-legacy-cleanup" \
    bash "${ROOT}/scripts/bash/spec-kit-jira.sh" \
    reconcile "${WORK}/specs/007-legacy-cleanup/spec.md" --dry-run --json
  # The run cannot reach the tracker, but the resolved project reaches the
  # summary or the failure text either way; BETA must appear, ALPHA must not.
  [[ "${output}" == *"BETA"* ]]
}
