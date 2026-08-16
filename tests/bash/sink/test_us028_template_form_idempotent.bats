#!/usr/bin/env bats
# 028, T017a [US3] — a story created from the template's own emphasised
# single-line Given/When/Then form, reconciled a second time against an
# unchanged specification, reports zero created and zero updated (FR-017,
# SC-007). The conformance corpus (us028-template-form-ac.json) proves the
# two ports AGREE on the re-run; this asserts the re-run wrote nothing.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-template-form-ac" "${WORK}"
  SPEC="${WORK}/specs/001-template-form/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-template-form"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

@test "028 FR-017/SC-007: a second reconcile over the unchanged template-form spec reports 0 created and 0 updated" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 5 ]

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
}
