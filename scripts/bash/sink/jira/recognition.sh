#!/usr/bin/env bash
# sink/jira/recognition.sh — Recognise the tickets reconcile already created
# (Phase 3, US1; contracts/recognition-contract.md).
#
# Reads each story's recorded ticket BY KEY (research R2 — never search: Jira's
# index is eventually consistent, and this is the reported defect's exact
# window), folds the identity marker returned by the SAME request into a
# verification decision, and returns {bound, new, blocked} for the command
# layer to split into the plan and lifecycle contexts. A read failure is NEVER
# downgraded to "no ticket exists" (FR-004) — an inconclusive read fails the
# WHOLE specification closed; a marker mismatch/duplicate/malformed marker
# blocks only the story it names (FR-011, FR-016, FR-021).
#
# 021, US4: a bulk PREFETCH (prefetch.sh) may satisfy this read instead of a
# per-key GET, but it is never a search — it is addressed by the SAME keys
# research R2 already committed to, is optional (a miss falls through to
# today's GET unchanged, contracts/recognition-prefetch.md §3), and never
# changes a classification, only how many requests reach it. The eventual-
# consistency risk R2 exists to avoid is a QUERY finding a stale index, not a
# key-addressed read finding a stale one — bulkfetch is documented to resolve
# a key exactly as its single-issue counterpart does, so batching it costs
# nothing here that batching a search would have.

[[ -n ${_JIRA_SINK_RECOGNITION:-} ]] && return 0
_JIRA_SINK_RECOGNITION=1

_recognition_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_recognition_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_recognition_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_recognition_dir}/client.sh"
# shellcheck source=/dev/null
source "${_recognition_dir}/prefetch.sh"

: "${SPEC_KIT_JIRA_IDENTITY_KEY:=spec-kit-jira}"

# _recognition_read <key> [extra-fields-csv] — consults the prefetch (021,
# US4; contracts/recognition-prefetch.md §3) first; on a hit its own
# projected result is printed and no request is made. On a miss (never
# populated, chunk failure, or _RECOGNITION_NO_PREFETCH set — test seam,
# underscore-prefixed and absent from the CLI contract) falls through to
# today's GET UNCHANGED, folding the identity property into the issue fetch
# (research R3). Prints canonical JSON on success: {"gone":false,
# "marker":<marker-or-null>,"fields":{...}}, or {"gone":true} on a 404 (the
# ticket no longer exists — not a failure; a prefetch hit can never express
# this, so a deleted/forbidden key ALWAYS falls through here). Any other
# transport failure returns the mapped exit code, zero stdout (fail-closed,
# Constitution III).
_recognition_read() {
  local key="$1" extra="${2:-}" base url fields_param resp rc tmp hit
  # Flagged (FR-036): requested by its literal display name, matching the
  # ["Flagged"] lookup below — every story/task read needs it, so it belongs
  # in the fixed set rather than a per-caller extra.
  fields_param="summary,description,priority,status,issuelinks,parent,labels,Flagged"
  [[ -n "${extra}" ]] && fields_param="${fields_param},${extra}"
  if [[ -z "${_RECOGNITION_NO_PREFETCH:-}" ]]; then
    if hit="$(prefetch_get "${key}" "${fields_param}")"; then
      printf '%s' "${hit}"
      return 0
    fi
  fi
  base="${SPEC_KIT_JIRA_BASE_URL:-}"
  url="${base}/rest/api/3/issue/${key}?properties=${SPEC_KIT_JIRA_IDENTITY_KEY}&fields=${fields_param}"
  tmp="$(mktemp)"
  jira_request GET "${url}" > "${tmp}"
  rc=$?
  resp="$(cat "${tmp}")"
  rm -f "${tmp}"
  if ((rc == 0)); then
    jq -c --arg k "${SPEC_KIT_JIRA_IDENTITY_KEY}" \
      '{gone:false, marker:(.properties[$k] // null), fields:(.fields // {})}' <<< "${resp}" | json_canonical
    return 0
  fi
  if [[ "${JIRA_LAST_STATUS:-}" == "404" ]]; then
    printf '{"gone":true}'
    return 0
  fi
  return "${rc}"
}

# _recognition_project_of <issue-key> — the project-key prefix of an issue key.
_recognition_project_of() {
  printf '%s' "${1%%-*}"
}

# _recognition_read_parent <key> — one GET folding the identity property
# into the issue fetch. 023, research R6: the field projection widens from
# summary,description,labels to also carry status, issuelinks and Flagged —
# every safety rule FR-021 requires the parent to be evaluated against. The
# prefetch's requested union already carries all three
# (sink/jira/prefetch.sh:26), so only this reader's own projection changes;
# the bulk request itself is unchanged. Prints canonical JSON on success:
# {"gone":false,"marker":<marker-or-null>,"fields":{...}}, or {"gone":true}
# on a 404. Any other transport failure returns the mapped exit code, zero
# stdout (fail-closed, Constitution III).
_recognition_read_parent() {
  local key="$1" base url resp rc tmp hit
  if [[ -z "${_RECOGNITION_NO_PREFETCH:-}" ]]; then
    if hit="$(prefetch_get "${key}" "summary,description,labels,status,issuelinks,Flagged")"; then
      printf '%s' "${hit}"
      return 0
    fi
  fi
  base="${SPEC_KIT_JIRA_BASE_URL:-}"
  url="${base}/rest/api/3/issue/${key}?properties=${SPEC_KIT_JIRA_IDENTITY_KEY}&fields=summary,description,labels,status,issuelinks,Flagged"
  tmp="$(mktemp)"
  jira_request GET "${url}" > "${tmp}"
  rc=$?
  resp="$(cat "${tmp}")"
  rm -f "${tmp}"
  if ((rc == 0)); then
    jq -c --arg k "${SPEC_KIT_JIRA_IDENTITY_KEY}" \
      '{gone:false, marker:(.properties[$k] // null), fields:(.fields // {})}' <<< "${resp}" | json_canonical
    return 0
  fi
  if [[ "${JIRA_LAST_STATUS:-}" == "404" ]]; then
    printf '{"gone":true}'
    return 0
  fi
  return "${rc}"
}

# recognition_parent_run <marker-info-json> <spec-ref-json> <project-key>
#   <spec-path>
#   marker-info-json: {state, id, ticket?, lines} — spec_marker_document_info's
#   own shape (data-model.md §1 "epic.marker").
#   Prints on success:
#     {"state":"new"}
#     {"state":"new", "recreated_from":{"key":".."}}       — a recorded key returned 404
#     {"state":"bound", "key":"..", "current":{...}}
#     {"state":"blocked", "reason":"..", "detail":".."}
#   Returns a transport exit code (>=2) with ZERO stdout when the bound read
#   is inconclusive — the whole specification fails closed (contract §7:
#   "An inconclusive read is never downgraded to 'no parent exists'").
recognition_parent_run() {
  local minfo="$1" spec_ref="$2" project="$3" spec_path="$4"
  local state; state="$(jq -r '.state' <<< "${minfo}")"

  case "${state}" in
    absent | assigned)
      jq -cn '{state:"new"}' | json_canonical
      return 0
      ;;
    creating)
      local id; id="$(jq -r '.id' <<< "${minfo}")"
      jq -cn --arg r "parent-key-unrecorded" \
        --arg d "${spec_path} marks its parent \`creating\`: a previous run was interrupted after creating the parent and before recording its key, so whether it exists cannot be determined. Find the issue carrying identifier ${id} in project ${project} and record it as \`<!-- speckit-jira spec=${id} ticket=<KEY> -->\`, or delete \`creating\` to mirror a new parent." \
        '{state:"blocked", reason:$r, detail:$d}' | json_canonical
      return 0
      ;;
    malformed)
      local line; line="$(jq -r '.lines[0] // 0' <<< "${minfo}")"
      jq -cn --arg r "parent-marker-malformed" \
        --arg d "${spec_path} line ${line}: malformed speckit-jira parent marker; nothing was written for this specification. Expected \`<!-- speckit-jira spec=<16 hex> ticket=<KEY> -->\`." \
        '{state:"blocked", reason:$r, detail:$d}' | json_canonical
      return 0
      ;;
    duplicate)
      local lines_csv count
      lines_csv="$(jq -r '.lines | join(", ")' <<< "${minfo}")"
      count="$(jq -r '.lines | length' <<< "${minfo}")"
      jq -cn --arg r "parent-marker-duplicate" \
        --arg d "${spec_path} carries ${count} speckit-jira parent markers (lines ${lines_csv}); a specification has exactly one parent. Keep the line naming the parent that exists in Jira and delete the others." \
        '{state:"blocked", reason:$r, detail:$d}' | json_canonical
      return 0
      ;;
    bound)
      local key; key="$(jq -r '.ticket' <<< "${minfo}")"
      local read_result rc=0
      read_result="$(_recognition_read_parent "${key}")" || rc=$?
      ((rc != 0)) && return "${rc}"

      local gone; gone="$(jq -r '.gone' <<< "${read_result}")"
      if [[ "${gone}" == "true" ]]; then
        jq -cn --arg k "${key}" '{state:"new", recreated_from:{key:$k}}' | json_canonical
        return 0
      fi

      local marker; marker="$(jq -c '.marker' <<< "${read_result}")"
      if [[ "${marker}" == "null" ]]; then
        jq -cn --arg r "parent-identity-unverifiable" \
          --arg d "${key} is recorded as the parent of ${spec_path} but carries no spec-kit-jira parent identity; nothing was written. The bridge never adopts a ticket it did not create — clear the ticket= value to create a new parent, or restore the identity by hand." \
          '{state:"blocked", reason:$r, detail:$d}' | json_canonical
        return 0
      fi

      local role; role="$(jq -r '.role // ""' <<< "${marker}")"
      if [[ "${role}" != "parent" ]]; then
        jq -cn --arg r "parent-identity-unverifiable" \
          --arg d "${key} is recorded as the parent of ${spec_path} but carries no spec-kit-jira parent identity; nothing was written. The bridge never adopts a ticket it did not create — clear the ticket= value to create a new parent, or restore the identity by hand." \
          '{state:"blocked", reason:$r, detail:$d}' | json_canonical
        return 0
      fi

      local repo slug m_repo m_slug
      repo="$(jq -r '.repo // ""' <<< "${spec_ref}")"
      slug="$(jq -r '.spec_slug // ""' <<< "${spec_ref}")"
      m_repo="$(jq -r '.repo // ""' <<< "${marker}")"
      m_slug="$(jq -r '.spec_slug // ""' <<< "${marker}")"
      if [[ "${m_repo}" != "${repo}" || "${m_slug}" != "${slug}" ]]; then
        jq -cn --arg other "${m_slug}" --arg r "parent-claimed-by-other" \
          --arg d "${key} is recorded as the parent of ${spec_path} but its identity names specification ${m_slug}; nothing was written. Correct the ticket= value, or clear it to create a new parent." \
          '{state:"blocked", reason:$r, detail:$d}' | json_canonical
        return 0
      fi

      local fields current origin last_summary status status_category flagged blockers
      fields="$(jq -c '.fields' <<< "${read_result}")"
      current="$(jq -c '{summary:(.summary // ""), description:(.description // {}), labels:((.labels // []) | unique)}' <<< "${fields}")"
      origin="$(jq -r '.origin // "bridge"' <<< "${marker}")"
      # last_summary (018, T044; contracts/summary-record.md §1/§5: every
      # tier, including the parent) — from the same already-fetched marker.
      last_summary="$(jq -r '.summary // empty' <<< "${marker}")"
      # 023, research R6: status/status_category/flagged/blockers, the same
      # shape a story's bound entry already carries — what makes the parent
      # evaluable by the SAME lifecycle-safety body a story already runs
      # through (FR-021).
      status="$(jq -r '.status.name // ""' <<< "${fields}")"
      status_category="$(jq -r '.status.statusCategory.key // ""' <<< "${fields}")"
      flagged="$(jq -r 'if ((.["Flagged"]? // []) | length) > 0 then true else false end' <<< "${fields}")"
      blockers="$(jq -c '[(.issuelinks // [])[] | select(.type.inward? and .inwardIssue?) | .inwardIssue.key]' <<< "${fields}")"
      jq -cn --arg k "${key}" --argjson c "${current}" --arg o "${origin}" --arg ls "${last_summary}" \
        --arg st "${status}" --arg sc "${status_category}" --argjson fl "${flagged}" --argjson bl "${blockers}" \
        '{state:"bound", key:$k, current:$c, origin:$o, status:$st, status_category:$sc, flagged:$fl, blockers:$bl}
         + (if $ls == "" then {} else {last_summary:$ls} end)' | json_canonical
      return 0
      ;;
  esac
}

# recognition_run <stories-json> <spec-ref-json> <project-key> <spec-path>
#   [kind]
#   stories-json: [{local_id, marker:{state,id,ticket?,lines?}}, ...] — the
#     slim per-story marker view sliced from the parsed document.
#   spec-ref-json: {repo, spec_slug, folder}
#   project-key: the routed project (US3, FR-019 scoping)
#   spec-path: repository-relative path to spec.md, for diagnostics.
#   kind: the noun (and marker grammar prefix) used in diagnostics — "story"
#     by default, unchanged from every existing call site. Phase 2, T029/T030
#     fold the task tier into this SAME function by calling it a second time
#     with kind="task": recognition is on exactly the same terms as a story
#     (contract §"Recognising a sub-task that already exists") — reusing the
#     function rather than duplicating it is what makes that guarantee hold
#     by construction rather than by two implementations staying in sync.
#
# Prints the recognition result on success:
#   {"bound":{<id>:{key,origin,current,status,flagged,blockers}}, "new":[ids],
#    "blocked":[{story,reason,detail}],
#    "rerouted":{<id>:{former_key,former_project}}}
#   rerouted entries are also present in `new` (the story IS mirrored, into the
#   routed project); the command layer uses the extra detail to emit the
#   catalogued `re-routed` notice once the new key is recorded (T071).
# Returns a transport exit code (>=2) with ZERO stdout when any read is
# inconclusive — the whole specification fails closed (research R2/R3,
# contract "The read").
recognition_run() {
  local stories="$1" spec_ref="$2" project="$3" spec_path="$4" kind="${5:-story}"
  local repo
  repo="$(jq -r '.repo // ""' <<< "${spec_ref}")"

  # 024, contracts/spawn-budget.md C1.2/C1.3: the three loops below each used
  # to re-read `.local_id` / `.marker.state` / `.marker.lines` / `.marker.ticket`
  # off `stories` with their OWN `jq` call per item — the read is native
  # accumulation once instead: one `jq -r … | @tsv` call for the WHOLE array,
  # decoded into parallel bash arrays, so every loop below indexes memory
  # rather than forking. `new`/`blocked`/`bound`/`rerouted` are collected the
  # same way `_parse_lines_to_json` (024, T026) collects lines — bash arrays
  # of already-JSON fragments, joined with ONE `jq -cs` at the very end —
  # rather than a `. + […]`/`. + {…}` merge re-parsed on every append (O(n²)
  # data movement, and one process per append).
  # A literal tab (`@tsv`, `IFS=$'\t'`) is bash-IFS *whitespace*: consecutive
  # delimiters are squeezed into one, so an empty field (no ticket, no
  # duplicate lines — the common case) silently shifts every field after it.
  # The unit separator is not whitespace, so `read` preserves empty fields.
  local _tsv_sep=$'\x1f'
  local -a _rid=() _rstate=() _rlines0=() _rlinescsv=() _rticket=()
  local _tsv_i=0 _tsv_id _tsv_state _tsv_lines0 _tsv_linescsv _tsv_ticket
  while IFS="${_tsv_sep}" read -r _tsv_id _tsv_state _tsv_lines0 _tsv_linescsv _tsv_ticket; do
    _rid[_tsv_i]="${_tsv_id}"
    _rstate[_tsv_i]="${_tsv_state}"
    _rlines0[_tsv_i]="${_tsv_lines0}"
    _rlinescsv[_tsv_i]="${_tsv_linescsv}"
    _rticket[_tsv_i]="${_tsv_ticket}"
    _tsv_i=$((_tsv_i + 1))
  done < <(jq -r --arg sep "${_tsv_sep}" '.[] | [
      .local_id,
      (.marker.state // "absent"),
      ((.marker.lines[0] // 0) | tostring),
      ((.marker.lines // []) | join(", ")),
      (.marker.ticket // "")
    ] | join($sep)' <<< "${stories}")
  local n="${_tsv_i}"
  local all_ids; all_ids="$(jq -c '[.[].local_id]' <<< "${stories}")"

  local -a blocked_items=() new_items=() bound_frags=() rerouted_frags=()
  local i

  # --- Parse-level marker problems: malformed / duplicate-in-section -------
  for ((i = 0; i < n; i++)); do
    case "${_rstate[i]}" in
      malformed)
        blocked_items+=("$(jq -cn --arg s "${_rid[i]}" --arg r "marker-malformed" \
          --arg d "${spec_path} line ${_rlines0[i]}: malformed speckit-jira marker; nothing was written for that ${kind}. Expected \`<!-- speckit-jira ${kind}=<16 hex> ticket=<KEY> -->\`." \
          '{story:$s, reason:$r, detail:$d}')")
        ;;
      duplicate)
        blocked_items+=("$(jq -cn --arg s "${_rid[i]}" --arg r "duplicate-claim" \
          --arg d "${kind^} identifier ${_rid[i]} appears on 2 ${kind}s in ${spec_path} (lines ${_rlinescsv[i]}); nothing was written for any of them. Give each ${kind} its own marker line, or delete the duplicates to have them mirrored as new tickets." \
          '{story:$s, reason:$r, detail:$d}')")
        ;;
    esac
  done

  # --- New (assigned, no ticket yet) and creating (fail-closed window) -----
  for ((i = 0; i < n; i++)); do
    case "${_rstate[i]}" in
      assigned)
        new_items+=("${_rid[i]}")
        ;;
      creating)
        blocked_items+=("$(jq -cn --arg s "${_rid[i]}" --arg r "key-unrecorded" \
          --arg d "${kind^} ${_rid[i]} in ${spec_path} is marked \`creating\`: a previous run was interrupted after creating its ticket and before recording the key, so whether a ticket exists cannot be determined. Check the project for a ticket carrying that identifier and record it as \`<!-- speckit-jira ${kind}=${_rid[i]} ticket=<KEY> -->\`, or replace \`creating\` with nothing to mirror the ${kind} as a new ticket." \
          '{story:$s, reason:$r, detail:$d}')")
        ;;
    esac
  done

  # --- Bound stories: cross-story duplicate-claim on identifier or key -----
  local -a bound_idx=()
  for ((i = 0; i < n; i++)); do
    [[ "${_rstate[i]}" == "bound" ]] && bound_idx+=("${i}")
  done

  # Duplicate KEY: two+ bound stories recording the same ticket key — a plain
  # bash tally over the already-decoded tickets rather than a `group_by` jq
  # call re-reading `stories`.
  local -A _ticket_count=()
  for i in "${bound_idx[@]}"; do
    _ticket_count["${_rticket[i]}"]=$(( ${_ticket_count["${_rticket[i]}"]:-0} + 1 ))
  done

  for i in "${bound_idx[@]}"; do
    local id="${_rid[i]}" key="${_rticket[i]}"

    if (( ${_ticket_count[${key}]:-0} > 1 )); then
      blocked_items+=("$(jq -cn --arg s "${id}" --arg r "duplicate-claim" \
        --arg d "Ticket ${key} is recorded for more than one ${kind} in ${spec_path}; nothing was written for any of them. Give each ${kind} its own ticket, or correct the ticket= value." \
        '{story:$s, reason:$r, detail:$d}')")
      continue
    fi

    # A recorded key whose project differs from the routed one: mirror into
    # the routed project instead (US3, Phase 5) — treated as NEW, former
    # ticket left untouched. Recorded here so the command layer can emit the
    # catalogued `re-routed` notice once the new key is known (T071).
    local _key_proj; _key_proj="$(_recognition_project_of "${key}")"
    if [[ -n "${project}" ]] && [[ "${_key_proj}" != "${project}" ]]; then
      new_items+=("${id}")
      rerouted_frags+=("$(jq -cn --arg s "${id}" --arg fk "${key}" --arg fp "${_key_proj}" \
        '{($s): {former_key:$fk, former_project:$fp}}')")
      continue
    fi

    local read_result rc=0 read_extra=""
    # subtasks (T073, FR-021): fetched only for story-kind reads — the
    # orphan/re-attribution check reconcile.sh runs against a story's
    # Jira-side children needs this; the task tier itself has no children of
    # its own to compare against.
    [[ "${kind}" == "story" ]] && read_extra="subtasks"
    read_result="$(_recognition_read "${key}" "${read_extra}")" || rc=$?
    if ((rc != 0)); then
      return "${rc}"
    fi

    local gone; gone="$(jq -r '.gone' <<< "${read_result}")"
    if [[ "${gone}" == "true" ]]; then
      new_items+=("${id}")
      continue
    fi

    local marker; marker="$(jq -c '.marker' <<< "${read_result}")"
    if [[ "${marker}" == "null" ]]; then
      blocked_items+=("$(jq -cn --arg s "${id}" --arg k "${key}" --arg r "marker-mismatch" \
        --arg d "Ticket ${key} recorded for ${kind} ${id} in ${spec_path} does not carry that ${kind}'s identity marker; nothing was written to it. Correct the ticket= value in ${spec_path}, or delete the marker line to mirror the ${kind} as a new ticket." \
        '{story:$s, reason:$r, detail:$d}')")
      continue
    fi

    # One combined read (024, C1.2/C1.3) — `story`/`repo`/`spec_slug` for the
    # verification below, `origin`/`summary`/`checklist` for the bound entry
    # further down, all off the SAME already-fetched marker object, which
    # used to cost up to five separate `jq -r` calls.
    local m_story m_repo m_slug m_origin m_last_summary m_last_checklist
    IFS="${_tsv_sep}" read -r m_story m_repo m_slug m_origin m_last_summary m_last_checklist \
      < <(jq -r --arg sep "${_tsv_sep}" '[(.story // ""), (.repo // ""), (.spec_slug // ""), (.origin // "bridge"), (.summary // ""), (.checklist // "")] | join($sep)' <<< "${marker}")

    # Decision order (first match wins, per contracts/recognition-contract.md
    # "Marker verification — decision table"): a marker with no `story` field
    # at all is always marker-mismatch, regardless of repo/spec_slug; THEN
    # repo is checked — claimed-by-other applies even when `story` happens to
    # equal this id, since it is the more fundamental "is this ticket even
    # for this repository" question. spec_slug is deliberately NOT part of
    # this check (US3, FR-017/FR-018): it is derived from the specification
    # FOLDER's name, which a rename changes — the durable `story` identifier,
    # unique per specification by construction (16 random hex characters), is
    # what recognition-contract.md's decision table's `spec_slug=P` actually
    # protects against, and it does so without breaking on a rename. Only
    # once repo agrees does a non-matching `story` resolve to orphan or
    # marker-mismatch.
    if [[ -z "${m_story}" ]]; then
      blocked_items+=("$(jq -cn --arg s "${id}" --arg k "${key}" --arg r "marker-mismatch" \
        --arg d "Ticket ${key} recorded for ${kind} ${id} in ${spec_path} does not carry that ${kind}'s identity marker; nothing was written to it. Correct the ticket= value in ${spec_path}, or delete the marker line to mirror the ${kind} as a new ticket." \
        '{story:$s, reason:$r, detail:$d}')")
      continue
    fi

    if [[ "${m_repo}" != "${repo}" ]]; then
      blocked_items+=("$(jq -cn --arg s "${id}" --arg k "${key}" --arg other "${m_slug}" --arg r "claimed-by-other" \
        --arg d "Ticket ${key} recorded for ${kind} ${id} in ${spec_path} is claimed by specification ${m_slug}; nothing was written to it. Correct the ticket= value in ${spec_path}, or reconcile that specification instead." \
        '{story:$s, reason:$r, detail:$d}')")
      continue
    fi

    if [[ "${m_story}" != "${id}" ]]; then
      if ! jq -e --arg mid "${m_story}" 'index($mid) != null' <<< "${all_ids}" > /dev/null 2>&1; then
        blocked_items+=("$(jq -cn --arg s "${id}" --arg k "${key}" --arg other "${m_story}" --arg r "orphan" \
          --arg d "Ticket ${key} recorded in ${spec_path} carries ${kind} identifier ${m_story}, which no ${kind} in ${spec_path} claims; nothing was written to it. Restore ${m_story} as that ${kind}'s identifier with \`<!-- speckit-jira ${kind}=${m_story} ticket=${key} -->\`, or delete the marker line to mirror the ${kind} as a new ticket and close ${key} in Jira." \
          '{story:$s, reason:$r, detail:$d}')")
      else
        blocked_items+=("$(jq -cn --arg s "${id}" --arg k "${key}" --arg r "marker-mismatch" \
          --arg d "Ticket ${key} recorded for story ${id} in ${spec_path} does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in ${spec_path}, or delete the marker line to mirror the story as a new ticket." \
          '{story:$s, reason:$r, detail:$d}')")
      fi
      continue
    fi

    # Bound: recognised. current/status/status_category/flagged/blockers
    # feed the plan and lifecycle contexts (Phase 4/6). One `jq` call builds
    # the whole keyed entry off `read_result`/`marker` — the nine-plus reads
    # (fields, origin, last_summary, current, status, status_category,
    # flagged, blockers, subtasks, last_checklist, the entry assembly, and
    # the keyed-merge wrap) this replaces are algebraically the same filter,
    # just evaluated by one process instead of a dozen (024, C1.2/C1.3;
    # verified byte-identical against the pre-024 per-field form before this
    # landed).
    bound_frags+=("$(jq -c --arg k "${key}" --arg o "${m_origin}" --arg ls "${m_last_summary}" --arg lc "${m_last_checklist}" --arg id "${id}" '
      .fields as $f
      | {
          ($id): (
            {
              key: $k,
              origin: $o,
              current: {
                summary: ($f.summary // ""),
                description: ($f.description // {}),
                priority: ($f.priority // null),
                parent: ($f.parent.key // null),
                labels: (($f.labels // []) | unique)
              },
              status: ($f.status.name // ""),
              status_category: ($f.status.statusCategory.key // ""),
              flagged: (if (($f["Flagged"]? // []) | length) > 0 then true else false end),
              blockers: [($f.issuelinks // [])[] | select(.type.inward? and .inwardIssue?) | .inwardIssue.key],
              subtasks: [($f.subtasks // [])[] | {key, issuetype_id: (.fields.issuetype.id // null)}]
            }
            + (if $ls == "" then {} else {last_summary: $ls} end)
            + (if $lc == "" then {} else {last_checklist: $lc} end)
          )
        }
    ' <<< "${read_result}")")
  done

  local bound="{}" new="[]" blocked="[]" rerouted="{}"
  ((${#bound_frags[@]} > 0)) && bound="$(printf '%s\n' "${bound_frags[@]}" | jq -cs 'add')"
  ((${#new_items[@]} > 0)) && new="$(printf '%s\n' "${new_items[@]}" | jq -Rn -c '[inputs]')"
  ((${#blocked_items[@]} > 0)) && blocked="$(printf '%s\n' "${blocked_items[@]}" | jq -cs '.')"
  ((${#rerouted_frags[@]} > 0)) && rerouted="$(printf '%s\n' "${rerouted_frags[@]}" | jq -cs 'add')"

  # 024, T053 real-machine finding: each of these four grows with story
  # count, and Linux caps a SINGLE jq argument at MAX_ARG_STRLEN (128 KiB)
  # independently of the much larger total ARG_MAX (the same class of
  # defect research/#31 first fixed, at different call sites — see
  # lib/output.sh's `json_build`, which routes each value through a temp
  # file instead of argv). Captured, not piped straight into json_canonical:
  # on an empty input jq writes nothing and exits 0, so a json_build failure
  # would be swallowed (matches plan_apply.sh's own call sites).
  local _result
  # shellcheck disable=SC2016  # a jq filter: $b/$nw/$bl/$rr are jq variables
  _result="$(json_build '{bound:$b, new:$nw, blocked:$bl, rerouted:$rr}' \
    b "${bound}" nw "${new}" bl "${blocked}" rr "${rerouted}")" || return $?
  json_canonical <<< "${_result}"
}
