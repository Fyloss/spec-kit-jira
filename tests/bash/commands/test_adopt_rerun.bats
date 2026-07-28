#!/usr/bin/env bats
# T106 [US3] / T159 [US6] — Re-running adoption on an adopted corpus
# (003 FR-019, FR-027, SC-004, SC-007).
#
# Zero-churn idempotency is Principle II applied to adoption: a second run over
# an already-adopted corpus performs ZERO writes of every kind and exits 0. The
# mechanism is the marker itself — a candidate carrying THIS spec's marker with
# origin `human` is recognised as already adopted, skipped, and counted as
# skipped rather than re-stamped. That is also what makes an INTERRUPTED
# adoption complete on re-run with exactly one stamp per ticket.

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
  ISSUES='"ADO-1":{"labels":["speckit-adopt:003-label-based-adoption"]},
          "ADO-2":{"labels":["speckit-adopt:003-label-based-adoption:us1"],"parent":"ADO-1"},
          "ADO-3":{"labels":["speckit-adopt:003-label-based-adoption:us2"],"parent":"ADO-1"},
          "ADO-4":{"labels":["speckit-adopt:004-billing-export"]},
          "ADO-5":{"labels":["speckit-adopt:004-billing-export:us1"],"parent":"ADO-4"},
          "ADO-6":{"labels":["speckit-adopt:005-audit-trail"]},
          "ADO-7":{"labels":["speckit-adopt:005-audit-trail:us1"],"parent":"ADO-6"}'
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

# start_with_adopted <key...> — the corpus with those keys already carrying this
# spec's human-origin marker (i.e. already adopted by a previous run).
start_with_adopted() {
  local identity='{}' key slug
  for key in "$@"; do
    case "${key}" in
      ADO-1 | ADO-2 | ADO-3) slug="003-label-based-adoption" ;;
      ADO-4 | ADO-5) slug="004-billing-export" ;;
      *) slug="005-audit-trail" ;;
    esac
    identity="$(jq -c --arg k "${key}" --arg s "${slug}" \
      '. + {($k): {origin:"human", repo:"acme/app", spec_slug:$s}}' <<< "${identity}")"
  done
  mock_start_json "$(jq -cn --argjson id "${identity}" --argjson iss "{${ISSUES}}" \
    '{projects:{ADO:"company"}, identity:$id, issues:$iss}')"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

adopt() {
  ( cd "${WORK}" && bash "${ENTRY}" adopt "$@" )
}

puts() {
  mock_calls | grep -c '^PUT ' || true
}

writes_of_every_kind() {
  mock_calls | grep -cE '^(PUT|POST|DELETE|PATCH) ' || true
}

# --- a fully adopted corpus: zero writes, exit 0 (FR-019, SC-004) ------------

@test "re-running over a fully adopted corpus performs ZERO writes and exits 0" {
  start_with_adopted ADO-1 ADO-2 ADO-3 ADO-4 ADO-5 ADO-6 ADO-7
  run adopt --yes --json
  [ "$status" -eq 0 ]
  [ "$(writes_of_every_kind)" -eq 0 ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 0 ]
}

@test "every binding of an adopted corpus is reported already-adopted and skipped" {
  start_with_adopted ADO-1 ADO-2 ADO-3 ADO-4 ADO-5 ADO-6 ADO-7
  run adopt --yes --json
  [ "$(jq -r '[.adoption.bindings[] | select(.status == "already-adopted")] | length' <<< "$output")" -eq 7 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 7 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  # Skipped is NOT an error (FR-027).
  [ "$(jq -r '.counts.errors' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.adoption.refusals | length' <<< "$output")" -eq 0 ]
}

@test "the prose plan calls an adopted ticket already adopted, not a refusal" {
  start_with_adopted ADO-1 ADO-2 ADO-3 ADO-4 ADO-5 ADO-6 ADO-7
  run adopt --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"already adopted"* ]]
  [[ "$output" != *"REFUSED"* ]]
}

# --- an interrupted run completes on re-run (FR-027, SC-007) -----------------

@test "an interrupted adoption completes on re-run with exactly ONE stamp per ticket" {
  # First run: interrupted after three tickets were stamped.
  start_with_adopted ADO-1 ADO-2 ADO-3
  run adopt --yes --json
  [ "$status" -eq 0 ]
  # The three already-stamped tickets are skipped, not re-stamped …
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 3 ]
  # … and only the remaining four are written.
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 4 ]
  [ "$(puts)" -eq 4 ]
  for k in ADO-1 ADO-2 ADO-3; do
    [ "$(mock_calls | grep -c "PUT /rest/api/3/issue/${k}/" || true)" -eq 0 ]
  done
  for k in ADO-4 ADO-5 ADO-6 ADO-7; do
    [ "$(mock_calls | grep -c "PUT /rest/api/3/issue/${k}/" || true)" -eq 1 ]
  done
}

@test "no ticket is ever stamped twice across the two runs (SC-007)" {
  # Run one stamps four; run two (with all seven marked) stamps none. Total:
  # exactly one stamp per ticket.
  start_with_adopted ADO-1 ADO-2 ADO-3
  adopt --yes > /dev/null
  local first_run
  first_run="$(puts)"
  mock_stop
  start_with_adopted ADO-1 ADO-2 ADO-3 ADO-4 ADO-5 ADO-6 ADO-7
  adopt --yes > /dev/null
  [ $((first_run + $(puts))) -eq 4 ]
}

# --- a stale claim by ANOTHER spec is still a refusal, not a skip ------------

@test "an adopted ticket claimed by another spec is refused, never silently skipped" {
  mock_start_json "$(jq -cn --argjson iss "{${ISSUES}}" '
    {projects:{ADO:"company"},
     identity:{"ADO-4":{origin:"human", repo:"acme/app", spec_slug:"009-elsewhere"}},
     issues:$iss}')"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run adopt --yes --json
  [ "$status" -eq 4 ]
  [ "$(jq -r '[.adoption.refusals[] | select(.reason == "already-claimed")] | length' <<< "$output")" -eq 1 ]
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/ADO-4/' || true)" -eq 0 ]
}

# --- the re-run is still read-only until confirmed ---------------------------

@test "a dry re-run over an adopted corpus also writes nothing and reports no action" {
  start_with_adopted ADO-1 ADO-2 ADO-3 ADO-4 ADO-5 ADO-6 ADO-7
  run adopt --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(writes_of_every_kind)" -eq 0 ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 0 ]
}
