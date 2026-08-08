#!/usr/bin/env bats
# T018 [US2] — The run-state short-circuit's document layer (spec FR-019…
# FR-028, contracts/run-state.md, data-model.md §1).
#
# git hash-object needs no repository — a plain mktemp -d workdir is enough
# (research R7). JIRA_CONFIG_DIR is overridden to an absolute path per test,
# which is fine here: cross-port byte parity for the "inputs" keys is a
# conformance-corpus concern (T020/T021), not this file's.

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
  a="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  b="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  [ -n "${a}" ]
  [ "${a}" = "${b}" ]
}

@test "the composed document carries exactly the documented top-level fields, and no project_key" {
  local doc keys
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  keys="$(jq -rS 'keys | join(",")' <<< "${doc}")"
  [ "${keys}" = "base_url,email,extension_version,field_values,inputs,on_drift,schema" ]
}

@test "schema is the integer 1 at introduction" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  [ "$(jq -r '.schema' <<< "${doc}")" = "1" ]
  [ "$(jq -r '.schema | type' <<< "${doc}")" = "number" ]
}

@test "base_url, email, on_drift, and field_values are carried verbatim" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "proceed" $'KEY=Story=Label=Value\x1fKEY=Task=Other=Val')"
  [ "$(jq -r '.base_url' <<< "${doc}")" = "https://acme.atlassian.net" ]
  [ "$(jq -r '.email' <<< "${doc}")" = "user@example.com" ]
  [ "$(jq -r '.on_drift' <<< "${doc}")" = "proceed" ]
  [ "$(jq -r '.field_values' <<< "${doc}")" = $'KEY=Story=Label=Value\x1fKEY=Task=Other=Val' ]
}

@test "the document never contains a credential-shaped string" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  [[ "${doc}" != *"Authorization"* ]]
  [[ "${doc}" != *"Basic "* ]]
  [[ "${doc}" != *"ATATT"* ]]
}

# --- inputs: hashing primitive and presence rules ------------------------------

@test "spec.md is always present, hashed with git hash-object --no-filters" {
  local doc want got
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  want="$(git hash-object --no-filters "${SPEC}")"
  got="$(jq -r '.inputs["spec.md"]' <<< "${doc}")"
  [ "${got}" = "${want}" ]
}

@test "tasks.md is omitted when absent, present with its hash when it exists" {
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  [ "$(jq 'has("tasks.md") | not' <<< "$(jq '.inputs' <<< "${doc}")")" = "true" ]

  printf '%s\n' '- [ ] T001 do the thing' > "$(dirname "${SPEC}")/tasks.md"
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  local want got
  want="$(git hash-object --no-filters "$(dirname "${SPEC}")/tasks.md")"
  got="$(jq -r '.inputs["tasks.md"]' <<< "${doc}")"
  [ "${got}" = "${want}" ]
}

@test "config.yml, config.local.yml, and personal.yml are each omitted when absent" {
  local doc inputs_keys
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  inputs_keys="$(jq -r '.inputs | keys | join(",")' <<< "${doc}")"
  [ "${inputs_keys}" = "spec.md" ]
}

@test "config.yml, config.local.yml, and personal.yml are each present with a hash when they exist" {
  printf 'projects: []\n' > "${JIRA_CONFIG_DIR}/config.yml"
  printf 'overrides: []\n' > "${JIRA_CONFIG_DIR}/config.local.yml"
  printf 'name: Ada\n' > "${JIRA_CONFIG_DIR}/personal.yml"
  local doc
  doc="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  [ "$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/config.yml\"]" <<< "${doc}")" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/config.yml")" ]
  [ "$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/config.local.yml\"]" <<< "${doc}")" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/config.local.yml")" ]
  [ "$(jq -r ".inputs[\"${JIRA_CONFIG_DIR}/personal.yml\"]" <<< "${doc}")" = "$(git hash-object --no-filters "${JIRA_CONFIG_DIR}/personal.yml")" ]
}

@test "run_state_compose returns 1 and prints nothing when spec.md cannot be hashed" {
  run run_state_compose "${WORK}/specs/021-example/does-not-exist.md" "https://acme.atlassian.net" "user@example.com" "abort" ""
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

# --- run_state_matches ----------------------------------------------------------

@test "run_state_matches is false when no state file exists" {
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is true after run_state_record with the identical inputs" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  [ "${status}" -eq 0 ]
}

@test "run_state_matches is false once spec.md changes" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  printf '# Feature Specification: Example (touched)\n' > "${SPEC}"
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is false once on_drift differs" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "proceed" ""
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is false once field_values differs" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "KEY=Story=Label=New"
  [ "${status}" -ne 0 ]
}

@test "run_state_matches is false when the recorded file is corrupt JSON" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  printf 'not json' > "$(run_state_path "${SPEC}")"
  run run_state_matches "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  [ "${status}" -ne 0 ]
}

# --- run_state_record -------------------------------------------------------------

@test "run_state_record writes a document byte-identical to a fresh compose" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  local recorded fresh
  recorded="$(cat "$(run_state_path "${SPEC}")")"
  fresh="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  [ "${recorded}" = "${fresh}" ]
}

@test "run_state_record creates the state directory and its self-ignoring .gitignore" {
  [ ! -d "${JIRA_CONFIG_DIR}/state" ]
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  [ -d "${JIRA_CONFIG_DIR}/state" ]
  [ "$(cat "${JIRA_CONFIG_DIR}/state/.gitignore")" = "*" ]
}

@test "run_state_record leaves no sibling temp file behind on success" {
  run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  run bash -c "find '${JIRA_CONFIG_DIR}/state' -name '*.tmp.*'"
  [ -z "${output}" ]
}

@test "run_state_record never fails the run: a write error is a warning, not an exit code" {
  mkdir -p "${JIRA_CONFIG_DIR}/state"
  chmod 000 "${JIRA_CONFIG_DIR}/state"
  run run_state_record "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" ""
  chmod 755 "${JIRA_CONFIG_DIR}/state"
  [ "${status}" -eq 0 ]
}

# --- run_state_path ---------------------------------------------------------------

@test "run_state_path names the recorded document after the spec's feature directory" {
  [ "$(run_state_path "${SPEC}")" = "${JIRA_CONFIG_DIR}/state/021-example.json" ]
}
