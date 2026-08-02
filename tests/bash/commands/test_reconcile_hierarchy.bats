#!/usr/bin/env bats
# T009 [Phase 1, defect 1] — The regression test required by the repository's
# bug-fix policy: a three-story specification must mirror as one parent plus
# three children, each carrying the parent's key. Before this feature the
# neutral document's `epic` is never read by `plan_writes`, so the current
# run issues exactly three `POST /rest/api/3/issue` calls, no parent, and no
# `fields.parent` on any child (quickstart Step 1). This test asserts the
# TARGET behaviour and is therefore RED until Phase 5 (US2) lands.
#
# T023 [Phase 3, US4] extends this file with the retired-key hook-downgrade
# case. T095 [Phase 8] extends it with dry-run parity.

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
  # One extra id for the parent, ahead of the three story ids.
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222 3333333333333333"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "creates one parent and three children" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  run mock_calls
  posts="$(grep -c '^POST /rest/api/3/issue$' <<< "$output")"
  [ "$posts" -eq 4 ]
  puts="$(grep -c '^PUT /rest/api/3/issue/[^ ]*/properties/spec-kit-jira$' <<< "$output")"
  [ "$puts" -eq 4 ]

  # The parent is created first (COMP-1, the mock's per-project sequence).
  [ "$(mock_issue_field COMP-1 '.fields.parent')" = "null" ]

  # Every child names the parent.
  [ "$(mock_issue_field COMP-2 '.fields.parent.key')" = "COMP-1" ]
  [ "$(mock_issue_field COMP-3 '.fields.parent.key')" = "COMP-1" ]
  [ "$(mock_issue_field COMP-4 '.fields.parent.key')" = "COMP-1" ]
}

@test "T113: a specification with no User Story headings mirrors as one parent and one child" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  cat > "${SPEC}" << 'MD'
# Feature Specification: Billing Invoices

We need to let customers export invoices.
MD

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  run mock_calls
  posts="$(grep -c '^POST /rest/api/3/issue$' <<< "$output")"
  [ "$posts" -eq 2 ]

  # One parent (COMP-1) and its one implicit child (COMP-2), not a parent alone.
  [ "$(mock_issue_field COMP-1 '.fields.parent')" = "null" ]
  [ "$(mock_issue_field COMP-2 '.fields.parent.key')" = "COMP-1" ]
}

@test "the specification carries one spec= marker naming the parent, after the H1" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  run grep -c 'speckit-jira spec=[0-9a-f]\{16\} ticket=COMP-1 -->' "${SPEC}"
  [ "$output" -eq 1 ]
}

@test "T095: --dry-run predicts the parent's creation and every child's parent reference, with zero writes" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dry_run' <<< "$output")" = "true" ]
  [ "$(jq -r '.actions[0].role' <<< "$output")" = "parent" ]
  [ "$(jq -r '.actions[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.actions[0].body.fields.summary' <<< "$output")" = "Billing Invoices" ]
  [ "$(jq -r '[.actions[] | select(.role=="story")] | length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '[.actions[] | select(.role=="story")][0].body.fields.parent.key' <<< "$output")" = "<resolved at apply time>" ]

  run mock_calls
  [ -z "$output" ]
}

@test "T095: --dry-run predicts a recognised, unchanged parent's reuse — no parent action, matching the real zero-churn run" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dry_run' <<< "$output")" = "true" ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 3 ]

  run mock_calls
  posts="$(grep -c '^POST /rest/api/3/issue$' <<< "$output")"
  [ "$posts" -eq 4 ]
}

@test "T095: --dry-run predicts the mandatory-field refusal exactly as the real run — same exit code, same message, zero writes" {
  local work="${BATS_TEST_TMPDIR}/repo-mandatory-dry"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${work}"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${work}/specs/001-reporting/spec.md" --dry-run --json
  local dry_status="$status" dry_output="$output"
  [ "$dry_status" -eq 4 ]
  [[ "$dry_output" == *"Deliverable"* ]]
  [[ "$dry_output" == *"Business Owner"* ]]

  run cmd_reconcile reconcile "${work}/specs/001-reporting/spec.md" --json
  [ "$status" -eq "$dry_status" ]
  [ "$output" = "$dry_output" ]

  run mock_calls
  [ -z "$output" ]
}

@test "T023 [US4] — a retired-key config refuses direct exit 4; under a hook, one WARNING and exit 0" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  {
    printf 'projects:\n'
    printf '  - key: COMP\n'
    printf '    style: company_managed\n'
    printf '    epic_strategy: per_repo\n'
    printf 'routing_default: COMP\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"epic_strategy"* ]]

  export SPEC_KIT_JIRA_HOOK_CONTEXT="after_specify"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WARNING: ' <<< "$output")" -eq 1 ]
  [[ "$output" == *"epic_strategy"* ]]
}

# =============================================================================
# T047/T052 [Phase 6, US4] — §8 re-validation against the PERSISTED binding
# =============================================================================
#
# Every reconcile run above already exercises the FR-004 case implicitly: the
# fixture binding carries no `roles` key at all, and reconcile mirrors fine —
# an absent `roles` key stays non-fatal. These two tests cover the case a
# stale or hand-edited binding DOES carry `roles`, and check 4 (ordering) is
# re-run against them with no re-read of the project's metadata.

@test "T047/T052 — an inverted roles ordering in the persisted binding refuses at reconcile, reconcile: prefixed, zero writes" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Inject a `roles` block with specification BELOW story — impossible to
  # produce via the config ceremony (role_validate would refuse it first),
  # but representative of a hand-edited or pre-010 binding upgraded by hand.
  local localf="${JIRA_CONFIG_DIR}/config.local.yml"
  local injected
  injected="$(jq -cS '.resolved_ids.COMP.roles = {
      specification: {logical_name: "Story", id: "10004", hierarchy_level: "0", subtask: false, source: "declared"},
      story: {logical_name: "Epic", id: "10001", hierarchy_level: "1", subtask: false, source: "declared"}
    }' <<< "$(config_yaml_to_json "${localf}")")"
  printf '%s' "${injected}" | config_to_yaml > "${localf}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"reconcile: project COMP: specification names"* ]]
  [[ "$output" == *"is not above story"* ]]

  run mock_calls
  [ -z "$output" ]
}

# =============================================================================
# T080 [Phase 9] — reconcile over the declared-hierarchy fixture (010,
# contract §5, US1's independent test). This fixture existed since Phase 1
# (T005) but was referenced by no test until now (FR-022, FR-025, SC-007).
# =============================================================================

@test "T080 — reconcile mirrors into the DECLARED types: one parent (Epic), one child per story (Story), each naming the parent" {
  local work="${BATS_TEST_TMPDIR}/repo-declared-hierarchy"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-declared-hierarchy" "${work}"
  local spec="${work}/specs/001-consumer-onboarding/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-consumer-onboarding"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
  mock_start "${MOCK}/configs/consumer-hierarchy.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]

  # The parent is the declared specification type (Epic, id 10701).
  [ "$(mock_issue_field CONSUMER-1 '.fields.issuetype.id')" = "10701" ]
  [ "$(mock_issue_field CONSUMER-1 '.fields.parent')" = "null" ]
  # Every child is the declared story type (Story, id 10704), naming the parent.
  [ "$(mock_issue_field CONSUMER-2 '.fields.issuetype.id')" = "10704" ]
  [ "$(mock_issue_field CONSUMER-2 '.fields.parent.key')" = "CONSUMER-1" ]
  [ "$(mock_issue_field CONSUMER-3 '.fields.issuetype.id')" = "10704" ]
  [ "$(mock_issue_field CONSUMER-3 '.fields.parent.key')" = "CONSUMER-1" ]
}

@test "T047 — a binding with roles but no task entry mirrors normally (§3.4, absent roles.task is not an error)" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local localf="${JIRA_CONFIG_DIR}/config.local.yml"
  local injected
  injected="$(jq -cS '.resolved_ids.COMP.roles = {
      specification: {logical_name: "Epic", id: "10001", hierarchy_level: "1", subtask: false, source: "derived"},
      story: {logical_name: "Story", id: "10004", hierarchy_level: "0", subtask: false, source: "derived"}
    }' <<< "$(config_yaml_to_json "${localf}")")"
  printf '%s' "${injected}" | config_to_yaml > "${localf}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
}
