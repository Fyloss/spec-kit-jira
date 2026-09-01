#!/usr/bin/env bash
# sink/jira/attachments.sh — publishing the feature's artifacts onto its
# specification ticket (036; contracts/artifact-publication.md;
# contracts/comment-body.md).
#
# SINK layer: everything here knows about Jira. The engine hands over the
# artifact set (a list of relative paths, hashes and flattened names) and this
# module turns it into attachments, one announcing comment, and a manifest.
#
# The shape of the whole thing is dictated by three rules that do not bend:
#
#   * ONE REQUEST FOR THE WHOLE SET. Never a call and never a process per
#     artifact (FR-023, docs/11-process-budget.md).
#   * ZERO WRITES WHEN NOTHING CHANGED. Not "few" — zero of every kind,
#     attachments, comment and manifest alike (Principle II, C4.5).
#   * NOTHING IS EVER REMOVED. A superseded attachment stays; the manifest
#     records the current state and the comment stream carries the history
#     (Principle I, FR-014).

[[ -n ${_JIRA_SINK_ATTACHMENTS:-} ]] && return 0
_JIRA_SINK_ATTACHMENTS=1

_attachments_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_attachments_dir}/../../lib/cli.sh"
# shellcheck source=/dev/null
source "${_attachments_dir}/../../lib/output.sh"
# shellcheck source=/dev/null
source "${_attachments_dir}/client.sh"
# shellcheck source=/dev/null
source "${_attachments_dir}/adf.sh"

# The entity-property key holding the publication manifest. A constant of ours,
# never an Atlassian default — the sibling of `spec-kit-jira` in identity.sh.
: "${SPEC_KIT_JIRA_ARTIFACTS_KEY:=spec-kit-jira-artifacts}"

# The manifest's shape version (contracts/artifact-manifest.schema.json). A
# reader that does not recognise the value treats the manifest as ABSENT and
# republishes — never as an error, and never as a reason to write.
_ATTACHMENTS_MANIFEST_SCHEMA=1

# An assumed cap on an entity-property value, pending research §R15 item 4.
# Declared here as an ASSUMPTION rather than a measured constant, because that
# is what it is: nothing in this repository has observed the real limit.
: "${SPEC_KIT_JIRA_PROPERTY_CAP:=32768}"

# attachments_limit <base-url> — print "<enabled> <uploadLimit>" for the site
# (C1.1). Read ONCE per run and memoised, because it is a site fact that cannot
# change mid-run and a second call would be a second request for nothing.
#
# Principle VII forbids compiling in 10 MB as though it were universal: sites
# raise and lower it, and FR-017 requires the warning to state the real number.
_ATTACHMENTS_LIMIT_CACHE=""
attachments_limit() {
  local base="$1"
  if [[ -n "${_ATTACHMENTS_LIMIT_CACHE}" ]]; then
    printf '%s' "${_ATTACHMENTS_LIMIT_CACHE}"
    return 0
  fi
  local body
  if ! body="$(jira_request GET "${base}/rest/api/3/attachment/meta")"; then
    return 1
  fi
  local enabled limit
  enabled="$(jq -r '.enabled // true' <<< "${body}" 2> /dev/null)"
  limit="$(jq -r '.uploadLimit // 0' <<< "${body}" 2> /dev/null)"
  [[ -n "${limit}" && "${limit}" != "null" ]] || return 1
  _ATTACHMENTS_LIMIT_CACHE="${enabled} ${limit}"
  printf '%s' "${_ATTACHMENTS_LIMIT_CACHE}"
}

# attachments_manifest_read <base-url> <ticket-key> — print the manifest stored
# on the ticket, or `{}` when there is none (C1.2).
#
# A 404 is NOT a fail-closed condition here: it means "nothing published yet",
# which is the ordinary state of a first run. Treating it as an error would
# make every first publication a failure.
attachments_manifest_read() {
  local base="$1" key="$2" body
  if ! body="$(jira_request GET "${base}/rest/api/3/issue/${key}/properties/${SPEC_KIT_JIRA_ARTIFACTS_KEY}" 2> /dev/null)"; then
    printf '{}'
    return 0
  fi
  local schema
  schema="$(jq -r '.value.schema // empty' <<< "${body}" 2> /dev/null)"
  if [[ "${schema}" != "${_ATTACHMENTS_MANIFEST_SCHEMA}" ]]; then
    # An unrecognised shape reads as absent, so the run republishes rather than
    # trusting a document it cannot interpret.
    printf '{}'
    return 0
  fi
  jq -c '.value.artifacts // {}' <<< "${body}" 2> /dev/null || printf '{}'
}

# attachments_classify <set-json> <manifest-json> <limit> [ticket-attachment-ids-json]
# — print the decision for every artifact, as an array of
# `{path, attachment_name, action, reason?, size?, limit?, collides_with?}`
# (C4.1, C4.2, data-model §5).
#
# `action` is one of published · revised · unchanged · withheld.
#
# A decision that WILL be published carries the artifact's `hash`, because the
# manifest is composed from the decision set and has nothing else to record it
# from. Without it the manifest stores an empty hash, every later run reads
# "the hash differs", and zero-churn never holds — the defect would look like
# the feature working and re-uploading everything forever.
#
# WITHHOLDING PRECEDENCE is fixed — name-collision, then oversized — so a run's
# warnings are deterministic across ports rather than depending on which check
# a reader happens to write first.
#
# The trust rule (C4.3): an artifact whose hash matches the manifest is
# `unchanged` ONLY if the attachment id the manifest claims is still on the
# ticket. When the caller supplies the ticket's real id list and the id is
# absent, the artifact is republished — which is what repairs a run that wrote
# the property but died before the upload landed.
attachments_classify() {
  local set_json="$1" manifest="${2:-\{\}}" limit="${3:-0}" ticket_ids="${4:-null}"
  jq -c -n --argjson s "${set_json}" --argjson m "${manifest}" \
    --argjson lim "${limit}" --argjson ids "${ticket_ids}" '
    # Names shared by more than one artifact — the collision set (FR-005).
    ($s | group_by(.attachment_name) | map(select(length > 1)) | flatten
        | map(.attachment_name) | unique) as $collided
    | [ $s[]
        | . as $a
        | ($m[$a.path] // null) as $rec
        | if ($collided | index($a.attachment_name)) then
            {path: $a.path, attachment_name: $a.attachment_name, action: "withheld",
             reason: "name-collision",
             collides_with: ([$s[] | select(.attachment_name == $a.attachment_name and .path != $a.path) | .path] | join(", "))}
          elif ($lim > 0 and $a.size > $lim) then
            {path: $a.path, attachment_name: $a.attachment_name, action: "withheld",
             reason: "oversized", size: $a.size, limit: $lim}
          elif ($rec == null) then
            {path: $a.path, attachment_name: $a.attachment_name, hash: $a.hash, action: "published"}
          elif ($rec.hash != $a.hash) then
            {path: $a.path, attachment_name: $a.attachment_name, hash: $a.hash, action: "revised"}
          elif ($ids != null and (($ids | index($rec.attachment_id)) | not)) then
            # The manifest is ahead of the ticket: republish (C4.3).
            {path: $a.path, attachment_name: $a.attachment_name, hash: $a.hash, action: "published"}
          else
            {path: $a.path, attachment_name: $a.attachment_name, action: "unchanged"}
          end ]'
}

# attachments_comment_body <event> <decisions-json> — print the ADF document
# announcing this run's publication (contracts/comment-body.md B1–B4).
#
# The literals below are PINNED, copied from the contract rather than composed,
# because the PowerShell twin must produce the same bytes and a shared
# generator across two languages is exactly where they drift apart.
#
# Withheld artifacts are ABSENT from the comment (B4): it announces what a
# reader can now download, and naming a file that is not there is worse than
# silence. They are reported in the run summary, where the operator can act.
attachments_comment_body() {
  local event="$1" decisions="$2"
  jq -c -n --arg ev "${event}" --argjson d "${decisions}" '
    ([$d[] | select(.action == "published" or .action == "revised")]) as $pub
    # The lead is the same in both variants; only the tail changes. Kept as one
    # literal rather than two identical branches, so there is exactly one place
    # the PowerShell twin has to match.
    | "Spec Kit published these feature artifacts after " as $lead
    | (if ([$pub[] | select(.action == "revised")] | length) > 0 then
         ". Revised files are attached again; earlier versions are kept."
       else
         ". They are attached to this ticket."
       end) as $tail
    | {type: "doc", version: 1, content: [
        {type: "paragraph", content: [
          {type: "text", text: $lead},
          {type: "text", text: $ev, marks: [{type: "code"}]},
          {type: "text", text: $tail}
        ]},
        {type: "bulletList", content: [
          $pub[] | {type: "listItem", content: [
            {type: "paragraph", content: [
              {type: "text", text: .path, marks: [{type: "code"}]},
              {type: "text", text: (if .action == "revised" then " — revised" else " — new" end)}
            ]}
          ]}
        ]}
      ]}' | json_canonical
}

# attachments_manifest_compose <manifest-json> <decisions-json> <created-json>
# <event> — print the manifest to store after this run (data-model §2).
#
# Only entries that ACTUALLY LANDED are folded in: `created` is the sink's own
# response, so an upload that failed contributes nothing and the next run
# retries it. Entries for artifacts no longer in the set are LEFT IN PLACE —
# their attachments still exist on the ticket (FR-015), so the manifest still
# describes reality.
attachments_manifest_compose() {
  local manifest="${1:-\{\}}" decisions="$2" created="${3:-[]}" event="$4"
  jq -c -n --argjson m "${manifest}" --argjson d "${decisions}" \
    --argjson c "${created}" --arg ev "${event}" '
    ([$d[] | select(.action == "published" or .action == "revised")]) as $pub
    | reduce range(0; ($pub | length)) as $i ($m;
        ($pub[$i]) as $p
        | ($c[$i] // null) as $made
        | if $made == null then . else
            .[$p.path] = {hash: ($p.hash // ""), attachment_id: ($made.id | tostring), run: $ev}
          end)'
}

# attachments_manifest_write <base-url> <ticket-key> <artifacts-json> — store
# the manifest (C1.6). Issued ONLY by a caller that has something to record;
# this function does not second-guess that, so the zero-write floor lives at
# the call site where the decision set is known.
attachments_manifest_write() {
  local base="$1" key="$2" artifacts="$3" body
  body="$(jq -c -n --argjson sc "${_ATTACHMENTS_MANIFEST_SCHEMA}" --argjson a "${artifacts}" \
    '{schema: $sc, artifacts: $a}')"
  jira_request PUT "${base}/rest/api/3/issue/${key}/properties/${SPEC_KIT_JIRA_ARTIFACTS_KEY}" "${body}" > /dev/null
}

# attachments_manifest_oversized <artifacts-json> — return 0 when the composed
# manifest would exceed the property cap (C4.4.1).
#
# Fails closed rather than publishing what fits: a partial manifest would make
# the next run republish exactly the artifacts this one dropped, forever, which
# is worse than not starting.
attachments_manifest_oversized() {
  local artifacts="$1" size
  size="$(jq -c -n --argjson sc "${_ATTACHMENTS_MANIFEST_SCHEMA}" --argjson a "${artifacts}" \
    '{schema: $sc, artifacts: $a}' | wc -c | tr -d '[:space:]')"
  ((size > SPEC_KIT_JIRA_PROPERTY_CAP))
}

# attachments_upload <base-url> <ticket-key> <feature-dir> <decisions-json> —
# upload every artifact this run decided to publish, in ONE request (C1.4).
# Prints the sink's response array; empty on failure.
attachments_upload() {
  local base="$1" key="$2" dir="$3" decisions="$4"
  local parts
  parts="$(jq -c --arg d "${dir}" '
    [ .[] | select(.action == "published" or .action == "revised")
          | {attachment_name: .attachment_name, file: ($d + "/" + .path)} ]' <<< "${decisions}")"
  [[ "$(jq -r 'length' <<< "${parts}")" -gt 0 ]] || {
    printf '[]'
    return 0
  }
  jira_request_multipart POST "${base}/rest/api/3/issue/${key}/attachments" "${parts}"
}

# attachments_comment_post <base-url> <ticket-key> <adf-json> — post the
# announcing comment (C1.5). One per publishing run; the caller decides whether
# there is anything to announce.
attachments_comment_post() {
  local base="$1" key="$2" adf="$3" body
  body="$(jq -c -n --argjson b "${adf}" '{body: $b}')"
  jira_request POST "${base}/rest/api/3/issue/${key}/comment" "${body}" > /dev/null
}

# attachments_ticket_ids <base-url> <ticket-key> — the attachment ids currently
# on the ticket, as a JSON array (C1.3). Used only by the trust rule, and only
# when the manifest claims an id that a run is about to call `unchanged`.
attachments_ticket_ids() {
  local base="$1" key="$2" body
  if ! body="$(jira_request GET "${base}/rest/api/3/issue/${key}?fields=attachment" 2> /dev/null)"; then
    printf 'null'
    return 0
  fi
  jq -c '[(.fields.attachment // [])[] | .id | tostring]' <<< "${body}" 2> /dev/null || printf 'null'
}
