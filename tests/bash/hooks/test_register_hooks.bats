#!/usr/bin/env bats
# T006 / T063 [003] — The hook registry READER (FR-021 – FR-025, FR-028).
#
# The registry has one writer and it is not us: `specify extension add` writes
# it, other extensions have entries in it, and the operator edits it by hand and
# keeps comments in it. This module reads that file, recognises which entries are
# ours, classifies every declared event, and reports. It never writes.
#
# Recognition has two rules and they are not the same rule:
#   * ours      — the entry carries `extension: jira-mirror`, the ownership key the host
#                 install writes and matches on when it purges and re-adds;
#   * leftover  — the entry carries one of our commands and NO `extension` field,
#                 the shape every pre-manifest version of this extension wrote.
#                 The install's purge predicate (`h.get("extension") == id`)
#                 never matches it, so the install adds a second entry beside it
#                 instead of replacing it (research R2). Neither the host nor we
#                 can remove it; it must be reported precisely (FR-028).
#
# The canonical entry has EIGHT fields, and `prompt` is the host's EXPANDED
# default — the host builds it with an f-string, so the file receives
# "Execute speckit.jira.reconcile?" and never a "{command}" placeholder
# (research R2, verified at specify_cli/extensions/__init__.py:3866).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HOOK_DIR="${ROOT}/scripts/bash/hooks"
  PS_HOOK="${ROOT}/scripts/powershell/hooks"
  # shellcheck source=/dev/null
  source "${HOOK_DIR}/register_hooks.sh"
  WORK="$(mktemp -d)"
  EXT="${WORK}/.specify/extensions.yml"
  mkdir -p "$(dirname "${EXT}")"
}

teardown() {
  rm -rf "${WORK}"
}

# canonical_registry — write a registry in exactly the shape the host install
# produces: one eight-field entry per declared event, owned by `jira`.
canonical_registry() {
  {
    printf 'hooks:\n'
    local e cmd
    for e in "${HOOK_EVENTS[@]}"; do
      cmd="$(register_hooks_command_for "${e}")"
      printf '  %s:\n' "${e}"
      printf '    - extension: jira-mirror\n'
      printf '      command: %s\n' "${cmd}"
      printf '      enabled: true\n'
      printf '      optional: false\n'
      printf '      priority: 10\n'
      printf '      prompt: Execute %s?\n' "${cmd}"
      printf '      description: A human-readable sentence.\n'
      printf '      condition: null\n'
    done
  } > "${EXT}"
}

# =============================================================================
# The closed set of seven declared events
# =============================================================================

@test "the seven declared events are one closed set (research R9, data-model)" {
  [ "${#HOOK_EVENTS[@]}" -eq 7 ]
  local expected="after_analyze after_clarify after_implement after_plan after_specify after_tasks before_specify"
  local actual
  actual="$(printf '%s\n' "${HOOK_EVENTS[@]}" | LC_ALL=C sort | tr '\n' ' ')"
  [ "${actual% }" = "${expected}" ]
}

@test "before_specify names the feature command; every after_* names reconcile" {
  [ "$(register_hooks_command_for before_specify)" = "speckit.jira.feature" ]
  local e
  for e in after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
    [ "$(register_hooks_command_for "$e")" = "speckit.jira.reconcile" ]
  done
}

# =============================================================================
# Recognition: ours vs leftover vs foreign
# =============================================================================

@test "an entry is recognised as ours when extension is jira" {
  run register_hooks_entry_is_ours '{"extension":"jira-mirror","command":"speckit.jira.reconcile"}'
  [ "$status" -eq 0 ]
  run register_hooks_entry_is_ours '{"extension":"git","command":"speckit.git.commit"}'
  [ "$status" -ne 0 ]
}

@test "an entry is recognised as leftover when extension is absent and command is one of ours (FR-028)" {
  # The four-field shape every pre-manifest version of this extension wrote.
  run register_hooks_entry_is_leftover '{"command":"speckit.jira.reconcile","description":"x","enabled":true,"optional":true}'
  [ "$status" -eq 0 ]
  run register_hooks_entry_is_leftover '{"command":"speckit.jira.feature","enabled":true}'
  [ "$status" -eq 0 ]
  # Ours by ownership is NOT leftover — the install can purge it.
  run register_hooks_entry_is_leftover '{"extension":"jira-mirror","command":"speckit.jira.reconcile"}'
  [ "$status" -ne 0 ]
  # Another extension's entry is never ours, with or without the field.
  run register_hooks_entry_is_leftover '{"command":"other.ext.thing"}'
  [ "$status" -ne 0 ]
}

# =============================================================================
# The canonical eight-field shape, asserted on READ
# =============================================================================

@test "the canonical eight-field shape is asserted on read (contracts/hook-registry-entry.md)" {
  local entry
  entry='{"extension":"jira-mirror","command":"speckit.jira.reconcile","enabled":true,"optional":false,"priority":10,"prompt":"Execute speckit.jira.reconcile?","description":"Mirror.","condition":null}'
  run register_hooks_entry_shape_errors "${entry}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing field is reported as a shape deviation, field by field" {
  local f
  for f in extension command enabled optional priority prompt description condition; do
    local entry
    entry="$(jq -c --arg f "$f" 'del(.[$f])' <<< '{"extension":"jira-mirror","command":"speckit.jira.reconcile","enabled":true,"optional":false,"priority":10,"prompt":"Execute speckit.jira.reconcile?","description":"d","condition":null}')"
    run register_hooks_entry_shape_errors "${entry}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$f"* ]]
  done
}

@test "prompt must be the host's EXPANDED default, never a {command} placeholder (research R2)" {
  local entry
  entry='{"extension":"jira-mirror","command":"speckit.jira.reconcile","enabled":true,"optional":false,"priority":10,"prompt":"Execute {command}?","description":"d","condition":null}'
  run register_hooks_entry_shape_errors "${entry}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"prompt"* ]]
  # The exact string the host writes, with the command substituted.
  entry="$(jq -c '.prompt = "Execute speckit.jira.reconcile?"' <<< "${entry}")"
  run register_hooks_entry_shape_errors "${entry}"
  [ "$status" -eq 0 ]
}

@test "a non-empty condition is a shape deviation — it suppresses agent dispatch (research R8)" {
  local entry
  entry='{"extension":"jira-mirror","command":"speckit.jira.reconcile","enabled":true,"optional":false,"priority":10,"prompt":"Execute speckit.jira.reconcile?","description":"d","condition":"configured"}'
  run register_hooks_entry_shape_errors "${entry}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"condition"* ]]
}

# =============================================================================
# Classification over a whole registry
# =============================================================================

@test "a registry in the canonical shape classifies all seven events present" {
  canonical_registry
  local h
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.present | length' <<< "$h")" -eq 7 ]
  [ "$(jq -r '.missing | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r '.disabled | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r '.duplicated | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r '.held_disabled | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r '.unreadable' <<< "$h")" = "false" ]
  [ "$(jq -r 'has("repair_hint")' <<< "$h")" = "false" ]
}

@test "a deleted entry is missing, and the hint names the official install command (FR-025)" {
  canonical_registry
  local trimmed
  trimmed="$(config_yaml_to_json "${EXT}" | jq -c 'del(.hooks.after_tasks)')"
  printf '%s' "$trimmed" | config_to_yaml > "${EXT}"
  local h
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.missing | index("after_tasks") != null' <<< "$h")" = "true" ]
  [ "$(jq -r '.present | length' <<< "$h")" -eq 6 ]
  [[ "$(jq -r '.repair_hint' <<< "$h")" == *"specify extension add"* ]]
  [[ "$(jq -r '.repair_hint' <<< "$h")" == *"after_tasks"* ]]
}

@test "an operator-disabled entry is disabled — neither present nor missing" {
  canonical_registry
  local disabled
  disabled="$(config_yaml_to_json "${EXT}" | jq -c '.hooks.after_implement[0].enabled = false')"
  printf '%s' "$disabled" | config_to_yaml > "${EXT}"
  local h
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.disabled | index("after_implement") != null' <<< "$h")" = "true" ]
  [ "$(jq -r '.present | length' <<< "$h")" -eq 6 ]
  [ "$(jq -r '.missing | length' <<< "$h")" -eq 0 ]
}

@test "a foreign extension's entry is never classified as ours (FR-006)" {
  printf '%s\n' \
    'hooks:' \
    '  after_plan:' \
    '    - extension: git' \
    '      command: speckit.git.commit' \
    '      enabled: true' > "${EXT}"
  local h
  h="$(register_hooks_health "${EXT}")"
  # The foreign entry does not make after_plan present, and does not become a
  # leftover of ours either.
  [ "$(jq -r '.missing | index("after_plan") != null' <<< "$h")" = "true" ]
  [ "$(jq -r '.duplicated | length' <<< "$h")" -eq 0 ]
}

# =============================================================================
# T063 — leftover pre-manifest entries (FR-028)
# =============================================================================

@test "a leftover entry — our command, no extension field — is classified duplicated (FR-028)" {
  canonical_registry
  local seeded
  seeded="$(config_yaml_to_json "${EXT}" \
    | jq -c '.hooks.after_plan += [{"command":"speckit.jira.reconcile","description":"old","enabled":true,"optional":true}]')"
  printf '%s' "$seeded" | config_to_yaml > "${EXT}"
  local h
  h="$(register_hooks_health "${EXT}")"
  [ "$(jq -r '.duplicated | index("after_plan") != null' <<< "$h")" = "true" ]
  # duplicated is an ANNOTATION, not a partition: the canonical entry is still present.
  [ "$(jq -r '.present | index("after_plan") != null' <<< "$h")" = "true" ]
}

@test "the duplicated report names every affected event and a copy-pasteable manual edit (FR-028)" {
  canonical_registry
  local seeded
  seeded="$(config_yaml_to_json "${EXT}" \
    | jq -c '.hooks.after_plan += [{"command":"speckit.jira.reconcile","enabled":true}]
             | .hooks.before_specify += [{"command":"speckit.jira.feature","enabled":true}]')"
  printf '%s' "$seeded" | config_to_yaml > "${EXT}"
  local hint
  hint="$(register_hooks_health "${EXT}" | jq -r '.repair_hint')"
  [[ "$hint" == *"after_plan"* ]]
  [[ "$hint" == *"before_specify"* ]]
  # The remedy is a manual edit, because neither the host nor we can perform it.
  [[ "$hint" == *".specify/extensions.yml"* ]]
  [[ "$hint" == *"extension: jira-mirror"* ]]
}

@test "classifying a registry with leftovers writes NOTHING (FR-022)" {
  canonical_registry
  local seeded before after
  seeded="$(config_yaml_to_json "${EXT}" | jq -c '.hooks.after_plan += [{"command":"speckit.jira.reconcile"}]')"
  printf '%s' "$seeded" | config_to_yaml > "${EXT}"
  before="$(shasum -a 256 < "${EXT}")"
  register_hooks_health "${EXT}" > /dev/null || true
  after="$(shasum -a 256 < "${EXT}")"
  [ "${before}" = "${after}" ]
}

# =============================================================================
# The disable record is honoured in the classification
# =============================================================================

@test "an event in the disable record is annotated held_disabled, and the hint names the release flag" {
  canonical_registry
  local h
  h="$(register_hooks_health "${EXT}" '["after_implement"]')"
  [ "$(jq -r '.held_disabled | index("after_implement") != null' <<< "$h")" = "true" ]
  # The registry still says enabled: true (the install rewrote it), so the event
  # is ALSO present — held_disabled annotates, it does not partition.
  [ "$(jq -r '.present | index("after_implement") != null' <<< "$h")" = "true" ]
  [[ "$(jq -r '.repair_hint' <<< "$h")" == *"--enable-hook"* ]]
}

# =============================================================================
# Unreadable (FR-024)
# =============================================================================

@test "an unreadable registry reports unreadable, and does NOT report the events as missing (FR-024)" {
  printf '%s\n' 'hooks:' '  after_plan:' '   - broken' '     : : :' > "${EXT}"
  run register_hooks_health "${EXT}"
  [ "$status" -eq 4 ]
  [ "$(jq -r '.unreadable' <<< "$output")" = "true" ]
  [ "$(jq -r '.missing | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.present | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.disabled | length' <<< "$output")" -eq 0 ]
}

@test "a YAML anchor is reported as unreadable with the construct NAMED (FR-024, spec Edge Cases)" {
  printf '%s\n' \
    'defaults: &defaults' \
    '  enabled: true' \
    'hooks:' \
    '  after_plan:' \
    '    - extension: jira-mirror' > "${EXT}"
  run register_hooks_health "${EXT}"
  [ "$status" -eq 4 ]
  [ "$(jq -r '.unreadable' <<< "$output")" = "true" ]
  [[ "$(jq -r '.repair_hint' <<< "$output")" == *"anchor"* ]]
}

@test "a flow collection is reported as unreadable with the construct NAMED (FR-024)" {
  printf '%s\n' 'hooks:' '  after_plan: [{extension: jira-mirror, command: speckit.jira.reconcile}]' > "${EXT}"
  run register_hooks_health "${EXT}"
  [ "$status" -eq 4 ]
  [[ "$(jq -r '.repair_hint' <<< "$output")" == *"flow"* ]]
}

@test "an EMPTY flow collection is inside the reader's subset — our own writer emits it" {
  # `key: []` and `key: {}` are what config_to_yaml emits for empty collections,
  # so flagging them would make the extension call its own output unreadable.
  printf '%s\n' 'hooks:' '  after_plan: []' > "${EXT}"
  run register_hooks_health "${EXT}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unreadable' <<< "$output")" = "false" ]
}

@test "an absent registry reports every declared event missing — not unreadable" {
  local h
  h="$(register_hooks_health "${WORK}/nope.yml")"
  [ "$(jq -r '.missing | length' <<< "$h")" -eq 7 ]
  [ "$(jq -r '.present | length' <<< "$h")" -eq 0 ]
  [ "$(jq -r '.unreadable' <<< "$h")" = "false" ]
}

# =============================================================================
# The writer is GONE (FR-022, SC-011)
# =============================================================================

@test "register_hooks_write no longer exists — the module has no writer (FR-022)" {
  run declare -F register_hooks_write
  [ "$status" -ne 0 ]
}

@test "no function in the module opens the registry for writing (SC-011)" {
  # The module-level guarantee, asserted against the source rather than against
  # behaviour: a write reintroduced in good faith by a later feature fails here.
  run grep -nE '(>>?[[:space:]]*"?\$\{?(path|ext_path)|(\bmv\b|\bcp\b|\brm\b|\btee\b|\btruncate\b|sed -i).*(path|extensions\.yml))' \
    "${HOOK_DIR}/register_hooks.sh"
  [ "$status" -ne 0 ]
}

# =============================================================================
# Cross-port equality (Constitution VI)
# =============================================================================

@test "the PowerShell port classifies the same input state identically (Constitution VI)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  canonical_registry
  local seeded
  seeded="$(config_yaml_to_json "${EXT}" \
    | jq -c '.hooks.after_plan += [{"command":"speckit.jira.reconcile"}]
             | .hooks.after_implement[0].enabled = false')"
  printf '%s' "$seeded" | config_to_yaml > "${EXT}"
  local b p ps_abs
  b="$(register_hooks_health "${EXT}" '["after_clarify"]')"
  ps_abs="$(cd "${PS_HOOK}" && pwd)"
  p="$(EXT="${EXT}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/RegisterHooks.psm1' -Force
    Get-JiraHookHealth -Path \$env:EXT -DisabledJson '[\"after_clarify\"]'
  ")"
  [ "${b}" = "${p}" ]
}
