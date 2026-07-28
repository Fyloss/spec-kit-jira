#!/usr/bin/env bats
# T146 [US5] — Dry-run and audit-trail conformance (003 FR-023, FR-024, FR-025,
# SC-003, SC-008, NFR-1, NFR-3).
#
# Two things are proven end to end here: that the dry-run twin reports EXACTLY
# what the real run performs, and that the structured summary an operator or a
# script consumes is complete, closed, and free of any credential or site host —
# byte-identically on both ports.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  RUN_SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  ADOPT_SCHEMA="${ROOT}/specs/003-label-based-adoption/contracts/adoption-plan.schema.json"
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

step() {
  sed -n "$1p" "${TMP}/out-bash/stdout"
}

# --- the dry-run twin (T144, FR-023, SC-003) ---------------------------------

@test "dry run: the reported action set equals the real run's exactly" {
  run_bash us5-adopt-dry-run.json
  [ "$(cat "${TMP}/out-bash/exit")" = "$(printf '0\n0')" ]
  [ "$(jq -c '.actions' <<< "$(step 1)")" = "$(jq -c '.actions' <<< "$(step 2)")" ]
  [ "$(jq -r '.actions | length' <<< "$(step 1)")" -eq 7 ]
}

@test "dry run: the whole plan is identical apart from the confirmation flag" {
  run_bash us5-adopt-dry-run.json
  [ "$(jq -c '.adoption | del(.confirmed)' <<< "$(step 1)")" = "$(jq -c '.adoption | del(.confirmed)' <<< "$(step 2)")" ]
  [ "$(jq -r '.adoption.confirmed' <<< "$(step 1)")" = "false" ]
  [ "$(jq -r '.adoption.confirmed' <<< "$(step 2)")" = "true" ]
}

@test "dry run: the counts it reports are the ones the real run performs" {
  run_bash us5-adopt-dry-run.json
  [ "$(jq -c '.counts' <<< "$(step 1)")" = "$(jq -c '.counts' <<< "$(step 2)")" ]
}

@test "dry run: exactly the predicted writes happen, and only in the second step" {
  run_bash us5-adopt-dry-run.json
  # Seven stamps in total across both steps — so the dry run performed none.
  [ "$(grep -cE '^(PUT|POST|DELETE) ' "${TMP}/out-bash/calls.log")" -eq 7 ]
  # Both steps searched and read: the dry run is a real discovery, not a stub.
  [ "$(grep -c '^GET /rest/api/3/search/jql' "${TMP}/out-bash/calls.log")" -eq 2 ]
}

@test "dry run: every action carries a host-relative url (Constitution IV)" {
  run_bash us5-adopt-dry-run.json
  [ "$(jq -r '[.actions[] | select(.url | startswith("/rest/api/3/") | not)] | length' <<< "$(step 1)")" -eq 0 ]
}

@test "dry run is byte-identical across ports (SC-008)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us5-adopt-dry-run.json
  parity
}

# --- the structured summary (T145, FR-024) -----------------------------------

@test "summary: applied bindings carry their reason, refusals their remediation" {
  run_bash us5-adopt-json-summary.json
  local s
  s="$(cat "${TMP}/out-bash/stdout")"
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  [ "$(jq -r '.adoption.bindings | length' <<< "$s")" -gt 0 ]
  [ "$(jq -r '.adoption.refusals | length' <<< "$s")" -gt 0 ]
  [ "$(jq -r '[.adoption.bindings[] | select((.reason // "") == "")] | length' <<< "$s")" -eq 0 ]
  [ "$(jq -r '[.adoption.refusals[] | select((.remediation // "") == "")] | length' <<< "$s")" -eq 0 ]
  [ "$(jq -r '[.adoption.refusals[] | select((.message // "") == "")] | length' <<< "$s")" -eq 0 ]
}

@test "summary: both refusal classes in the corpus are reported by name" {
  run_bash us5-adopt-json-summary.json
  local reasons
  reasons="$(jq -r '[.adoption.refusals[].reason] | sort | unique | join(",")' "${TMP}/out-bash/stdout")"
  [[ "${reasons}" == *"already-claimed"* ]]
  [[ "${reasons}" == *"several-candidates"* ]]
}

@test "summary: the adoption block is exactly the schema's closed key set" {
  run_bash us5-adopt-json-summary.json
  local required
  required="$(jq -r '.required | sort | join(",")' "${ADOPT_SCHEMA}")"
  [ "$(jq -r '.adoption | keys | join(",")' "${TMP}/out-bash/stdout")" = "${required}" ]
}

@test "summary: validates against both schemas (oracle, if available)" {
  run_bash us5-adopt-json-summary.json
  if ! command -v jsonschema > /dev/null 2>&1; then skip "jsonschema CLI not available"; fi
  jsonschema --instance "${TMP}/out-bash/stdout" "${RUN_SCHEMA}"
  jq -c '.adoption' "${TMP}/out-bash/stdout" > "${TMP}/adoption.json"
  jsonschema --instance "${TMP}/adoption.json" "${ADOPT_SCHEMA}"
}

@test "summary: no credential and no site host at --verbose (FR-025, NFR-3)" {
  run_bash us5-adopt-json-summary.json
  run bash -c "cat '${TMP}/out-bash/stdout' '${TMP}/out-bash/stderr' | grep -c -e RAWSECRETXYZ -e 127.0.0.1 -e 'user@example.com'"
  [ "$output" = "0" ]
}

@test "summary is byte-identical across ports (SC-008)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us5-adopt-json-summary.json
  parity
}
