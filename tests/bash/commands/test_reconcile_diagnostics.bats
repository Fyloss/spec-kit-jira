#!/usr/bin/env bats
# T031 [US3] — The diagnostics catalogue (contracts/resolution-contract.md):
# each resolution fault names its own cause and remedy, makes ZERO Jira
# requests of any kind (FR-019 — resolution completes before the first network
# call), fails closed (exit 4) on direct invocation, and downgrades to exit 0
# with exactly one warning under a lifecycle hook (FR-015, FR-016).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"

  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
  unset SPEC_KIT_JIRA_PROJECT_KEY
  unset SPEC_KIT_JIRA_EPIC_STRATEGY
  unset SPEC_KIT_JIRA_PLAN_CONTEXT
  unset SPEC_KIT_JIRA_HOOK_CONTEXT

  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Diagnostics' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${SPEC}"

  mock_start '{}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

_assert_fault_properties() {
  local needle="$1"
  # (1) Direct invocation: exit 4, the named cause appears, zero requests.
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"${needle}"* ]]
  [ -z "$(mock_calls)" ]
  # FR-018: no diagnostic ever names the site host or a credential shape.
  [[ "$output" != *"${MOCK_BASE_URL#http://}"* ]]
  [[ "$output" != *"ATATT"* ]]
  [[ "$output" != *"@"* ]]

  # (2) Hook context: exit 0, exactly one occurrence of the message, zero requests.
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(grep -c "${needle}" <<< "$output")" -eq 1 ]
  [ -z "$(mock_calls)" ]
  [[ "$output" != *"${MOCK_BASE_URL#http://}"* ]]
  [[ "$output" != *"ATATT"* ]]
  [[ "$output" != *"@"* ]]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT

  # (3) --verbose changes nothing about the leak guarantee (FR-018, "at any verbosity").
  run cmd_reconcile reconcile --dry-run --json --verbose "${SPEC}"
  [[ "$output" != *"${MOCK_BASE_URL#http://}"* ]]
  [[ "$output" != *"ATATT"* ]]
  [[ "$output" != *"@"* ]]
}

@test "routing-unresolved: no rule and no routing_default (contract cause 2)" {
  # routing_default is schema-mandatory on the committed team layer, so this
  # state is reached the way a real repository would reach it: the machine
  # layer's own override nulls it out (schema-valid on both layers — neither
  # layer's own routing_default is invalid, only the merged result is empty).
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: COMP
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: COMP
EOF
  cat > "${JIRA_CONFIG_DIR}/config.local.yml" <<'EOF'
overrides:
  routing_default: null
EOF
  _assert_fault_properties "add routing_default to config.yml"
}

@test "placeholder-binding: the resolved key equals the shipped placeholder (contract cause 3)" {
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: PROJ
EOF
  _assert_fault_properties "placeholder"
}

@test "unknown-project: a routing rule names a project projects[] does not declare (contract cause 4)" {
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: COMP
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: NOPE
EOF
  _assert_fault_properties "not declared"
}

@test "project-not-bound: the resolved project has no resolved_ids entry (contract cause 5)" {
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: COMP
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: COMP
EOF
  cat > "${JIRA_CONFIG_DIR}/config.local.yml" <<'EOF'
resolved_ids:
  OTHERPROJ:
    style: company_managed
EOF
  _assert_fault_properties "has not been bound yet"
}

@test "the four causes each produce a message distinguishable from the others" {
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: COMP
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: COMP
EOF
  cat > "${JIRA_CONFIG_DIR}/config.local.yml" <<'EOF'
overrides:
  routing_default: null
EOF
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  routing_msg="$output"

  rm -f "${JIRA_CONFIG_DIR}/config.local.yml"
  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: PROJ
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: PROJ
EOF
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  placeholder_msg="$output"

  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: COMP
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: NOPE
EOF
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  unknown_msg="$output"

  cat > "${JIRA_CONFIG_DIR}/config.yml" <<'EOF'
projects:
  - key: COMP
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: COMP
EOF
  rm -f "${JIRA_CONFIG_DIR}/config.local.yml"
  cat > "${JIRA_CONFIG_DIR}/config.local.yml" <<'EOF'
resolved_ids:
  OTHERPROJ:
    style: company_managed
EOF
  run cmd_reconcile reconcile --dry-run --json "${SPEC}"
  notbound_msg="$output"

  [ "${routing_msg}" != "${placeholder_msg}" ]
  [ "${routing_msg}" != "${unknown_msg}" ]
  [ "${routing_msg}" != "${notbound_msg}" ]
  [ "${placeholder_msg}" != "${unknown_msg}" ]
  [ "${placeholder_msg}" != "${notbound_msg}" ]
  [ "${unknown_msg}" != "${notbound_msg}" ]
}
