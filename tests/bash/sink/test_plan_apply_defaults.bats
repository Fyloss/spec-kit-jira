#!/usr/bin/env bats
# T025/T027 [Phase 2, 011] — label -> id resolution and precedence (research
# R2, contract §3.1/§3.2, data-model.md §3). `plan_resolve_field_defaults`
# joins the labels `config.yml`'s field_defaults holds to the ids the
# binding's defaultable_fields holds, for one project: an answer supplied to
# this run wins over the recorded default; an unresolvable label is
# reported, never silently dropped; the result is keyed issue-type id ->
# field id -> value, with a parallel source map.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/plan_apply.sh"
  ITYPES='[{"logical_name":"Epic","id":"10101"},{"logical_name":"Story","id":"10102"}]'
  DEFAULTABLE='{"10101":[
    {"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]},
    {"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}
  ]}'
}

@test "a recorded label resolves to its field id through the binding's defaultable_fields, source team-config" {
  local recorded='{"Epic":{"Business Owner":"Platform Team"}}'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "${recorded}" "[]"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.field_defaults."10101"."customfield_40011"' <<< "$output")" = "Platform Team" ]
  [ "$(jq -r '.field_default_sources."10101"."customfield_40011"' <<< "$output")" = "team-config" ]
}

@test "an answer for this run wins over the recorded default, source operator-answer" {
  local recorded='{"Epic":{"Business Owner":"Platform Team"}}'
  local answers='[{"type":"Epic","label":"Business Owner","value":"Override Team"}]'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "${recorded}" "${answers}"
  [ "$(jq -r '.field_defaults."10101"."customfield_40011"' <<< "$output")" = "Override Team" ]
  [ "$(jq -r '.field_default_sources."10101"."customfield_40011"' <<< "$output")" = "operator-answer" ]
}

@test "an answer for a field with no recorded default is applied on its own" {
  local answers='[{"type":"Epic","label":"Program Increment","value":"PI-2026-Q3"}]'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "{}" "${answers}"
  [ "$(jq -r '.field_defaults."10101"."customfield_40012"' <<< "$output")" = "PI-2026-Q3" ]
}

@test "an unresolvable field label is reported, never silently dropped" {
  local recorded='{"Epic":{"Nonexistent Field":"X"}}'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.unresolved[0].type' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.unresolved[0].label' <<< "$output")" = "Nonexistent Field" ]
}

@test "an unresolvable issue-type name is reported, never silently dropped" {
  local recorded='{"NoSuchType":{"Team":"Payments"}}'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "${recorded}" "[]"
  [ "$(jq -r '.unresolved[0].type' <<< "$output")" = "NoSuchType" ]
}

@test "the 'ask' key of the recorded map is never mistaken for an issue-type name" {
  local recorded='{"ask":false,"Epic":{"Business Owner":"Platform Team"}}'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "${recorded}" "[]"
  [ "$(jq -r '.unresolved | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.field_defaults."10101"."customfield_40011"' <<< "$output")" = "Platform Team" ]
}

@test "the result is keyed issue-type id -> field id -> value, never by label or type name" {
  local recorded='{"Epic":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q3"}}'
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults | keys | join(",")' <<< "$output")" = "10101" ]
  [ "$(jq -r '.field_defaults."10101" | keys | sort | join(",")' <<< "$output")" = "customfield_40011,customfield_40012" ]
}

@test "empty inputs resolve to nothing, never an error" {
  run plan_resolve_field_defaults "${ITYPES}" "${DEFAULTABLE}" "{}" "[]"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.field_defaults | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.unresolved | length' <<< "$output")" -eq 0 ]
}

# --- T054/T057 — plan_confirmation_fields (011, Phase 4, US2, contract §3.3,
# data-model.md §4): the confirmation-pending question's `fields` array,
# scoped to the types with a creation pending this run.

@test "a field about to be sent is included with its recorded value" {
  local defaults='{"10101":{"customfield_40011":"Platform Team"}}'
  run plan_confirmation_fields "${ITYPES}" "${DEFAULTABLE}" "${defaults}" '["10101"]'
  [ "$status" -eq 0 ]
  # Program Increment is also required, with no resolved value — included too (recorded_value null).
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  local bo; bo="$(jq -c '[.[] | select(.label == "Business Owner")][0]' <<< "$output")"
  [ "$(jq -r '.issue_type' <<< "$bo")" = "Epic" ]
  [ "$(jq -r '.recorded_value' <<< "$bo")" = "Platform Team" ]
  [ "$(jq -r '.required' <<< "$bo")" = "true" ]
}

@test "a required field with no resolved value is included with recorded_value null" {
  run plan_confirmation_fields "${ITYPES}" "${DEFAULTABLE}" "{}" '["10101"]'
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.[] | select(.label == "Program Increment")][0].recorded_value' <<< "$output")" = "null" ]
}

@test "a merely-defaultable optional field with no resolved value is never included" {
  local optional_df='{"10101":[
    {"logical_name":"Team Nickname","field_id":"customfield_40099","schema_type":"string","required":false,"defaultable":true,"allowed_values":[]}
  ]}'
  run plan_confirmation_fields "${ITYPES}" "${optional_df}" "{}" '["10101"]'
  [ "$(jq -r 'length' <<< "$output")" -eq 0 ]
}

@test "a type the project offers but has no creation pending this run contributes nothing" {
  local defaults='{"10101":{"customfield_40011":"Platform Team"}}'
  run plan_confirmation_fields "${ITYPES}" "${DEFAULTABLE}" "${defaults}" '[]'
  [ "$(jq -r 'length' <<< "$output")" -eq 0 ]
}

@test "allowed_values is carried through for a field that has them" {
  local df='{"10101":[
    {"logical_name":"Program Increment","field_id":"customfield_40012","schema_type":"option","required":true,"defaultable":true,"allowed_values":["PI-2026-Q2","PI-2026-Q3"]}
  ]}'
  run plan_confirmation_fields "${ITYPES}" "${df}" "{}" '["10101"]'
  [ "$(jq -r '.[0].allowed_values | join(",")' <<< "$output")" = "PI-2026-Q2,PI-2026-Q3" ]
}

# --- T027 — no default reaches an update, whatever is recorded or changed --

@test "T027 — an UPDATE (existing ticket) is built with a payload carrying no defaulted field, even when defaults are recorded" {
  local doc='{
    "routing": {"project_key": "CONSUMER"},
    "stories": [ {"local_id":"S1","title":"Existing story","priority_logical":null,"estimation":null} ]
  }'
  local ctx='{
    "base_url":"https://example.atlassian.net","story_type_id":"10102",
    "tickets": {"S1":"CONSUMER-9"},
    "field_defaults": {"10102": {"customfield_50001": "Payments"}}
  }'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].method' <<< "$output")" = "PUT" ]
  [ "$(jq -r '.stories[0].body.fields | has("customfield_50001")' <<< "$output")" = "false" ]
}

# --- T033 — the CREATE branch acquires field_defaults from the plan context

@test "T033 — a story CREATE merges field_defaults from the plan context" {
  local doc='{
    "routing": {"project_key": "CONSUMER"},
    "stories": [ {"local_id":"S1","title":"New story","priority_logical":null,"estimation":null} ]
  }'
  local ctx='{
    "base_url":"https://example.atlassian.net","story_type_id":"10102",
    "field_defaults": {"10102": {"customfield_50001": "Payments"}}
  }'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.stories[0].body.fields.customfield_50001' <<< "$output")" = "Payments" ]
}

@test "T033 — a parent CREATE merges field_defaults, scoped to the parent type" {
  local doc='{
    "routing": {"project_key": "CONSUMER"},
    "epic": {"local_id":"E1","title":"New epic","description":{"blocks":[{"type":"paragraph","spans":[{"text":"Overview.","marks":[]}]}]}},
    "stories": []
  }'
  local ctx='{
    "base_url":"https://example.atlassian.net","parent_type_id":"10101",
    "field_defaults": {"10101": {"customfield_40011": "Platform Team"}, "10102": {"customfield_50001": "Payments"}}
  }'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent.body.fields.customfield_40011' <<< "$output")" = "Platform Team" ]
  [ "$(jq -r '.parent.body.fields | has("customfield_50001")' <<< "$output")" = "false" ]
}

@test "T033 — no field_defaults key in the context leaves every payload byte-identical to before this feature (FR-028)" {
  local doc='{
    "routing": {"project_key": "CONSUMER"},
    "stories": [ {"local_id":"S1","title":"New story","priority_logical":null,"estimation":null} ]
  }'
  local ctx='{"base_url":"https://example.atlassian.net","story_type_id":"10102"}'
  run plan_writes "${doc}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].body.fields | keys | sort | join(",")' <<< "$output")" = "description,issuetype,parent,project,summary" ]
}

# --- 015, T008 [US1] — the encoding table (contract §1.3, data-model.md §2) -
# `plan_resolve_field_defaults` emits `field_defaults_encoded` alongside the
# unchanged `field_defaults`, shaping each value for the wire per its
# field's declared schema_type.

setup_015() {
  ITYPES_015='[{"logical_name":"Epic","id":"10101"}]'
}

@test "015 T008 — a select-list (option) default is encoded as {value: v}" {
  setup_015
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}]}'
  local recorded='{"Epic":{"Region":"EMEA"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.field_defaults_encoded."10101"."customfield_1"' <<< "$output")" = '{"value":"EMEA"}' ]
  [ "$(jq -r '.field_defaults."10101"."customfield_1"' <<< "$output")" = "EMEA" ]
}

@test "015 T008 — each named-entity schema_type is encoded as {name: v}" {
  setup_015
  for st in priority resolution version component group; do
    local df='{"10101":[{"logical_name":"F","field_id":"customfield_2","schema_type":"'"${st}"'","required":true,"defaultable":true,"allowed_values":[]}]}'
    local recorded='{"Epic":{"F":"Val"}}'
    run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
    [ "$status" -eq 0 ]
    [ "$(jq -c '.field_defaults_encoded."10101"."customfield_2"' <<< "$output")" = '{"name":"Val"}' ]
  done
}

@test "015 T008 — a string-typed default falls through unencoded" {
  setup_015
  local df='{"10101":[{"logical_name":"F","field_id":"customfield_3","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}]}'
  local recorded='{"Epic":{"F":"Plain text"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults_encoded."10101"."customfield_3"' <<< "$output")" = "Plain text" ]
}

@test "015 T008 (FR-004) — a user-typed default falls through unencoded, deliberately excluded from the table" {
  setup_015
  local df='{"10101":[{"logical_name":"Business Owner","field_id":"customfield_40011","schema_type":"user","required":true,"defaultable":true,"allowed_values":[]}]}'
  local recorded='{"Epic":{"Business Owner":"Platform Team"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults_encoded."10101"."customfield_40011"' <<< "$output")" = "Platform Team" ]
}

@test "015 T008 — a cascading select (option-with-child) falls through unencoded — deliberately absent from the table" {
  setup_015
  local df='{"10101":[{"logical_name":"Cascade","field_id":"customfield_4","schema_type":"option-with-child","required":true,"defaultable":true,"allowed_values":[]}]}'
  local recorded='{"Epic":{"Cascade":"Parent Value"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults_encoded."10101"."customfield_4"' <<< "$output")" = "Parent Value" ]
}

@test "015 T008 (FR-006) — the non-string guard: a non-string recorded value passes through unchanged even for an option field" {
  setup_015
  local df='{"10101":[{"logical_name":"Flag","field_id":"customfield_5","schema_type":"option","required":false,"defaultable":true,"allowed_values":[]}]}'
  local recorded='[{"type":"Epic","label":"Flag","value":true}]'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "{}" "${recorded}"
  [ "$(jq -c '.field_defaults_encoded."10101"."customfield_5"' <<< "$output")" = "true" ]
  [ "$(jq -c '.field_defaults."10101"."customfield_5"' <<< "$output")" = "true" ]
}

@test "015 T050 (US2/AC4) — a this-run answer on an option-typed field encodes identically to the same text recorded" {
  setup_015
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]}]}'
  local answers='[{"type":"Epic","label":"Region","value":"EMEA"}]'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "{}" "${answers}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.field_defaults_encoded."10101"."customfield_1"' <<< "$output")" = '{"value":"EMEA"}' ]

  local recorded='{"Epic":{"Region":"EMEA"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -c '.field_defaults_encoded."10101"."customfield_1"' <<< "$output")" = '{"value":"EMEA"}' ]
}

@test "015 T008 (FR-007) — a label resolving to no field falls through as recorded, and unresolved stays byte-identical to today" {
  setup_015
  local df='{"10101":[]}'
  local recorded='{"Epic":{"Nonexistent":"X"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.field_defaults_encoded | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.unresolved[0].reason' <<< "$output")" = "unknown field label" ]
}

@test "015 T008 (FR-007) — a field with absent schema_type falls through as recorded" {
  setup_015
  local df='{"10101":[{"logical_name":"F","field_id":"customfield_6","required":true,"defaultable":true,"allowed_values":[]}]}'
  local recorded='{"Epic":{"F":"Val"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults_encoded."10101"."customfield_6"' <<< "$output")" = "Val" ]
}

@test "015 (data-model §2 I1/I2) — field_defaults is unchanged, and both maps share an identical key set" {
  setup_015
  local df='{"10101":[
    {"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA"]},
    {"logical_name":"F","field_id":"customfield_3","schema_type":"string","required":true,"defaultable":true,"allowed_values":[]}
  ]}'
  local recorded='{"Epic":{"Region":"EMEA","F":"Plain"}}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "${recorded}" "[]"
  [ "$(jq -r '.field_defaults."10101" | keys | sort | join(",")' <<< "$output")" = "customfield_1,customfield_3" ]
  [ "$(jq -r '.field_defaults_encoded."10101" | keys | sort | join(",")' <<< "$output")" = "customfield_1,customfield_3" ]
  [ "$(jq -r '.field_defaults."10101".Region // empty' <<< "$output")" = "" ]
}

@test "015 (data-model §2 I4) — nothing recorded and no answer: both maps are {} and the output is byte-identical to today's" {
  setup_015
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":false,"defaultable":true,"allowed_values":[]}]}'
  run plan_resolve_field_defaults "${ITYPES_015}" "${df}" "{}" "[]"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'keys' <<< "$output")" = '["field_default_sources","field_defaults","field_defaults_encoded","unresolved"]' ]
  [ "$(jq -r '.field_defaults | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.field_defaults_encoded | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.unresolved | length' <<< "$output")" -eq 0 ]
}
