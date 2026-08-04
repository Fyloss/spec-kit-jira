#!/usr/bin/env bats
# 015 T026 [US3] — `counts.created` reports confirmed creations, never
# planned ones (contract §5, data-model.md §6, research R4). A dedicated
# file, not test_reconcile_field_defaults.bats (US2's) — this is what keeps
# US3 genuinely parallel with US1/US2.

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
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${WORK}"
  SPEC="${WORK}/specs/001-reporting/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

_record_both_fields() {
  cmd_config config PM --issue-type "PM=story=Story" \
    --field-default 'PM=Deliverable=Business Owner=Platform Team' \
    --field-default 'PM=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
}

@test "a fully successful run: counts.created is the confirmed count (unchanged from before this feature, FR-013)" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
}

@test "every planned creation refused: counts.created is zero, alongside the fail-closed status and the refusal warning" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  mock_stop

  local cfg
  cfg="$(mktemp)"
  printf '%s' '{"projects":{"PM":"company"},"createmetaFields":{"10101":"parent-mandatory"},"faults":{"PM":{"status":400}}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 2 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
}

@test "counts.created is derived from the apply outcome, not recomputed from the planned action set (FR-013)" {
  # The mock's fault is project-keyed (research R4/T032) and cannot fault the
  # story's create without also faulting the parent's — both target the same
  # project in one reconcile run. The "parent created, story refused" shape
  # is proven exhaustively at the plan_apply unit level
  # (test_plan_apply_outcome.bats, "story rejection"). What remains to prove
  # HERE, at the reconcile-command level, is the wiring: that counts.created
  # reads apply_writes_with_recognition's OWN outcome rather than the planned
  # count computed earlier from the action set — shadowing the apply
  # function with a canned single-entry outcome, against a plan that
  # actually creates two (parent + story), makes the two counts provably
  # different if the wiring were wrong.
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  apply_writes_with_recognition() {
    jq -cn '{created:[{key:"PM-1",role:"parent",local_id:"aaaaaaaaaaaaaaaa"}]}'
    return 0
  }

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 1 ]
}

@test "--dry-run still reports the planned count (FR-012)" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
  # Zero writes under --dry-run — the mock recorded no create calls.
  run mock_calls
  [[ "$output" != *"POST /rest/api/3/issue"* ]]
}
