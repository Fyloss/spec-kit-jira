#!/usr/bin/env bats
# T114 [US3] — Human-content preservation, end to end (003 SC-002, SC-004,
# SC-006, FR-018, FR-019).
#
# This is the promise that makes adoption acceptable to a Product Owner, so it is
# proven through the real dispatchers on both ports rather than at unit level:
#
#   us3-adopt-preserve          adopt -> reconcile -> reconcile
#   us3-adopt-rerun-zero-write  adopt -> adopt
#
# A single modified byte outside the managed panel is a failing test, not a
# tolerance.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
  HUMAN="PO handwritten note that must survive byte-for-byte."
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

# step_summary <n> — the JSON summary emitted by the nth step (1-based).
step_summary() {
  sed -n "$1p" "${TMP}/out-bash/stdout"
}

# --- adopt -> reconcile -> reconcile (T112) ----------------------------------

@test "preserve: all three steps succeed" {
  run_bash us3-adopt-preserve.json
  [ "$(cat "${TMP}/out-bash/exit")" = "$(printf '0\n0\n0')" ]
}

@test "preserve: adoption stamps identity and writes nothing else (FR-007)" {
  run_bash us3-adopt-preserve.json
  local adopt
  adopt="$(step_summary 1)"
  [ "$(jq -r '.command' <<< "${adopt}")" = "adopt" ]
  [ "$(jq -r '[.actions[] | select(.url | endswith("/properties/spec-kit-jira") | not)] | length' <<< "${adopt}")" -eq 0 ]
  [ "$(jq -r '.actions | length' <<< "${adopt}")" -eq 7 ]
}

@test "preserve: the first reconcile ADDS the panel below the human prose (SC-002)" {
  run_bash us3-adopt-preserve.json
  local first desc
  first="$(step_summary 2)"
  desc="$(jq -c '.actions[0].body.fields.description' <<< "${first}")"
  # The human paragraph is still the FIRST node, byte-for-byte …
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "${HUMAN}" ]
  # … and the managed marker comes after it, never before.
  local human_at marker_at
  human_at="$(jq -r --arg t "${HUMAN}" '[.content[] | ([.. | .text? // empty] | join(""))] | index($t)' <<< "${desc}")"
  marker_at="$(jq -r '[.content[] | ([.. | .text? // empty] | join(""))] | map(select(test("do not edit below"))) | length' <<< "${desc}")"
  [ "${human_at}" -eq 0 ]
  [ "${marker_at}" -eq 1 ]
}

@test "preserve: the first reconcile reports each adopted ticket and what it added (FR-018)" {
  run_bash us3-adopt-preserve.json
  local first
  first="$(step_summary 2)"
  [ "$(jq -r '.adopted | length' <<< "${first}")" -eq 2 ]
  [[ "$(jq -r '.adopted[0].action' <<< "${first}")" == *"added below the existing description"* ]]
  [[ "$(jq -r '.adopted[0].action' <<< "${first}")" == *"nothing outside it was touched"* ]]
}

@test "preserve: zero creations, deletions and transitions on adopted tickets (SC-006)" {
  run_bash us3-adopt-preserve.json
  [ "$(grep -c '^POST /rest/api/3/issue$' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(grep -c '^DELETE ' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(grep -c 'transitions' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "preserve: the SECOND reconcile writes nothing at all (SC-006)" {
  run_bash us3-adopt-preserve.json
  local second
  second="$(step_summary 3)"
  [ "$(jq -r '.actions | length' <<< "${second}")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "${second}")" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "${second}")" -eq 0 ]
  # Across the whole sequence: 7 identity stamps + 2 content updates, no more.
  [ "$(grep -cE '^(PUT|POST|DELETE) ' "${TMP}/out-bash/calls.log")" -eq 9 ]
}

@test "preserve: the human's bytes never enter the second run's payload at all" {
  run_bash us3-adopt-preserve.json
  local second
  second="$(step_summary 3)"
  [[ "$(jq -c '.actions' <<< "${second}")" != *"PO handwritten"* ]]
}

@test "preserve is byte-identical across ports (NFR-1, SC-008)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-adopt-preserve.json
  parity
}

# --- adopt -> adopt (T113) ---------------------------------------------------

@test "re-run: the second adoption performs ZERO writes and exits 0 (FR-019, SC-004)" {
  run_bash us3-adopt-rerun-zero-write.json
  [ "$(cat "${TMP}/out-bash/exit")" = "$(printf '0\n0')" ]
  local second
  second="$(step_summary 2)"
  [ "$(jq -r '.actions | length' <<< "${second}")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "${second}")" -eq 0 ]
  # Exactly one stamp per ticket across BOTH runs.
  [ "$(grep -cE '^(PUT|POST|DELETE) ' "${TMP}/out-bash/calls.log")" -eq 7 ]
}

@test "re-run: every ticket is reported already-adopted and counted as skipped (FR-027)" {
  run_bash us3-adopt-rerun-zero-write.json
  local second
  second="$(step_summary 2)"
  [ "$(jq -r '.counts.skipped' <<< "${second}")" -eq 7 ]
  [ "$(jq -r '[.adoption.bindings[] | select(.status == "already-adopted")] | length' <<< "${second}")" -eq 7 ]
  # Skipped is not an error.
  [ "$(jq -r '.counts.errors' <<< "${second}")" -eq 0 ]
}

@test "re-run: the second run still READS the corpus — it is idempotent, not inert" {
  run_bash us3-adopt-rerun-zero-write.json
  # Two searches (one per run) and two rounds of claim reads.
  [ "$(grep -c '^GET /rest/api/3/search/jql' "${TMP}/out-bash/calls.log")" -eq 2 ]
  [ "$(grep -c '^GET /rest/api/3/issue/.*/properties/spec-kit-jira' "${TMP}/out-bash/calls.log")" -eq 14 ]
}

@test "re-run is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-adopt-rerun-zero-write.json
  parity
}
