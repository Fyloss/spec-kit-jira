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

# _disc_style <project-json> — map the detected style to its logical value
# (research §1): next-gen / simplified -> team_managed, classic -> company_managed,
# neither present -> company_managed (the superset path degrades gracefully).
_disc_style() {
  local proj="$1" style simplified
  style="$(jq -r '.style // ""' <<< "${proj}")"
  simplified="$(jq -r 'if has("simplified") then (.simplified|tostring) else "" end' <<< "${proj}")"
  if [[ "${style}" == "next-gen" || "${simplified}" == "true" ]]; then
    printf 'team_managed'
  elif [[ "${style}" == "classic" || "${simplified}" == "false" ]]; then
    printf 'company_managed'
  else
    printf 'company_managed'
  fi
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

  # (3) Project field schema (estimation candidates + flagged field source).
  local meta
  meta="$(jira_request GET "${api}/issue/createmeta/${key}/issuetypes/${first_type}")" || return $?

  # (4) Statuses + statusCategory (seeds the four-category classification).
  local statuses
  statuses="$(jira_request GET "${api}/project/${key}/statuses")" || return $?

  # (5) Priorities.
  local priorities
  priorities="$(jira_request GET "${api}/priority")" || return $?

  # (6) Field catalogue (logical-name -> id resolution).
  local fields
  fields="$(jira_request GET "${api}/field")" || return $?

  # Assemble the neutral binding. Arrays keep discovered order; json_canonical
  # sorts object keys so both ports converge to identical bytes (research §11).
  jq -n \
    --arg style "${style}" \
    --argjson itypes "${itypes}" \
    --argjson meta "${meta}" \
    --argjson statuses "${statuses}" \
    --argjson priorities "${priorities}" \
    --argjson fields "${fields}" '
    {
      style: $style,
      issue_types: [ $itypes.issueTypes[]
        | {logical_name: .name, id: .id, subtask: .subtask, hierarchy_level: .hierarchyLevel} ],
      statuses: ( reduce ($statuses[] | .statuses[]) as $s ([];
        if any(.[]; .id == $s.id) then .
        else . + [ {name: $s.name, id: $s.id, status_category: $s.statusCategory.key} ] end) ),
      priorities: [ $priorities[] | {logical_name: .name, id: .id} ],
      fields: [ $fields[] | {logical_name: .name, id: .id, schema_type: (.schema.type // null), custom: .custom} ],
      estimation_candidates: ( [ $meta.fields[]
        | select(.schema.type == "number")
        | {logical_name: .name, id: .fieldId, schema_type: .schema.type,
           score: ( 2
                  + (if ((.schema.custom // "") | test("float|gh-sprint|story-point"; "i")) then 2 else 0 end)
                  + (if (.name | test("estimat|point|effort|story"; "i")) then 1 else 0 end) ) } ]
        | sort_by([(-.score), .id]) ),
      flagged_field: ( [ $meta.fields[]
        | select(.name | test("impediment|flag"; "i"))
        | {logical_name: .name, id: .fieldId} ] | (.[0] // null) )
    }' | json_canonical
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
}
