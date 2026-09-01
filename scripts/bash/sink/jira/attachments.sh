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
#
# Keyed on the base URL, matching the PowerShell twin. A cache keyed on nothing
# answers for the FIRST site anything asked about; this port never reaches that
# state anyway — every caller captures it in a subshell, so the cache does not
# survive a single call — but the twin does, where it made the C3.7/C3.9
# withholding paths untestable. The two ports say the same thing here.
_ATTACHMENTS_LIMIT_CACHE=""
_ATTACHMENTS_LIMIT_CACHE_URL=""
attachments_limit() {
  local base="$1"
  if [[ -n "${_ATTACHMENTS_LIMIT_CACHE}" && "${_ATTACHMENTS_LIMIT_CACHE_URL}" == "${base}" ]]; then
    printf '%s' "${_ATTACHMENTS_LIMIT_CACHE}"
    return 0
  fi
  local body
  if ! body="$(jira_request GET "${base}/rest/api/3/attachment/meta")"; then
    return 1
  fi
  local enabled limit
  # NOT `.enabled // true`: jq's alternative operator treats `false` as a
  # missing value, so a site that answers `"enabled": false` reads back as
  # enabled and C3.9 never fires — the ports diverge, because the PowerShell
  # twin tests for the property's PRESENCE and honours the false. Absence still
  # means enabled: an older site that omits the field is not a disabled one.
  enabled="$(jq -r 'if has("enabled") then (.enabled | if . then "true" else "false" end) else "true" end' <<< "${body}" 2> /dev/null)"
  limit="$(jq -r '.uploadLimit // 0' <<< "${body}" 2> /dev/null)"
  [[ -n "${limit}" && "${limit}" != "null" ]] || return 1
  _ATTACHMENTS_LIMIT_CACHE="${enabled} ${limit}"
  _ATTACHMENTS_LIMIT_CACHE_URL="${base}"
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
# The result is CANONICALISED (keys sorted) before it is printed. Not cosmetic:
# these decisions reach the run summary, which Constitution VI requires to be
# byte-identical across ports, and the PowerShell twin canonicalises by
# construction. Without it the two agreed on every value and differed on every
# key order — a divergence no unit test on either port alone would show.
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
  # json_build, not --argjson: the set, the manifest and the ticket's id list
  # all grow with the artifact count, and a command-line argument is capped at
  # ~32 767 bytes on Windows — reached at roughly the same directory size as
  # the manifest's own cap (C4.4). `lim` stays a bound scalar; it is one
  # integer whatever the input (docs/11-process-budget.md).
  # shellcheck disable=SC2016  # a jq filter: $s/$m/$lim/$ids are jq variables
  json_build '
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
          end ]' \
    s "${set_json}" m "${manifest}" lim "${limit}" ids "${ticket_ids}" | json_canonical
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
  # json_build: the decision set grows with the artifact count. The event is a
  # short token but travels the same way — json_build binds every value from a
  # file, so it is JSON-encoded once rather than mixed with an --arg.
  # shellcheck disable=SC2016  # a jq filter: $ev/$d are jq variables
  json_build '
    # The four spellings, not two: a --dry-run decision set carries
    # `would-publish` / `would-revise`, and the comment it PREDICTS has to be
    # the comment the real run would post, or the prediction is not one
    # (FR-020, SC-006).
    ([$d[] | select(.action == "published" or .action == "revised"
                    or .action == "would-publish" or .action == "would-revise")]) as $pub
    # The lead is the same in both variants; only the tail changes. Kept as one
    # literal rather than two identical branches, so there is exactly one place
    # the PowerShell twin has to match.
    | "Spec Kit published these feature artifacts after " as $lead
    | (if ([$pub[] | select(.action == "revised" or .action == "would-revise")] | length) > 0 then
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
              {type: "text", text: (if .action == "revised" or .action == "would-revise" then " — revised" else " — new" end)}
            ]}
          ]}
        ]}
      ]}' \
    ev "$(jq -cn --arg t "${event}" '$t')" d "${decisions}" | json_canonical
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
  # json_build: the manifest, the decisions and the sink's response all grow
  # with the artifact count (docs/11-process-budget.md).
  # shellcheck disable=SC2016  # a jq filter: $m/$d/$c/$ev are jq variables
  json_build '
    ([$d[] | select(.action == "published" or .action == "revised")]) as $pub
    | reduce range(0; ($pub | length)) as $i ($m;
        ($pub[$i]) as $p
        | ($c[$i] // null) as $made
        | if $made == null then . else
            .[$p.path] = {hash: ($p.hash // ""), attachment_id: ($made.id | tostring), run: $ev}
          end)' \
    m "${manifest}" d "${decisions}" c "${created}" \
    ev "$(jq -cn --arg t "${event}" '$t')" | json_canonical
}

# attachments_manifest_write <base-url> <ticket-key> <artifacts-json> — store
# the manifest (C1.6). Issued ONLY by a caller that has something to record;
# this function does not second-guess that, so the zero-write floor lives at
# the call site where the decision set is known.
attachments_manifest_write() {
  local base="$1" key="$2" artifacts="$3" body
  # shellcheck disable=SC2016  # a jq filter: $sc/$a are jq variables
  body="$(json_build '{schema: $sc, artifacts: $a}' \
    sc "${_ATTACHMENTS_MANIFEST_SCHEMA}" a "${artifacts}")"
  jira_request PUT "${base}/rest/api/3/issue/${key}/properties/${SPEC_KIT_JIRA_ARTIFACTS_KEY}" "${body}" > /dev/null
}

# attachments_manifest_oversized <artifacts-json> — return 0 when the composed
# manifest would exceed the property cap (C4.4.1).
#
# Fails closed rather than publishing what fits: a partial manifest would make
# the next run republish exactly the artifacts this one dropped, forever, which
# is worse than not starting.
attachments_manifest_oversized() {
  local size
  size="$(attachments_manifest_size "$1")"
  ((size > SPEC_KIT_JIRA_PROPERTY_CAP))
}

# attachments_manifest_size <artifacts-json> — the composed document's size in
# bytes. Its own function because C4.4.1's warning has to NAME the number, not
# merely act on it: "more artifacts than one ticket can track" tells an operator
# nothing they can do, where "412 artifacts, a 45 000-byte record, a 32 768-byte
# cap" tells them exactly how far over they are (Principle XVI).
attachments_manifest_size() {
  # shellcheck disable=SC2016  # a jq filter: $sc/$a are jq variables
  json_build '{schema: $sc, artifacts: $a}' \
    sc "${_ATTACHMENTS_MANIFEST_SCHEMA}" a "$1" | wc -c | tr -d '[:space:]'
}

# attachments_property_cap — the assumed cap, as the code's single reading of it.
attachments_property_cap() { printf '%s' "${SPEC_KIT_JIRA_PROPERTY_CAP}"; }

# attachments_pending <decisions-json> — the entries a run intends to write, in
# order. One reading of "will be written", shared by everything that has to ask:
# the four spellings (`published`/`revised` and their two dry-run twins) drifted
# apart across five call sites before this existed.
attachments_pending() {
  jq -c '[ .[] | select(.action == "published" or .action == "revised"
                        or .action == "would-publish" or .action == "would-revise") ]' <<< "$1"
}

# attachments_predict <decisions-json> — the dry-run twin of a decision set:
# the two WRITE actions become `would-publish` / `would-revise` (data-model §5,
# the existing `would-` convention). Everything else is untouched — an
# `unchanged` artifact is unchanged in a dry run too, and a withholding is
# predicted exactly as it would happen.
attachments_predict() {
  jq -c '[ .[] | if .action == "published" then .action = "would-publish"
                 elif .action == "revised" then .action = "would-revise"
                 else . end ]' <<< "$1" | json_canonical
}

# attachments_withhold <decisions-json> <reason> — rewrite every entry this run
# would have written into a `withheld` one carrying <reason>.
#
# For the withholdings that take down the WHOLE publication — the site has
# attachments off, the limit could not be read, the manifest would overflow, the
# upload was refused. Without this the summary reports `published` for artifacts
# that reached nothing, which is the one thing an audit trail must never do
# (FR-021, US4 AS3). An already-withheld entry keeps its own, more specific
# reason: `oversized` tells the operator more than `upload-failed` does.
attachments_withhold() {
  local decisions="$1" reason="$2"
  jq -c --arg r "${reason}" '
    [ .[] | if .action == "published" or .action == "revised"
               or .action == "would-publish" or .action == "would-revise"
            then {path: .path, attachment_name: .attachment_name,
                  action: "withheld", reason: $r}
            else . end ]' <<< "${decisions}" | json_canonical
}

# attachments_actions <ticket-key> <decisions-json> <comment-adf-json> — the two
# planned actions the publication contributes to the run summary (data-model §5).
#
# Composed HERE rather than in plan_apply.sh, which is where the sink's other
# action kinds are planned: publication runs after the apply, because the
# specification ticket may have been created by it (FR-006). The actions are
# reported identically whether or not the run performed them, which is what
# makes the dry-run report equal the real one (SC-006).
attachments_actions() {
  local key="$1" decisions="$2" adf="$3"
  # shellcheck disable=SC2016  # a jq filter: $k/$p/$c are jq variables
  json_build '
    if ($p | length) == 0 then [] else
      [ {method: "POST", url: ("/rest/api/3/issue/" + $k + "/attachments"),
         body: {parts: [$p[] | .attachment_name]}},
        {method: "POST", url: ("/rest/api/3/issue/" + $k + "/comment"),
         body: {body: $c}} ]
    end' \
    k "$(jq -cn --arg t "${key}" '$t')" \
    p "$(attachments_pending "${decisions}")" c "${adf}" | json_canonical
}

# attachments_upload <base-url> <ticket-key> <feature-dir> <decisions-json> —
# upload every artifact this run decided to publish, in ONE request (C1.4).
#
# Prints an ENVELOPE, `{"status": <http-status>, "created": [...]}`, not the bare
# response array. C3.2, C3.3 and C3.4 are three different outcomes with three
# different messages, and the status is the only thing that tells them apart —
# but `JIRA_LAST_STATUS` is set by the transport in ITS shell, and every caller
# here reaches this function through a command substitution, so the status
# cannot travel any other way. `status` is 0 when the request never reached a
# response at all (a network-level failure).
attachments_upload() {
  local base="$1" key="$2" dir="$3" decisions="$4"
  local parts
  parts="$(jq -c --arg d "${dir}" '
    [ .[] | select(.action == "published" or .action == "revised")
          | {attachment_name: .attachment_name, file: ($d + "/" + .path)} ]' <<< "${decisions}")"
  [[ "$(jq -r 'length' <<< "${parts}")" -gt 0 ]] || {
    printf '{"created":[],"status":0}'
    return 0
  }
  # Redirection, NOT a command substitution: `$( … )` would run the transport in
  # a subshell and JIRA_LAST_STATUS would die with it — the whole reason this
  # function exists in this shape.
  local respfile body
  respfile="$(mktemp)"
  JIRA_LAST_STATUS=0
  jira_request_multipart POST "${base}/rest/api/3/issue/${key}/attachments" "${parts}" > "${respfile}" || true
  body="$(cat "${respfile}" 2> /dev/null)"
  rm -f "${respfile}"
  # shellcheck disable=SC2016  # a jq filter: $s/$c are jq variables
  json_build '{status: $s, created: $c}' \
    s "${JIRA_LAST_STATUS:-0}" \
    c "$(jq -c '.' <<< "${body}" 2> /dev/null || printf '[]')" | json_canonical
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
