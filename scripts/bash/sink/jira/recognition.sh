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

[[ -n ${_JIRA_SINK_RECOGNITION:-} ]] && return 0
_JIRA_SINK_RECOGNITION=1

_recognition_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_recognition_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_recognition_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_recognition_dir}/client.sh"

: "${SPEC_KIT_JIRA_IDENTITY_KEY:=spec-kit-jira}"

# _recognition_read <key> [extra-fields-csv] — one GET folding the identity
# property into the issue fetch (research R3). Prints canonical JSON on
# success: {"gone":false,"marker":<marker-or-null>,"fields":{...}}, or
# {"gone":true} on a 404 (the ticket no longer exists — not a failure). Any
# other transport failure returns the mapped exit code, zero stdout
# (fail-closed, Constitution III).
_recognition_read() {
  local key="$1" extra="${2:-}" base url fields_param resp rc tmp
  base="${SPEC_KIT_JIRA_BASE_URL:-}"
  fields_param="summary,description,priority,status,issuelinks"
  [[ -n "${extra}" ]] && fields_param="${fields_param},${extra}"
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

# recognition_run <stories-json> <spec-ref-json> <project-key> <spec-path>
#   stories-json: [{local_id, marker:{state,id,ticket?,lines?}}, ...] — the
#     slim per-story marker view sliced from the parsed document.
#   spec-ref-json: {repo, spec_slug, folder}
#   project-key: the routed project (US3, FR-019 scoping)
#   spec-path: repository-relative path to spec.md, for diagnostics.
#
# Prints the recognition result on success:
#   {"bound":{<id>:{key,origin,current,status,flagged,blockers}}, "new":[ids],
#    "blocked":[{story,reason,detail}]}
# Returns a transport exit code (>=2) with ZERO stdout when any read is
# inconclusive — the whole specification fails closed (research R2/R3,
# contract "The read").
recognition_run() {
  local stories="$1" spec_ref="$2" project="$3" spec_path="$4"
  local repo
  repo="$(jq -r '.repo // ""' <<< "${spec_ref}")"

  local bound="{}" new="[]" blocked="[]"
  local all_ids; all_ids="$(jq -c '[.[].local_id]' <<< "${stories}")"

  # --- Parse-level marker problems: malformed / duplicate-in-section -------
  local n i
  n="$(jq 'length' <<< "${stories}")"
  for ((i = 0; i < n; i++)); do
    local st id state
    st="$(jq -c ".[${i}]" <<< "${stories}")"
    id="$(jq -r '.local_id' <<< "${st}")"
    state="$(jq -r '.marker.state // "absent"' <<< "${st}")"
    case "${state}" in
      malformed)
        local lines; lines="$(jq -r '.marker.lines[0] // 0' <<< "${st}")"
        blocked="$(jq -c --arg s "${id}" --arg r "marker-malformed" \
          --arg d "${spec_path} line ${lines}: malformed speckit-jira marker; nothing was written for that story. Expected \`<!-- speckit-jira story=<16 hex> ticket=<KEY> -->\`." \
          '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
        ;;
      duplicate)
        local lines_csv; lines_csv="$(jq -r '.marker.lines | join(", ")' <<< "${st}")"
        local dup_id; dup_id="$(jq -r '.local_id' <<< "${st}")"
        blocked="$(jq -c --arg s "${dup_id}" --arg r "duplicate-claim" \
          --arg d "Story identifier ${dup_id} appears on 2 user stories in ${spec_path} (lines ${lines_csv}); nothing was written for any of them. Give each story its own marker line, or delete the duplicates to have them mirrored as new tickets." \
          '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
        ;;
    esac
  done

  # --- New (assigned, no ticket yet) and creating (fail-closed window) -----
  for ((i = 0; i < n; i++)); do
    local st id state
    st="$(jq -c ".[${i}]" <<< "${stories}")"
    id="$(jq -r '.local_id' <<< "${st}")"
    state="$(jq -r '.marker.state // "absent"' <<< "${st}")"
    case "${state}" in
      assigned)
        new="$(jq -c --arg s "${id}" '. + [$s]' <<< "${new}")"
        ;;
      creating)
        blocked="$(jq -c --arg s "${id}" --arg r "key-unrecorded" \
          --arg d "Story ${id} in ${spec_path} is marked \`creating\`: a previous run was interrupted after creating its ticket and before recording the key, so whether a ticket exists cannot be determined. Check the project for a ticket carrying that identifier and record it as \`<!-- speckit-jira story=${id} ticket=<KEY> -->\`, or replace \`creating\` with nothing to mirror the story as a new ticket." \
          '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
        ;;
    esac
  done

  # --- Bound stories: cross-story duplicate-claim on identifier or key -----
  local -a bound_idx=()
  for ((i = 0; i < n; i++)); do
    local state; state="$(jq -r ".[${i}].marker.state // \"absent\"" <<< "${stories}")"
    [[ "${state}" == "bound" ]] && bound_idx+=("${i}")
  done

  # Duplicate KEY: two+ bound stories recording the same ticket key.
  local dup_keys; dup_keys="$(jq -c '[.[] | select(.marker.state=="bound") | .marker.ticket] | group_by(.) | map(select(length>1)) | flatten | unique' <<< "${stories}")"

  for i in "${bound_idx[@]}"; do
    local st id key
    st="$(jq -c ".[${i}]" <<< "${stories}")"
    id="$(jq -r '.local_id' <<< "${st}")"
    key="$(jq -r '.marker.ticket' <<< "${st}")"

    if jq -e --arg k "${key}" 'index($k) != null' <<< "${dup_keys}" > /dev/null 2>&1; then
      blocked="$(jq -c --arg s "${id}" --arg r "duplicate-claim" \
        --arg d "Ticket ${key} is recorded for more than one story in ${spec_path}; nothing was written for any of them. Give each story its own ticket, or correct the ticket= value." \
        '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
      continue
    fi

    # A recorded key whose project differs from the routed one: mirror into
    # the routed project instead (US3, Phase 5) — treated as NEW, former
    # ticket left untouched.
    if [[ -n "${project}" ]] && [[ "$(_recognition_project_of "${key}")" != "${project}" ]]; then
      new="$(jq -c --arg s "${id}" '. + [$s]' <<< "${new}")"
      continue
    fi

    local read_result rc=0
    read_result="$(_recognition_read "${key}")" || rc=$?
    if ((rc != 0)); then
      return "${rc}"
    fi

    local gone; gone="$(jq -r '.gone' <<< "${read_result}")"
    if [[ "${gone}" == "true" ]]; then
      new="$(jq -c --arg s "${id}" '. + [$s]' <<< "${new}")"
      continue
    fi

    local marker; marker="$(jq -c '.marker' <<< "${read_result}")"
    if [[ "${marker}" == "null" ]]; then
      blocked="$(jq -c --arg s "${id}" --arg k "${key}" --arg r "marker-mismatch" \
        --arg d "Ticket ${key} recorded for story ${id} in ${spec_path} does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in ${spec_path}, or delete the marker line to mirror the story as a new ticket." \
        '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
      continue
    fi

    local m_story m_repo m_slug
    m_story="$(jq -r '.story // ""' <<< "${marker}")"
    m_repo="$(jq -r '.repo // ""' <<< "${marker}")"
    m_slug="$(jq -r '.spec_slug // ""' <<< "${marker}")"

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
      blocked="$(jq -c --arg s "${id}" --arg k "${key}" --arg r "marker-mismatch" \
        --arg d "Ticket ${key} recorded for story ${id} in ${spec_path} does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in ${spec_path}, or delete the marker line to mirror the story as a new ticket." \
        '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
      continue
    fi

    if [[ "${m_repo}" != "${repo}" ]]; then
      blocked="$(jq -c --arg s "${id}" --arg k "${key}" --arg other "${m_slug}" --arg r "claimed-by-other" \
        --arg d "Ticket ${key} recorded for story ${id} in ${spec_path} is claimed by specification ${m_slug}; nothing was written to it. Correct the ticket= value in ${spec_path}, or reconcile that specification instead." \
        '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
      continue
    fi

    if [[ "${m_story}" != "${id}" ]]; then
      if ! jq -e --arg mid "${m_story}" 'index($mid) != null' <<< "${all_ids}" > /dev/null 2>&1; then
        blocked="$(jq -c --arg s "${id}" --arg k "${key}" --arg other "${m_story}" --arg r "orphan" \
          --arg d "Ticket ${key} recorded in ${spec_path} carries story identifier ${m_story}, which no user story in ${spec_path} claims; nothing was written to it. Restore ${m_story} as that story's identifier with \`<!-- speckit-jira story=${m_story} ticket=${key} -->\`, or delete the marker line to mirror the story as a new ticket and close ${key} in Jira." \
          '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
      else
        blocked="$(jq -c --arg s "${id}" --arg k "${key}" --arg r "marker-mismatch" \
          --arg d "Ticket ${key} recorded for story ${id} in ${spec_path} does not carry that story's identity marker; nothing was written to it. Correct the ticket= value in ${spec_path}, or delete the marker line to mirror the story as a new ticket." \
          '. + [{story:$s, reason:$r, detail:$d}]' <<< "${blocked}")"
      fi
      continue
    fi

    # Bound: recognised. current/status/status_category/flagged/blockers
    # feed the plan and lifecycle contexts (Phase 4/6).
    local fields origin current status status_category flagged blockers
    fields="$(jq -c '.fields' <<< "${read_result}")"
    origin="$(jq -r '.origin // "bridge"' <<< "${marker}")"
    current="$(jq -c '{summary:(.summary // ""), description:(.description // {}), priority:(.priority // null)}' <<< "${fields}")"
    status="$(jq -r '.status.name // ""' <<< "${fields}")"
    status_category="$(jq -r '.status.statusCategory.key // ""' <<< "${fields}")"
    flagged="$(jq -r 'if (.["Flagged"]? // [] | length) > 0 then true else false end' <<< "${fields}")"
    blockers="$(jq -c '[(.issuelinks // [])[] | select(.type.inward? and .inwardIssue?) | .inwardIssue.key]' <<< "${fields}")"

    local entry; entry="$(jq -cn --arg k "${key}" --arg o "${origin}" --argjson c "${current}" \
      --arg st "${status}" --arg sc "${status_category}" --argjson fl "${flagged}" --argjson bl "${blockers}" \
      '{key:$k, origin:$o, current:$c, status:$st, status_category:$sc, flagged:$fl, blockers:$bl}')"
    bound="$(jq -c --arg id "${id}" --argjson e "${entry}" '. + {($id): $e}' <<< "${bound}")"
  done

  jq -cn --argjson b "${bound}" --argjson nw "${new}" --argjson bl "${blocked}" \
    '{bound:$b, new:$nw, blocked:$bl}' | json_canonical
}
