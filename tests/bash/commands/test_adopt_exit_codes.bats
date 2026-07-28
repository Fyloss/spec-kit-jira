#!/usr/bin/env bats
# T080 [US2] — Exit-code precedence (003 FR-013, FR-030, adopt-cli-contract).
#
# A mixed run applies its unambiguous bindings AND exits 4: a per-binding refusal
# never stops the rest of the run, but it is still an error. When classes
# co-occur the HIGHEST applicable code wins — a privacy block (9) beats a
# refusal (4), a transport failure (2/3) beats a refusal, and a usage error (1)
# stops the run before any of them can be reached. A decline is an operator
# choice and stays 0, unless a refusal already made the run a 4.

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

  # 003 is fully labelled; 004 has two candidates (several-candidates); 005 has
  # none (no-candidate). So a run over the fixture mixes bindings and refusals.
  MIXED='{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
    "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
    "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
    "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}'
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

start() {
  mock_start_json "${1:-${MIXED}}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

adopt() {
  ( cd "${WORK}" && bash "${ENTRY}" adopt "$@" )
}

puts() {
  mock_calls | grep -c '^PUT ' || true
}

# --- a mixed run applies and exits 4 (FR-013) --------------------------------

@test "a mixed run applies the unambiguous bindings AND exits 4" {
  start
  run adopt --yes --json
  [ "$status" -eq 4 ]
  # 003's three tickets bind; 004 and 005 refuse.
  [ "$(jq -r '.adoption.bindings | length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '.adoption.refusals | length' <<< "$output")" -gt 0 ]
  [ "$(jq -r '.exit_code' <<< "$output")" -eq 4 ]
  [ "$(puts)" -eq 3 ]
}

@test "a refused binding leaves ZERO writes of its own" {
  start
  run adopt --yes
  [ "$status" -eq 4 ]
  # Neither of 004's two candidates is stamped.
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/ADO-8/' || true)" -eq 0 ]
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/ADO-9/' || true)" -eq 0 ]
}

@test "the errors count equals the number of refusals" {
  start
  run adopt --yes --json
  [ "$(jq -r '.counts.errors' <<< "$output")" -eq "$(jq -r '.adoption.refusals | length' <<< "$output")" ]
}

@test "a clean run exits 0 (control)" {
  start '{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
    "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
    "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
    "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
    "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
    "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}'
  run adopt --yes
  [ "$status" -eq 0 ]
}

# --- a decline still exits 4 when a refusal occurred -------------------------

@test "a decline exits 4 if any refusal occurred, with zero writes" {
  start
  run env SPEC_KIT_JIRA_ADOPT_ANSWER=n bash -c "cd '${WORK}' && bash '${ENTRY}' adopt"
  [ "$status" -eq 4 ]
  [ "$(puts)" -eq 0 ]
}

@test "a dry run over a refusing corpus also exits 4, with zero writes" {
  start
  run adopt --dry-run
  [ "$status" -eq 4 ]
  [ "$(puts)" -eq 0 ]
}

# --- the highest applicable code wins (FR-013) -------------------------------

@test "a privacy block (9) beats a refusal (4)" {
  start
  run env SPEC_KIT_JIRA_REPO="acme/mirror-of-acme.atlassian.net" \
    bash -c "cd '${WORK}' && bash '${ENTRY}' adopt --yes"
  [ "$status" -eq 9 ]
  [ "$(puts)" -eq 0 ]
}

@test "an authentication failure (3) during discovery beats a refusal (4)" {
  start '{"projects":{"ADO":"company"},"faults":{"ADO":{"status":401}},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]}}}'
  run adopt --yes
  [ "$status" -eq 3 ]
  [ "$(puts)" -eq 0 ]
}

@test "a usage error (1) stops the run before anything is read" {
  start
  run adopt --nonsense
  [ "$status" -eq 1 ]
  [ -z "$(mock_calls)" ]
}

@test "a configuration refusal (4) is reported even with no candidate read" {
  start
  run env JIRA_CONFIG_DIR=".specify/jira-disabled" \
    bash -c "cd '${WORK}' && bash '${ENTRY}' adopt --yes"
  [ "$status" -eq 4 ]
  [ -z "$(mock_calls)" ]
}

# --- the exit code is reported inside the summary too ------------------------

@test "the summary's exit_code matches the process exit code" {
  start
  run adopt --yes --json
  [ "$(jq -r '.exit_code' <<< "$output")" -eq "$status" ]
}
