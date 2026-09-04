#!/usr/bin/env bats
# T034/T036/T039/T044/T052/T053/T057/T061/T063 [036] — the publication decision
# and everything downstream of it
# (036 contracts/artifact-publication.md C1, C4; contracts/comment-body.md).
#
# These are the PURE parts: classification, the comment body, the manifest.
# They need no network, and they are where the feature's correctness actually
# lives — the request shapes are covered by test_client_multipart.bats and the
# mock contract guard, and the end-to-end behaviour by the command suites.
#
# The zero-churn cycle is the assertion that matters most and it is the last
# block: publish, record, re-classify. If the hash does not survive that round
# trip the feature re-uploads everything forever while looking like it works.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/attachments.sh"
  CONTRACT="${ROOT}/specs/036-attach-feature-artifacts/contracts/comment-body.md"

  SET='[
    {"path":"spec.md",         "hash":"aaa","size":10,"attachment_name":"spec.md"},
    {"path":"contracts/api.md","hash":"bbb","size":5, "attachment_name":"contracts__api.md"}
  ]'
}

# --- C4.1: the four classifications ----------------------------------------

@test "C4.1 an artifact absent from the manifest is a first publication" {
  run attachments_classify "${SET}" '{}' 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "published" ]
  [ "$(jq -r '.[1].action' <<< "$output")" = "published" ]
}

@test "C4.1 an artifact whose hash differs is a revision" {
  run attachments_classify "${SET}" '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"after_specify"}}' 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "revised" ]
}

@test "C4.1 an artifact whose hash matches is unchanged — the zero-write case" {
  run attachments_classify "${SET}" '{"spec.md":{"hash":"aaa","attachment_id":"1","run":"after_specify"}}' 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "unchanged" ]
}

@test "C4.3 the trust rule republishes when the ticket does not carry the claimed id" {
  # The manifest is ahead of reality: the property write landed, the upload did
  # not. Without this the artifact would read `unchanged` forever and never
  # actually exist on the ticket.
  run attachments_classify "${SET}" \
    '{"spec.md":{"hash":"aaa","attachment_id":"999","run":"after_specify"}}' 100 '["1","2"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "published" ]
}

@test "C4.3 the trust rule leaves an artifact unchanged when the id IS on the ticket" {
  run attachments_classify "${SET}" \
    '{"spec.md":{"hash":"aaa","attachment_id":"1","run":"after_specify"}}' 100 '["1","2"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "unchanged" ]
}

# --- C4.2: withholding, and its precedence ---------------------------------

@test "FR-017 an artifact above the discovered limit is withheld, naming size and limit" {
  run attachments_classify "${SET}" '{}' 6
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "withheld" ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "oversized" ]
  [ "$(jq -r '.[0].size' <<< "$output")" -eq 10 ]
  [ "$(jq -r '.[0].limit' <<< "$output")" -eq 6 ]
  # And the rest still publishes — FR-017's "MUST NOT prevent the remaining".
  [ "$(jq -r '.[1].action' <<< "$output")" = "published" ]
}

@test "FR-005 two artifacts sharing an attachment name are BOTH withheld, each naming the other" {
  local colliding='[
    {"path":"contracts/x.md","hash":"a","size":1,"attachment_name":"c.md"},
    {"path":"c.md",          "hash":"b","size":1,"attachment_name":"c.md"}
  ]'
  run attachments_classify "${colliding}" '{}' 100
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].action' <<< "$output")" = "withheld" ]
  [ "$(jq -r '.[1].action' <<< "$output")" = "withheld" ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "name-collision" ]
  [ "$(jq -r '.[0].collides_with' <<< "$output")" = "c.md" ]
  [ "$(jq -r '.[1].collides_with' <<< "$output")" = "contracts/x.md" ]
}

@test "C4.2 a collision outranks an oversize, so warnings are deterministic across ports" {
  local both='[
    {"path":"contracts/x.md","hash":"a","size":9999,"attachment_name":"c.md"},
    {"path":"c.md",          "hash":"b","size":1,   "attachment_name":"c.md"}
  ]'
  run attachments_classify "${both}" '{}' 10
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].reason' <<< "$output")" = "name-collision" ]
}

@test "C4.1 a limit of 0 disables the size gate rather than withholding everything" {
  # A run that could not read the site limit must not silently decide every
  # artifact is too big.
  run attachments_classify "${SET}" '{}' 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.action == "withheld")] | length' <<< "$output")" -eq 0 ]
}

# --- comment-body.md: the pinned literals ----------------------------------

# The paragraph as a reader sees it, with the event put back where the contract
# writes `<event>` — so the assertion compares against the contract's own line
# rather than a copy of it that could drift with it.
_paragraph_text() {
  local body="$1"
  printf '%s`<event>`%s' \
    "$(jq -r '.content[0].content[0].text' <<< "${body}")" \
    "$(jq -r '.content[0].content[2].text' <<< "${body}")"
}

_contract_line() { sed -n "$1p" "${CONTRACT}" | sed 's/^  //'; }

@test "B2 the all-new paragraph is byte-identical to the contract's literal" {
  local d body
  d="$(attachments_classify "${SET}" '{}' 100)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "$(_paragraph_text "${body}")" = "$(_contract_line 36)" ]
}

@test "B2 the revision paragraph is byte-identical to the contract's literal" {
  local d body
  d="$(attachments_classify "${SET}" '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"x"}}' 100)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "$(_paragraph_text "${body}")" = "$(_contract_line 42)" ]
}

@test "B2 the lifecycle event is rendered as code-marked text, verbatim" {
  local d body
  d="$(attachments_classify "${SET}" '{}' 100)"
  body="$(attachments_comment_body after_converge "${d}")"
  [ "$(jq -r '.content[0].content[1].text' <<< "${body}")" = "after_converge" ]
  [ "$(jq -r '.content[0].content[1].marks[0].type' <<< "${body}")" = "code" ]
}

@test "B3 one list item per published artifact, in set order, path code-marked" {
  local d body
  d="$(attachments_classify "${SET}" '{}' 100)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "$(jq -r '.content[1].content | length' <<< "${body}")" -eq 2 ]
  [ "$(jq -r '.content[1].content[0].content[0].content[0].text' <<< "${body}")" = "spec.md" ]
  [ "$(jq -r '.content[1].content[0].content[0].content[0].marks[0].type' <<< "${body}")" = "code" ]
  [ "$(jq -r '.content[1].content[1].content[0].content[0].text' <<< "${body}")" = "contracts/api.md" ]
}

@test "B3 a new artifact reads ' — new' and a revised one ' — revised'" {
  local d body
  d="$(attachments_classify "${SET}" '{"spec.md":{"hash":"OLD","attachment_id":"1","run":"x"}}' 100)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "$(jq -r '.content[1].content[0].content[0].content[1].text' <<< "${body}")" = " — revised" ]
  [ "$(jq -r '.content[1].content[1].content[0].content[1].text' <<< "${body}")" = " — new" ]
}

@test "B4 a withheld artifact is ABSENT from the comment" {
  # The comment announces what a reader can now download; naming a file that is
  # not there is worse than silence. The summary reports it instead.
  local d body
  d="$(attachments_classify "${SET}" '{}' 6)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "$(jq -r '.content[1].content | length' <<< "${body}")" -eq 1 ]
  ! grep -q 'spec.md' <<< "$(jq -r '.content[1]' <<< "${body}")"
}

@test "B1 the body is a valid ADF doc with no media node" {
  local d body
  d="$(attachments_classify "${SET}" '{}' 100)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "$(jq -r '.type' <<< "${body}")" = "doc" ]
  [ "$(jq -r '.version' <<< "${body}")" -eq 1 ]
  ! grep -q '"media"' <<< "${body}"
}

@test "B6.4 the body carries no trailing newline" {
  local d body
  d="$(attachments_classify "${SET}" '{}' 100)"
  body="$(attachments_comment_body after_plan "${d}")"
  [ "${body: -1}" = "}" ]
}

# --- data-model §2: the manifest -------------------------------------------

@test "data-model §2 the manifest records path, hash, id and the run that published" {
  local d m
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" \
    '[{"id":"10001","filename":"spec.md"},{"id":"10002","filename":"contracts__api.md"}]' after_plan)"
  [ "$(jq -r '."spec.md".hash' <<< "${m}")" = "aaa" ]
  [ "$(jq -r '."spec.md".attachment_id' <<< "${m}")" = "10001" ]
  [ "$(jq -r '."spec.md".run' <<< "${m}")" = "after_plan" ]
  [ "$(jq -r '."contracts/api.md".attachment_id' <<< "${m}")" = "10002" ]
}

@test "data-model §2 an upload that did not land contributes nothing to the manifest" {
  # `created` is the sink's own response: one entry short means one upload did
  # not happen, and the next run must retry it rather than record it as done.
  local d m
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" '[{"id":"10001","filename":"spec.md"}]' after_plan)"
  [ "$(jq -r 'has("spec.md")' <<< "${m}")" = "true" ]
  [ "$(jq -r 'has("contracts/api.md")' <<< "${m}")" = "false" ]
}

@test "FR-015 a path no longer in the set keeps its manifest entry" {
  # Its attachment still exists on the ticket, so the manifest still describes
  # reality. Dropping it would make a later re-add look like a first publication.
  local d m
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{"gone.md":{"hash":"z","attachment_id":"7","run":"old"}}' \
    "${d}" '[{"id":"1"},{"id":"2"}]' after_plan)"
  [ "$(jq -r '."gone.md".attachment_id' <<< "${m}")" = "7" ]
}

@test "C4.4.1 a manifest that would exceed the property cap is detected" {
  local big
  big="$(jq -cn '[range(0;400)] | map({key: ("contracts/c" + (. | tostring) + ".md"),
        value: {hash: "0123456789abcdef0123456789abcdef01234567", attachment_id: "1", run: "after_plan"}}) | from_entries')"
  run attachments_manifest_oversized "${big}"
  [ "$status" -eq 0 ]
}

@test "C4.4.1 an ordinary manifest is not flagged" {
  local d m
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" '[{"id":"1"},{"id":"2"}]' after_plan)"
  run attachments_manifest_oversized "${m}"
  [ "$status" -ne 0 ]
}

# --- C4.5: the zero-churn cycle, end to end --------------------------------

@test "C4.5 publish, record, re-classify: the second pass is entirely unchanged" {
  # THE assertion. If the hash does not survive the manifest round trip, every
  # later run reads "the hash differs" and the feature re-uploads everything
  # forever while looking like it works.
  local d m d2
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" \
    '[{"id":"10001","filename":"spec.md"},{"id":"10002","filename":"contracts__api.md"}]' after_plan)"
  d2="$(attachments_classify "${SET}" "${m}" 100)"
  [ "$(jq -r '[.[] | select(.action != "unchanged")] | length' <<< "${d2}")" -eq 0 ]
}

@test "C4.5 a run with nothing to publish produces an empty part list" {
  local d m d2 parts
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" '[{"id":"1"},{"id":"2"}]' after_plan)"
  d2="$(attachments_classify "${SET}" "${m}" 100)"
  parts="$(jq -c '[.[] | select(.action == "published" or .action == "revised")]' <<< "${d2}")"
  [ "$(jq -r 'length' <<< "${parts}")" -eq 0 ]
}

@test "C4.5 changing exactly one artifact republishes exactly that one" {
  local d m changed d2
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" '[{"id":"1"},{"id":"2"}]' after_plan)"
  changed='[
    {"path":"spec.md",         "hash":"NEW","size":10,"attachment_name":"spec.md"},
    {"path":"contracts/api.md","hash":"bbb","size":5, "attachment_name":"contracts__api.md"}
  ]'
  d2="$(attachments_classify "${changed}" "${m}" 100)"
  [ "$(jq -r '.[0].action' <<< "${d2}")" = "revised" ]
  [ "$(jq -r '.[1].action' <<< "${d2}")" = "unchanged" ]
}

# --- C4.4: the composed size is a BYTE COUNT of the document, both ports ------

@test "C4.4 the manifest size counts the document, not jq's trailing newline" {
  # Found by the conformance corpus, in a message an operator reads: bash said
  # a 6-artifact record needed 642 bytes and PowerShell said 641. `json_build`
  # ends with `jq -cn`, which emits a trailing newline; `wc -c` counted it. The
  # PUT body has no such byte, so the Bash port measured a document nobody
  # sends — and, worse, applied a threshold one byte tighter than its twin, so
  # at exactly one boundary size the two ports disagreed about whether a
  # manifest overflows at all.
  local d m size expected
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" '[{"id":"1"},{"id":"2"}]' after_plan)"
  size="$(attachments_manifest_size "${m}")"

  # The document exactly as attachments_manifest_write composes it for the body.
  expected="$(printf '%s' "$(jq -cn --argjson sc 1 --argjson a "${m}" '{schema: $sc, artifacts: $a}')" | LC_ALL=C wc -c | tr -d '[:space:]')"
  [ "${size}" -eq "${expected}" ]
}

@test "C4.4 both ports compute the identical manifest size" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local d m mine theirs f
  d="$(attachments_classify "${SET}" '{}' 100)"
  m="$(attachments_manifest_compose '{}' "${d}" '[{"id":"1"},{"id":"2"}]' after_plan)"
  mine="$(attachments_manifest_size "${m}")"

  # Through a FILE, never the -Command string: this JSON carries quote
  # characters two shells each want to interpret.
  f="${BATS_TEST_TMPDIR}/manifest.json"
  printf '%s' "${m}" > "${f}"
  theirs="$(pwsh -NoProfile -Command "Import-Module '${ROOT}/scripts/powershell/sink/jira/Attachments.psm1' -Force; [Console]::Out.Write((Get-JiraManifestSize -ArtifactsJson ([System.IO.File]::ReadAllText('${f}'))))")"
  [ "${mine}" = "${theirs}" ]
}
