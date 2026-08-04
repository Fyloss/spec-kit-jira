#!/usr/bin/env bats
# T047 [US2] — recording an identifier into tasks.md changes only the
# inserted marker lines; every other byte, and every line ending, is
# unchanged (FR-014). Run against both the LF and CRLF fixtures.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-task-tier"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"
  TASKS="${WORK}/specs/001-feature/tasks.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  local cfg; cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

@test "LF fixture: every byte outside the inserted marker lines is preserved, and no CR is introduced" {
  local before; before="$(cat "${TASKS}")"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  local after; after="$(cat "${TASKS}")"
  # The two original task lines survive verbatim.
  [[ "${after}" == *"- [ ] T001 Do the setup work"* ]]
  [[ "${after}" == *"- [ ] T002 [US1] Implement the first story's feature"* ]]
  # Only marker lines were inserted — every other line of the original
  # content still appears, in order, once each.
  local before_non_blank after_non_blank
  before_non_blank="$(grep -vc '^$' <<< "${before}")"
  after_non_blank="$(grep -Evc '^$|speckit-jira task=' <<< "${after}")"
  [ "${before_non_blank}" -eq "${after_non_blank}" ]
  # No line in the (LF) fixture gained a trailing CR.
  ! grep -qU $'\r' "${TASKS}"
}

@test "CRLF fixture: the host's dominant CRLF line ending is respected for every inserted marker line" {
  # Convert the fixture to CRLF in place — the same content, a different
  # dominant line ending, exactly as marker_splice.sh's CRLF detection reads.
  local tmp="${BATS_TEST_TMPDIR}/crlf.md"
  sed 's/$/\r/' "${TASKS}" > "${tmp}"
  mv "${tmp}" "${TASKS}"
  local before; before="$(cat "${TASKS}")"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  local after; after="$(cat "${TASKS}")"
  [[ "${after}" == *$'- [ ] T001 Do the setup work\r'* ]]
  [[ "${after}" == *"- [ ] T002 [US1] Implement the first story's feature"$'\r'* ]]
  # Every line in the rewritten file, including the newly-inserted marker
  # lines, ends in CRLF — none was left as a bare LF.
  local total_lines crlf_lines
  total_lines="$(grep -c '' "${TASKS}")"
  crlf_lines="$(grep -cU $'\r$' "${TASKS}")"
  [ "${total_lines}" -eq "${crlf_lines}" ]
}
