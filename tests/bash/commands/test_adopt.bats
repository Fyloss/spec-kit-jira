#!/usr/bin/env bats
# T039 [US1] — The adopt command's two phases (003 FR-001, FR-006, FR-023,
# adopt-cli-contract §Phases/§Confirmation).
#
# Phase 1 is read-only and ALWAYS prints the plan before anything is written.
# Phase 2 runs only after confirmation. The enablement gate short-circuits the
# whole command with zero reads against candidate tickets; a decline is an
# operator choice, not a failure; and with neither a terminal nor --yes the run
# collapses onto its own dry-run path and names --yes as the way to proceed.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  ENTRY="${ROOT}/scripts/bash/spec-kit-jira.sh"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  WORK="$(mktemp -d)"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-adoption/." "${WORK}/"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  CORPUS='{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
    "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
    "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
    "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
    "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
    "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}'
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

start() {
  mock_start_json "${1:-${CORPUS}}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

# adopt <args...> — run the real dispatcher inside the fixture workdir.
adopt() {
  ( cd "${WORK}" && bash "${ENTRY}" adopt "$@" )
}

puts() {
  mock_calls | grep -c '^PUT ' || true
}

# --- The enablement gate (FR-001, SC-009) ------------------------------------

@test "adoption disabled: exit 4 naming the config key, ZERO candidate reads" {
  start
  run env JIRA_CONFIG_DIR=".specify/jira-disabled" bash -c "cd '${WORK}' && bash '${ENTRY}' adopt --yes"
  [ "$status" -eq 4 ]
  [[ "$output" == *"adoption.enabled"* ]]
  [ -z "$(mock_calls)" ]
}

@test "an absent adoption section is exactly equivalent to disabled" {
  start
  # Strip the section entirely; the gate must behave identically.
  grep -v -e '^adoption:' -e '^  enabled:' -e '^  label_prefix:' \
    "${WORK}/.specify/jira/config.yml" > "${WORK}/.specify/jira/config.yml.new"
  mv "${WORK}/.specify/jira/config.yml.new" "${WORK}/.specify/jira/config.yml"
  run adopt --yes
  [ "$status" -eq 4 ]
  [ -z "$(mock_calls)" ]
}

# --- Phase 1 precedes phase 2 (FR-006) ---------------------------------------

@test "the plan is printed BEFORE any write" {
  start
  run adopt --yes
  [ "$status" -eq 0 ]
  local plan_line write_line
  plan_line="$(printf '%s\n' "$output" | grep -n 'Adoption plan' | head -1 | cut -d: -f1)"
  write_line="$(printf '%s\n' "$output" | grep -n 'Updated: 7' | head -1 | cut -d: -f1)"
  [ -n "$plan_line" ]
  [ -n "$write_line" ]
  [ "$plan_line" -lt "$write_line" ]
}

@test "the plan lists one line per target with its key and reason" {
  start
  run adopt --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"003-label-based-adoption"*"ADO-1"*"adopt"*"(label match)"* ]]
  [[ "$output" == *"005-audit-trail:us1"* ]]
}

# --- Confirmation (research §6, adopt-cli-contract §Confirmation) ------------

@test "--yes pre-confirms and the apply phase runs" {
  start
  run adopt --yes
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 7 ]
}

@test "an affirmative answer applies the plan" {
  start
  run env SPEC_KIT_JIRA_ADOPT_ANSWER=y bash -c "cd '${WORK}' && bash '${ENTRY}' adopt"
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 7 ]
  [[ "$output" == *"Apply this plan? [y/N]"* ]]
}

@test "a decline exits 0 with zero writes and reports the cancellation" {
  start
  run env SPEC_KIT_JIRA_ADOPT_ANSWER=n bash -c "cd '${WORK}' && bash '${ENTRY}' adopt"
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$output" == *"Adoption cancelled"* ]]
}

@test "any answer that is not affirmative declines (fail-closed)" {
  start
  run env SPEC_KIT_JIRA_ADOPT_ANSWER="maybe later" bash -c "cd '${WORK}' && bash '${ENTRY}' adopt"
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$output" == *"Adoption cancelled"* ]]
}

@test "no terminal and no --yes: dry-run-identical output naming --yes, zero writes" {
  start
  run adopt
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"no terminal is attached"* ]]
}

@test "the no-terminal path reports the same plan and action set as --dry-run" {
  # The two paths differ only in their closing note and in the summary's
  # dry-run marker: the PLAN and the ACTION SET — everything up to and
  # including the Actions block — must be identical (research §6).
  start
  local no_tty
  no_tty="$(adopt | sed '/^Adoption not applied/,$d')"
  mock_stop
  start
  local dry
  dry="$(adopt --dry-run | sed '/^Dry run:/,$d')"
  [ -n "$no_tty" ]
  [ "$no_tty" = "$dry" ]
}

# --- --dry-run never prompts and never writes (FR-023) -----------------------

@test "--dry-run performs zero writes and never prompts" {
  start
  run adopt --dry-run
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 0 ]
  [[ "$output" != *"Apply this plan?"* ]]
  [[ "$output" == *"Dry run: nothing was written."* ]]
}

@test "--dry-run reports the action set the real run performs (FR-023, SC-003)" {
  start
  local dry_actions
  dry_actions="$(adopt --dry-run --json | jq -c '.actions')"
  mock_stop
  start
  local real_actions
  real_actions="$(adopt --yes --json | jq -c '.actions')"
  [ "$dry_actions" = "$real_actions" ]
}

# --- Output shape -------------------------------------------------------------

@test "the default output is prose and --json is the opt-in machine form" {
  start
  run adopt --dry-run
  [[ "$output" == "Adoption plan"* ]]
  mock_stop
  start
  run adopt --dry-run --json
  [ "$(jq -r '.command' <<< "$output")" = "adopt" ]
  [ "$(jq -r '.schema_version' <<< "$output")" = "1.0" ]
  [ "$(jq -r '.adoption.label_prefix' <<< "$output")" = "speckit-adopt:" ]
}

@test "no output at any verbosity carries the token or the site host (FR-025)" {
  start
  run adopt --yes --verbose --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"RAWSECRETXYZ"* ]]
  [[ "$output" != *"${MOCK_BASE_URL}"* ]]
  [[ "$output" != *"127.0.0.1"* ]]
}

# --- nothing in scope (T190, spec Edge Cases) --------------------------------
#
# A repository carrying no spec folder is not an error. The run completes, reads
# nothing, writes nothing — and SAYS so, rather than printing a bare header the
# operator is left to interpret as success (Constitution XVI).

# empty_specs — the repository with adoption enabled and not one spec folder.
empty_specs() {
  rm -rf "${WORK:?}/specs"
  mkdir -p "${WORK}/specs"
}

@test "zero targets in scope: exit 0, zero reads, zero writes" {
  start
  empty_specs
  run adopt --yes
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls)" ]
  [ "$(puts)" -eq 0 ]
}

@test "zero targets in scope: the plan states that nothing was found" {
  start
  empty_specs
  run adopt --yes
  [[ "$output" == *"nothing was found"* ]]
}

@test "zero targets in scope: no binding, no refusal, no out-of-scope folder" {
  start
  empty_specs
  run adopt --yes --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.adoption.bindings | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.adoption.refusals | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.adoption.out_of_scope | length' <<< "$output")" -eq 0 ]
}

@test "a plan that DOES carry targets never claims nothing was found" {
  start
  run adopt --dry-run
  [[ "$output" != *"nothing was found"* ]]
}
