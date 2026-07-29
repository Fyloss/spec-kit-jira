#!/usr/bin/env bats
# T022 [US2] — Creation context resolution from the persisted binding
# (FR-007–FR-011, FR-013). RED before reconcile.sh's _reconcile_plan_context
# builds story_type_id / priority_ids / estimation_field_id from resolved_ids.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
  CFG="$(config_load "${FIXTURE}")"
}

@test "story_type_id comes from resolved_ids.<KEY>.issue_types.Story (FR-007)" {
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.story_type_id' <<< "$output")" = "10004" ]
}

@test "priority resolves in two steps: priority_map then resolved_ids.priorities (FR-008)" {
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.priority_ids.P1' <<< "$output")" = "1" ]
  [ "$(jq -r '.priority_ids.P2' <<< "$output")" = "3" ]
  [ "$(jq -r '.priority_ids.P3' <<< "$output")" = "4" ]
}

@test "an unresolvable priority level is omitted rather than blocking the run (FR-011)" {
  local cfg
  cfg="$(jq -c '.projects[0].priority_map = {"P1":"Highest"}' <<< "${CFG}")"
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${cfg}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.priority_ids | has("P2")' <<< "$output")" = "false" ]
  [ "$(jq -r '.priority_ids.P1' <<< "$output")" = "1" ]
}

@test "the machine-owned binding wins over the committed team config for issue types (FR-009)" {
  # The fixture's committed layer declares Story: 10002; the persisted binding
  # declares Story: 10004 — the persisted value must win.
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  [ "$(jq -r '.story_type_id' <<< "$output")" = "10004" ]
}

@test "an explicit SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived object wholesale (FR-013)" {
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"99999"}'
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT
  [ "$status" -eq 0 ]
  [ "$(jq -r '.story_type_id' <<< "$output")" = "99999" ]
  [ "$(jq -r 'has("priority_ids")' <<< "$output")" = "false" ]
}

@test "estimation field id is carried when the binding declares one" {
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  [ "$(jq -r '.estimation_field_id' <<< "$output")" = "customfield_20011" ]
}

@test "the project has no persisted binding: refused, distinct cause (FR-010)" {
  run _reconcile_plan_context "https://mock" "NOPE" "${FIXTURE}" "${CFG}"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "the local layer is missing entirely: reported as never-bound, not the project-not-bound fault" {
  local empty_dir
  empty_dir="${BATS_TEST_TMPDIR}/never-bound/.specify/jira"
  mkdir -p "${empty_dir}"
  cp "${FIXTURE}/config.yml" "${empty_dir}/config.yml"
  run _reconcile_plan_context "https://mock" "COMP" "${empty_dir}" "${CFG}"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "cmd_reconcile reads config.yml for priority_map even when only project key and epic strategy are overridden (T057, FR-008 partial)" {
  local legacy spec
  legacy="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-legacy/.specify/jira"
  spec="${BATS_TEST_TMPDIR}/priority.md"
  printf '%s\n' \
    '# Feature Specification: Priority Wiring' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${spec}"

  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export SPEC_KIT_JIRA_EPIC_STRATEGY="per_repo"
  export JIRA_CONFIG_DIR="${legacy}"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT

  run cmd_reconcile reconcile --dry-run --json "${spec}"
  [ "$status" -eq 0 ]
  # The legacy fixture's config.yml maps P1 -> Highest, and its
  # config.local.yml resolves Highest -> "1" — resolvable only if config.yml
  # is actually read when SPEC_KIT_JIRA_PLAN_CONTEXT is not overridden, even
  # though the project key and epic strategy are.
  [ "$(jq -r '.actions[0].body.fields.priority.id' <<< "$output")" = "1" ]
}
