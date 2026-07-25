#!/usr/bin/env bats
# T080 [US9] — Idempotent after_* lifecycle-hook registration (FR-045, FR-047, FR-048).
#
# The config command registers a non-blocking Jira reconcile under every spec-kit
# lifecycle event in .specify/extensions.yml. Registration is set-not-append and
# idempotent: a re-run produces no duplicates and rewrites byte-identical bytes.
# A genuinely missing hook is repaired; an operator-disabled hook is preserved and
# never re-enabled; another extension's hooks under the same event survive.
# The PowerShell port registers byte-identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HOOK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/hooks"
  PS_HOOK="${ROOT}/.specify/extensions/jira/scripts/powershell/hooks"
  # shellcheck source=/dev/null
  source "${HOOK_DIR}/register_hooks.sh"
  WORK="$(mktemp -d)"
  EXT="${WORK}/.specify/extensions.yml"
}

teardown() {
  rm -rf "${WORK}"
}

@test "an absent extensions.yml is created with all six lifecycle hooks (FR-045)" {
  run register_hooks_write "${EXT}"
  [ "$status" -eq 0 ]
  [ "$output" = "created" ]
  [ -f "${EXT}" ]
  local json
  json="$(config_yaml_to_json "${EXT}")"
  for e in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    [ "$(jq -r --arg e "$e" '.hooks[$e] | map(select(.command=="speckit.jira.reconcile")) | length' <<< "$json")" -eq 1 ]
  done
}

@test "a re-run adds no duplicates and is reported unchanged (FR-047)" {
  register_hooks_write "${EXT}" > /dev/null
  run register_hooks_write "${EXT}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  local json
  json="$(config_yaml_to_json "${EXT}")"
  [ "$(jq -r '.hooks.after_plan | length' <<< "$json")" -eq 1 ]
}

@test "two runs write a byte-identical extensions.yml (FR-047)" {
  register_hooks_write "${EXT}" > /dev/null
  cp "${EXT}" "${WORK}/ext1"
  register_hooks_write "${EXT}" > /dev/null
  run diff "${WORK}/ext1" "${EXT}"
  [ "$status" -eq 0 ]
}

@test "a missing hook is repaired without touching the others (FR-047)" {
  register_hooks_write "${EXT}" > /dev/null
  # Drop one event by hand, then repair.
  local trimmed
  trimmed="$(config_yaml_to_json "${EXT}" | jq -c 'del(.hooks.after_tasks)')"
  printf '%s' "$trimmed" | config_to_yaml > "${EXT}"
  run register_hooks_write "${EXT}"
  [ "$status" -eq 0 ]
  [ "$output" = "repaired" ]
  local json
  json="$(config_yaml_to_json "${EXT}")"
  [ "$(jq -r '.hooks.after_tasks | map(select(.command=="speckit.jira.reconcile")) | length' <<< "$json")" -eq 1 ]
}

@test "an operator-disabled hook stays disabled across repair (FR-048)" {
  register_hooks_write "${EXT}" > /dev/null
  # Operator disables the implement hook by hand.
  local disabled
  disabled="$(config_yaml_to_json "${EXT}" | jq -c '.hooks.after_implement[0].enabled = false')"
  printf '%s' "$disabled" | config_to_yaml > "${EXT}"
  run register_hooks_write "${EXT}"
  [ "$status" -eq 0 ]
  # Registration must NOT re-enable it and must NOT duplicate it.
  local json
  json="$(config_yaml_to_json "${EXT}")"
  [ "$(jq -r '.hooks.after_implement | length' <<< "$json")" -eq 1 ]
  [ "$(jq -r '.hooks.after_implement[0].enabled' <<< "$json")" = "false" ]
}

@test "another extension's hook under the same event is preserved" {
  # A pre-existing foreign hook must survive registration.
  mkdir -p "$(dirname "${EXT}")"
  printf '%s' '{"hooks":{"after_plan":[{"command":"other.ext.thing","enabled":true}]}}' | config_to_yaml > "${EXT}"
  run register_hooks_write "${EXT}"
  [ "$status" -eq 0 ]
  local json
  json="$(config_yaml_to_json "${EXT}")"
  [ "$(jq -r '.hooks.after_plan | length' <<< "$json")" -eq 2 ]
  [ "$(jq -r '.hooks.after_plan | map(select(.command=="other.ext.thing")) | length' <<< "$json")" -eq 1 ]
  [ "$(jq -r '.hooks.after_plan | map(select(.command=="speckit.jira.reconcile")) | length' <<< "$json")" -eq 1 ]
}

@test "health reports present/missing in the contract shape (FR-047, run-summary.schema.json)" {
  register_hooks_write "${EXT}" > /dev/null
  local h
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.present | length' <<< "$h")" -eq 6 ]
  [ "$(jq -r '.missing | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r '.disabled | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r 'has("repair_hint")' <<< "$h")" = "false" ]

  local trimmed
  trimmed="$(config_yaml_to_json "${EXT}" | jq -c 'del(.hooks.after_analyze)')"
  printf '%s' "$trimmed" | config_to_yaml > "${EXT}"
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.missing[0]' <<< "$h")" = "after_analyze" ]
  [ "$(jq -r '.present | length' <<< "$h")" -eq 5 ]
  [[ "$(jq -r '.repair_hint' <<< "$h")" == *"repair-hooks"* ]]
}

@test "health lists an operator-disabled hook under disabled — neither present nor missing (FR-048)" {
  register_hooks_write "${EXT}" > /dev/null
  local disabled
  disabled="$(config_yaml_to_json "${EXT}" | jq -c '.hooks.after_implement[0].enabled = false')"
  printf '%s' "$disabled" | config_to_yaml > "${EXT}"
  local h
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.disabled[0]' <<< "$h")" = "after_implement" ]
  [ "$(jq -r '.present | length' <<< "$h")" -eq 5 ]
  [ "$(jq -r '.missing | length' <<< "$h")" -eq 0 ]
}

@test "health on an absent file reports every hook missing" {
  local h
  h="$(register_hooks_health "${WORK}/nope.yml")"
  [ "$(jq -r '.missing | length' <<< "$h")" -eq 6 ]
  [ "$(jq -r '.present | length' <<< "$h")" -eq 0 ]
}

@test "the PowerShell port registers a byte-identical extensions.yml (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  register_hooks_write "${EXT}" > /dev/null
  cp "${EXT}" "${WORK}/ext-bash"
  local psext="${WORK}/ps/.specify/extensions.yml"
  local ps_abs
  ps_abs="$(cd "${PS_HOOK}" && pwd)"
  PSEXT="${psext}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/RegisterHooks.psm1' -Force
    [void](Set-JiraHookRegistration -Path \$env:PSEXT)
  "
  run diff "${WORK}/ext-bash" "${psext}"
  [ "$status" -eq 0 ]
}
