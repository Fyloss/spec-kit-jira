#!/usr/bin/env bats
# T018 [US2] — The run-state short-circuit's document layer (spec FR-019…
# FR-028, contracts/run-state.md, data-model.md §1).
#
# git hash-object needs no repository — a plain mktemp -d workdir is enough
# (research R7). JIRA_CONFIG_DIR is overridden to an absolute path per test,
# which is fine here: cross-port byte parity for the "inputs" keys is a
# conformance-corpus concern (T020/T021), not this file's.
#
# 023, contracts/run-state-v2.md §2/C1: `hook_event` is a new explicit
# argument (5th positional, before `field_values`) and the schema bumped
# 1 -> 2 — every call site below carries an empty `""` hook_event unless a
# test is specifically about it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/run_state.sh"

  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  mkdir -p "${WORK}/specs/021-example"
  SPEC="${WORK}/specs/021-example/spec.md"
  printf '# Feature Specification: Example\n' > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

# --- run_state_compose: shape and determinism ---------------------------------

@test "run_state_compose is deterministic across repeated calls" {
  local a b
  a="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  b="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ -n "${a}" ]
  [ "${a}" = "${b}" ]
}

@test "the composed document carries exactly the documented top-level fields, and no project_key" {
  local doc keys
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  keys="$(jq -rS 'keys | join(",")' <<< "${doc}")"
  [ "${keys}" = "base_url,email,extension_version,field_values,hook_event,inputs,on_drift,schema" ]
}

@test "schema is the integer 2 since 023's hook_event/plan.md inputs (contracts/run-state-v2.md C1)" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ "$(jq -r '.schema' <<< "${doc}")" = "2" ]
  [ "$(jq -r '.schema | type' <<< "${doc}")" = "number" ]
}

@test "base_url, email, on_drift, and field_values are carried verbatim" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "proceed" "" $'KEY=Story=Label=Value\x1fKEY=Task=Other=Val')"
  [ "$(jq -r '.base_url' <<< "${doc}")" = "https://acme.atlassian.net" ]
  [ "$(jq -r '.email' <<< "${doc}")" = "user@example.com" ]
  [ "$(jq -r '.on_drift' <<< "${doc}")" = "proceed" ]
  [ "$(jq -r '.field_values' <<< "${doc}")" = $'KEY=Story=Label=Value\x1fKEY=Task=Other=Val' ]
}

@test "hook_event is carried verbatim, empty string when a run has none" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "after_plan" "")"
  [ "$(jq -r '.hook_event' <<< "${doc}")" = "after_plan" ]
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ "$(jq -r '.hook_event' <<< "${doc}")" = "" ]
}

@test "the document never contains a credential-shaped string" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [[ "${doc}" != *"Authorization"* ]]
  [[ "${doc}" != *"Basic "* ]]
  [[ "${doc}" != *"ATATT"* ]]
}

# --- inputs: hashing primitive and presence rules ------------------------------

@test "spec.md is always present, hashed with git hash-object --no-filters" {
  local doc want got
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  want="$(git hash-object --no-filters "${SPEC}")"
  got="$(jq -r '.inputs["spec.md"]' <<< "${doc}")"
  [ "${got}" = "${want}" ]
}

@test "tasks.md is omitted when absent, present with its hash when it exists" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ "$(jq 'has("tasks.md") | not' <<< "$(jq '.inputs' <<< "${doc}")")" = "true" ]

  printf '%s\n' '- [ ] T001 do the thing' > "$(dirname "${SPEC}")/tasks.md"
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  local want got
  want="$(git hash-object --no-filters "$(dirname "${SPEC}")/tasks.md")"
  got="$(jq -r '.inputs["tasks.md"]' <<< "${doc}")"
  [ "${got}" = "${want}" ]
}

@test "plan.md is omitted when absent, present with its hash when it exists (contracts/run-state-v2.md C3)" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ "$(jq 'has("plan.md") | not' <<< "$(jq '.inputs' <<< "${doc}")")" = "true" ]

  printf '%s\n' '## Summary' > "$(dirname "${SPEC}")/plan.md"
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  local want got
  want="$(git hash-object --no-filters "$(dirname "${SPEC}")/plan.md")"
  got="$(jq -r '.inputs["plan.md"]' <<< "${doc}")"
  [ "${got}" = "${want}" ]
}

@test "config.yml, config.local.yml, and personal.yml are each omitted when absent" {
  local doc inputs_keys
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  inputs_keys="$(jq -r '.inputs | keys | join(",")' <<< "${doc}")"
  [ "${inputs_keys}" = "spec.md" ]
}

@test "config.yml, config.local.yml, and personal.yml are each present with a hash when they exist" {
  printf 'projects: []\n' > "${JIRA_CONFIG_DIR}/config.yml"
  printf 'overrides: []\n' > "${JIRA_CONFIG_DIR}/config.local.yml"
  printf 'name: Ada\n' > "${JIRA_CONFIG_DIR}/personal.yml"
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ "$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/config.yml\"]" <<< "${doc}")" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/config.yml")" ]
  [ "$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/config.local.yml\"]" <<< "${doc}")" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/config.local.yml")" ]
  [ "$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/personal.yml\"]" <<< "${doc}")" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/personal.yml")" ]
}

@test "run_state_compose returns 1 and prints nothing when spec.md cannot be hashed" {
  run run_state_compose "${WORK}/specs/021-example/does-not-exist.md" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

# --- run_state_matches ----------------------------------------------------------

@test "run_state_matches is false when no state file exists" {
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is true after run_state_record with the identical inputs" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  [ "${status}" -eq 0 ]
}

@test "run_state_matches is false once spec.md changes" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  printf '# Feature Specification: Example (touched)\n' > "${SPEC}"
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is false once on_drift differs" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "proceed" "" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is false once field_values differs" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "KEY=Story=Label=New"
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is false once hook_event differs — an unhonoured lifecycle event is never skipped (S1, S9)" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "after_plan" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is true after run_state_record with the identical hook_event" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "after_plan" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "after_plan" ""
  [ "${status}" -eq 0 ]
}

@test "run_state_matches is false when the recorded file is corrupt JSON" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  printf 'not json' > "$(run_state_path "${SPEC}")"
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  [ "${status}" -ne 0 ]
}

# --- run_state_record -------------------------------------------------------------

@test "run_state_record writes a document byte-identical to a fresh compose" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  local recorded fresh
  recorded="$(cat "$(run_state_path "${SPEC}")")"
  fresh="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")"
  [ "${recorded}" = "${fresh}" ]
}

@test "run_state_record creates the state directory and its self-ignoring .gitignore" {
  [ ! -d "${JIRA_CONFIG_DIR}/state" ]
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  [ -d "${JIRA_CONFIG_DIR}/state" ]
  [ "$(cat "${JIRA_CONFIG_DIR}/state/.gitignore")" = "*" ]
}

@test "run_state_record leaves no sibling temp file behind on success" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  run bash -c "find '${JIRA_CONFIG_DIR}/state' -name '*.tmp.*'"
  [ -z "${output}" ]
}

@test "run_state_record never fails the run: a write error is a warning, not an exit code" {
  mkdir -p "${JIRA_CONFIG_DIR}/state"
  chmod 000 "${JIRA_CONFIG_DIR}/state"
  run run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" ""
  chmod 755 "${JIRA_CONFIG_DIR}/state"
  [ "${status}" -eq 0 ]
}

# --- run_state_path ---------------------------------------------------------------

@test "run_state_path names the recorded document after the spec's feature directory" {
  [ "$(run_state_path "${SPEC}")" = "${JIRA_CONFIG_DIR}/state/021-example.json" ]
}

# --- 022 T022: task_mirror edits invalidate the short-circuit ------------------

@test "T022 [022] — editing task_mirror in config.yml changes the recorded config.yml hash" {
  printf 'projects:\n  - key: CONSUMER\n    style: company_managed\nrouting_default: CONSUMER\n' > "${JIRA_CONFIG_DIR}/config.yml"
  local before after
  before="$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/config.yml\"]" <<< "$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")")"
  printf 'task_mirror:\n  CONSUMER: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"
  after="$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/config.yml\"]" <<< "$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "" "")")"
  [ "${before}" != "${after}" ]
  [ "${after}" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/config.yml")" ]
}

# --- T161 [Phase 12, US10]: invariant S6 (021's contracts/run-state-v2.md
# §5) under a NEW event -- a lifecycle event that resolves an actual
# transition (023's own addition to what a run can do), proving the
# --dry-run guard reconcile.sh applies around BOTH run_state_matches (the
# read) and run_state_record (the write) still holds once a move is in
# play, not only for a content-only run (021's own original S6 coverage
# predates hook_event/transitions entirely).

@test "S6 -- --dry-run under a hook event that resolves a transition neither reads nor writes the state document (contracts/run-state-v2.md §5)" {
  local root="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${root}/tests/conformance/mock-jira/lib.sh"
  # shellcheck source=/dev/null
  source "${root}/scripts/bash/commands/reconcile.sh"

  # A pre-bound fixture (COMP-1 parent, COMP-2 story), never a freshly
  # created one: creation carries its own stray-marker note (unrelated to
  # this invariant) that would keep warn_count above zero on every run,
  # masking whether the write's absence is --dry-run's own guard or that
  # unrelated one.
  local work="${BATS_TEST_TMPDIR}/s6-repo"
  cp -R "${root}/tests/conformance/fixtures/repo-with-bound-story-due" "${work}"
  local spec="${work}/specs/001-declared-mapping/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-declared-mapping"

  mock_start "${root}/tests/conformance/mock-jira/configs/comp-bound-story-due-seed.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  # The priming run above (no hook event, zero warnings) already recorded
  # state -- so "unwritten" is proven by content staying IDENTICAL across
  # the dry-run, not by the file's absence.
  local state_file before_dry after_dry
  state_file="$(run_state_path "${spec}")"
  [ -f "${state_file}" ]
  before_dry="$(cat "${state_file}")"

  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  cmd_reconcile reconcile "${spec}" --json --dry-run > /dev/null
  # The read: a preview against the recorded (hook-event-less) state would
  # short-circuit if dry-run ever consulted run_state_matches -- it does
  # not (reconcile.sh's own `dry_run != true` guard around the read), so
  # the preview still ran the full resolution (proven separately by
  # T159/T160). The write: the document on disk is untouched.
  after_dry="$(cat "${state_file}")"
  [ "${before_dry}" = "${after_dry}" ]

  cmd_reconcile reconcile "${spec}" --json > /dev/null
  unset SPEC_KIT_JIRA_HOOK_EVENT
  # The SAME event, for real, DOES record (the hook_event key now present
  # in the document) -- proving the file's continued lack of change above
  # was the dry-run guard, not an unrelated reason (a warning outstanding,
  # a non-zero exit) that would have suppressed the write regardless of
  # --dry-run.
  local after_real
  after_real="$(cat "${state_file}")"
  [ "${after_real}" != "${before_dry}" ]
  [ "$(jq -r '.hook_event' <<< "${after_real}")" = "after_plan" ]

  mock_stop
}
