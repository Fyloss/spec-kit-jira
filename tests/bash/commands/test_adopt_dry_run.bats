#!/usr/bin/env bats
# T138 [US5] — The dry-run twin is EXACT (003 FR-023, SC-003).
#
# For `adopt` this is a structural guarantee rather than a behavioural promise:
# the action set IS the prediction. The command builds one ordered set of
# identity stamps and either prints it (dry run) or hands the SAME value to the
# write path (real run) — there is no second code path that could drift.
#
# These tests hold both halves of that to the same corpus and diff them.

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
  FULL='{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
    "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
    "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
    "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
    "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
    "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}}}'
  # A corpus that mixes bindings with refusals, so the equivalence is proven for
  # a plan that is not simply "everything binds".
  MIXED='{"projects":{"ADO":"company"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
    "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
    "ADO-8":{"labels":["speckit-adopt:004-billing-export"]},
    "ADO-9":{"labels":["speckit-adopt:004-billing-export"]}}}'
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

start() {
  mock_start_json "${1:-${FULL}}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

adopt() {
  ( cd "${WORK}" && bash "${ENTRY}" adopt "$@" )
}

writes() {
  mock_calls | grep -cE '^(PUT|POST|DELETE|PATCH) ' || true
}

# --- the dry run writes nothing (FR-023) -------------------------------------

@test "a dry run performs zero writes of every kind" {
  start
  run adopt --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 0 ]
}

@test "a dry run still READS: it is a real discovery, not a stub" {
  start
  adopt --dry-run --json > /dev/null
  [ "$(mock_calls | grep -c '^GET /rest/api/3/search/jql')" -eq 1 ]
  [ "$(mock_calls | grep -c '^GET .*/properties/spec-kit-jira')" -eq 7 ]
}

@test "a dry run marks itself as one in the summary" {
  start
  run adopt --dry-run --json
  [ "$(jq -r '.dry_run' <<< "$output")" = "true" ]
  [ "$(jq -r '.adoption.confirmed' <<< "$output")" = "false" ]
}

@test "the real run is not marked a dry run and is confirmed" {
  start
  run adopt --yes --json
  [ "$(jq -r '.dry_run' <<< "$output")" = "false" ]
  [ "$(jq -r '.adoption.confirmed' <<< "$output")" = "true" ]
}

# --- the reported action set is IDENTICAL (SC-003) ---------------------------

@test "the dry-run action set equals the real run's, byte for byte" {
  start
  local dry
  dry="$(adopt --dry-run --json | jq -c '.actions')"
  mock_stop
  start
  local real
  real="$(adopt --yes --json | jq -c '.actions')"
  [ "$dry" = "$real" ]
  [ "$(jq 'length' <<< "$dry")" -eq 7 ]
}

@test "the equivalence holds for a plan that MIXES bindings and refusals" {
  start "${MIXED}"
  local dry
  dry="$(adopt --dry-run --json | jq -c '.actions')"
  mock_stop
  start "${MIXED}"
  local real
  real="$(adopt --yes --json | jq -c '.actions')"
  [ "$dry" = "$real" ]
}

@test "the whole adoption plan — bindings, refusals, scope — is identical too" {
  start "${MIXED}"
  local dry
  dry="$(adopt --dry-run --json | jq -c '.adoption | del(.confirmed)')"
  mock_stop
  start "${MIXED}"
  local real
  real="$(adopt --yes --json | jq -c '.adoption | del(.confirmed)')"
  [ "$dry" = "$real" ]
}

@test "the counts a dry run reports are the ones the real run performs" {
  start
  local dry
  dry="$(adopt --dry-run --json | jq -c '.counts')"
  mock_stop
  start
  local real
  real="$(adopt --yes --json | jq -c '.counts')"
  [ "$dry" = "$real" ]
}

@test "the dry run predicts the exit code the real run returns" {
  start "${MIXED}"
  run adopt --dry-run
  local dry_status="$status"
  mock_stop
  start "${MIXED}"
  run adopt --yes
  [ "$dry_status" -eq "$status" ]
  [ "$status" -eq 4 ]
}

# --- the prediction is the SET, so the call log matches it --------------------

@test "every action the dry run predicted appears in the real run's call log" {
  start
  local predicted
  predicted="$(adopt --dry-run --json | jq -r '.actions[] | "\(.method) \(.url)"')"
  mock_stop
  start
  adopt --yes > /dev/null
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    mock_calls | grep -qF "${line}"
  done <<< "${predicted}"
}

@test "the real run performs NOTHING the dry run did not predict" {
  start
  local predicted
  predicted="$(adopt --dry-run --json | jq -r '[.actions[] | "\(.method) \(.url)"] | length')"
  mock_stop
  start
  adopt --yes > /dev/null
  [ "$(writes)" -eq "${predicted}" ]
}

# --- --dry-run never prompts --------------------------------------------------

@test "--dry-run never prompts, even with an answer available" {
  start
  run env SPEC_KIT_JIRA_ADOPT_ANSWER=y bash -c "cd '${WORK}' && bash '${ENTRY}' adopt --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Apply this plan?"* ]]
  [ "$(writes)" -eq 0 ]
}

@test "--dry-run wins over --yes: the operator asked to see, not to write" {
  start
  run adopt --dry-run --yes --json
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 0 ]
  [ "$(jq -r '.adoption.confirmed' <<< "$output")" = "false" ]
}
