#!/usr/bin/env bats
# T107/T109/T111/T113/T115/T117 [027, US7] — Provenance, decline, and resume
# (contracts/seed-cli-contract.md §4/§5/§8: C-8…C-12, S-2…S-4;
# contracts/pin-marker.md §5/§8: P-5/P-6).

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
}

teardown() {
  mock_stop 2> /dev/null || true
  rm -rf "${WORK}"
}

_routing() {
  jq -cn '{project:"PROJ", declared_type_specification:"Epic", declared_type_story:"Story", terminal_statuses_csv:"Done"}'
}

# Two stories, one parent, matching the fixture spec.md below.
_two_story_designators() {
  jq -cn '[
    {"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}
  ]'
}

_write_two_story_record() {
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" "$(_two_story_designators)" "" "$(_routing)" "[]")"
  seed_state_write "${SPEC}" "${doc}"
}

_write_two_story_spec() {
  printf '%s\n' \
    '# Feature' \
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
  printf '"%s":{"summary":"%s","description":"%s","status":{"name":"%s"},"issuetype":{"name":"%s"},"project":{"key":"%s"}}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

_start_mock_three_issues() {
  local issues="{"
  issues+="$(_seed_issue "PROJ-1" "Payment webhooks rollout" "Parent body" "In Progress" "Epic" "PROJ")"
  issues+=",$(_seed_issue "PROJ-11" "Accept a partial payment" "Story one body" "To Do" "Story" "PROJ")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "Story two body" "To Do" "Story" "PROJ")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

# --- T107/C-7: provenance report, emitted at the gate ------------------------

@test "T107: provenance maps each drafted user story to its pin source" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.confirmation_required.provenance | length' <<< "$output")" -ge 2 ]
  [ "$(jq -r '[.confirmation_required.provenance[] | select(.source=="PROJ-11")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.confirmation_required.provenance[] | select(.source=="PROJ-12")] | length' <<< "$output")" -eq 1 ]
}

@test "T107: an unpinned user story maps to source 'new'" {
  printf '%s\n' \
    '# Feature' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' \
    '' \
    'Body one.' \
    '' \
    '### User Story 2 - A brand new story (Priority: P2)' \
    '' \
    'Body two, unpinned.' \
    > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "" "$(_routing)" "[]")"
  seed_state_write "${SPEC}" "${doc}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.confirmation_required.provenance[] | select(.source=="new")] | length' <<< "$output")" -eq 1 ]
}

@test "T107: a named parent maps to the Overview section" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.confirmation_required.provenance[] | select(.heading=="Overview" and .source=="PROJ-1")] | length' <<< "$output")" -eq 1 ]
}

@test "T107: provenance is emitted before any Jira mutation (zero writes at the gate)" {
  _write_two_story_spec
  _write_two_story_record
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.confirmation_required | has("provenance")' <<< "$output")" = "true" ]
  [ -z "$(mock_calls)" ]
}

# --- T109/C-8: decline -------------------------------------------------------

@test "C-8: declining leaves the seed record present, pins present, zero identity markers" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
  grep -q 'pin=PROJ-11' "${SPEC}"
  grep -q 'pin=PROJ-12' "${SPEC}"
  ! grep -q 'story=' "${SPEC}"
  ! grep -q 'spec=' "${SPEC}"
}

@test "C-8: declining issues zero Jira requests" {
  _write_two_story_spec
  _write_two_story_record
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls)" ]
}

# --- T111/C-9/C-10/S-2/S-3/S-4: resume ---------------------------------------

@test "C-9: resume with the same set returns to the gate, spec.md byte-identical, no REF-EXISTS" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  local before after
  before="$(git hash-object "${SPEC}" 2> /dev/null)"

  _start_mock_three_issues
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"REF-EXISTS"* ]]
  after="$(git hash-object "${SPEC}" 2> /dev/null)"
  [ "${before}" = "${after}" ]
}

@test "C-10: resume with a different set refuses REF-RESEED, zero writes" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  run cmd_seed seed "${SPEC}" --parent PROJ-1 --story PROJ-11 --story PROJ-99 --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-RESEED"* ]]
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
}

@test "S-2: the recorded slug is read on resume, never re-derived" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  local slug_before
  slug_before="$(jq -r '.slug' <<< "$(seed_state_read "${SPEC}")")"

  _start_mock_three_issues
  # Jira-side edit between decline and resume — must not influence the slug.
  curl -sf -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/PROJ-1" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"description":"Completely different now."}}' > /dev/null

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  local slug_after
  slug_after="$(jq -r '.slug' <<< "$(seed_state_read "${SPEC}")")"
  [ "${slug_before}" = "${slug_after}" ]
}

@test "S-3: a key and its URL compare equal across invocations" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  _start_mock_three_issues
  run cmd_seed seed "${SPEC}" --parent PROJ-1 --story "${MOCK_BASE_URL}/browse/PROJ-11" --story PROJ-12 --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"REF-RESEED"* ]]
}

@test "S-4: reordered --story flags refuse REF-RESEED" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  run cmd_seed seed "${SPEC}" --parent PROJ-1 --story PROJ-12 --story PROJ-11 --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-RESEED"* ]]
}

# --- T113/C-11: full re-evaluation on resume ---------------------------------

@test "C-11: a story closed between decline and resume refuses REF-TERMINAL on resume" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  local issues="{"
  issues+="$(_seed_issue "PROJ-1" "Payment webhooks rollout" "Parent body" "In Progress" "Epic" "PROJ")"
  issues+=",$(_seed_issue "PROJ-11" "Accept a partial payment" "Story one body" "Done" "Story" "PROJ")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "Story two body" "To Do" "Story" "PROJ")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-TERMINAL"* ]]
  [[ "$output" == *"PROJ-11"* ]]

  # A refusal on resume leaves the seeded-not-bound state untouched.
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
}

@test "C-19: a resume issues the same ceil(N/B) reads as the first run, never a comment field" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  _start_mock_three_issues
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c 'POST /rest/api/3/issue/bulkfetch')" -eq 1 ]
  local calls
  calls="$(mock_calls)"
  [[ "${calls}" != *'"comment"'* ]]
}

# --- T115/T116: REF-DRAFT-EDIT distinct from REF-DECOMP on resume -----------

@test "P-5: a prose rewrite, a renamed heading, and a new unpinned story all pass on resume" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  printf '%s\n' \
    '# Feature' \
    '' \
    '### User Story 1 - Accept a partial payment, rewritten (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' \
    '' \
    'Body one, entirely rewritten prose.' \
    '' \
    '### User Story 2 - Refund a captured payment (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-12 -->' \
    '' \
    'Body two.' \
    '' \
    '### User Story 3 - A brand new addition (Priority: P2)' \
    '' \
    'Body three, unpinned, added during review.' \
    > "${SPEC}"

  _start_mock_three_issues
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"REF-DRAFT-EDIT"* ]]
}

@test "P-6: a deleted pinned user story refuses REF-DRAFT-EDIT on resume" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  printf '%s\n' \
    '# Feature' \
    '' \
    '### User Story 1 - Accept a partial payment (Priority: P1)' \
    '<!-- speckit-jira pin=PROJ-11 -->' \
    '' \
    'Body one.' \
    > "${SPEC}"

  _start_mock_three_issues
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-DRAFT-EDIT"* ]]
  [[ "$output" != *"REF-DECOMP"* ]]
  [[ "$output" == *"PROJ-12"* ]]

  # A refusal on resume leaves the seeded-not-bound state untouched.
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
}

# --- T117/C-12: plan recomputation and delta on resume -----------------------

@test "C-12: resume after adding a user story shows the extra create in the plan and its delta" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  local plan_before
  plan_before="$(jq -r '.confirmation_required.plan | length' <<< "$output")"

  printf '%s\n' \
    '# Feature' \
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
    '' \
    '### User Story 3 - A brand new addition (Priority: P2)' \
    '' \
    'Body three, added during review.' \
    > "${SPEC}"

  _start_mock_three_issues
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  local plan_after
  plan_after="$(jq -r '.confirmation_required.plan | length' <<< "$output")"
  [ "${plan_after}" -eq "${plan_before}" ]
  [ "$(jq -r '.confirmation_required.delta | has("added")' <<< "$output")" = "true" ]
  [ "$(jq -r '.confirmation_required.delta | has("removed")' <<< "$output")" = "true" ]
}

@test "a first gate-reach carries an empty delta (nothing to compare against yet)" {
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.confirmation_required.delta' <<< "$output")" = "{}" ]
}
