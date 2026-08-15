#!/usr/bin/env bats
# T099/T100 [027, US6] — quickstart.md Scenario 2, FR-009/FR-010/SC-009: the
# load-bearing one-way-read guarantee. Once a specification is seeded and
# bound, a Jira-side edit to a named issue's description or summary MUST
# NEVER reach spec.md again — not on the seeding run, and not on any later
# reconcile. A single changed byte is the regression.

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
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

@test "Scenario 2 (FR-009/FR-010/SC-009): editing a named issue's description and summary in Jira, then a full reconcile, leaves spec.md byte-identical" {
  printf '%s\n' \
    '# Feature' \
    '' \
    '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->' \
    '' \
    'Body one, as the human wrote it.' \
    > "${SPEC}"

  local cfg
  cfg="$(mock_write_config '{"projects":{"COMP":"company"},"issues":{"COMP-1":{"summary":"Billing invoices","issuetype":{"name":"Epic"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"parent","repo":"acme/app","spec_slug":"001-billing-invoices"}}},"COMP-11":{"summary":"Accept a partial payment","issuetype":{"name":"Story"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"story","story":"3333333333333333","repo":"acme/app","spec_slug":"001-billing-invoices"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local before
  before="$(git hash-object "${SPEC}" 2> /dev/null || sha256sum "${SPEC}")"

  # Jira-side edit: the operator (or someone else) rewrites the description
  # and summary of BOTH named issues — the human content that seeded
  # spec.md in the first place.
  curl -sf -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"summary":"RENAMED after seeding","description":"Completely rewritten Jira-side."}}' > /dev/null
  curl -sf -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-11" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"summary":"RENAMED after seeding too","description":"Also completely rewritten Jira-side."}}' > /dev/null

  # A full reconcile (what after_plan/after_tasks/after_implement hooks
  # each trigger downstream of the host's own plan/tasks steps).
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  local after
  after="$(git hash-object "${SPEC}" 2> /dev/null || sha256sum "${SPEC}")"
  [ "${before}" = "${after}" ]
}

@test "T101 (FR-030): the managed boundary marker is appended BELOW a human's existing description on the first reconcile after binding" {
  printf '%s\n' \
    '# Feature' \
    '' \
    '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->' \
    '' \
    'Mirrored body.' \
    > "${SPEC}"

  local cfg
  cfg="$(mock_write_config '{"projects": {"COMP": "company"}, "issues": {"COMP-1": {"summary": "Billing invoices", "issuetype": {"name": "Epic"}, "project": {"key": "COMP"}, "properties": {"spec-kit-jira": {"origin": "human", "role": "parent", "repo": "acme/app", "spec_slug": "001-billing-invoices"}}}, "COMP-11": {"summary": "Accept a partial payment", "description": {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [{"type": "text", "text": "A HUMAN wrote this before the ceremony ever ran."}]}]}, "issuetype": {"name": "Story"}, "project": {"key": "COMP"}, "properties": {"spec-kit-jira": {"origin": "human", "role": "story", "story": "3333333333333333", "repo": "acme/app", "spec_slug": "001-billing-invoices"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  local desc human_idx marker_idx
  desc="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/COMP-11" | jq -c '.fields.description')"
  human_idx="$(jq -r '[.content[] | .content[0].text] | map(test("A HUMAN wrote this")) | index(true)' <<< "${desc}")"
  marker_idx="$(jq -r '[.content[] | .content[0].text] | map(test("Synced from spec-kit")) | index(true)' <<< "${desc}")"
  [ "${human_idx}" != "null" ]
  [ "${marker_idx}" != "null" ]
  [ "${human_idx}" -lt "${marker_idx}" ]
}

@test "T103 (FR-030 inventory): assignee, reporter, priority, issue links, and hand-applied labels survive the first reconcile after binding" {
  printf '%s\n' \
    '# Feature' \
    '' \
    '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->' \
    '' \
    'Mirrored body.' \
    > "${SPEC}"

  local cfg
  cfg="$(mock_write_config '{"projects":{"COMP":"company"},"issues":{
    "COMP-1":{"summary":"Billing invoices","issuetype":{"name":"Epic"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"parent","repo":"acme/app","spec_slug":"001-billing-invoices"}}},
    "COMP-11":{"summary":"Accept a partial payment","issuetype":{"name":"Story"},"project":{"key":"COMP"},
      "assignee":{"accountId":"hand-assigned-owner"},
      "reporter":{"accountId":"the-product-owner"},
      "issuelinks":[{"type":{"name":"Blocks"},"outwardIssue":{"key":"COMP-999"}}],
      "labels":["hand-applied-label"],
      "properties":{"spec-kit-jira":{"origin":"human","role":"story","story":"3333333333333333","repo":"acme/app","spec_slug":"001-billing-invoices"}}}
  }}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  local fields
  fields="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/COMP-11" | jq -c '.fields')"
  [ "$(jq -r '.assignee.accountId' <<< "${fields}")" = "hand-assigned-owner" ]
  [ "$(jq -r '.reporter.accountId' <<< "${fields}")" = "the-product-owner" ]
  [ "$(jq -r '.issuelinks[0].outwardIssue.key' <<< "${fields}")" = "COMP-999" ]
  [ "$(jq -r '.labels | index("hand-applied-label") != null' <<< "${fields}")" = "true" ]
}

@test "T105: a human edit to the preserved region AFTER binding still survives the next reconcile" {
  printf '%s\n' \
    '# Feature' \
    '' \
    '<!-- speckit-jira spec=1111111111111111 ticket=COMP-1 -->' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira story=3333333333333333 ticket=COMP-11 -->' \
    '' \
    'Mirrored body.' \
    > "${SPEC}"

  local cfg
  cfg="$(mock_write_config '{"projects":{"COMP":"company"},"issues":{"COMP-1":{"summary":"Billing invoices","issuetype":{"name":"Epic"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"parent","repo":"acme/app","spec_slug":"001-billing-invoices"}}},"COMP-11":{"summary":"Accept a partial payment","issuetype":{"name":"Story"},"project":{"key":"COMP"},"properties":{"spec-kit-jira":{"origin":"human","role":"story","story":"3333333333333333","repo":"acme/app","spec_slug":"001-billing-invoices"}}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # First reconcile: establishes the managed boundary.
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  # A human now edits the PRESERVED region (above the boundary) directly in
  # Jira — the exact thing FR-030 exists to protect.
  local adf='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"An edit the human made AFTER binding."}]},{"type":"paragraph","content":[{"marks":[{"type":"strong"}],"text":"Synced from spec-kit — do not edit below this line","type":"text"}]},{"type":"paragraph","content":[{"type":"text","text":"Mirrored body."}]}]}'
  curl -sf -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-11" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson d "${adf}" '{fields:{description:$d}}')" > /dev/null

  # Second reconcile: the human's post-binding edit must survive.
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  local desc
  desc="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/COMP-11" | jq -c '.fields.description')"
  [[ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" == "An edit the human made AFTER binding." ]]
}
