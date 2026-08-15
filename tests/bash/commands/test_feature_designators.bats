#!/usr/bin/env bats
# T054 [027] — Slug derivation number-source selection (FR-059,
# research R9). `engine/naming.sh` gains zero lines; the selection lives in
# `commands/feature.sh` step (5), choosing WHICH key naming_ticket_number
# is handed.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/seed_fixture.bash"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/feature.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  helper_seed_config "${JIRA_CONFIG_DIR}" PROJ proj
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

_desig_seed_issue() {
  printf '"%s":{"summary":"%s","description":"%s","status":{"name":"%s","statusCategory":{"key":"%s"}},"issuetype":{"id":"10001","name":"%s"},"project":{"key":"%s"}}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

_desig_boot_three_stories() {
  local issues="{"
  issues+="$(_desig_seed_issue "PROJ-11" "Accept a partial payment" "Story one body" "To Do" "new" "Story" "PROJ")"
  issues+=",$(_desig_seed_issue "PROJ-12" "Refund a captured payment" "Story two body" "To Do" "new" "Story" "PROJ")"
  issues+=",$(_desig_seed_issue "PROJ-13" "Reconcile a disputed charge" "Story three body" "To Do" "new" "Story" "PROJ")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "shape 1: parent by key plus stories -> the parent's key" {
  local parent stories
  parent='{"role":"specification","raw":"PROJ-1","form":"key","key":"PROJ-1"}'
  stories='[{"role":"story","raw":"PROJ-11","form":"key","key":"PROJ-11","position":0}]'
  run _feat_designator_number_source "${parent}" "${stories}"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-1" ]
}

@test "shape 2: parent as free text plus stories -> the first story-role key" {
  local parent stories
  parent='{"role":"specification","raw":"New parent title","form":"free_text","text":"New parent title"}'
  stories='[{"role":"story","raw":"PROJ-11","form":"key","key":"PROJ-11","position":0},{"role":"story","raw":"PROJ-12","form":"key","key":"PROJ-12","position":1}]'
  run _feat_designator_number_source "${parent}" "${stories}"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-11" ]
}

@test "shape 3: stories only -> the first story-role key" {
  local stories
  stories='[{"role":"story","raw":"PROJ-21","form":"key","key":"PROJ-21","position":0},{"role":"story","raw":"PROJ-22","form":"key","key":"PROJ-22","position":1}]'
  run _feat_designator_number_source "" "${stories}"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-21" ]
}

@test "shape 4: parent only by key or URL -> the parent's key" {
  local parent
  parent='{"role":"specification","raw":"https://acme.atlassian.net/browse/PROJ-1","form":"url","key":"PROJ-1"}'
  run _feat_designator_number_source "${parent}" "[]"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-1" ]
}

@test "shape 5: parent only as free text, no stories -> falls through (ordinary naming, not a refusal)" {
  local parent
  parent='{"role":"specification","raw":"New parent title","form":"free_text","text":"New parent title"}'
  run _feat_designator_number_source "${parent}" "[]"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "no designators at all -> falls through (ordinary naming behaviour, unchanged)" {
  run _feat_designator_number_source "" "[]"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "story order fixed by FR-054: the FIRST by position wins, not argv scan order" {
  local stories
  stories='[{"role":"story","raw":"PROJ-99","form":"key","key":"PROJ-99","position":1},{"role":"story","raw":"PROJ-10","form":"key","key":"PROJ-10","position":0}]'
  run _feat_designator_number_source "" "${stories}"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-10" ]
}

# --- T070: US1 AC1/AC5 — moment 1 end to end, one bulkfetch, no parent -------

@test "T070: a key, a browse URL, and a board URL resolve to three keys in ONE bulkfetch; no parent designator ⇒ zero parent lookups" {
  _desig_boot_three_stories
  run cmd_feature feature --json \
    --story PROJ-11 \
    --story "${MOCK_BASE_URL}/browse/PROJ-12" \
    --story "${MOCK_BASE_URL}/jira/software/projects/PROJ/boards/7?selectedIssue=PROJ-13" \
    "invoice export"
  [ "$status" -eq 0 ]
  [ "$(mock_calls | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(mock_calls | grep -c 'POST /rest/api/3/issue/bulkfetch')" -eq 1 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "PROJ-11" ]
  [ "$(jq -r '.ticket.number' <<< "$output")" = "11" ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "adopted" ]
  [ "$(jq -r '.short_name' <<< "$output")" = "proj-11" ]
  [ "$(jq -r '.branch_name' <<< "$output")" = "proj-11/proj-11" ]
  local material_path
  material_path="$(jq -r '.seed_material' <<< "$output")"
  [ -f "${material_path}" ]
  [ "$(jq 'length' "${material_path}")" -eq 3 ]
  [ "$(jq -r '.[0].key' "${material_path}")" = "PROJ-11" ]
  [ "$(jq -r '.[2].key' "${material_path}")" = "PROJ-13" ]
}

@test "C-5 (T073): Jira unreachable WITH designators supplied -> exit 2, never the {active:false} fallback" {
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-11":{"summary":"S","description":"D"}},"fault":{"status":500}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_feature feature --json --story PROJ-11 "invoice export"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.active' <<< "$output" 2> /dev/null)" != "false" ]
}

@test "T070: the ordinary parent behaviour is byte-identical to a designator-free run (no designators supplied)" {
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10201","priority_ids":{"P1":"1","P2":"2","P3":"3"},"estimation_field_id":null}'
  local cfg
  cfg="$(mktemp)"
  printf '%s' '{"projects":{"PROJ":"team"},"createdKey":"PROJ-999"}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_feature feature --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "created" ]
  [ "$(jq -r 'has("seed_material")' <<< "$output")" = "false" ]
}

# --- T075: the seed material travels by FILE, never through argv ------------

@test "T075: a description large enough to threaten argv reaches no single argument at 128 KiB, and the seed material lands in a file" {
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/argv_size.bash"
  local big
  big="$(printf 'x%.0s' $(seq 1 150000))"
  local issues="{"
  issues+="$(_desig_seed_issue "PROJ-11" "Accept a partial payment" "${big}" "To Do" "new" "Story" "PROJ")"
  issues+=",$(_desig_seed_issue "PROJ-12" "Refund a captured payment" "Story two body" "To Do" "new" "Story" "PROJ")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local shim_dir="${BATS_TEST_TMPDIR}/argv_shim" report="${BATS_TEST_TMPDIR}/argv_report.log"
  helper_argv_size_setup "${shim_dir}" "${report}"

  PATH="${shim_dir}:${PATH}" run cmd_feature feature --json --story PROJ-11 --story PROJ-12 "invoice export"
  [ "$status" -eq 0 ]
  [ ! -s "${report}" ]
  local material_path
  material_path="$(jq -r '.seed_material' <<< "$output")"
  [ -f "${material_path}" ]
  [ "$(jq -r '.[0].description' "${material_path}" | wc -c | tr -d ' ')" -gt 150000 ]
}

# --- T092/T093 (US3): REF-ROLE for a mistyped parent designator -------------

@test "T092: a named parent whose type does not match hierarchy.specification refuses REF-ROLE" {
  local issues="{"
  issues+="$(_desig_seed_issue "PROJ-1" "Payment webhooks rollout" "Epic body" "To Do" "new" "Story" "PROJ")"
  issues+=",$(_desig_seed_issue "PROJ-11" "Accept a partial payment" "Story one body" "To Do" "new" "Story" "PROJ")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_feature feature --json --parent PROJ-1 --story PROJ-11 "invoice export"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-ROLE"* ]]
  [[ "$output" == *"PROJ-1"* ]]
}

@test "T093: a named parent whose type matches hierarchy.specification resolves cleanly" {
  local issues="{"
  issues+="$(_desig_seed_issue "PROJ-1" "Payment webhooks rollout" "Epic body" "To Do" "new" "Epic" "PROJ")"
  issues+=",$(_desig_seed_issue "PROJ-11" "Accept a partial payment" "Story one body" "To Do" "new" "Story" "PROJ")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_feature feature --json --parent PROJ-1 --story PROJ-11 "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "PROJ-1" ]
}
