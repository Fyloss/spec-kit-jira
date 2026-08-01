#!/usr/bin/env bats
# T011 [Phase 1, defect 3] / T013 [Phase 2] — `config_resolved_ids_for`
# reduces discovered issue types to a `{logical_name: id}` map, discarding
# `hierarchy_level` and `subtask` at the exact moment they become durable
# (research R5). RED until Phase 2 lands the list shape (data-model.md §3).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
}

@test "keeps hierarchy_level and subtask" {
  binding='{
    "issue_types": [
      { "logical_name": "Épopée",  "id": "10301", "hierarchy_level": 1,  "subtask": false },
      { "logical_name": "Récit",   "id": "10302", "hierarchy_level": 0,  "subtask": false },
      { "logical_name": "Sous-tâche", "id": "10304", "hierarchy_level": -1, "subtask": true }
    ],
    "priorities": [],
    "statuses": []
  }'
  run config_resolved_ids_for "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issue_types | type' <<< "$output")" = "array" ]
  [ "$(jq -r '.issue_types[] | select(.logical_name=="Récit") | .hierarchy_level' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.issue_types[] | select(.logical_name=="Sous-tâche") | .subtask' <<< "$output")" = "true" ]
}

@test "preserves discovered order and every issue type, priorities/statuses stay maps (T013)" {
  binding='{
    "issue_types": [
      { "logical_name": "Initiative", "id": "10100", "hierarchy_level": 2, "subtask": false },
      { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false },
      { "logical_name": "Story", "id": "10102", "hierarchy_level": 0, "subtask": false },
      { "logical_name": "Defect", "id": "10103", "hierarchy_level": 0, "subtask": false },
      { "logical_name": "Sub-task", "id": "10104", "hierarchy_level": -1, "subtask": true }
    ],
    "priorities": [ { "logical_name": "Highest", "id": "1" } ],
    "statuses": [ { "name": "To Do", "id": "10000" } ]
  }'
  run config_resolved_ids_for "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issue_types | length' <<< "$output")" -eq 5 ]
  [ "$(jq -r '[.issue_types[].logical_name] | join(",")' <<< "$output")" = "Initiative,Deliverable,Story,Defect,Sub-task" ]
  [ "$(jq -r '.priorities | type' <<< "$output")" = "object" ]
  [ "$(jq -r '.priorities.Highest' <<< "$output")" = "1" ]
  [ "$(jq -r '.statuses."To Do"' <<< "$output")" = "10000" ]
}

@test "every logical_name round-trips byte for byte in the new list shape (T014c)" {
  local json yaml tmpf roundtripped
  json='{"resolved_ids":{"COMP":{
    "child_type": {"logical_name":"高/低","id":"1","source":"operator"},
    "issue_types": [
      {"logical_name":"Задача (QA)","id":"1","hierarchy_level":"0","subtask":false},
      {"logical_name":"Done (QA)","id":"2","hierarchy_level":"1","subtask":false},
      {"logical_name":"Épopée","id":"3","hierarchy_level":"2","subtask":false}
    ],
    "required_fields": {"1": [{"logical_name":"Won'"'"'t Do","field_id":"f1"}]}
  }}}'
  yaml="$(printf '%s' "${json}" | config_to_yaml)"
  tmpf="${BATS_TEST_TMPDIR}/roundtrip.yml"
  printf '%s' "${yaml}" > "${tmpf}"
  roundtripped="$(config_yaml_to_json "${tmpf}")"
  [ "$(jq -cS . <<< "${roundtripped}")" = "$(jq -cS . <<< "${json}")" ]
}

@test "required_fields and parent_link_available carry through untouched, omitted when empty (T020)" {
  binding='{
    "issue_types": [ { "logical_name": "Story", "id": "10102", "hierarchy_level": 0, "subtask": false } ],
    "priorities": [], "statuses": [],
    "required_fields": { "10102": [ { "logical_name": "Summary", "field_id": "summary" } ] },
    "parent_link_available": { "10102": true }
  }'
  run config_resolved_ids_for "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.required_fields."10102"[0].logical_name' <<< "$output")" = "Summary" ]
  [ "$(jq -r '.parent_link_available."10102"' <<< "$output")" = "true" ]

  binding_no_hierarchy='{ "issue_types": [], "priorities": [], "statuses": [] }'
  run config_resolved_ids_for "${binding_no_hierarchy}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("required_fields")' <<< "$output")" = "false" ]
  [ "$(jq -r 'has("parent_link_available")' <<< "$output")" = "false" ]
}

@test "a logical_name the reader cannot unescape refuses with a located, redacted message, even nested (T014c/FR-003b)" {
  local json
  json='{"resolved_ids":{"COMP":{"issue_types":[
    {"logical_name":"Bad\"Name","id":"1","hierarchy_level":"0","subtask":false}
  ]}}}'
  run config_to_yaml <<< "${json}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"resolved_ids.COMP.issue_types[0].logical_name"* ]]
  [[ "$output" != *'Bad"Name'* ]]
}
