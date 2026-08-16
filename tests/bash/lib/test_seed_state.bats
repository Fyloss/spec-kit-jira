#!/usr/bin/env bats
# T048/T052 [027] — The seeded-not-bound record (contracts/seed-record.md).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/seed_state.sh"
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  mkdir -p "${WORK}/specs/001-add-payment-webhooks"
  SPEC="${WORK}/specs/001-add-payment-webhooks/spec.md"
  printf '# Feature\n' > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

_designators() {
  printf '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
}

@test "seed_state_path is a sibling of run_state_path, under state/, suffixed .seed.json" {
  run seed_state_path "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$output" = "${JIRA_CONFIG_DIR}/state/001-add-payment-webhooks.seed.json" ]
}

# --- S-1/S-8: the record is written with bindings: [] and the ordered set ---

@test "S-1: seed_state_compose carries bindings: [] and the ordered designator set" {
  run seed_state_compose "ijt-add-payment-webhooks" "$(_designators)" ""
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schema_version' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.slug' <<< "$output")" = "ijt-add-payment-webhooks" ]
  [ "$(jq -c '.bindings' <<< "$output")" = "[]" ]
  [ "$(jq -r '.designators | length' <<< "$output")" -eq 2 ]
}

@test "seed_state_write then seed_state_read round-trips the exact document" {
  local doc
  doc="$(seed_state_compose "ijt-add-payment-webhooks" "$(_designators)" "")"
  seed_state_write "${SPEC}" "${doc}"
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$output" = "${doc}" ]
}

@test "seed_state_read on an absent record returns 1 and prints nothing" {
  run seed_state_read "${SPEC}"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "seed_state_delete removes the record; seed_state_read then fails" {
  local doc
  doc="$(seed_state_compose "ijt-add-payment-webhooks" "$(_designators)" "")"
  seed_state_write "${SPEC}" "${doc}"
  seed_state_delete "${SPEC}"
  run seed_state_read "${SPEC}"
  [ "$status" -eq 1 ]
}

# --- S-9: gitignored, never appears in git status ----------------------------

@test "S-9: the state directory is gitignored" {
  local doc
  doc="$(seed_state_compose "ijt-add-payment-webhooks" "$(_designators)" "")"
  seed_state_write "${SPEC}" "${doc}"
  [ -f "${JIRA_CONFIG_DIR}/state/.gitignore" ]
  run cat "${JIRA_CONFIG_DIR}/state/.gitignore"
  [[ "$output" == *"*"* ]]
}

@test "S-9: never appears in git status in a real repo" {
  (cd "${WORK}" && git init -q .)
  local doc
  doc="$(seed_state_compose "ijt-add-payment-webhooks" "$(_designators)" "")"
  seed_state_write "${SPEC}" "${doc}"
  run bash -c "cd '${WORK}' && git status --porcelain .specify"
  [[ "$output" != *"seed.json"* ]]
}

# --- §3/FR-041: seed_state_designators_equal --------------------------------

@test "seed_state_designators_equal: identical two-item sets compare equal" {
  local a b
  a="$(_designators)"
  b="$(_designators)"
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "true" ]
}

@test "seed_state_designators_equal: a SINGLE-designator set compares equal to itself (regression: PowerShell's single-element array collapse)" {
  local a b
  a='[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
  b='[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "true" ]
}

@test "seed_state_designators_equal: a single differing story key compares unequal" {
  local a b
  a='[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
  b='[{"role":"story","form":"key","key":"PROJ-99","raw":"PROJ-99","position":0}]'
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "false" ]
}

@test "seed_state_designators_equal: S-3, a key and its URL for the same issue compare equal" {
  local a b
  a='[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]'
  b='[{"role":"story","form":"url","key":"PROJ-11","raw":"https://example.com/browse/PROJ-11","position":0}]'
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "true" ]
}

@test "seed_state_designators_equal: S-4, reordered story keys compare unequal" {
  local a b
  a='[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]'
  b='[{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":1}]'
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "false" ]
}

@test "seed_state_designators_equal: a free-text specification-role value compares byte-equal" {
  local a b
  a='[{"role":"specification","form":"free_text","raw":"Payment webhooks","text":"Payment webhooks","position":0}]'
  b='[{"role":"specification","form":"free_text","raw":"Payment webhooks","text":"Payment webhooks","position":0}]'
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "true" ]
  b='[{"role":"specification","form":"free_text","raw":"Payment webhooks!","text":"Payment webhooks!","position":0}]'
  [ "$(seed_state_designators_equal "${a}" "${b}")" = "false" ]
}
