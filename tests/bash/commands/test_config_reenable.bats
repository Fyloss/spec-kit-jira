#!/usr/bin/env bats
# T065 [003 US6] — `--enable-hook <event>`, the operator's explicit release
# (FR-007, FR-029, Constitution XI, XV).
#
# This flag is the one affordance this feature adds, and it exists only because
# upstream leaves no alternative. `specify extension add` writes `enabled: true`
# unconditionally on every install and upgrade (research R5), so the extension
# cannot tell an operator's deliberate re-enable from the install's blind one.
# Guessing would silently discard a deliberate choice, so the extension does not
# guess: it holds the event disabled until the operator says otherwise, in one
# explicit command that the ceremony's own report names.
#
# The critical property is what the flag does NOT do. It clears one entry from
# the extension's own gitignored record and touches the hook registry not at all
# (FR-022) — the registry is not "restored" to enabled, because it is not ours to
# write in either direction.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"

  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  {
    printf 'projects:\n'
    printf '  - key: TEAM\n'
    printf '    epic_strategy: per_repo\n'
    printf '    task_strategy: subtask\n'
    printf 'routing_default: TEAM\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  # No connection: the run is degraded, which is exactly where an operator
  # reaching for this flag is most likely to be.
  unset SPEC_KIT_JIRA_BASE_URL

  # A registry the install wrote, with every entry enabled — the state after a
  # reinstall has blown away the operator's `enabled: false`.
  printf '%s\n' \
    'hooks:' \
    '  after_implement:' \
    '  - extension: jira' \
    '    command: speckit.jira.reconcile' \
    '    enabled: true' > "${SPEC_KIT_JIRA_EXTENSIONS_YML}"
}

teardown() {
  rm -rf "${WORK}"
}

summary() { grep '^{' <<< "$output"; }

@test "--enable-hook clears the event from the disable record (FR-007, FR-029)" {
  config_hooks_disabled_add after_implement "${JIRA_CONFIG_DIR}" > /dev/null
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = '["after_implement"]' ]
  run cmd_config config --enable-hook after_implement --json
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = "[]" ]
}

@test "the registry is NOT touched by the release (FR-022)" {
  config_hooks_disabled_add after_implement "${JIRA_CONFIG_DIR}" > /dev/null
  local before
  before="$(shasum -a 256 < "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"
  run cmd_config config --enable-hook after_implement --json
  [ "$(shasum -a 256 < "${SPEC_KIT_JIRA_EXTENSIONS_YML}")" = "${before}" ]
}

@test "the release is reported, naming the event (Principle XVI)" {
  config_hooks_disabled_add after_implement "${JIRA_CONFIG_DIR}" > /dev/null
  run cmd_config config --enable-hook after_implement --json
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(summary)")" == *"released: after_implement"* ]]
}

@test "the flag is repeatable" {
  config_hooks_disabled_add after_implement "${JIRA_CONFIG_DIR}" > /dev/null
  config_hooks_disabled_add after_plan "${JIRA_CONFIG_DIR}" > /dev/null
  run cmd_config config --enable-hook after_implement --enable-hook after_plan --json
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = "[]" ]
}

@test "against an unrecorded event it is a no-op, reported as such" {
  run cmd_config config --enable-hook after_plan --json
  [ "$status" -eq 0 ]
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = "[]" ]
  # Nothing was released, so nothing is claimed to have been.
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(summary)")" != *"released:"* ]]
}

@test "an unknown event name is reported and does NOT fail the run (FR-029)" {
  run cmd_config config --enable-hook not_an_event --json
  [ "$status" -eq 0 ]
}

@test "--dry-run predicts the clearance without performing it (Constitution XI)" {
  config_hooks_disabled_add after_implement "${JIRA_CONFIG_DIR}" > /dev/null
  run cmd_config config --enable-hook after_implement --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.effects.hooks.detail' <<< "$(summary)")" == *"released: after_implement"* ]]
  # Predicted, not performed.
  [ "$(config_hooks_disabled_read "${JIRA_CONFIG_DIR}")" = '["after_implement"]' ]
}

@test "the released event is no longer held at dispatch (FR-007)" {
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  local spec="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Release' '' 'A spec.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' > "${spec}"

  config_hooks_disabled_add after_implement "${JIRA_CONFIG_DIR}" > /dev/null
  export SPEC_KIT_JIRA_HOOK_EVENT=after_implement
  run cmd_reconcile reconcile --dry-run --json "${spec}"
  # Held: inert and silent.
  [ -z "$output" ]

  cmd_config config --enable-hook after_implement --json > /dev/null 2>&1
  run cmd_reconcile reconcile --dry-run --json "${spec}"
  # Released: the step runs again (and reports it is not configured, which is a
  # different message with a different cause).
  [ -n "$output" ]
}

@test "requires a value, and says so (usage)" {
  run cmd_config config --enable-hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"--enable-hook requires a lifecycle event"* ]]
}
