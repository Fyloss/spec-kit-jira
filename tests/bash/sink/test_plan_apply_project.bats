#!/usr/bin/env bats
# T010 [US1] — plan_writes declares the resolved project in the payload
# (FR-022–FR-024, research R2). RED before plan_apply.sh reads
# doc.routing.project_key through jira_create_fields_base and gains the
# assembly guard.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/plan_apply.sh"
}

_doc() {
  local project="$1"
  jq -cn --arg p "${project}" '{
    schema_version:"1.0",
    spec_ref:{repo:"acme/app", spec_slug:"001-x", folder:"/tmp/001-x"},
    routing:{project_key:$p},
    epic:{strategy:"per_repo", title:"E", description:{blocks:[{type:"paragraph", text:"e"}]}},
    stories:[{local_id:"s1", title:"Story One", priority_logical:"P2",
              description:{blocks:[{type:"paragraph", text:"d"}]}}]
  }'
}

@test "every POST body carries a non-empty fields.project.key equal to routing.project_key (FR-022, FR-023)" {
  local doc ctx
  doc="$(_doc "COMP")"
  ctx='{"base_url":"https://mock","story_type_id":"10004"}'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.[0].body.fields.project.key' <<< "$output")" = "COMP" ]
}

@test "assembly refuses to emit a creation with an empty project (FR-024)" {
  local doc ctx
  doc="$(_doc "")"
  ctx='{"base_url":"https://mock","story_type_id":"10004"}'
  run --separate-stderr plan_writes "${doc}" "${ctx}"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "assembly refuses to emit a creation with an empty issue type (FR-024)" {
  local doc ctx
  doc="$(_doc "COMP")"
  ctx='{"base_url":"https://mock"}'
  run --separate-stderr plan_writes "${doc}" "${ctx}"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "an UPDATE is unaffected by the assembly guard (no issuetype required)" {
  local doc ctx
  doc="$(_doc "COMP")"
  ctx='{"base_url":"https://mock","tickets":{"s1":"COMP-9"}}'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].method' <<< "$output")" = "PUT" ]
}

@test "the base fields come from jira_create_fields_base, unchanged (FR-025, SC-010)" {
  local doc ctx base
  doc="$(_doc "COMP")"
  ctx='{"base_url":"https://mock","story_type_id":"10004"}'
  base="$(jira_create_fields_base "COMP" "Story One" "10004")"
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0].body.fields.project, .[0].body.fields.issuetype, .[0].body.fields.summary' <<< "$output" | jq -cs .)" \
    = "$(jq -c '.project, .issuetype, .summary' <<< "${base}" | jq -cs .)" ]
}
