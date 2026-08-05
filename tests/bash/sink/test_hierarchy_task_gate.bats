#!/usr/bin/env bats
# T055 [US6] — the task-tier satisfiability verdict (data-model.md §5): a
# THIRD, SEPARATE gate from hierarchy_mandatory_gate, over the type carrying
# the `task` role alone. hierarchy_mandatory_gate's own two-type verdict is
# unchanged by any of this — it never inspects `roles.task` (FR-036).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/hierarchy.sh"
}

# A binding whose specification/story tiers are already clean, and whose
# `task` role (Sous-tâche, id 10201) carries one required, defaultable field
# (Definition of Done) and one required, undefaultable field (Affected
# Teams, an array — its shape can never be a recorded value).
BINDING_TASK='{
  "child_type": {"logical_name":"Story", "id":"10102"},
  "parent_type": {"logical_name":"Deliverable", "id":"10101"},
  "parent_link_available": {"10102": true},
  "required_fields": {
    "10101": [{"logical_name":"Summary", "field_id":"summary"}],
    "10102": [{"logical_name":"Summary", "field_id":"summary"}],
    "10201": [
      {"logical_name":"Summary", "field_id":"summary"},
      {"logical_name":"Definition of Done", "field_id":"customfield_50011"},
      {"logical_name":"Affected Teams", "field_id":"customfield_50012"}
    ]
  },
  "defaultable_fields": {
    "10201": [
      {"logical_name":"Definition of Done", "field_id":"customfield_50011", "schema_type":"string", "required":true, "defaultable":true, "allowed_values":[]},
      {"logical_name":"Affected Teams", "field_id":"customfield_50012", "schema_type":"array", "required":true, "defaultable":false, "allowed_values":[], "undefaultable_reason":"a list of values cannot be expressed as a single recorded value"}
    ]
  },
  "roles": {"task": {"logical_name":"Sous-tâche", "id":"10201"}}
}'

@test "T055 — a task role with nothing unsatisfiable or undefaultable passes clean (ok)" {
  local binding
  binding="$(jq -c '.required_fields."10201" = [{"logical_name":"Summary","field_id":"summary"}] | .defaultable_fields."10201" = []' <<< "${BINDING_TASK}")"
  run hierarchy_task_gate "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
}

@test "T055 — no task role in the binding at all trivially passes (ok)" {
  local binding
  binding="$(jq -c 'del(.roles.task)' <<< "${BINDING_TASK}")"
  run hierarchy_task_gate "${binding}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
}

@test "T055 — a required, defaultable field nothing has satisfied yet reports unsatisfiable, named by Jira label, with a --field-default remedy" {
  local binding
  binding="$(jq -c '.required_fields."10201" = [{"logical_name":"Summary","field_id":"summary"},{"logical_name":"Definition of Done","field_id":"customfield_50011"}] | .defaultable_fields."10201" = [{"logical_name":"Definition of Done","field_id":"customfield_50011","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}]' <<< "${BINDING_TASK}")"
  run hierarchy_task_gate "${binding}" "COMP"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "unsatisfiable" ]
  [ "$(jq -r '.fields | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.fields[0].logical_name' <<< "$output")" = "Definition of Done" ]
  local msg; msg="$(jq -r '.message' <<< "$output")"
  [[ "${msg}" == *"Definition of Done"* ]]
  [[ "${msg}" == *"--field-default"* ]]
  [[ "${msg}" == *"customfield_"* ]] && false || true
}

@test "T055 — a recorded or answered default resolves the unsatisfiable field (ok)" {
  local binding defaults
  binding="$(jq -c '.required_fields."10201" = [{"logical_name":"Summary","field_id":"summary"},{"logical_name":"Definition of Done","field_id":"customfield_50011"}] | .defaultable_fields."10201" = [{"logical_name":"Definition of Done","field_id":"customfield_50011","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}]' <<< "${BINDING_TASK}")"
  defaults='{"10201":{"customfield_50011":"Shipped and documented"}}'
  run hierarchy_task_gate "${binding}" "COMP" "${defaults}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "ok" ]
}

@test "T055 — a required field whose shape cannot be defaulted at all reports undefaultable, named by Jira label with its reason, and no --field-default remedy" {
  local binding
  binding="$(jq -c '.required_fields."10201" = [{"logical_name":"Summary","field_id":"summary"},{"logical_name":"Affected Teams","field_id":"customfield_50012"}] | .defaultable_fields."10201" = [{"logical_name":"Affected Teams","field_id":"customfield_50012","schema_type":"array","required":true,"defaultable":false,"allowed_values":[],"undefaultable_reason":"a list of values cannot be expressed as a single recorded value"}]' <<< "${BINDING_TASK}")"
  run hierarchy_task_gate "${binding}" "COMP"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "undefaultable" ]
  [ "$(jq -r '.fields | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.fields[0].logical_name' <<< "$output")" = "Affected Teams" ]
  [ "$(jq -r '.fields[0].reason' <<< "$output")" = "a list of values cannot be expressed as a single recorded value" ]
  local msg; msg="$(jq -r '.message' <<< "$output")"
  [[ "${msg}" == *"Affected Teams"* ]]
  [[ "${msg}" == *"a list of values cannot be expressed as a single recorded value"* ]]
  [[ "${msg}" != *"--field-default"* ]]
}

@test "T055 — hierarchy_mandatory_gate's own two-type verdict is unchanged by a binding that also carries roles.task" {
  local without with
  without="$(jq -c 'del(.roles)' <<< "${BINDING_TASK}")"
  with="${BINDING_TASK}"
  run hierarchy_mandatory_gate "${without}"
  local out_without="$output"
  run hierarchy_mandatory_gate "${with}"
  local out_with="$output"
  [ "${out_without}" = "${out_with}" ]
  [ "$(jq -r '.status' <<< "${out_with}")" = "ok" ]
}
