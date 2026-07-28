#!/usr/bin/env bats
# T155 [US6] — Partial adoption through --spec (003 FR-026, data-model §6).
#
# `--spec` restricts a run to a subset of spec folders. The claim that has to
# hold is stronger than "the others are not written to": an out-of-scope folder
# contributes NO LABEL to any query, so there is zero read and zero write against
# its tickets — the bridge does not look at them at all. A scope naming a folder
# absent from disk stops the whole run as a usage error with zero writes.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  ENTRY="${ROOT}/scripts/bash/spec-kit-jira.sh"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  WORK="$(mktemp -d)"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-adoption-multi/." "${WORK}/"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  # Every one of the five folders is fully labelled, so anything left unbound is
  # the scope's doing rather than a gap in the corpus.
  CORPUS='{"projects":{"ADO":"company","BILL":"team"},"issues":{
    "ADO-1":{"labels":["speckit-adopt:003-alpha-report"]},
    "ADO-2":{"labels":["speckit-adopt:003-alpha-report:us1"],"parent":"ADO-1"},
    "ADO-3":{"labels":["speckit-adopt:004-beta-import"]},
    "ADO-4":{"labels":["speckit-adopt:004-beta-import:us1"],"parent":"ADO-3"},
    "ADO-5":{"labels":["speckit-adopt:004-gamma-export"]},
    "ADO-6":{"labels":["speckit-adopt:004-gamma-export:us1"],"parent":"ADO-5"},
    "BILL-1":{"labels":["speckit-adopt:005-delta-billing"]},
    "BILL-2":{"labels":["speckit-adopt:005-delta-billing:us1"],"parent":"BILL-1"},
    "BILL-3":{"labels":["speckit-adopt:006-epsilon-ledger"]},
    "BILL-4":{"labels":["speckit-adopt:006-epsilon-ledger:us1"],"parent":"BILL-3"}}}'
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

start() {
  mock_start_json "${CORPUS}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

adopt() {
  ( cd "${WORK}" && bash "${ENTRY}" adopt "$@" )
}

puts() {
  mock_calls | grep -c '^PUT ' || true
}

# --- only the scoped folders are discovered (FR-026) -------------------------

@test "only the scoped folders are bound" {
  start
  run adopt --spec 003-alpha-report --spec 005-delta-billing --yes --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.adoption.bindings[].spec_folder] | unique | join(",")' <<< "$output")" = "003-alpha-report,005-delta-billing" ]
  [ "$(jq -r '.adoption.bindings | length' <<< "$output")" -eq 4 ]
  [ "$(puts)" -eq 4 ]
}

@test "the rest are reported out of scope, sorted ascending" {
  start
  run adopt --spec 003-alpha-report --spec 005-delta-billing --yes --json
  [ "$(jq -r '.adoption.out_of_scope | join(",")' <<< "$output")" = "004-beta-import,004-gamma-export,006-epsilon-ledger" ]
}

@test "an out-of-scope folder contributes NO label to any query (zero reads)" {
  start
  run adopt --spec 003-alpha-report --yes
  [ "$status" -eq 0 ]
  local calls
  calls="$(mock_calls)"
  # Its labels never appear in a JQL, so its tickets are never even returned …
  [[ "$calls" != *"004-beta-import"* ]]
  [[ "$calls" != *"006-epsilon-ledger"* ]]
  # … and therefore never read or written.
  for k in ADO-3 ADO-4 ADO-5 ADO-6 BILL-1 BILL-2 BILL-3 BILL-4; do
    [ "$(grep -c "${k}" <<< "$calls" || true)" -eq 0 ]
  done
}

@test "scoping to one project searches only that project" {
  start
  run adopt --spec 003-alpha-report --yes
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c '^GET /rest/api/3/search/jql')" -eq 1 ]
  [[ "$(mock_calls)" == *"%22ADO%22"* ]]
  [[ "$(mock_calls)" != *"%22BILL%22"* ]]
}

@test "no --spec means every folder on disk, and an empty out_of_scope" {
  start
  run adopt --yes --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.adoption.out_of_scope | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.adoption.bindings[].spec_folder] | unique | length' <<< "$output")" -eq 5 ]
}

@test "a repeated --spec accumulates rather than replacing" {
  start
  run adopt --spec 003-alpha-report --spec 004-beta-import --spec 006-epsilon-ledger --yes --json
  [ "$(jq -r '[.adoption.bindings[].spec_folder] | unique | length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '.adoption.out_of_scope | join(",")' <<< "$output")" = "004-gamma-export,005-delta-billing" ]
}

# --- an unknown folder stops the run (FR-026, US6 AS-3) ---------------------

@test "a --spec naming a folder absent from disk is a usage error, exit 1" {
  start
  run adopt --spec 009-never-on-disk --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"009-never-on-disk"* ]]
}

@test "the unknown-folder error stops the run BEFORE anything is read or written" {
  start
  run adopt --spec 009-never-on-disk --yes
  [ "$status" -eq 1 ]
  [ -z "$(mock_calls)" ]
  [ "$(puts)" -eq 0 ]
}

@test "one unknown folder among known ones still stops the whole run" {
  start
  run adopt --spec 003-alpha-report --spec 009-never-on-disk --yes
  [ "$status" -eq 1 ]
  [ -z "$(mock_calls)" ]
}

# --- scope is applied BEFORE label derivation (data-model §6) ---------------

@test "scoping to ONE of the two 004 folders makes its short form unambiguous" {
  # 004-beta-import and 004-gamma-export share the numbering component, so the
  # short form is suppressed for both — unless only one of them is in scope.
  mock_start_json '{"projects":{"ADO":"company"},"issues":{
    "ADO-40":{"labels":["speckit-adopt:004"]}}}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run adopt --spec 004-beta-import --yes --json
  [ "$status" -eq 4 ]
  # It binds through the short form; the refusal that remains is its story's.
  [ "$(jq -r '[.adoption.bindings[] | select(.issue_key == "ADO-40")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.adoption.refusals[] | select(.reason == "ambiguous-short-number")] | length' <<< "$output")" -eq 0 ]
}

@test "with BOTH 004 folders in scope the short form is ambiguous again" {
  mock_start_json '{"projects":{"ADO":"company"},"issues":{
    "ADO-40":{"labels":["speckit-adopt:004"]}}}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run adopt --spec 004-beta-import --spec 004-gamma-export --yes --json
  [ "$status" -eq 4 ]
  [ "$(jq -r '[.adoption.refusals[] | select(.reason == "ambiguous-short-number")] | length' <<< "$output")" -eq 2 ]
  [ "$(puts)" -eq 0 ]
}

# --- the plan reports the scope to the operator (Principle XVI) -------------

@test "the prose plan names the out-of-scope folders" {
  start
  run adopt --spec 003-alpha-report --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"out of scope: 004-beta-import, 004-gamma-export, 005-delta-billing, 006-epsilon-ledger"* ]]
}

@test "the prose plan omits the out-of-scope line entirely when nothing is excluded" {
  start
  run adopt --dry-run
  [[ "$output" != *"out of scope"* ]]
}
