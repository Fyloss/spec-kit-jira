#!/usr/bin/env bats
# T009 [US1] — Routing resolution: the mirror resolves its own target project
# from the repository's own config, with no environment variable required
# (FR-001–FR-006, FR-013). RED before reconcile.sh gains
# _reconcile_resolve_routing and the PROJ fallback is removed.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
  CFG="$(config_load "${FIXTURE}")"
}

_spec_with_folder() {
  local folder="$1" spec="${BATS_TEST_TMPDIR}/${folder}/spec.md"
  mkdir -p "$(dirname "${spec}")"
  printf '%s\n' \
    '# Feature Specification: Invoices' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${spec}"
  printf '%s' "${spec}"
}

@test "a folder-prefix rule routes the spec to its project (FR-002)" {
  run _reconcile_resolve_routing "billing-042-invoices" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "COMP" ]
}

@test "no rule matches: falls back to routing_default (FR-003)" {
  run _reconcile_resolve_routing "checkout-007-cart" "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "COMP" ]
}

@test "no rule and no routing_default: refused, zero output (FR-005)" {
  local cfg
  cfg="$(jq -c 'del(.routing_default)' <<< "${CFG}")"
  run _reconcile_resolve_routing "checkout-007-cart" "${cfg}"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "explicit SPEC_KIT_JIRA_PROJECT_KEY override wins over config (FR-013)" {
  local spec
  spec="$(_spec_with_folder "billing-042-invoices")"
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_PROJECT_KEY="OTHER"
  export SPEC_KIT_JIRA_SPEC_SLUG="004-billing-invoices"
  export JIRA_CONFIG_DIR="${FIXTURE}"
  # This test is about ROUTING precedence, not the creation-context binding for
  # project "OTHER" (which the fixture never bound) — bypass that lookup with a
  # minimal override supplying the issue type the assembly guard requires.
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"99999"}'
  run cmd_reconcile reconcile --dry-run --json "${spec}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].body.fields.project.key' <<< "$output")" = "OTHER" ]
}

@test "a placeholder-key override is refused, zero writes (FR-005)" {
  local spec
  spec="$(_spec_with_folder "billing-042-invoices")"
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_PROJECT_KEY="PROJ"
  export JIRA_CONFIG_DIR="${FIXTURE}"
  run cmd_reconcile reconcile --dry-run --json "${spec}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"placeholder"* ]]
  [ "$(jq -r '.actions // empty' <<< "$output" 2>/dev/null)" = "" ]
}

