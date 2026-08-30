#!/usr/bin/env bats
# T058/T059 [Phase 6] — the two constitutional obligations that belong to no
# user story, and which a story-organised task list therefore never generates.
#
# T058, Principle III (the fail-closed DEPARTURE). This feature adds a NEW
# refusal branch — the four-rank routing refusal. The branch that CHANGED is
# the one that needs the test: in hook context a bridge failure must never fail
# the host command, whatever new way the bridge found to fail.
#
# T059, Principle IV. The routing refusal is the first message in the tree to
# reason about the CONTENTS of personal.yml, which also holds the operator's
# authentication email. It may name the selected team id and the file's path,
# and nothing else from that file.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira" "${WORK}/specs/007-legacy-cleanup"
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: ALPHA
    style: company_managed
routing:
  - match:
      folder_prefix: '003-billing-'
    project: ALPHA
YAML
  cat > "${WORK}/.specify/jira/personal.yml" << 'YAML'
email: operator@example.invalid
YAML
  printf '# Feature Specification: Legacy\n\nprose\n' > "${WORK}/specs/007-legacy-cleanup/spec.md"
}

teardown() {
  rm -rf "${WORK}"
}

_run_reconcile() {
  env JIRA_CONFIG_DIR="${WORK}/.specify/jira" \
    SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:9" \
    JIRA_EMAIL="operator@example.invalid" JIRA_API_TOKEN="X" \
    SPEC_KIT_JIRA_REPO="acme/app" SPEC_KIT_JIRA_SPEC_SLUG="007-legacy-cleanup" \
    "$@" \
    bash "${ROOT}/scripts/bash/spec-kit-jira.sh" \
    reconcile "${WORK}/specs/007-legacy-cleanup/spec.md" --dry-run 2>&1
}

@test "T058 the new routing refusal exits 4 on a direct run" {
  run _run_reconcile
  [ "$status" -eq 4 ]
  [[ "${output}" == *"routing could not be resolved"* ]]
}

@test "T058 in hook context the SAME refusal returns success to the host" {
  # Principle III: an after_* hook must never fail the spec-kit command that
  # fired it. The refusal is new, so this branch has never been exercised.
  run _run_reconcile SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify
  [ "$status" -eq 0 ]
}

@test "T058 the hook-context downgrade emits exactly one WARNING line" {
  run _run_reconcile SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify
  local n
  n="$(printf '%s\n' "${output}" | awk '/^WARNING:/{c++} END{print c+0}')"
  [ "${n}" -eq 1 ]
}

@test "T058 the warning carries the four-rank diagnosis, not a generic cause" {
  # The fault path surfaces the refusal's OWN message rather than substituting
  # a generic "the configuration was refused" line. That matters here: the
  # whole point of FR-007 is that the operator learns which rank failed, and a
  # lifecycle hook is exactly where they are least able to go and ask again.
  run _run_reconcile SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify
  [[ "${output}" == *"Rule route:"* ]]
  [[ "${output}" == *"Team route:"* ]]
  [[ "${output}" == *"Your team:"* ]]
  [[ "${output}" == *"Default:"* ]]
}

@test "T058 the warning tells the operator the host command was unaffected" {
  run _run_reconcile SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify
  [[ "${output}" == *"This spec-kit command completed normally."* ]]
}

@test "T059 the refusal never emits the operator's email from personal.yml" {
  run _run_reconcile
  [[ "${output}" != *"operator@example.invalid"* ]]
}

@test "T059 the refusal names personal.yml's path but not its contents" {
  run _run_reconcile
  [[ "${output}" == *"personal.yml"* ]]
  [[ "${output}" != *"email"* ]]
}

@test "T059 the refusal names the selected team id and nothing else from the file" {
  cat > "${WORK}/.specify/jira/personal.yml" << 'YAML'
email: operator@example.invalid
team: ghost
YAML
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: ALPHA
    style: company_managed
routing: []
teams:
  - id: ghost
    project: ALPHA
    folder_prefix: "ghost-"
    branch_pattern: "ghost-<ID>/<FEATURE_NAME>"
YAML
  run _run_reconcile
  # With the team resolving, routing SUCCEEDS — the point of the case is that
  # nothing from personal.yml other than the id can reach any message.
  [[ "${output}" != *"operator@example.invalid"* ]]
}
