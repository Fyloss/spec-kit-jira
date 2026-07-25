#!/usr/bin/env bash
# hooks/register_hooks.sh — Idempotent after_* lifecycle-hook registration (US9).
#
# The config command registers the six spec-kit lifecycle events (specify, clarify,
# plan, tasks, implement, analyze) so each triggers a non-blocking Jira reconcile
# through `.specify/extensions.yml` (FR-045). Registration is SET-not-append and
# idempotent (FR-047): our reconcile hook appears at most once per event, so a
# re-run produces no duplicates. A hook the operator explicitly disabled
# (`enabled: false`) is left exactly as found — its presence counts as registered,
# so repair never re-adds it and it stays disabled forever (FR-048). Every existing
# entry (this or another extension's) is preserved; only a genuinely missing
# reconcile hook is added.
#
# This is the hooks layer, not the engine: it owns the hook/command vocabulary. It
# reuses the deterministic YAML reader/writer from lib/config.sh (no yq at runtime),
# so a re-run against an already-registered file rewrites byte-identical bytes.

[[ -n ${_JIRA_HOOK_REGISTER:-} ]] && return 0
_JIRA_HOOK_REGISTER=1

_register_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_register_hooks_dir}/../lib/config.sh" # config_yaml_to_json / config_to_yaml
# shellcheck source=/dev/null
source "${_register_hooks_dir}/../lib/output.sh" # json_canonical

: "${EXIT_CONFIG:=4}"

# The reconcile command every lifecycle hook triggers, and the six spec-kit
# lifecycle events that MUST mirror to Jira (FR-045).
HOOK_COMMAND='speckit.jira.reconcile'
HOOK_EVENTS=(after_specify after_clarify after_plan after_tasks after_implement after_analyze)

# _register_hooks_events_json — the lifecycle events as a canonical JSON array.
_register_hooks_events_json() {
  printf '%s\n' "${HOOK_EVENTS[@]}" | jq -cR . | jq -cs .
}

# _register_hooks_entry — the canonical desired entry for our reconcile hook.
# `optional: true` makes the hook non-blocking: a bridge failure never fails the
# host command (FR-046).
_register_hooks_entry() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --arg cmd "${HOOK_COMMAND}" '{
    command: $cmd,
    description: "Mirror the updated spec-kit artifacts into Jira Cloud (non-blocking).",
    enabled: true,
    optional: true
  }'
  # kcov-excl-stop
}

# _register_hooks_merge <existing-json> — ensure our reconcile hook is present under
# every lifecycle event, set-not-append (FR-047) and never disturbing an entry the
# operator already placed or disabled (FR-048). Prints the canonical merged JSON.
_register_hooks_merge() {
  local existing="$1" events entry
  events="$(_register_hooks_events_json)"
  entry="$(_register_hooks_entry)"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c --argjson events "${events}" --argjson entry "${entry}" --arg cmd "${HOOK_COMMAND}" '
    reduce $events[] as $e (.;
      .hooks[$e] = (
        (((.hooks // {})[$e]) // []) as $cur
        | if any($cur[]; .command == $cmd) then $cur else $cur + [$entry] end
      ))
  ' <<< "${existing}" | json_canonical
  # kcov-excl-stop
}

# register_hooks_health <extensions-yml-path> — READ-ONLY hook-health check for the
# run summary (FR-047). Prints the canonical hook_health object of
# run-summary.schema.json:
#   { present: [event...], missing: [event...], disabled: [event...], repair_hint? }
# `missing` lists lifecycle events with no reconcile hook at all; an operator-
# disabled hook is listed under `disabled` (never "missing"), so it is never
# re-added (FR-048). `repair_hint` names the one-command repair and appears only
# when a hook is missing. A malformed file reports every event missing and
# returns EXIT_CONFIG.
register_hooks_health() {
  local path="$1" existing="{}" events
  events="$(_register_hooks_events_json)"
  if [[ -f "${path}" ]]; then
    if ! existing="$(config_yaml_to_json "${path}" 2> /dev/null)"; then
      # kcov-excl-start — jq literal (string lines are not statements)
      jq -cn --argjson events "${events}" \
        '{present: [], missing: $events, disabled: [],
          repair_hint: "extensions.yml is not valid YAML — fix it, then run /speckit.jira.config or reconcile --repair-hooks"}' \
        | json_canonical
      # kcov-excl-stop
      return "${EXIT_CONFIG}"
    fi
  fi
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -c --argjson events "${events}" --arg cmd "${HOOK_COMMAND}" '
    (.hooks // {}) as $h
    | reduce $events[] as $e ({present: [], missing: [], disabled: []};
        (($h[$e] // []) | map(select(.command == $cmd))) as $ours
        | if ($ours | length) == 0 then .missing += [$e]
          elif any($ours[]; .enabled != false) then .present += [$e]
          else .disabled += [$e] end)
    | . + (if (.missing | length) > 0
           then {repair_hint: "run /speckit.jira.config or reconcile --repair-hooks"}
           else {} end)
  ' <<< "${existing}" | json_canonical
  # kcov-excl-stop
}

# register_hooks_write <extensions-yml-path> [dry-run:true|false] — idempotently
# register the reconcile hook under every lifecycle event, creating the file (and
# its directory) if absent. Prints a status token on stdout
# (created | repaired | unchanged | refused). Returns 0, or EXIT_CONFIG (4) on a
# malformed existing file (zero writes). In dry-run the status is computed but no
# file is touched.
register_hooks_write() {
  local path="$1" dry="${2:-false}" existing="{}" existed="false" merged yaml tmp status
  if [[ -f "${path}" ]]; then
    existed="true"
    if ! existing="$(config_yaml_to_json "${path}" 2> /dev/null)"; then
      printf 'refused'
      return "${EXIT_CONFIG}"
    fi
  fi

  merged="$(_register_hooks_merge "${existing}")"
  yaml="$(printf '%s' "${merged}" | config_to_yaml)"

  tmp="$(mktemp)"
  printf '%s\n' "${yaml}" > "${tmp}"
  if [[ "${existed}" == "true" ]] && cmp -s "${tmp}" "${path}"; then
    status="unchanged"
  elif [[ "${existed}" == "false" ]]; then
    status="created"
  else
    status="repaired"
  fi

  if [[ "${dry}" != "true" && "${status}" != "unchanged" ]]; then
    mkdir -p "$(dirname "${path}")"
    mv "${tmp}" "${path}"
  else
    rm -f "${tmp}"
  fi
  printf '%s' "${status}"
  return 0
}
