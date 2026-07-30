#!/usr/bin/env bash
# sink/jira/plan_apply.sh — The Jira write path (US11 gate; extended by US3).
#
# `apply_writes` executes an ordered action set against Jira. Its FIRST
# responsibility (US11, T049) is the mandatory pre-write privacy gate: every
# action's content payload is scanned through the BLOCK guard BEFORE any write is
# performed. A single blocked payload aborts the whole apply with EXIT_BLOCK (9)
# and ZERO writes — there is no gap through which a leak could reach Jira
# (Constitution IV, FR-052).
#
# US3 (T058) fleshes out plan_writes / the richer action set (create / update /
# transition / comment / link / label, estimation create-only). This module owns
# the guard-then-write ordering; the guard placement is invariant across that
# extension.
#
# Action shape: [ {method, url, body?}, ... ]. Only the content `body` is scanned
# (the request URL necessarily targets the real host and is not content).

[[ -n ${_JIRA_SINK_PLAN_APPLY:-} ]] && return 0
_JIRA_SINK_PLAN_APPLY=1

_plan_apply_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/privacy_guard.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/client.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/adf.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/ticket.sh" # jira_create_fields_base — the shared creation-fields builder (research R3)
# The sink may consume the neutral engine (the boundary only forbids engine->sink).
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/drift.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/idempotency.sh"
# shellcheck source=/dev/null
source "${_plan_apply_dir}/../../engine/story_marker.sh" # R5 steps 4/6 — mark `creating`, stamp + record per ticket
# shellcheck source=/dev/null
source "${_plan_apply_dir}/identity.sh" # stamp the identity marker on each created ticket (R5 step 6)

# plan_writes <neutral-doc-json> <plan-context-json> — resolve the validated
# neutral document into an ordered action set (US3, T058). Each story becomes a
# create OR an update, with logical values resolved to ids (FR-017 priority by
# logical name) and the estimation written to the discovered field ON CREATE ONLY
# (FR-018 — never re-sent on update). The `--dry-run` report is exactly this
# action set (FR-033); no Jira mutation happens here. apply_writes performs it.
#
# plan-context carries the resolved facts the engine cannot know:
#   { base_url, story_type_id, priority_ids:{P1,P2,P3}, estimation_field_id|null,
#     tickets:{<local_id>: <existing-issue-key>},   (a local_id absent => create)
#     ticket_origins:{<local_id>: "bridge-created"|"human"},  (optional, US7)
#     ticket_descriptions:{<local_id>: <existing-adf-doc>} }   (optional, US7)
# When a ticket carries a human origin and its existing description, the update's
# description is rendered through the managed-panel splice so the human-authored
# prose above the panel is preserved verbatim (FR-038); absent that context the
# whole description is bridge-owned (the US3 behaviour, byte-for-byte unchanged).
plan_writes() {
  local doc="$1" ctx="$2"
  local base story_type estid project
  base="$(jq -r '.base_url // ""' <<< "${ctx}")"
  story_type="$(jq -r '.story_type_id // ""' <<< "${ctx}")"
  estid="$(jq -r '.estimation_field_id // ""' <<< "${ctx}")"
  # The payload's project comes from the neutral document's validated
  # routing.project_key — never from the plan context — so it cannot disagree
  # with the run summary's resolved project (research R2, FR-023).
  project="$(jq -r '.routing.project_key // ""' <<< "${doc}")"

  local actions="[]" n i
  n="$(jq '.stories | length' <<< "${doc}")"
  for ((i = 0; i < n; i++)); do
    local story sid title prio est ticket priority_id adf fields action base_fields
    story="$(jq -c ".stories[${i}]" <<< "${doc}")"
    sid="$(jq -r '.local_id' <<< "${story}")"
    title="$(jq -r '.title' <<< "${story}")"
    prio="$(jq -r '.priority_logical' <<< "${story}")"
    est="$(jq -c '.estimation // null' <<< "${story}")"
    ticket="$(jq -r --arg s "${sid}" '.tickets[$s] // ""' <<< "${ctx}")"
    priority_id="$(jq -r --arg p "${prio}" '.priority_ids[$p] // ""' <<< "${ctx}")"
    adf="$(adf_render_description "${story}")"

    if [[ -z "${ticket}" ]]; then
      # FR-024 assembly guard: refuse an incomplete creation BEFORE it is ever
      # emitted, rather than sending it for the destination service to reject.
      if [[ -z "${project}" || -z "${story_type}" ]]; then
        printf 'plan_writes: refusing to assemble a creation for "%s" with no project or issue type (zero writes)\n' "${sid}" >&2
        return 1
      fi
      # CREATE: the shared mandatory base (research R3, FR-025) + description +
      # priority + estimation (create-only). A bridge-created ticket owns its
      # whole description (no delimiter, FR-040).
      base_fields="$(jira_create_fields_base "${project}" "${title}" "${story_type}")"
      fields="$(jq -cn --argjson base "${base_fields}" --argjson d "${adf}" '$base + {description:$d}')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"
      if [[ -n "${estid}" && "${est}" != "null" ]]; then
        fields="$(jq -c --arg fid "${estid}" --argjson v "${est}" '. + {($fid): $v}' <<< "${fields}")"
      fi
      action="$(jq -cn --arg u "${base}/rest/api/3/issue" --argjson f "${fields}" --arg sid "${sid}" \
        '{method:"POST", url:$u, body:{fields:$f}, local_id:$sid}')"
    else
      # UPDATE: content + priority; the estimation is NEVER re-sent (FR-018). On a
      # human-origin ticket the description is spliced into the managed panel so the
      # human prose above it survives (FR-038).
      local origin existing
      origin="$(jq -r --arg s "${sid}" '.ticket_origins[$s] // ""' <<< "${ctx}")"
      if [[ -n "${origin}" && "${origin}" != "bridge-created" ]]; then
        existing="$(jq -c --arg s "${sid}" '.ticket_descriptions[$s] // {}' <<< "${ctx}")"
        adf="$(adf_render_managed_description "${story}" "${origin}" "${existing}")"
      fi
      fields="$(jq -cn --arg t "${title}" --argjson d "${adf}" '{summary:$t, description:$d}')"
      [[ -n "${priority_id}" ]] && fields="$(jq -c --arg pid "${priority_id}" '. + {priority:{id:$pid}}' <<< "${fields}")"
      action="$(jq -cn --arg u "${base}/rest/api/3/issue/${ticket}" --argjson f "${fields}" \
        '{method:"PUT", url:$u, body:{fields:$f}}')"
    fi
    actions="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${actions}")"
  done
  json_canonical <<< "${actions}"
}

# plan_managed_description_status <current-desc-json> <new-desc-json>
#   FR-039: decide description churn on the managed section ALONE. Both descriptions
#   are split at the panel marker and only their managed portions are compared, so a
#   human edit to the prose above the panel never counts as churn. Echoes
#   "unchanged" | "changed".
plan_managed_description_status() {
  local current="$1" new="$2" marker cm nm
  marker="$(adf_managed_marker)"
  cm="$(jq -c '.content // []' <<< "${current}" | managed_section_panel_split "${marker}" | jq -c '.managed')"
  nm="$(jq -c '.content // []' <<< "${new}" | managed_section_panel_split "${marker}" | jq -c '.managed')"
  if [[ "$(json_canonical <<< "${cm}")" == "$(json_canonical <<< "${nm}")" ]]; then
    printf 'unchanged'
  else
    printf 'changed'
  fi
}

# plan_lifecycle <content-actions-json> <neutral-doc-json> <lifecycle-ctx-json>
#   Fold the US6 lifecycle-safety rules over the planned content actions and emit
#   the final action set plus the human-facing warnings/notes. PURE: no Jira reads
#   or writes happen here; the current Jira facts (status, its classification,
#   Flagged marker, open blockers, the transition id) arrive in the lifecycle
#   context — the seam the config/discovery integration fills from a fail-closed
#   read. content-actions[i] corresponds to neutral-doc.stories[i] (plan_writes
#   emits one content action per story, in order).
#
# lifecycle-ctx: { on_drift, base_url, order:[status,...],
#   tickets:{ <local_id>: { key, current:{fields...}, status, category, target,
#                           transition_id, flagged, blockers:[...] } } }
#
# Rules applied per story:
#   - Zero churn (FR-030): an UPDATE whose desired fields already match the
#     ticket's `current` fields is dropped — no content write.
#   - Drift (FR-031/034/035): the drift engine decides the transition. `withhold`
#     suppresses the transition (content still reconciles); `halt` stops every
#     write to the ticket and surfaces the remediations; `transition` emits the
#     transition action. --on-drift=proceed authorises a backward pull.
#   - Flagged (FR-036): a flagged ticket has its transition withheld and the flag
#     surfaced; the bridge never sets or removes the flag (no flag write is emitted).
#   - Human links (FR-037): the bridge emits no link mutation, so human links are
#     never modified; advancing past open blockers adds an info note, not a block.
# Returns { actions, warnings, notes } (canonical).
plan_lifecycle() {
  local actions="$1" doc="$2" lc="$3"
  local on_drift order n i
  on_drift="$(jq -r '.on_drift // "abort"' <<< "${lc}")"
  order="$(jq -c '.order // []' <<< "${lc}")"
  n="$(jq '.stories | length' <<< "${doc}")"

  local kept="[]" warns="[]" notes="[]"
  for ((i = 0; i < n; i++)); do
    local sid action method tk
    sid="$(jq -r ".stories[${i}].local_id" <<< "${doc}")"
    action="$(jq -c ".[${i}] // null" <<< "${actions}")"
    [[ "${action}" == "null" ]] && continue
    method="$(jq -r '.method' <<< "${action}")"
    tk="$(jq -c --arg s "${sid}" '.tickets[$s] // {}' <<< "${lc}")"

    local drop_content="false" do_transition="false"
    # --- Zero churn: drop an unchanged UPDATE ---------------------------------
    if [[ "${method}" == "PUT" ]]; then
      local current
      current="$(jq -c '.current // null' <<< "${tk}")"
      if [[ "${current}" != "null" ]]; then
        local desired origin st
        desired="$(jq -c '.body.fields' <<< "${action}")"
        origin="$(jq -r '.origin // ""' <<< "${tk}")"
        if [[ -n "${origin}" && "${origin}" != "bridge-created" ]]; then
          # FR-039: on a human-origin ticket the description diff is computed on the
          # managed section alone; the other fields compare normally.
          local desc_st other_st cur_desc new_desc cur_rest des_rest
          cur_desc="$(jq -c '.description // {}' <<< "${current}")"
          new_desc="$(jq -c '.description // {}' <<< "${desired}")"
          desc_st="$(plan_managed_description_status "${cur_desc}" "${new_desc}")"
          cur_rest="$(jq -c 'del(.description)' <<< "${current}")"
          des_rest="$(jq -c 'del(.description)' <<< "${desired}")"
          other_st="$(idempotency_field_status "${cur_rest}" "${des_rest}")"
          [[ "${desc_st}" == "unchanged" && "${other_st}" == "unchanged" ]] && drop_content="true"
        else
          st="$(idempotency_field_status "${current}" "${desired}")"
          [[ "${st}" == "unchanged" ]] && drop_content="true"
        fi
      fi
    fi

    # --- Drift / Flagged: decide the transition -------------------------------
    local status target category flagged transition_id key
    status="$(jq -r '.status // ""' <<< "${tk}")"
    target="$(jq -r '.target // ""' <<< "${tk}")"
    category="$(jq -r '.category // "unknown"' <<< "${tk}")"
    flagged="$(jq -r '.flagged // false' <<< "${tk}")"
    transition_id="$(jq -r '.transition_id // ""' <<< "${tk}")"
    key="$(jq -r '.key // ""' <<< "${tk}")"

    if [[ -n "${status}" && -n "${target}" && "${status}" != "${target}" ]]; then
      if [[ "${flagged}" == "true" ]]; then
        warns="$(jq -c --arg w "ticket \"${sid}\" carries the Flagged (impediment) marker; its transition is withheld and the flag is left untouched" '. + [$w]' <<< "${warns}")"
      else
        local di dec d cw dwarns
        di="$(jq -cn --arg cs "${status}" --arg cc "${category}" --arg ts "${target}" --argjson o "${order}" --arg od "${on_drift}" \
          '{current_status:$cs, current_category:$cc, target_status:$ts, order:$o, on_drift:$od}')"
        dec="$(drift_evaluate "${di}")"
        d="$(jq -r '.decision' <<< "${dec}")"
        cw="$(jq -r '.content_writes' <<< "${dec}")"
        dwarns="$(jq -c '.warnings' <<< "${dec}")"
        warns="$(jq -c --argjson dw "${dwarns}" '. + $dw' <<< "${warns}")"
        [[ "${cw}" == "false" ]] && drop_content="true"
        [[ "${d}" == "transition" ]] && do_transition="true"
      fi
    fi

    [[ "${drop_content}" == "false" ]] && kept="$(jq -c --argjson a "${action}" '. + [$a]' <<< "${kept}")"

    if [[ "${do_transition}" == "true" && -n "${transition_id}" && -n "${key}" ]]; then
      local base taction
      base="$(jq -r '.base_url // ""' <<< "${lc}")"
      taction="$(jq -cn --arg u "${base}/rest/api/3/issue/${key}/transitions" --arg tid "${transition_id}" \
        '{method:"POST", url:$u, body:{transition:{id:$tid}}}')"
      kept="$(jq -c --argjson a "${taction}" '. + [$a]' <<< "${kept}")"

      local blockers bcount
      blockers="$(jq -c '.blockers // []' <<< "${tk}")"
      bcount="$(jq 'length' <<< "${blockers}")"
      if [[ "${bcount}" -gt 0 ]]; then
        local blist note
        blist="$(jq -r 'join(", ")' <<< "${blockers}")"
        note="transition of \"${sid}\" proceeds with open blocking links (${blist}); human-created links are left unchanged"
        notes="$(jq -c --arg n "${note}" '. + [$n]' <<< "${notes}")"
      fi
    fi
  done

  jq -cn --argjson a "${kept}" --argjson w "${warns}" --argjson no "${notes}" \
    '{actions:$a, warnings:$w, notes:$no}' | json_canonical
}

# _apply_known_coords <extra-json> — the known-coordinate set the guard checks:
# the real site host derived from SPEC_KIT_JIRA_BASE_URL plus any caller extras.
_apply_known_coords() {
  local extra="${1:-[]}" base="${SPEC_KIT_JIRA_BASE_URL:-}" host=""
  host="$(sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:[0-9]+$##' <<< "${base}")"
  jq -cn --arg h "${host}" --argjson e "${extra}" \
    '($e + (if $h == "" then [] else [$h] end)) | unique'
}

# apply_writes <actions-json> [extra-known-coords-json] — guard every payload,
# then perform the writes in order. Returns EXIT_BLOCK (9) with zero writes if any
# payload is blocked; otherwise returns the worst (highest) transport exit code.
apply_writes() {
  local actions="$1" extra="${2:-[]}"
  local coords allow
  coords="$(_apply_known_coords "${extra}")"
  # The allowlist (US12, FR-053) neutralises allowlisted Confluence links/domains so
  # they never false-block; it is empty unless the caller supplies one out of band.
  allow="${SPEC_KIT_JIRA_ALLOWLIST:-[]}"

  local n
  n="$(jq 'length' <<< "${actions}")"

  # (1) Pre-write gate — scan every content payload before writing anything.
  local i body
  for ((i = 0; i < n; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${actions}")"
    privacy_guard_scan "${body}" "${coords}" "${allow}" || return $?
  done

  # (2) Write pass — all payloads cleared; perform each write in order. A
  # fail-closed transport result (exit >= 2: fail_closed or auth) ABORTS the
  # remaining writes for this spec and is returned verbatim — no further mutation
  # is attempted once a read/write is unreliable (FR-032, monotonic escalation).
  local worst=0 method url rc
  for ((i = 0; i < n; i++)); do
    method="$(jq -r ".[${i}].method" <<< "${actions}")"
    url="$(jq -r ".[${i}].url" <<< "${actions}")"
    body="$(jq -c ".[${i}].body // empty" <<< "${actions}")"
    if [[ -n "${body}" ]]; then
      jira_request "${method}" "${url}" "${body}" > /dev/null
    else
      jira_request "${method}" "${url}" > /dev/null
    fi
    rc=$?
    ((rc > worst)) && worst=${rc}
    ((rc >= 2)) && return "${worst}"
  done
  return "${worst}"
}

# apply_writes_with_recognition <actions-json> <spec-ref-json> <spec-file>
#   [extra-known-coords-json]
#   Mirror of apply_writes's guard-then-write discipline (US11), extended
#   with R5 steps 4 and 6: every story whose action is a creation
#   (`local_id` present on a `POST .../issue` action — plan_writes stamps
#   this) is marked `creating` in spec-file in ONE splice, immediately after
#   the guard and before the first create (step 4, research R5); then, for
#   each ticket actually created, its identity marker is stamped and its
#   `creating` mark is replaced with the recorded key IN spec-file — per
#   ticket, IMMEDIATELY, never batched (step 6): a run interrupted between
#   one create's response and its record leaves every OTHER story's
#   identifier untouched and creatable by the next run.
apply_writes_with_recognition() {
  local actions="$1" spec_ref="$2" spec_file="$3" extra="${4:-[]}"
  local coords allow
  coords="$(_apply_known_coords "${extra}")"
  allow="${SPEC_KIT_JIRA_ALLOWLIST:-[]}"

  local n
  n="$(jq 'length' <<< "${actions}")"

  # (1) Pre-write gate — unchanged: scan every payload before writing anything.
  local i body
  for ((i = 0; i < n; i++)); do
    body="$(jq -c ".[${i}].body // {}" <<< "${actions}")"
    privacy_guard_scan "${body}" "${coords}" "${allow}" || return $?
  done

  # (2) R5 step 4 — mark every planned creation `creating`, one splice.
  local creating_ids
  creating_ids="$(jq -c '[.[] | select(.method=="POST" and (.url|endswith("/issue")) and (.local_id // "") != "") | .local_id]' <<< "${actions}")"
  if [[ "$(jq 'length' <<< "${creating_ids}")" -gt 0 ]]; then
    local current new_content
    current="$(cat "${spec_file}" 2> /dev/null; printf x)"; current="${current%x}"
    new_content="$(printf '%s' "${current}" | story_marker_mark_creating "${creating_ids}"; printf x)"; new_content="${new_content%x}"
    story_marker_write_file "${spec_file}" "${new_content}" > /dev/null
  fi

  # (3) Write pass, in order; a CREATE stamps + records IMMEDIATELY (step 6).
  local worst=0 method url rc resp
  for ((i = 0; i < n; i++)); do
    method="$(jq -r ".[${i}].method" <<< "${actions}")"
    url="$(jq -r ".[${i}].url" <<< "${actions}")"
    body="$(jq -c ".[${i}].body // empty" <<< "${actions}")"
    resp="$(mktemp)"
    if [[ -n "${body}" ]]; then
      jira_request "${method}" "${url}" "${body}" > "${resp}"
    else
      jira_request "${method}" "${url}" > "${resp}"
    fi
    rc=$?
    ((rc > worst)) && worst=${rc}
    if ((rc >= 2)); then
      rm -f "${resp}"
      return "${worst}"
    fi

    if [[ "${method}" == "POST" && "${url}" == */issue ]]; then
      local key local_id
      key="$(jq -r '.key // empty' < "${resp}")"
      local_id="$(jq -r ".[${i}].local_id // empty" <<< "${actions}")"
      if [[ -n "${key}" && -n "${local_id}" ]]; then
        identity_write "${key}" "${spec_ref}" "bridge" "${local_id}" || true
        local cur new
        cur="$(cat "${spec_file}" 2> /dev/null; printf x)"; cur="${cur%x}"
        new="$(printf '%s' "${cur}" | story_marker_record_ticket "${local_id}" "${key}"; printf x)"; new="${new%x}"
        story_marker_write_file "${spec_file}" "${new}" > /dev/null
      fi
    fi
    rm -f "${resp}"
  done
  return "${worst}"
}
