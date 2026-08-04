#!/usr/bin/env bash
# sink/jira/discovery.sh — Project metadata discovery (SINK layer, T037/T038).
#
# `discover_binding <project_key>` assembles the neutral Project Binding for one
# project, by LOGICAL name (Constitution VII — no literal Atlassian default type,
# status, or field id is ever compiled in). The style is DETECTED FIRST (research
# §1) and the per-style, scheme-based discovery path follows (research §2/§3):
#
#   1. GET /project/{key}                                  -> style
#   2. GET /issue/createmeta/{key}/issuetypes             -> issue types + levels
#   3. GET /issue/createmeta/{key}/issuetypes/{firstType} -> project field schema
#      (estimation candidates + flagged field come from the PROJECT's own fields,
#       never the global /field catalogue — that is the whole point of research §3)
#   4. GET /project/{key}/statuses                        -> statuses + categories
#   5. GET /priority                                       -> priorities
#   6. GET /field                                          -> logical-name catalogue
#
# The estimation field is RANKED, not assumed: numeric project fields are scored
# by documented signals and proposed to the operator (US1 confirms). The flagged
# field is discovered by shape (research §15), never an assumed customfield id.
#
# Output: the canonical binding JSON on stdout (byte-identical to the PowerShell
# port, NFR-1); on any fail-closed read, nothing on stdout and the transport's
# mapped exit code (Constitution III).

[[ -n ${_JIRA_SINK_DISCOVERY:-} ]] && return 0
_JIRA_SINK_DISCOVERY=1

_discovery_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_discovery_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_discovery_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_discovery_dir}/client.sh"

# discovery_flagged_field <project-fields-json> — resolve the project's
# Flagged/impediment field, the input of flagged-withholding lifecycle safety
# (FR-036). LOCALE-INDEPENDENT: the English name (`Impediment`/`Flagged`) is only
# a first-chance match; a localized or renamed site resolves by SHAPE — the
# Flagged field is an array-of-options checkbox custom field — and only an
# unambiguous single shape candidate is accepted (precision over recall).
# Prints the canonical {logical_name,id} object, or null.
discovery_flagged_field() {
  local fields="${1:-[]}"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson fields "${fields}" '
    ([ $fields[] | select((.name // "") | test("impediment|flag"; "i"))
       | {logical_name: .name, id: .fieldId} ]) as $byname
    | ([ $fields[] | select(((.schema.type // "") == "array")
           and ((.schema.custom // "") | test("multicheckboxes|gh-flagged"; "i")))
       | {logical_name: .name, id: .fieldId} ]) as $byshape
    | ($byname[0] // (if ($byshape | length) == 1 then $byshape[0] else null end))
  ' | json_canonical
  # kcov-excl-stop
}

# _disc_style <project-json> — THREE-VALUED style mapping (002 research §2,
# FR-001/FR-002): a style is returned ONLY on an explicit, non-contradictory
# signal — `style: next-gen` / `simplified: true` -> team_managed,
# `style: classic` / `simplified: false` -> company_managed. Both signals
# absent, or the two signals contradicting each other, print NOTHING: the sink
# never substitutes a default (the binding carries `style: null` and the
# command layer asks / fails closed).
_disc_style() {
  local proj="$1" style simplified s_sig="" f_sig=""
  style="$(jq -r '.style // ""' <<< "${proj}")"
  simplified="$(jq -r 'if has("simplified") then (.simplified|tostring) else "" end' <<< "${proj}")"
  case "${style}" in
    next-gen) s_sig="team_managed" ;;
    classic) s_sig="company_managed" ;;
  esac
  case "${simplified}" in
    true) f_sig="team_managed" ;;
    false) f_sig="company_managed" ;;
  esac
  if [[ -n "${s_sig}" && -n "${f_sig}" ]]; then
    if [[ "${s_sig}" == "${f_sig}" ]]; then
      printf '%s' "${s_sig}"
    fi
  else
    printf '%s' "${s_sig}${f_sig}"
  fi
  return 0
}

# discovery_list_projects — the accessible-projects list (002 US2, FR-004c).
# Paginated GET /rest/api/3/project/search through the existing transport
# (honouring isLast/total); each page's values map to {key, name, style} with
# the same three-valued style rule as _disc_style (null when ambiguous). Zero
# results fail closed: the credentials can browse no project, so there is no
# closed question to ask. Prints the canonical array on stdout.
discovery_list_projects() {
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'discovery: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"
  local start=0 page n i value style entry is_last total list='[]'
  while :; do
    page="$(jira_request GET "${api}/project/search?startAt=${start}&maxResults=50")" || return $?
    n="$(jq -r '.values | length' <<< "${page}")"
    for ((i = 0; i < n; i++)); do
      value="$(jq -c ".values[${i}]" <<< "${page}")"
      style="$(_disc_style "${value}")"
      entry="$(jq -cn --argjson v "${value}" --arg s "${style}" \
        '{key: $v.key, name: $v.name, style: (if $s == "" then null else $s end)}')"
      list="$(jq -c --argjson e "${entry}" '. + [$e]' <<< "${list}")"
    done
    # `// true` would swallow a real `false` (jq treats false as empty).
    is_last="$(jq -r 'if has("isLast") then (.isLast | tostring) else "true" end' <<< "${page}")"
    total="$(jq -r '.total // 0' <<< "${page}")"
    start=$((start + n))
    if [[ "${is_last}" == "true" || ${start} -ge ${total} || ${n} -eq 0 ]]; then
      break
    fi
  done
  if [[ "$(jq -r 'length' <<< "${list}")" -eq 0 ]]; then
    printf 'discovery: the configured credentials can browse no visible project (project/search returned zero results)\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  printf '%s' "${list}" | json_canonical
}

# discovery_priorities_for_project <project-fields-json> <catalogue-json> —
# derive the priorities a resolved project actually accepts, from its OWN
# create metadata against the site-wide identifier catalogue (research R4,
# 004 US4, FR-030/FR-031). Three branches, never a rule keyed on project style
# (FR-028):
#   1. no `priority` field at all             -> []  (the project has no priority)
#   2. `priority` field WITH allowedValues    -> only those, resolved by id
#      against the catalogue
#   3. `priority` field WITHOUT allowedValues -> the whole catalogue (today's
#      behaviour, preserved for a site that does not populate allowedValues)
# Prints the canonical [{logical_name,id}, ...] array.
discovery_priorities_for_project() {
  local fields="${1:-[]}" catalogue="${2:-[]}"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson fields "${fields}" --argjson cat "${catalogue}" '
    (first($fields[] | select(.fieldId == "priority")) // null) as $pf
    | if $pf == null then []
      elif ($pf.allowedValues // null) != null then
        [ $pf.allowedValues[] | .id as $id | ($cat[] | select(.id == $id) | {logical_name: .name, id: .id}) ]
      else
        [ $cat[] | {logical_name: .name, id: .id} ]
      end
  ' | json_canonical
  # kcov-excl-stop
}

# _disc_hierarchy_candidates <issueTypes-array-json> — the SOLE-candidate
# child and parent type ids, when the level is unambiguous (research R1/R2).
# No refusal here: an ambiguous level simply yields no candidate for that
# tier. The full derivation and its refusals (no-parent-level, parent-level-
# ambiguous) live in sink/jira/hierarchy.sh (Phase 4, US1); this is only
# enough to know which types' create metadata discovery can usefully fetch
# before the child type has been resolved by the ceremony (or needs no
# resolving because the level held one candidate all along).
_disc_hierarchy_candidates() {
  local itypes="$1"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson t "${itypes}" '
    ($t | map(select(.subtask | not))) as $cand
    | (if ($cand|length) > 0 then ($cand | map(.hierarchyLevel) | min) else null end) as $childLevel
    | ($cand | map(select(.hierarchyLevel == $childLevel))) as $childCands
    | ($cand | map(select(.hierarchyLevel > $childLevel))) as $above
    | (if ($above|length) > 0 then ($above | map(.hierarchyLevel) | min) else null end) as $parentLevel
    | ($above | map(select(.hierarchyLevel == $parentLevel))) as $parentCands
    | {
        child:  (if ($childCands|length)  == 1 then $childCands[0].id  else null end),
        parent: (if ($parentCands|length) == 1 then $parentCands[0].id else null end)
      }
  '
  # kcov-excl-stop
}

# _disc_required_fields <createmeta-fields-array-json> — every field this
# type's create metadata marks required, by its Jira NAME (never a
# customfield_NNNNN id), for the mandatory-field gate of contracts/
# hierarchy-resolution.md §5 (Phase 6, US3). Prints the canonical array.
_disc_required_fields() {
  local fields="${1:-[]}"
  jq -cn --argjson f "${fields}" \
    '[ $f[] | select(.required == true) | {logical_name: .name, field_id: .fieldId} ]' | json_canonical
}

# _disc_defaultable_fields <createmeta-fields-array-json> — every field this
# type's create metadata reports that the bridge does NOT itself supply (011,
# research R3, contract §2.1), whether Jira marks it required or not (FR-004).
# The bridge-supplied constant (summary, description, issuetype, project,
# priority, reporter, parent) is never a candidate for a recorded default —
# it is not extended by this feature (contract §1.1) — so those fields are
# simply absent from the output, never emitted with defaultable:false.
#
# A field is `defaultable: false` only when its shape cannot be a single
# recorded scalar at all — an array-shaped field (multi-select, checkbox
# group, attachment, labels) or an issue link — carrying an
# `undefaultable_reason` a human can read (FR-010). Every other shape,
# including `user`, is defaultable: the bridge sends exactly what was
# recorded, and a shape Jira itself then rejects is FR-019's concern, not
# discovery's. Prints the canonical array.
_disc_defaultable_fields() {
  local fields="${1:-[]}"
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson f "${fields}" '
    def bridgeSupplied: ["summary","description","issuetype","project","priority","reporter","parent"];
    def undefaultableReason($t):
      if $t == "array" then "a list of values cannot be expressed as a single recorded value"
      elif $t == "issuelink" then "an issue link cannot be expressed as a recorded value"
      else null end;
    [ $f[] | select((.fieldId as $fid | bridgeSupplied | index($fid)) | not)
      | (.schema.type // "") as $st
      | undefaultableReason($st) as $reason
      | { logical_name: .name, field_id: .fieldId, schema_type: $st,
          required: (.required == true), defaultable: ($reason == null),
          allowed_values: [ (.allowedValues // [])[] | (.value // .name) ] }
        + (if $reason == null then {} else {undefaultable_reason: $reason} end) ]
  ' | json_canonical
  # kcov-excl-stop
}

# discovery_type_metadata <project_key> <type_id> — one issue type's required
# fields, defaultable fields, and parent-link availability (010, T050/T051;
# 011 adds defaultable_fields), fetched on demand for a role the resolver
# selected but discover_binding's own single-candidate prefetch (research
# R1/R2, `_disc_hierarchy_candidates`) did not already cover — the ordinary
# case once a mapping is declared or answered rather than derived. Prints
# {required_fields:[...], parent_link_available:<bool>, defaultable_fields:[...]}.
discovery_type_metadata() {
  local key="$1" type_id="$2"
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'discovery: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"
  local tmeta
  tmeta="$(jira_request GET "${api}/issue/createmeta/${key}/issuetypes/${type_id}")" || return $?
  jq -cn --argjson rf "$(_disc_required_fields "$(jq -c '.fields // []' <<< "${tmeta}")")" \
    --argjson has "$(jq -c 'any(.fields[]?; .fieldId == "parent")' <<< "${tmeta}")" \
    --argjson df "$(_disc_defaultable_fields "$(jq -c '.fields // []' <<< "${tmeta}")")" \
    '{required_fields: $rf, parent_link_available: $has, defaultable_fields: $df}'
}

# discover_binding <project_key> — see the file header.
discover_binding() {
  local key="$1"
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'discovery: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"

  # (1) Style — the first Jira call, before any per-style discovery.
  local proj
  proj="$(jira_request GET "${api}/project/${key}")" || return $?
  local style
  style="$(_disc_style "${proj}")"

  # (2) Issue types + hierarchy levels.
  local itypes
  itypes="$(jira_request GET "${api}/issue/createmeta/${key}/issuetypes")" || return $?
  local first_type
  first_type="$(jq -r '.issueTypes[0].id // ""' <<< "${itypes}")"

  # (2b) The child/parent candidates this call can resolve without asking
  # (research R1/R2) — used only to pick which type(s) get a per-type
  # createmeta fetch (T017/T018, contract §4). An ambiguous level here is not
  # an error: the ceremony resolves it later and fetches that type's
  # metadata itself once chosen.
  local hier child_id parent_id
  hier="$(_disc_hierarchy_candidates "$(jq -c '.issueTypes' <<< "${itypes}")")"
  child_id="$(jq -r '.child // empty' <<< "${hier}")"
  parent_id="$(jq -r '.parent // empty' <<< "${hier}")"

  # (3) Project field schema (estimation candidates + flagged field source).
  # Sourced from the CHILD type when it is resolvable — the type this bridge
  # actually writes — falling back to the old arbitrary-first-type fetch only
  # when the child level is itself ambiguous (research §3 / plan.md).
  local meta_type_id="${child_id:-${first_type}}"
  local meta
  meta="$(jira_request GET "${api}/issue/createmeta/${key}/issuetypes/${meta_type_id}")" || return $?

  # (3b) required_fields and parent-link availability, per written type
  # actually resolvable at this point (T017–T020, contract §4) — at most two
  # requests, reusing the (3) fetch when a type coincides with it rather than
  # re-requesting the same metadata. Parent-link availability is READ from
  # the type's own metadata, never assumed from project style (R4) —
  # `parent-link-unavailable` (Phase 6, US3) depends on this being an honest
  # per-type fact rather than a guess.
  local required_fields='{}' parent_link_available='{}' defaultable_fields='{}' tid tmeta
  for tid in "${child_id}" "${parent_id}"; do
    [[ -z "${tid}" ]] && continue
    [[ "$(jq -r --arg t "${tid}" 'has($t)' <<< "${required_fields}")" == "true" ]] && continue
    if [[ "${tid}" == "${meta_type_id}" ]]; then
      tmeta="${meta}"
    else
      tmeta="$(jira_request GET "${api}/issue/createmeta/${key}/issuetypes/${tid}")" || return $?
    fi
    required_fields="$(jq -c --arg t "${tid}" \
      --argjson rf "$(_disc_required_fields "$(jq -c '.fields // []' <<< "${tmeta}")")" \
      '. + {($t): $rf}' <<< "${required_fields}")"
    parent_link_available="$(jq -c --arg t "${tid}" --argjson has "$(jq -c 'any(.fields[]?; .fieldId == "parent")' <<< "${tmeta}")" \
      '. + {($t): $has}' <<< "${parent_link_available}")"
    defaultable_fields="$(jq -c --arg t "${tid}" \
      --argjson df "$(_disc_defaultable_fields "$(jq -c '.fields // []' <<< "${tmeta}")")" \
      '. + {($t): $df}' <<< "${defaultable_fields}")"
  done

  # (4) Statuses + statusCategory (seeds the four-category classification).
  local statuses
  statuses="$(jira_request GET "${api}/project/${key}/statuses")" || return $?

  # (5) Priorities.
  local priorities
  priorities="$(jira_request GET "${api}/priority")" || return $?

  # (6) Field catalogue (logical-name -> id resolution).
  local fields
  fields="$(jira_request GET "${api}/field")" || return $?

  # The flagged field resolves by name, then by shape (locale-independent).
  local flagged
  flagged="$(discovery_flagged_field "$(jq -c '.fields // []' <<< "${meta}")")"

  # The project's own accepted priorities, derived from its create metadata
  # against the site-wide catalogue fetched above (research R4, 004 US4).
  local proj_priorities
  proj_priorities="$(discovery_priorities_for_project "$(jq -c '.fields // []' <<< "${meta}")" "${priorities}")"

  # Assemble the neutral binding. Arrays keep discovered order; json_canonical
  # sorts object keys so both ports converge to identical bytes (research §11).
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -n \
    --arg style "${style}" \
    --argjson itypes "${itypes}" \
    --argjson meta "${meta}" \
    --argjson statuses "${statuses}" \
    --argjson priorities "${proj_priorities}" \
    --argjson fields "${fields}" \
    --argjson flagged "${flagged}" \
    --argjson rf "${required_fields}" \
    --argjson pla "${parent_link_available}" \
    --argjson df "${defaultable_fields}" '
    {
      style: (if $style == "" then null else $style end),
      issue_types: [ $itypes.issueTypes[]
        | {logical_name: .name, id: .id, subtask: .subtask, hierarchy_level: .hierarchyLevel} ],
      statuses: ( reduce ($statuses[] | .statuses[]) as $s ([];
        if any(.[]; .id == $s.id) then .
        else . + [ {name: $s.name, id: $s.id, status_category: $s.statusCategory.key} ] end) ),
      priorities: $priorities,
      fields: [ $fields[] | {logical_name: .name, id: .id, schema_type: (.schema.type // null), custom: .custom} ],
      estimation_candidates: ( [ $meta.fields[]
        | select(.schema.type == "number")
        | {logical_name: .name, id: .fieldId, schema_type: .schema.type,
           score: ( 2
                  + (if ((.schema.custom // "") | test("float|gh-sprint|story-point"; "i")) then 2 else 0 end)
                  + (if (.name | test("estimat|point|effort|story"; "i")) then 1 else 0 end) ) } ]
        | sort_by([(-.score), .id]) ),
      flagged_field: $flagged,
      required_fields: $rf,
      parent_link_available: $pla,
      defaultable_fields: $df
    }' | json_canonical
  # kcov-excl-stop
}

# fetch_mentioned <issue_key> — READ-ONLY fetch of a mentioned ticket (US10, T087;
# FR-050). Returns the neutral fetch document on stdout: the ticket's content and
# acceptance criteria (extracted from its description; panels seed the criteria),
# priority (logical name), labels, status, flag, links, its linked Confluence
# pages (title and URL only — the page CONTENT is never fetched), its parent's
# context one level up, and a one-line sibling list. On a fail-closed read of the
# ticket itself nothing is emitted and the transport's mapped exit code is returned
# (Constitution III). The flagged field id, which the engine cannot know, is
# supplied out of band via SPEC_KIT_JIRA_FLAGGED_FIELD_ID (empty ⇒ flag reported
# false); the discovery binding fills it in the wired flow.
fetch_mentioned() {
  local key="$1"
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'fetch_mentioned: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"
  local flagged_id="${SPEC_KIT_JIRA_FLAGGED_FIELD_ID:-}"

  # (1) The ticket itself — the only read that must succeed (fail-closed).
  local issue
  issue="$(jira_request GET "${api}/issue/${key}")" || return $?

  # (2) Remote links (Confluence titles/URLs). Supplementary enrichment: a failure
  #     degrades to "no linked pages", never failing the read-only convenience fetch.
  local remote
  remote="$(jira_request GET "${api}/issue/${key}/remotelink")" || remote='[]'
  [[ -z "${remote}" ]] && remote='[]'

  # (3) Siblings — only when the ticket has a parent (JQL over the parent's children).
  local parent_key sib='{"issues":[]}'
  parent_key="$(jq -r '.fields.parent.key // ""' <<< "${issue}")"
  if [[ -n "${parent_key}" ]]; then
    local jql
    jql="$(jq -rn --arg p "${parent_key}" '("parent=" + $p) | @uri')"
    sib="$(jira_request GET "${api}/search?jql=${jql}&fields=summary,status")" || sib='{"issues":[]}'
    [[ -z "${sib}" ]] && sib='{"issues":[]}'
  fi

  # kcov-excl-start — jq literal (string lines are not statements)
  jq -n \
    --argjson issue "${issue}" \
    --argjson remote "${remote}" \
    --argjson sib "${sib}" \
    --arg key "${key}" \
    --arg flaggedId "${flagged_id}" '
    ($issue.fields // {}) as $f
    | {
        key: $key,
        content: ( [ $f.description.content[]? | select(.type != "panel")
                     | [ .. | .text? // empty ] | join("") ]
                   | map(select(. != "")) | join("\n") ),
        acceptance_criteria: ( [ $f.description.content[]? | select(.type == "panel")
                                 | [ .. | .text? // empty ] | join("") ]
                               | map(select(. != "")) | join("\n") ),
        priority_logical: ( $f.priority.name // null ),
        labels: ( $f.labels // [] ),
        status: ( $f.status.name // null ),
        flagged: ( ($f[$flaggedId] // null) as $v
                   | if ($flaggedId == "") or ($v == null) then false
                     elif ($v | type) == "array" then (($v | length) > 0)
                     else true end ),
        links: ( [ $f.issuelinks[]?
                   | if has("outwardIssue") then
                       {type: .type.name, direction: .type.outward, key: .outwardIssue.key,
                        title: .outwardIssue.fields.summary, status: .outwardIssue.fields.status.name}
                     elif has("inwardIssue") then
                       {type: .type.name, direction: .type.inward, key: .inwardIssue.key,
                        title: .inwardIssue.fields.summary, status: .inwardIssue.fields.status.name}
                     else empty end ] ),
        confluence_pages: ( [ $remote[]?
                              | select( ((.application.type // "") | test("confluence"; "i"))
                                        or ((.globalId // "") | test("confluence"; "i")) )
                              | {title: .object.title, url: .object.url} ] ),
        parent_context: ( ($f.parent // null)
                          | if . == null then null
                            else {key: .key, title: .fields.summary, status: .fields.status.name} end ),
        siblings: ( [ $sib.issues[]? | {key: .key, title: .fields.summary, status: .fields.status.name} ] )
      }' | json_canonical
  # kcov-excl-stop
}

# discovery_task_transition <issue_key> <direction> — the task tier's only new
# read (012, research R5, contract §6). direction is "forward" (select
# destinations the project classifies as done — FR-029/FR-030) or "backward"
# (select destinations it does NOT classify as done — FR-032's operator-
# authorised pull back). Classification is by the destination's own
# statusCategory, never a status name (Constitution VII; contract §8).
#
# Prints {candidates:[{id,name}], transition_id, withheld_field}:
#   - zero matching candidates  -> transition_id null, candidates []
#   - exactly one, ungated      -> transition_id set to it
#   - exactly one, but its own transition screen requires a field value
#     (expand=transitions.fields) -> transition_id null, withheld_field names
#     it (FR-041) — a recorded creation-time default is never sent here
#   - two or more                -> transition_id null, candidates lists them
#     (the caller reports the issue and the candidates; the bridge invents no
#     preference, Edge Cases)
discovery_task_transition() {
  local key="$1" direction="${2:-forward}"
  local base="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ -z "${base}" ]]; then
    printf 'discovery: SPEC_KIT_JIRA_BASE_URL is not set\n' >&2
    return "$(cli_exit_code fail_closed)"
  fi
  local api="${base}/rest/api/3"
  local resp
  resp="$(jira_request GET "${api}/issue/${key}/transitions?expand=transitions.fields")" || return $?
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson r "${resp}" --arg dir "${direction}" '
    ($r.transitions // []) as $t
    | [ $t[] | select((((.to.statusCategory.key // "") == "done")) == ($dir == "forward")) ] as $done
    | ($done | map({id, name})) as $cands
    | (if ($cands | length) == 1 then
         (($done[0].fields // {}) | to_entries | map(select(.value.required == true)) | first) as $req
         | if $req == null then
             {candidates: $cands, transition_id: $cands[0].id, withheld_field: null}
           else
             {candidates: $cands, transition_id: null,
              withheld_field: {logical_name: ($req.value.name // $req.key), field_id: $req.key}}
           end
       else
         {candidates: $cands, transition_id: null, withheld_field: null}
       end)
  ' | json_canonical
  # kcov-excl-stop
}
