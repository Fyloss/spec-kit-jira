#!/usr/bin/env bats
# T125/T127/T129/T131/T133/T135/T137 [027, US2] — A parent that does not
# exist yet (contracts/seed-cli-contract.md §8: C-17, C-18; spec.md FR-022,
# FR-023, FR-025, FR-026, FR-051, FR-052, FR-053, FR-061; research R14).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  LIB_DIR="${ROOT}/scripts/bash/lib"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/seed_state.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  FEATURE_DIR="${WORK}/specs/001-add-payment-webhooks"
  mkdir -p "${FEATURE_DIR}"
  SPEC="${FEATURE_DIR}/spec.md"
  export SPEC_KIT_JIRA_REPO="local/repo"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-add-payment-webhooks"
}

teardown() {
  mock_stop 2> /dev/null || true
  rm -rf "${WORK}"
}

_routing() {
  jq -cn '{project:"PROJ", declared_type_specification:"Epic", declared_type_story:"Story", terminal_statuses_csv:"", parent_type_id:"10000", child_type_id:"10001"}'
}

_write_create_record() {
  local designators="$1"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" "${designators}" "" "$(_routing)" "[]")"
  seed_state_write "${SPEC}" "${doc}"
}

_two_unparented_designators() {
  jq -cn '[
    {"role":"specification","form":"free_text","raw":"Payment webhooks rollout","text":"Payment webhooks rollout","position":0},
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}
  ]'
}

_write_two_story_spec() {
  printf '%s\n' \
    '# Feature' \
    '' \
    'This feature streamlines partial payments and refunds.' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' \
    '' \
    'Body one.' \
    '' \
    '### User Story 2 - Refund a captured payment (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-12 -->' \
    '' \
    'Body two.' \
    > "${SPEC}"
}

_seed_issue() {
  # <key> <summary> <status> <parent-key-or-empty> <parent-summary> <parent-status>
  local key="$1" summary="$2" status="$3" pkey="${4:-}" psum="${5:-}" pstat="${6:-}"
  local itype="Story"
  [[ "${key}" == "PROJ-1" ]] && itype="Epic"
  local parent_json="null"
  if [[ -n "${pkey}" ]]; then
    parent_json="{\"key\":\"${pkey}\",\"fields\":{\"summary\":\"${psum}\",\"status\":{\"name\":\"${pstat}\"}}}"
  fi
  printf '"%s":{"summary":"%s","description":"body","status":{"name":"%s"},"issuetype":{"name":"%s"},"project":{"key":"PROJ"},"parent":%s}' \
    "${key}" "${summary}" "${status}" "${itype}" "${parent_json}"
}

# --- T125/T126: free-text parent creation, no lookup issued -----------------

@test "T125: a free-text parent creates exactly one issue, no lookup of any kind" {
  _write_two_story_spec
  _write_create_record "$(_two_unparented_designators)"

  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"createdKey\":\"PROJ-1\",\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.bindings[] | select(.role=="parent")][0].key' <<< "$output")" = "PROJ-1" ]
  [ "$(jq -r '[.bindings[] | select(.role=="parent")][0].origin' <<< "$output")" = "bridge" ]
  [ "$(mock_calls | grep -c '^POST /rest/api/3/issue$')" -eq 1 ]
  # No GET of any kind was issued to check whether such a parent exists.
  [ -z "$(mock_calls | grep '^GET ')" ]
  grep -qE '<!-- speckit-jira spec=[0-9a-f]{16} ticket=PROJ-1 -->' "${SPEC}"
}

# --- T127/T128: content derivation -------------------------------------------

@test "T127: the created parent's summary is the free text and its description is the drafted overview" {
  _write_two_story_spec
  _write_create_record "$(_two_unparented_designators)"

  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"createdKey\":\"PROJ-1\",\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  local calls_body
  calls_body="$(mock_calls)"
  [[ "${calls_body}" == *"POST /rest/api/3/issue"* ]]
}

# --- T131/C-17: the reparent line -------------------------------------------

@test "C-17: a reparent line renders visually distinct, naming the current parent and the child-loss count" {
  _write_two_story_spec
  _write_create_record "$(_two_unparented_designators)"

  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "PROJ-99" "Q3 payments" "In Progress")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do" "PROJ-99" "Q3 payments" "In Progress")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"createdKey\":\"PROJ-1\",\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # A first gate-reach (decline) has no Jira-sourced placement info yet
  # (T100's one-way-read guarantee) — reparent detection is proven on the
  # resume that follows, which re-reads Jira (FR-062).
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  local lines
  lines="$(jq -r '.confirmation_required.plan[]' <<< "$output")"
  local reparent_lines
  reparent_lines="$(grep -c '^! reparent' <<< "${lines}")"
  [ "${reparent_lines}" -eq 2 ]
  [[ "${lines}" == *'from PROJ-99 "Q3 payments" [In Progress] - loses 2 children'* ]]
  # No adopt/create line starts in column 1.
  [ -z "$(grep -E '^  reparent' <<< "${lines}")" ]
}

@test "C-17: the child-loss count is stated even when it is one" {
  _write_two_story_spec
  local designators
  designators="$(jq -cn '[
    {"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}
  ]')"
  _write_create_record "${designators}"

  local issues="{"
  issues+="$(_seed_issue "PROJ-1" "Payment webhooks rollout" "In Progress")"
  issues+=",$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "PROJ-99" "Q3 payments" "In Progress")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.confirmation_required.plan[]' <<< "$output")" == *"loses 1 child"* ]]
}

# --- T133: operator-designated scoping ---------------------------------------

@test "T133: no reparent line, and no placement write, when the specification role is left undesignated" {
  _write_two_story_spec
  local designators
  designators="$(jq -cn '[
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}
  ]')"
  _write_create_record "${designators}"

  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "PROJ-99" "Q3 payments" "In Progress")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.confirmation_required.plan[]' <<< "$output")" != *"reparent"* ]]

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls | grep 'PUT /rest/api/3/issue/PROJ-11$')" ]
}

# --- T135/T136/C-18: FR-061 scatter note -------------------------------------

@test "C-18: no parent designator, a named story already parented -> scatter note, exit 0, zero writes for it" {
  _write_two_story_spec
  local designators
  designators="$(jq -cn '[
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}
  ]')"
  _write_create_record "${designators}"

  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "PROJ-88" "Legacy billing" "To Do")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.confirmation_required.provenance[] | select(.heading=="Overview")] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-11"* ]]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-88"* ]]

  # A disclosure, not a refusal: zero WRITES (the resume's own bulkfetch
  # READ is the only call), no exit-code change.
  # bulkfetch is a POST-shaped READ (Jira's own API), not a mutation.
  [ -z "$(mock_calls | grep -E 'POST|PUT' | grep -v bulkfetch)" ]
}

# --- T137/T138 (R14): partial-run resumption ---------------------------------

@test "T137/T138: an already-bound story is excluded from re-validation and re-binding on the next invocation" {
  printf '%s\n' \
    '# Feature' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira story=aaaaaaaaaaaaaaaa ticket=PROJ-11 -->' \
    '' \
    'Body one.' \
    '' \
    '### User Story 2 - Refund a captured payment (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-12 -->' \
    '' \
    'Body two.' \
    > "${SPEC}"
  local designators
  designators="$(jq -cn '[
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}
  ]')"
  _write_create_record "${designators}"

  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-12":{"summary":"Refund a captured payment","description":"body"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(jq '.bindings | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.bindings[0].key' <<< "$output")" = "PROJ-12" ]
  # PROJ-11 was never re-touched: no identity PUT issued for it this run.
  [ -z "$(mock_calls | grep 'PUT /rest/api/3/issue/PROJ-11/properties/spec-kit-jira')" ]
  grep -qE '<!-- speckit-jira story=[0-9a-f]{16} ticket=PROJ-12 -->' "${SPEC}"
}

# --- T129/T130 (FR-052): the free text is a creation seed only --------------

@test "T129: a human rename of the created parent survives reconcile; the free text is never re-applied" {
  printf '%s\n' \
    '# Feature' \
    '' \
    'This feature streamlines partial payments and refunds.' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira pin=COMP-11 -->' \
    '' \
    'Body one.' \
    '' \
    '### User Story 2 - Refund a captured payment (Priority: P1)' \
    '<!-- speckit-jira pin=COMP-12 -->' \
    '' \
    'Body two.' \
    > "${SPEC}"
  local designators
  designators="$(jq -cn '[
    {"role":"specification","form":"free_text","raw":"Payment webhooks rollout","text":"Payment webhooks rollout","position":0},
    {"role":"story","form":"key","key":"COMP-11","raw":"COMP-11","position":0},
    {"role":"story","form":"key","key":"COMP-12","raw":"COMP-12","position":1}
  ]')"
  local routing
  routing="$(jq -cn '{project:"COMP", declared_type_specification:"Epic", declared_type_story:"Story", terminal_statuses_csv:"", parent_type_id:"10000", child_type_id:"10001"}')"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" "${designators}" "" "${routing}" "[]")"
  seed_state_write "${SPEC}" "${doc}"

  {
    printf 'resolved_ids:\n'
    printf '  COMP:\n'
    printf '    style: company_managed\n'
    printf '    issue_types:\n'
    printf '      - logical_name: "Epic"\n'
    printf '        id: "10000"\n'
    printf '        hierarchy_level: "1"\n'
    printf '        subtask: false\n'
    printf '      - logical_name: "Story"\n'
    printf '        id: "10001"\n'
    printf '        hierarchy_level: "0"\n'
    printf '        subtask: false\n'
    printf '    child_type:\n'
    printf '      logical_name: "Story"\n'
    printf '      id: "10001"\n'
    printf '      source: derived\n'
    printf '    parent_type:\n'
    printf '      logical_name: "Epic"\n'
    printf '      id: "10000"\n'
    printf '      source: derived\n'
    printf '    required_fields:\n'
    printf '      "10000":\n'
    printf '        - logical_name: "Summary"\n'
    printf '          field_id: "summary"\n'
    printf '      "10001":\n'
    printf '        - logical_name: "Summary"\n'
    printf '          field_id: "summary"\n'
    printf '    parent_link_available:\n'
    printf '      "10001": true\n'
    printf '    statuses:\n'
    printf '      To Do: "10000"\n'
  } > "${JIRA_CONFIG_DIR}/config.local.yml"
  {
    printf 'projects:\n'
    printf '  - key: COMP\n'
    printf '    style: company_managed\n'
    printf 'routing_default: COMP\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  local issues="{"
  issues+="\"COMP-11\":{\"summary\":\"Accept a partial payment\",\"description\":\"body\",\"status\":{\"name\":\"To Do\"},\"issuetype\":{\"name\":\"Story\"},\"project\":{\"key\":\"COMP\"}}"
  issues+=",\"COMP-12\":{\"summary\":\"Refund a captured payment\",\"description\":\"body\",\"status\":{\"name\":\"To Do\"},\"issuetype\":{\"name\":\"Story\"},\"project\":{\"key\":\"COMP\"}}"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"createdKey\":\"COMP-1\",\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]

  # A human, in Jira, renames the created parent.
  curl -sf -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"summary":"Payment webhooks rollout, renamed by a human"}}' > /dev/null

  source "${CMD_DIR}/reconcile.sh"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  # The rename is never reverted: no PUT re-applies the free text.
  local calls
  calls="$(mock_calls)"
  [[ "${calls}" != *'"summary":"Payment webhooks rollout"'* ]]
  local stored_summary
  stored_summary="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1" | jq -r '.fields.summary')"
  [ "${stored_summary}" = "Payment webhooks rollout, renamed by a human" ]
}
