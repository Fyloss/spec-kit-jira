#!/usr/bin/env bats
# T041-T042 [Phase 5, US3] — recognition depends on nothing machine-local: no
# state file, no cache directory, and a renamed specification folder still
# recognises its tickets and creates none.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "recognition succeeds with no local run history at all — no state file, empty HOME" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  # A run from a completely empty $HOME and no XDG cache/state dirs: nothing
  # this feature reads or writes lives outside spec.md and the Jira API.
  local emptyhome="${BATS_TEST_TMPDIR}/empty-home"
  mkdir -p "${emptyhome}"
  : > "${MOCK_CALLLOG}"
  HOME="${emptyhome}" XDG_CACHE_HOME="${emptyhome}/.cache" XDG_STATE_HOME="${emptyhome}/.state" \
    run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 3 ]
  [ ! -d "${emptyhome}/.cache" ]
  [ ! -d "${emptyhome}/.state" ]
}

@test "a renamed specification folder still recognises its STORY tickets and creates none" {
  # This proves story recognition's rename tolerance (its durable `story`
  # identifier, decoupled from spec_slug) — not the parent's, which the
  # contract deliberately keeps slug-sensitive (contracts/
  # hierarchy-resolution.md §7, "different repo or spec_slug -> blocked");
  # that is covered on its own in test_recognition_parent.bats. A caller
  # that renames a spec folder mid-lifecycle keeps SPEC_KIT_JIRA_SPEC_SLUG
  # stable across the rename in practice, which this test mirrors.
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  mv "${work}/specs/001-billing-invoices" "${work}/specs/001-billing-invoices-renamed"
  local renamed_spec="${work}/specs/001-billing-invoices-renamed/spec.md"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${renamed_spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 3 ]
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "recognition is scoped to the routed project: two specs mirrored into different projects never recognise each other's tickets" {
  mock_start "${ROOT}/tests/conformance/mock-jira/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Reuse the SAME durable identifier (via SPEC_KIT_JIRA_ID_SOURCE) across
  # two DIFFERENT specifications, mirrored into two DIFFERENT projects.
  # Recognition must never let one spec's marker satisfy the other's.
  mkdir -p "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
  local specA="${BATS_TEST_TMPDIR}/a/spec.md" specB="${BATS_TEST_TMPDIR}/b/spec.md"
  printf '%s\n' '### User Story 1 - Alpha (Priority: P1)' '<!-- speckit-jira story=1111111111111111 ticket=OTHER-1 -->' '' 'Alpha body.' > "${specA}"
  printf '%s\n' '### User Story 1 - Beta (Priority: P1)' '<!-- speckit-jira story=1111111111111111 ticket=COMP-9 -->' '' 'Beta body.' > "${specB}"

  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"OTHER-1"}}]'
  local specRefB='{"repo":"acme/app","spec_slug":"002-beta","folder":"x"}'
  run recognition_run "${stories}" "${specRefB}" "COMP" "${specB}"
  [ "$status" -eq 0 ]
  # OTHER-1 does not belong to the routed COMP project: mirrored as new,
  # the former ticket left untouched (US3 re-routed case, FR-019).
  [ "$(jq -r '.new[0]' <<< "$output")" = "1111111111111111" ]
}

@test "re-routed: the catalogued notice names the story, the former key and project, and the new key (T071)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"

  printf '%s\n' \
    '# Feature Specification: Billing Invoices' '' \
    '### User Story 1 - Export a single invoice (Priority: P1)' \
    '<!-- speckit-jira story=1111111111111111 ticket=LEGACY-42 -->' '' \
    'As a customer, I want to export one invoice as a PDF.' '' \
    '- **Given** a signed-in customer viewing an invoice' \
    '- **When** they choose Export' \
    '- **Then** a PDF download starts' > "${spec}"

  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]

  local note; note="$(jq -r '.notes[0] // ""' <<< "$output")"
  [[ "${note}" == *"1111111111111111"* ]]
  [[ "${note}" == *"LEGACY-42"* ]]
  [[ "${note}" == *"in project LEGACY"* ]]
  [[ "${note}" == *"mirrored into COMP as COMP-2"* ]]

  # the recorded marker now names the new ticket; the former one is left
  # untouched — no write was ever issued to it. COMP-1 is the parent
  # (Phase 5, US2), created first.
  grep -q 'ticket=COMP-2' "${spec}"
  ! grep -q 'ticket=LEGACY-42' "${spec}"
  [ "$(grep -c 'LEGACY-42' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "a story whose recorded ticket lives outside the routed project is mirrored into the routed project, not blocked" {
  mock_start "${ROOT}/tests/conformance/mock-jira/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"LEGACY-42"}}]'
  local specRef='{"repo":"acme/app","spec_slug":"001-billing","folder":"x"}'
  run recognition_run "${stories}" "${specRef}" "COMP" "spec.md"
  [ "$status" -eq 0 ]
  [ "$(jq '.blocked | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.new[0]' <<< "$output")" = "1111111111111111" ]
}
