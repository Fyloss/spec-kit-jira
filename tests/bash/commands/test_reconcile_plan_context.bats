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

@test "story_type_id comes from resolved_ids.<KEY>.child_type.id (FR-007)" {
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

@test "017, T031 twin — issue_types is threaded into the context from the binding, for the label-decision helpers" {
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issue_types | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.issue_types[] | select(.logical_name=="Story")][0].id' <<< "$output")" = "10004" ]
}

@test "017 — defaultable_fields_by_type is omitted when the binding predates it (R6's absent branch)" {
  run _reconcile_plan_context "https://mock" "COMP" "${FIXTURE}" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("defaultable_fields_by_type")' <<< "$output")" = "false" ]
}

@test "017 — defaultable_fields_by_type is threaded into the context from the binding when recorded" {
  local cfg binding_dir
  binding_dir="${BATS_TEST_TMPDIR}/with-defaultable/.specify/jira"
  mkdir -p "${binding_dir}"
  cp "${FIXTURE}/config.yml" "${binding_dir}/config.yml"
  cp "${FIXTURE}/config.local.yml" "${binding_dir}/config.local.yml"
  cat >> "${binding_dir}/config.local.yml" <<'YAML'
    defaultable_fields:
      "10004":
        - logical_name: "Labels"
          field_id: "labels"
          defaultable: false
YAML
  cfg="$(config_load "${binding_dir}")"
  run _reconcile_plan_context "https://mock" "COMP" "${binding_dir}" "${cfg}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.defaultable_fields_by_type."10004"[0].field_id' <<< "$output")" = "labels" ]
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
  mkdir -p "${BATS_TEST_TMPDIR}/priority"
  spec="${BATS_TEST_TMPDIR}/priority/spec.md"
  printf '%s\n' \
    '# Feature Specification: Priority Wiring' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${spec}"

  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export JIRA_CONFIG_DIR="${legacy}"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT

  run cmd_reconcile reconcile --dry-run --json "${spec}"
  [ "$status" -eq 0 ]
  # The legacy fixture's config.yml maps P1 -> Highest, and its
  # config.local.yml resolves Highest -> "1" — resolvable only if config.yml
  # is actually read when SPEC_KIT_JIRA_PLAN_CONTEXT is not overridden, even
  # though the project key and epic strategy are.
  [ "$(jq -r '.actions[1].body.fields.priority.id' <<< "$output")" = "1" ]
}
