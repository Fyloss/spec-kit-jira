#!/usr/bin/env bats
# T140 [US5] — The adoption run summary (003 FR-024, NFR-4, adoption-plan.schema.json).
#
# Every run emits a structured summary listing applied bindings WITH THEIR REASON
# and refused bindings WITH THEIR REMEDIATION. Prose is the default (Principle
# XVI); `--json` is the opt-in machine form, and it must satisfy the 001
# run-summary schema plus the 003 adoption delta — a CLOSED object, so a stray
# key is a failure rather than a harmless extra.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  ENTRY="${ROOT}/scripts/bash/spec-kit-jira.sh"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  RUN_SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  ADOPT_SCHEMA="${ROOT}/specs/003-label-based-adoption/contracts/adoption-plan.schema.json"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  WORK="$(mktemp -d)"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-adoption/." "${WORK}/"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  # Bindings AND refusals in one run, so both halves of the summary are populated.
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

# --- the run-summary core (NFR-4) --------------------------------------------

@test "the summary carries the run-summary core keys with command adopt" {
  start
  run adopt --yes --json
  [ "$(jq -r '.schema_version' <<< "$output")" = "1.0" ]
  [ "$(jq -r '.command' <<< "$output")" = "adopt" ]
  [ "$(jq -r '.counts | keys | join(",")' <<< "$output")" = "created,errors,skipped,updated,warnings" ]
  [ "$(jq -r 'has("exit_code")' <<< "$output")" = "true" ]
}

@test "the 001 schema accepts adopt as a command (003 delta)" {
  jq -e '.properties.command.enum | index("adopt") != null' "${RUN_SCHEMA}" > /dev/null
}

@test "counts report adopted, skipped and refused (FR-024)" {
  start
  run adopt --yes --json
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq "$(jq -r '[.adoption.bindings[] | select(.status=="adopt")] | length' <<< "$output")" ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq "$(jq -r '[.adoption.bindings[] | select(.status=="already-adopted")] | length' <<< "$output")" ]
  [ "$(jq -r '.counts.errors' <<< "$output")" -eq "$(jq -r '.adoption.refusals | length' <<< "$output")" ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
}

# --- the adoption block (adoption-plan.schema.json) --------------------------

@test "the adoption block carries exactly the six required keys and no others" {
  start
  run adopt --yes --json
  local required
  required="$(jq -r '.required | sort | join(",")' "${ADOPT_SCHEMA}")"
  [ "$(jq -r '.adoption | keys | join(",")' <<< "$output")" = "${required}" ]
  # The schema is closed, so the emitted key set must equal the declared one.
  [ "$(jq -r '.properties | keys | sort | join(",")' "${ADOPT_SCHEMA}")" = "${required}" ]
  [ "$(jq -r '.additionalProperties' "${ADOPT_SCHEMA}")" = "false" ]
}

@test "each applied binding carries its REASON (FR-024)" {
  start
  run adopt --yes --json
  [ "$(jq -r '[.adoption.bindings[] | select(.reason == null)] | length' <<< "$output")" -eq 0 ]
  local allowed
  allowed="$(jq -r '.properties.bindings.items.properties.reason.enum | join(",")' "${ADOPT_SCHEMA}")"
  [ "$allowed" = "label-match,explicit-binding" ]
  [ "$(jq -r '[.adoption.bindings[] | select(.reason != "label-match" and .reason != "explicit-binding")] | length' <<< "$output")" -eq 0 ]
}

@test "each binding matches the schema's key set exactly" {
  start
  run adopt --yes --json
  local declared
  declared="$(jq -r '.properties.bindings.items.properties | keys | sort | join(",")' "${ADOPT_SCHEMA}")"
  [ "$(jq -r '[.adoption.bindings[] | keys | join(",")] | unique | join("|")' <<< "$output")" = "${declared}" ]
}

@test "each refusal carries its REMEDIATION and a closed reason (FR-024, SC-005)" {
  start
  run adopt --yes --json
  [ "$(jq -r '.adoption.refusals | length' <<< "$output")" -gt 0 ]
  [ "$(jq -r '[.adoption.refusals[] | select((.remediation // "") == "")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.adoption.refusals[] | select((.message // "") == "")] | length' <<< "$output")" -eq 0 ]
  # Every emitted reason is a member of the closed enumeration.
  local closed
  closed="$(jq -c '.properties.refusals.items.properties.reason.enum' "${ADOPT_SCHEMA}")"
  [ "$(jq -r --argjson e "${closed}" '[.adoption.refusals[] | select((. .reason) as $r | ($e | index($r)) == null)] | length' <<< "$output")" -eq 0 ]
}

@test "each refusal matches the schema's key set" {
  start
  run adopt --yes --json
  local declared
  declared="$(jq -r '.properties.refusals.items.properties | keys | sort | join(",")' "${ADOPT_SCHEMA}")"
  [ "$(jq -r '[.adoption.refusals[] | keys | join(",")] | unique | join("|")' <<< "$output")" = "${declared}" ]
}

@test "enabled, label_prefix and confirmed report the effective configuration" {
  start
  run adopt --yes --json
  [ "$(jq -r '.adoption.enabled' <<< "$output")" = "true" ]
  [ "$(jq -r '.adoption.label_prefix' <<< "$output")" = "speckit-adopt:" ]
  [ "$(jq -r '.adoption.confirmed' <<< "$output")" = "true" ]
}

@test "the summary validates against both schemas (oracle, if available)" {
  start
  local summary
  # The mixed corpus exits 4 by design (a refusal occurred), so the substitution
  # must tolerate it rather than let errexit abort the test.
  summary="$(adopt --yes --json || true)"
  if ! command -v jsonschema > /dev/null 2>&1; then skip "jsonschema CLI not available"; fi
  printf '%s' "${summary}" | jsonschema --instance /dev/stdin "${RUN_SCHEMA}"
  printf '%s' "${summary}" | jq -c '.adoption' | jsonschema --instance /dev/stdin "${ADOPT_SCHEMA}"
}

# --- prose is the default (Principle XVI) ------------------------------------

@test "the default output is prose, not JSON" {
  start
  run adopt --dry-run
  [[ "$output" == "Adoption plan"* ]]
  run jq -e . <<< "$output"
  [ "$status" -ne 0 ]
}

@test "the prose lists adopted, skipped and refused counts" {
  start
  run adopt --yes
  [[ "$output" == *"Command: adopt"* ]]
  [[ "$output" == *"Updated: 3"* ]]
  [[ "$output" == *"Errors: "* ]]
  [[ "$output" == *"Exit: 4"* ]]
}

@test "the prose renders every refusal's remediation on its own line" {
  start
  run adopt --dry-run
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"      remediation: "* ]]
  # One remediation line per refusal.
  local refusals
  refusals="$( (adopt --dry-run --json || true) | jq -r '.adoption.refusals | length')"
  [ "$(grep -c '^      remediation: ' <<< "$output")" -eq "${refusals}" ]
}

@test "the summary is deterministic — the same state emits the same bytes" {
  start
  local a b
  a="$(adopt --dry-run --json || true)"
  b="$(adopt --dry-run --json || true)"
  [ "$a" = "$b" ]
}
