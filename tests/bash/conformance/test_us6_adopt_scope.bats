#!/usr/bin/env bats
# T164 [US6] — Partial and resumable adoption, end to end (003 FR-026, FR-027,
# SC-007, NFR-1).
#
# Adoption of an enterprise backlog is not a single atomic event: an operator
# takes it a few specs at a time, and a run can be interrupted. These scenarios
# prove both halves — a scoped run leaves every other folder completely untouched
# (not merely unwritten), and a re-run completes what an interrupted one started
# without ever stamping a ticket twice.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

run_bash() {
  bash "${HARNESS}" "${CONF}/scenarios/$1" bash "${TMP}/out-bash" > /dev/null
}

both_ports() {
  bash "${HARNESS}" "${CONF}/scenarios/$1" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${CONF}/scenarios/$1" powershell "${TMP}/out-ps" > /dev/null
}

parity() {
  for f in exit stdout stderr calls.log; do
    run diff "${TMP}/out-bash/${f}" "${TMP}/out-ps/${f}"
    [ "$status" -eq 0 ]
  done
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

puts() {
  grep -c '^PUT ' "${TMP}/out-bash/calls.log" || true
}

# --- scoping (T161, FR-026) --------------------------------------------------

@test "scope: only the two scoped folders bind, exit 0" {
  run_bash us6-adopt-scope.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '[.adoption.bindings[].spec_folder] | unique | join(",")' "${TMP}/out-bash/stdout")" = "003-alpha-report,005-delta-billing" ]
  [ "$(jq -r '.adoption.bindings | length' "${TMP}/out-bash/stdout")" -eq 4 ]
  [ "$(puts)" -eq 4 ]
}

@test "scope: the other three are reported out of scope, sorted ascending" {
  run_bash us6-adopt-scope.json
  [ "$(jq -r '.adoption.out_of_scope | join(",")' "${TMP}/out-bash/stdout")" = "004-beta-import,004-gamma-export,006-epsilon-ledger" ]
}

@test "scope: ZERO reads and zero writes against out-of-scope tickets (US6 AS-1)" {
  run_bash us6-adopt-scope.json
  # Their labels never entered a query, so their keys never appear at all.
  for k in ADO-3 ADO-4 ADO-5 ADO-6 BILL-3 BILL-4; do
    [ "$(grep -c "${k}" "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  done
  for l in 004-beta-import 004-gamma-export 006-epsilon-ledger; do
    [ "$(grep -c "${l}" "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  done
}

@test "scope: one search per routed project still in scope, and no more" {
  run_bash us6-adopt-scope.json
  # The two scoped folders route to two different projects.
  [ "$(grep -c '^GET /rest/api/3/search/jql' "${TMP}/out-bash/calls.log")" -eq 2 ]
}

@test "scope is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us6-adopt-scope.json
  parity
}

# --- resuming (T162, FR-027, SC-007) -----------------------------------------

@test "resume: the pre-stamped tickets are skipped, the rest are stamped" {
  run_bash us6-adopt-resume.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.counts.skipped' "${TMP}/out-bash/stdout")" -eq 2 ]
  [ "$(jq -r '.counts.updated' "${TMP}/out-bash/stdout")" -eq 8 ]
  [ "$(puts)" -eq 8 ]
}

@test "resume: a pre-stamped ticket is never written again (SC-007)" {
  run_bash us6-adopt-resume.json
  for k in ADO-1 ADO-2; do
    [ "$(grep -c "PUT /rest/api/3/issue/${k}/" "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  done
  # Every other ticket is stamped exactly once.
  for k in ADO-3 ADO-4 ADO-5 ADO-6 BILL-1 BILL-2 BILL-3 BILL-4; do
    [ "$(grep -c "PUT /rest/api/3/issue/${k}/" "${TMP}/out-bash/calls.log")" -eq 1 ]
  done
}

@test "resume: a skipped ticket is reported already-adopted, never as an error" {
  run_bash us6-adopt-resume.json
  [ "$(jq -r '[.adoption.bindings[] | select(.status == "already-adopted") | .issue_key] | join(",")' "${TMP}/out-bash/stdout")" = "ADO-1,ADO-2" ]
  [ "$(jq -r '.counts.errors' "${TMP}/out-bash/stdout")" -eq 0 ]
  [ "$(jq -r '.adoption.refusals | length' "${TMP}/out-bash/stdout")" -eq 0 ]
}

@test "resume is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us6-adopt-resume.json
  parity
}

# --- an unknown scope stops the run (T163, US6 AS-3) -------------------------

@test "unknown scope: usage error, exit 1, zero writes, nothing searched" {
  run_bash us6-adopt-unknown-scope.json
  [ "$(cat "${TMP}/out-bash/exit")" = "1" ]
  [ "$(puts)" -eq 0 ]
  [ ! -s "${TMP}/out-bash/calls.log" ]
  grep -q '009-never-on-disk' "${TMP}/out-bash/stderr"
}

@test "unknown scope is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us6-adopt-unknown-scope.json
  parity
}
