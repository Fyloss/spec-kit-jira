#!/usr/bin/env bash
# sink/jira/transitions.sh — read a ticket's available moves and resolve them
# by destination NAME, never by category (023, contracts/transition-
# resolution.md). This is the tier that reads the declared step and decides
# how to reach it; discovery_task_transition (sink/jira/discovery.sh) keeps
# its own, unrelated rule — selection by destination statusCategory — for
# the task tier's done/not-done question (research D3).
#
# Branch C (research R1, decided 2026-08-13): one GET per ticket due a move —
# `GET /issue/{key}/transitions?expand=transitions.fields`, the exact
# spelling discovery_task_transition already uses in production. There is no
# bulk form: 021's dogfood-verified `bulkfetch` shape (contracts/
# recognition-prefetch.md §1) names no `expand` member and no `transitions`
# array, so branch A has no measured evidence and branch C — already proven
# against the real instance — is what this module implements.

[[ -n ${_JIRA_SINK_TRANSITIONS:-} ]] && return 0
_JIRA_SINK_TRANSITIONS=1

_transitions_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_transitions_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_transitions_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_transitions_dir}/client.sh"

# _TRANSITIONS_MAP: lower-cased key -> canonical availability record
# (data-model.md §3, extended with each move's own `name` — needed by the
# ambiguous outcome's candidate list, contract §4 — never used in the
# decision itself, contract §3 M1). A non-exported bash global, scoped to
# this process only; transitions_reset exists so tests never leak state
# across cases.
declare -gA _TRANSITIONS_MAP=()

# transitions_reset — empties the map. Test support (contract §2).
transitions_reset() {
  _TRANSITIONS_MAP=()
}

# transitions_load <key>… — one GET per key (branch C), populating the map.
# Returns 0 on full success. On ANY read failure (retries exhausted) returns
# the failing request's own exit code immediately, without reading the
# remaining keys — the authoritative read fails closed for the WHOLE
# specification (contract §2 F2), matching discovery_task_transition's
# existing treatment of the identical read. There is no bulk form to fall
# back from (F1 is vacuous under branch C).
transitions_load() {
  transitions_reset
  (($# == 0)) && return 0
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  local api="${base}/rest/api/3"
  local key resp
  # 023, T155 (024 spawn-budget's own decode-once shape, plan_apply.sh
  # `_apply_writes_decode_rows`): the N reads themselves stay one GET per
  # key (branch C has no bulk form — F1 is vacuous), but every response's
  # PARSE used to cost its own `jq` call (plus a second for
  # `json_canonical`) inside this loop — 2N spawns for an N-ticket due set.
  # Raw response bodies are concatenated into ONE JSON array here (bash
  # string interpolation, never a jq call): each is already syntactically
  # complete compact JSON from Jira, and `key` is a Jira issue key
  # (`[A-Z][A-Z0-9]*-[0-9]+`, never attacker-controlled — the same trust
  # boundary `_plan_transition_action`'s own URL interpolation already
  # relies on), so no escaping is needed. The single jq call below then
  # decodes the WHOLE array at once.
  local combined="[" first=true
  for key in "$@"; do
    resp="$(jira_request GET "${api}/issue/${key}/transitions?expand=transitions.fields")" || return $?
    if ${first}; then first=false; else combined+=","; fi
    combined+="{\"key\":\"${key}\",\"response\":${resp}}"
  done
  combined+="]"

  local decoded sep=$'\x1f'
  # kcov-excl-start — jq literal (string lines are not statements)
  decoded="$(jq -r --arg sep "${sep}" '
    def sortkeys: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end);
    .[] | [
      (.key | ascii_downcase),
      ( { key, moves: [ (.response.transitions // [])[] | {
            id, name, to: .to.name,
            gated_field: ( (.fields // {}) | to_entries | map(select(.value.required == true)) | first
                            as $req
                          | if $req == null then null
                            else {logical_name: ($req.value.name // $req.key), field_id: $req.key} end)
          } ] } | sortkeys | tojson )
    ] | join($sep)
  ' <<< "${combined}")"
  # kcov-excl-stop

  local lower entry
  while IFS="${sep}" read -r lower entry; do
    [[ -z "${lower}" ]] && continue
    _TRANSITIONS_MAP["${lower}"]="${entry}"
  done <<< "${decoded}"
  return 0
}

# transitions_get <key> — the cached availability record (data-model.md §3),
# matched back to the requested key case-insensitively, never by position
# (F3). Returns 1 and prints nothing on a miss; never issues a read itself —
# the caller must have called transitions_load first.
transitions_get() {
  local key="$1" lower entry
  lower="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')"
  entry="${_TRANSITIONS_MAP[${lower}]:-}"
  [[ -z "${entry}" ]] && return 1
  printf '%s' "${entry}"
}

# transitions_resolve <availability-record-json> <declared-step> — the pure
# rule of contract §3: exactly one of four outcomes (data-model.md §4).
# Comparison against `declared-step` is exact string equality (M2) — a
# difference in case or spacing is a different step, never accepted.
transitions_resolve() {
  local record="$1" declared="$2"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson r "${record}" --arg d "${declared}" '
    ($r.moves // []) as $moves
    | [ $moves[] | select(.to == $d) ] as $cands
    | ($cands | length) as $n
    | if $n == 1 and $cands[0].gated_field == null then
        {outcome:"move", transition_id: $cands[0].id}
      elif $n == 1 then
        {outcome:"gated", gated_field: $cands[0].gated_field}
      elif $n >= 2 then
        {outcome:"ambiguous", candidates: [ $cands[] | {id, name} ]}
      else
        {outcome:"unreachable", reachable: [ $moves[].to ]}
      end
  ' | json_canonical
  # kcov-excl-stop
}
