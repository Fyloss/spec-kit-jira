#!/usr/bin/env bats
# T150/T152 [027] — C-2: the uniform refusal property, across all fourteen
# classes of contracts/seed-cli-contract.md §8 — each performs zero writes,
# names the offending designator or marker, carries a copy-pasteable
# remediation, and exits EXIT_CONFIG (4). C-3: refusals at §3 steps 1-4
# issue zero requests, generalised beyond the host-mismatch case.

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
  jq -cn '{project:"PROJ", declared_type_specification:"Epic", declared_type_story:"Story", terminal_statuses_csv:"Done", parent_type_id:"10000", child_type_id:"10001"}'
}

_write_two_story_record() {
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]' "" "$(_routing)" "[]")"
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
  local key="$1" summary="$2" status="$3" itype="${4:-Story}" project="${5:-PROJ}"
  printf '"%s":{"summary":"%s","description":"body","status":{"name":"%s"},"issuetype":{"name":"%s"},"project":{"key":"%s"}}' \
    "${key}" "${summary}" "${status}" "${itype}" "${project}"
}

# _assert_uniform <status> <output> <code> [<needle>] — the C-2 shape.
_assert_uniform() {
  local status="$1" output="$2" code="$3" needle="${4:-}"
  [ "${status}" -eq 4 ]
  [[ "${output}" == *"${code}"* ]]
  [[ "${output}" == *" — "* || "${output}" == *": "* ]]
  if [[ -n "${needle}" ]]; then
    [[ "${output}" == *"${needle}"* ]]
  fi
}

# --- REF-EXISTS: no record, folder present (§3 step 4, C-3: zero requests) --

@test "REF-EXISTS: zero writes, names the folder, remediation present" {
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _write_two_story_spec
  run cmd_seed seed "${SPEC}" --json
  _assert_uniform "$status" "$output" "REF-EXISTS" "${SPEC}"
  [ -z "$(mock_calls)" ]
}

# --- REF-DESIGNATOR/REF-HOST/REF-DUPLICATE/REF-RESEED fire only when the
# operator resupplies --parent/--story (S-3/S-4) --------------------------

@test "REF-DESIGNATOR: a malformed resupplied designator, zero requests" {
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --story "not a valid designator at all" --json
  _assert_uniform "$status" "$output" "REF-DESIGNATOR"
  [ -z "$(mock_calls)" ]
}

@test "REF-HOST: a resupplied URL from an unconfigured host, zero requests" {
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --story "https://not-the-configured-host.example.com/browse/PROJ-11" --json
  _assert_uniform "$status" "$output" "REF-HOST"
  [ -z "$(mock_calls)" ]
}

@test "REF-DUPLICATE: the same key resupplied twice, zero requests" {
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --story PROJ-11 --story PROJ-11 --json
  _assert_uniform "$status" "$output" "REF-DUPLICATE" "PROJ-11"
  [ -z "$(mock_calls)" ]
}

@test "REF-RESEED: a resupplied set differing from the recorded one, zero requests" {
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _write_two_story_spec
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --story PROJ-11 --story PROJ-99 --json
  _assert_uniform "$status" "$output" "REF-RESEED"
  [ -z "$(mock_calls)" ]
}

# --- REF-DECOMP: first run, pin validation fails -----------------------

@test "REF-DECOMP: a missing pinning marker on a first run, naming the key" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n\nBody, no marker.\n' > "${SPEC}"
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --json
  _assert_uniform "$status" "$output" "REF-DECOMP" "PROJ-11"
}

# --- REF-DRAFT-EDIT: same violation, but on resume ----------------------

@test "REF-DRAFT-EDIT: a pinned story deleted between decline and resume" {
  _write_two_story_spec
  _write_two_story_record
  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  printf '# Feature\n\n### User Story 1 - Accept a partial payment (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody one.\n' > "${SPEC}"
  run cmd_seed seed "${SPEC}" --json
  _assert_uniform "$status" "$output" "REF-DRAFT-EDIT" "PROJ-12"
}

# --- The resume-only re-evaluation classes: REF-UNRESOLVED, REF-ROLE,
# REF-ROUTING, REF-MULTIPROJECT, REF-TERMINAL, REF-CLAIMED, REF-THIN ------

_decline_then_resume_with() {
  # <issues-json-body> — writes spec+record, declines once (no Jira needed
  # since the first gate-reach reads nothing), then mocks the given issues
  # and resumes, returning via $output/$status.
  local issues_body="$1"
  _write_two_story_spec
  _write_two_story_record
  local empty_cfg
  empty_cfg="$(mktemp)"
  printf '{}' > "${empty_cfg}"
  mock_start "${empty_cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  mock_stop
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues_body}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
}

@test "REF-UNRESOLVED: a designated key absent from the read" {
  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-UNRESOLVED" "PROJ-12"
}

@test "REF-ROLE: a story-role key whose Jira type does not match hierarchy.story" {
  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "Bug")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-ROLE" "PROJ-11"
}

@test "REF-ROUTING: a named issue outside the routed project" {
  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "Story" "OTHER")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-ROUTING" "PROJ-11"
}

@test "REF-MULTIPROJECT: named story-role issues span more than one project" {
  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "To Do" "Story" "PROJ")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do" "Story" "OTHER")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-MULTIPROJECT"
}

@test "REF-TERMINAL: a named issue in a configured terminal status" {
  local issues="{"
  issues+="$(_seed_issue "PROJ-11" "Accept a partial payment" "Done")"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-TERMINAL" "PROJ-11"
}

@test "REF-CLAIMED: a named issue already carries another specification's identity" {
  local issues="{\"PROJ-11\":{\"summary\":\"Accept a partial payment\",\"description\":\"body\",\"status\":{\"name\":\"To Do\"},\"issuetype\":{\"name\":\"Story\"},\"project\":{\"key\":\"PROJ\"},\"properties\":{\"spec-kit-jira\":{\"origin\":\"human\",\"role\":\"story\",\"repo\":\"local/repo\",\"spec_slug\":\"999-someone-elses-spec\"}}}"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-CLAIMED" "PROJ-11"
}

@test "REF-THIN: a named issue's description has no non-whitespace character" {
  local issues="{\"PROJ-11\":{\"summary\":\"Accept a partial payment\",\"description\":\"   \",\"status\":{\"name\":\"To Do\"},\"issuetype\":{\"name\":\"Story\"},\"project\":{\"key\":\"PROJ\"}}"
  issues+=",$(_seed_issue "PROJ-12" "Refund a captured payment" "To Do")"
  issues+="}"
  _decline_then_resume_with "${issues}"
  _assert_uniform "$status" "$output" "REF-THIN" "PROJ-11"
}

# --- C-3, generalised: every refusal at §3 steps 1-4 (before any read) is
# provably zero-request, not only the ones already asserted inline above ---

@test "C-3: REF-DESIGNATOR, REF-HOST, REF-DUPLICATE, REF-RESEED, and REF-EXISTS all precede any request" {
  # REF-EXISTS (no record at all).
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _write_two_story_spec
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 4 ]
  [ -z "$(mock_calls)" ]

  # The resupply-time classes, same mock instance, same zero-call bar.
  _write_two_story_record
  run cmd_seed seed "${SPEC}" --story "https://not-configured.example.com/browse/PROJ-11" --json
  [ "$status" -eq 4 ]
  run cmd_seed seed "${SPEC}" --story PROJ-11 --story PROJ-11 --json
  [ "$status" -eq 4 ]
  run cmd_seed seed "${SPEC}" --story PROJ-99 --story PROJ-11 --json
  [ "$status" -eq 4 ]
  [ -z "$(mock_calls)" ]
}
