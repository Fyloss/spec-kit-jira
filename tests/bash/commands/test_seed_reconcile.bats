#!/usr/bin/env bats
# T094/T095 [027, US3] — SC-002: after seeding and binding, the NEXT FULL
# reconcile creates exactly the unpinned user stories (drafted minus pinned)
# under the already-adopted parent — and creates NOTHING for the parent,
# which is already bound. This is a verification, not new production code:
# reconcile.sh already creates-under-parent for any bound specification,
# seeded or not; SC-002 is reconcile's ordinary behaviour reached through
# the seed path, so this test proves the composition, not a new mechanism.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="2222222222222222"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

@test "SC-002: after seed-binding a parent and one story, the next reconcile creates exactly the remaining unpinned story, under the adopted parent" {
  # Post-seed state, constructed directly (seed.sh's own binding mechanics
  # are T081-T091's job): a bound parent, a bound story, and one UNPINNED
  # user story the operator drafted alongside the named ones (FR-018).
  printf '%s\n' \
    '# Feature' \
    '' \
    '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->' \
    '' \
    'Body one.' \
    '' \
    '### User Story 2 - A brand new story the operator added (Priority: P1)' \
    '' \
    'Body two, no marker at all.' \
    > "${SPEC}"

  local cfg
  cfg="$(mock_write_config '{"projects":{"COMP":"company"},"issues":{"COMP-1":{"summary":"Billing invoices","issuetype":{"name":"Epic"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"parent","repo":"acme/app","spec_slug":"001-billing-invoices"}}},"COMP-11":{"summary":"Accept a partial payment","issuetype":{"name":"Story"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"story","story":"3333333333333333","repo":"acme/app","spec_slug":"001-billing-invoices"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 1 ]

  # The parent is NOT recreated (a PUT update, not a POST create): exactly
  # ONE create POST happens in this run, and it is the new story's.
  [ "$(mock_calls | grep -c '^POST /rest/api/3/issue$')" -eq 1 ]
  [ "$(mock_calls | grep -c '^PUT /rest/api/3/issue/COMP-1$')" -eq 1 ]

  # The new story now carries a bound marker.
  grep -qE '<!-- speckit-jira story=[0-9a-f]{16} ticket=COMP-[0-9]+ -->' <(grep -A1 'brand new story' "${SPEC}")
}
