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

# --- T078 [Phase 9] — the `roles` shape (010, contract §5.1, §9.2) ---------

@test "T078 — roles.<role> round-trips {logical_name, id, hierarchy_level, subtask, source} with hierarchy_level as a STRING" {
  local json yaml tmpf roundtripped
  json='{"resolved_ids":{"CONSUMER":{
    "roles": {
      "specification": {"logical_name":"Epic","id":"10701","hierarchy_level":"1","subtask":false,"source":"declared"},
      "story":         {"logical_name":"Story","id":"10704","hierarchy_level":"0","subtask":false,"source":"declared"},
      "task":          {"logical_name":"Sous-tâche","id":"10716","hierarchy_level":"-1","subtask":true,"source":"declared"}
    },
    "child_type":  {"logical_name":"Story","id":"10704","source":"declared"},
    "parent_type": {"logical_name":"Epic","id":"10701","source":"declared"}
  }}}'
  yaml="$(printf '%s' "${json}" | config_to_yaml)"
  tmpf="${BATS_TEST_TMPDIR}/roundtrip-roles.yml"
  printf '%s' "${yaml}" > "${tmpf}"
  roundtripped="$(config_yaml_to_json "${tmpf}")"
  [ "$(jq -cS . <<< "${roundtripped}")" = "$(jq -cS . <<< "${json}")" ]
  # hierarchy_level survives as a JSON string, never a number (the YAML
  # round-trip has no number type — contract §5.1).
  [ "$(jq -r '.resolved_ids.CONSUMER.roles.story.hierarchy_level | type' <<< "${roundtripped}")" = "string" ]
}

@test "T078 — roles.story ≡ child_type and roles.specification ≡ parent_type on the declared-hierarchy fixture" {
  local fixture; fixture="${ROOT}/tests/conformance/fixtures/repo-with-declared-hierarchy/.specify/jira/config.local.yml"
  local json; json="$(config_yaml_to_json "${fixture}")"
  [ "$(jq -cS '.resolved_ids.CONSUMER.roles.story | {logical_name, id, source}' <<< "${json}")" = \
    "$(jq -cS '.resolved_ids.CONSUMER.child_type' <<< "${json}")" ]
  [ "$(jq -cS '.resolved_ids.CONSUMER.roles.specification | {logical_name, id, source}' <<< "${json}")" = \
    "$(jq -cS '.resolved_ids.CONSUMER.parent_type' <<< "${json}")" ]
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

# --- T009 [Phase 2, 011] — defaultable_fields carries through the binding
# reshape and survives the round trip, keyed by issue-type id -------------

@test "T009 [011] — defaultable_fields carries straight through config_resolved_ids_for, keyed by issue-type id" {
  binding='{
    "issue_types": [ { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false } ],
    "priorities": [], "statuses": [],
    "defaultable_fields": { "10101": [
      { "logical_name": "Business Owner", "field_id": "customfield_40011", "schema_type": "user",
        "required": true, "defaultable": true, "allowed_values": [] }
    ] }
  }'
  run config_resolved_ids_for "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.defaultable_fields."10101"[0].logical_name' <<< "$output")" = "Business Owner" ]
}

@test "T009 [011] — defaultable_fields is OMITTED, never emitted empty, when discovery resolved no type" {
  binding='{ "issue_types": [], "priorities": [], "statuses": [] }'
  run config_resolved_ids_for "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("defaultable_fields")' <<< "$output")" = "false" ]
}

@test "T009 [011] — a full defaultable_fields entry (allowed_values + undefaultable_reason) round-trips byte for byte" {
  local json yaml tmpf roundtripped
  json='{"resolved_ids":{"PM":{
    "defaultable_fields": { "10101": [
      { "logical_name": "Business Owner", "field_id": "customfield_40011", "schema_type": "user",
        "required": true, "defaultable": true, "allowed_values": [] },
      { "logical_name": "Program Increment", "field_id": "customfield_40012", "schema_type": "option",
        "required": true, "defaultable": true, "allowed_values": ["PI-2026-Q2", "PI-2026-Q3"] },
      { "logical_name": "Attachment", "field_id": "attachment", "schema_type": "array",
        "required": true, "defaultable": false, "allowed_values": [],
        "undefaultable_reason": "a list of values cannot be expressed as a single recorded value" }
    ] }
  }}}'
  yaml="$(printf '%s' "${json}" | config_to_yaml)"
  tmpf="${BATS_TEST_TMPDIR}/roundtrip-defaultable.yml"
  printf '%s' "${yaml}" > "${tmpf}"
  roundtripped="$(config_yaml_to_json "${tmpf}")"
  [ "$(jq -cS . <<< "${roundtripped}")" = "$(jq -cS . <<< "${json}")" ]
}

@test "T009 [011] — a second write of the same binding is byte-identical (FR-007's persistence half)" {
  binding='{
    "issue_types": [ { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false } ],
    "priorities": [], "statuses": [],
    "defaultable_fields": { "10101": [
      { "logical_name": "Business Owner", "field_id": "customfield_40011", "schema_type": "user",
        "required": true, "defaultable": true, "allowed_values": [] }
    ] }
  }'
  local first second
  first="$(config_resolved_ids_for "${binding}")"
  second="$(config_resolved_ids_for "${binding}")"
  [ "${first}" = "${second}" ]
}

@test "T009 [011] — a binding written BEFORE this feature (no defaultable_fields key at all) still loads" {
  # A dedicated inline fixture, not tests/conformance/fixtures/repo-with-mandatory-field —
  # that shared fixture has since gained defaultable_fields of its own, to let the
  # US3 reconcile scenarios exercise the consolidated question without a config
  # ceremony run first. Reusing it here would test the wrong thing.
  local json yaml tmpf
  json='{"resolved_ids":{"PM":{
    "issue_types": [ { "logical_name": "Deliverable", "id": "10101", "hierarchy_level": 1, "subtask": false } ],
    "priorities": [], "statuses": [],
    "required_fields": { "10101": [
      { "logical_name": "Summary", "field_id": "summary" },
      { "logical_name": "Business Owner", "field_id": "customfield_40011" },
      { "logical_name": "Program Increment", "field_id": "customfield_40012" }
    ] }
  }}}'
  yaml="$(printf '%s' "${json}" | config_to_yaml)"
  tmpf="${BATS_TEST_TMPDIR}/pre-011-binding.yml"
  printf '%s' "${yaml}" > "${tmpf}"
  run config_yaml_to_json "${tmpf}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.resolved_ids.PM | has("defaultable_fields")' <<< "$output")" = "false" ]
  # required_fields, written by the pre-011 shape, is untouched.
  [ "$(jq -r '.resolved_ids.PM.required_fields."10101" | length' <<< "$output")" -eq 3 ]
}
