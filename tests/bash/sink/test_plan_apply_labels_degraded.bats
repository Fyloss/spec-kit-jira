#!/usr/bin/env bats
# T023 [US2] — the provenance label's two degradation triggers (017,
# contracts/provenance-label.md §4, contract §6 T7/T13): a type whose
# metadata offers no `labels` omits it with one warning, every ticket still
# mirrored; a slug pushing the rendered label past JIRA_LABEL_MAX_LENGTH omits
# it with one warning naming the measured length, never truncated. Neither
# trigger ever refuses or drops a write.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/plan_apply.sh"
}

_doc_one_story() {
  local slug="$1"
  jq -cn --arg slug "${slug}" '{
    spec_ref: {spec_slug: $slug},
    routing: {project_key: "COMP"},
    stories: [ {local_id:"S1", title:"New story", priority_logical:null, estimation:null} ]
  }'
}

# --- T7 — (a) the type's metadata offers no labels at all -----------------

@test "T7 — defaultable_fields records the type WITHOUT a labels entry: omitted, one warning, ticket still mirrored" {
  local doc ctx
  doc="$(_doc_one_story "001-test-page")"
  # The fixture's recorded entry MUST carry defaultable:false — the shape
  # discovery actually writes for an array-shaped field (contract §4) — so an
  # implementation reading "present" as defaultable:true fails this test.
  ctx='{
    "base_url":"https://example.atlassian.net","story_type_id":"10102",
    "issue_types":[{"logical_name":"Story","id":"10102"}],
    "defaultable_fields_by_type": {"10102": [
      {"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]}
    ]}
  }'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.stories[0].body.fields | has("labels")' <<< "$output")" = "false" ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"speckit-001-test-page"*"could not be applied to Story in COMP"* ]]
}

@test "T7 — no defaultable_fields entry recorded for the type AT ALL: the label sends (a pre-metadata binding must not gain a second refusal)" {
  local doc ctx
  doc="$(_doc_one_story "001-test-page")"
  ctx='{
    "base_url":"https://example.atlassian.net","story_type_id":"10102",
    "issue_types":[{"logical_name":"Story","id":"10102"}]
  }'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.labels | join(",")' <<< "$output")" = "speckit-001-test-page" ]
  [ "$(jq -r 'has("warnings")' <<< "$output")" = "false" ]
}

@test "T7 — defaultable_fields records the type WITH a labels entry present: the label sends" {
  local doc ctx
  doc="$(_doc_one_story "001-test-page")"
  ctx='{
    "base_url":"https://example.atlassian.net","story_type_id":"10102",
    "issue_types":[{"logical_name":"Story","id":"10102"}],
    "defaultable_fields_by_type": {"10102": [
      {"logical_name":"Labels","field_id":"labels","schema_type":"array","required":false,"defaultable":false,"allowed_values":[]}
    ]}
  }'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.labels | join(",")' <<< "$output")" = "speckit-001-test-page" ]
  [ "$(jq -r 'has("warnings")' <<< "$output")" = "false" ]
}

# --- T13 — (b) the rendered label is too long for the tracker --------------

@test "T13 — a slug pushing speckit-<slug> past JIRA_LABEL_MAX_LENGTH: absent from every payload, one warning, nothing truncated" {
  local long_slug slug_len doc ctx
  # 264 characters once "speckit-" is prefixed (8 + 256): comfortably over
  # the 255-character limit, and long enough that a truncation bug would be
  # visually obvious in a failing assertion.
  long_slug="001-$(printf 'a%.0s' $(seq 1 252))"
  slug_len="${#long_slug}"
  doc="$(_doc_one_story "${long_slug}")"
  ctx='{
    "base_url":"https://example.atlassian.net","story_type_id":"10102","parent_type_id":"10101",
    "issue_types":[{"logical_name":"Story","id":"10102"},{"logical_name":"Epic","id":"10101"}]
  }'
  doc="$(jq -c '. + {epic:{local_id:"E1", title:"New epic", description:{blocks:[{type:"paragraph", text:"Overview."}]}}}' <<< "${doc}")"
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields | has("labels")' <<< "$output")" = "false" ]
  [ "$(jq -r '.parent.body.fields | has("labels")' <<< "$output")" = "false" ]
  # One warning per TYPE this run touches (story and parent each decide
  # independently) — both name the same over-long slug.
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 2 ]
  local msg="$(jq -r '.warnings[0]' <<< "$output")"
  [[ "${msg}" == *"\"${long_slug}\""* ]]
  [[ "${msg}" == *"$((slug_len + 8)) characters"* ]]
  [[ "${msg}" == *"255-character limit"* ]]
  # Nothing truncated: no payload anywhere carries a label that is a PREFIX
  # of the full (over-long) one.
  [ "$(jq -r '[.stories[0].body.fields, .parent.body.fields] | map(.labels // []) | flatten | map(select(startswith("speckit-001"))) | length' <<< "$output")" -eq 0 ]
}

@test "T13 — a slug within the limit is unaffected" {
  local doc ctx
  doc="$(_doc_one_story "001-a-normal-length-slug")"
  ctx='{"base_url":"https://example.atlassian.net","story_type_id":"10102","issue_types":[{"logical_name":"Story","id":"10102"}]}'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields.labels | join(",")' <<< "$output")" = "speckit-001-a-normal-length-slug" ]
  [ "$(jq -r 'has("warnings")' <<< "$output")" = "false" ]
}
