#!/usr/bin/env bats
# T052 [Phase 6, US4] — the one-time upgrade of a pre-release estate onto the
# boundary (FR-020/FR-020a/FR-020b/FR-021): an untouched ticket migrates
# cleanly, a human-prefixed one keeps its prefix exactly, an ambiguous one
# loses nothing and warns by ticket key, and the run after each settles to
# zero writes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-pre-release-migration"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_ID_SOURCE

  mock_start "${MOCK}/configs/preserve-pre-release.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

@test "an untouched pre-release story migrates with nothing above the boundary and no duplication (FR-020a)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local pre1; pre1="$(jq -c '.actions[] | select(.url | endswith("PRE-1"))' <<< "$output")"
  [ -n "${pre1}" ]
  # The marker paragraph is the FIRST node: nothing sits above the boundary.
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre1}")" = "Synced from spec-kit — do not edit below this line" ]
  # The story's own line appears exactly once in the payload.
  [ "$(jq -r '[.body.fields.description.content[].content[].text? // empty] | map(select(. == "As a user, I want my note kept.")) | length' <<< "${pre1}")" -eq 1 ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-1"))) | length' <<< "$output")" -eq 0 ]
}

@test "a human-prefixed pre-release story keeps its prefix exactly (FR-020a)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local pre2; pre2="$(jq -c '.actions[] | select(.url | endswith("PRE-2"))' <<< "$output")"
  [ -n "${pre2}" ]
  # The human paragraph is preserved verbatim, above the boundary.
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre2}")" = "A human paragraph added after the mirror last wrote." ]
  [ "$(jq -r '.body.fields.description.content[1].content[0].text' <<< "${pre2}")" = "Synced from spec-kit — do not edit below this line" ]
  # The story's own line appears exactly once — no duplication.
  [ "$(jq -r '[.body.fields.description.content[].content[].text? // empty] | map(select(. == "As a user, I want my note kept.")) | length' <<< "${pre2}")" -eq 1 ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-2"))) | length' <<< "$output")" -eq 0 ]
}

@test "an ambiguous pre-release story loses nothing and produces one warning naming the ticket key (FR-020b)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local pre3; pre3="$(jq -c '.actions[] | select(.url | endswith("PRE-3"))' <<< "$output")"
  [ -n "${pre3}" ]
  # The whole prior description is preserved above the boundary — nothing lost.
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre3}")" = "Some unrelated content nobody expected." ]
  [ "$(jq -r '.body.fields.description.content[1].content[0].text' <<< "${pre3}")" = "Synced from spec-kit — do not edit below this line" ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-3"))) | length' <<< "$output")" -eq 1 ]
}

@test "the run after each migration reports zero writes (FR-021)" {
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 0 ]
}
