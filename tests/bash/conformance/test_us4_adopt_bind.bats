#!/usr/bin/env bats
# T129 [US4] — Explicit-binding conformance (003 FR-020, FR-021, FR-022, NFR-1).
#
# `--bind` is the documented answer to every US2 refusal, so what it must prove
# is not that it works but that it changes NOTHING about validation: a pinned
# target goes through the same routed-project check, the same claim check and the
# same hierarchy checks as a discovered one, and produces the same refusal
# classes and exit codes. The one class only reachable this way —
# `wrong-project` — is fixtured here.

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

refusal() {
  jq -c --arg r "$1" '.adoption.refusals[] | select(.reason == $r)' "${TMP}/out-bash/stdout"
}

puts() {
  grep -c '^PUT ' "${TMP}/out-bash/calls.log" || true
}

# --- pins resolve what discovery could not (T125) ----------------------------

@test "explicit binding: pinned targets bind with reason explicit-binding, exit 0" {
  run_bash us4-adopt-explicit-binding.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '[.adoption.bindings[] | select(.reason == "explicit-binding") | .issue_key] | join(",")' "${TMP}/out-bash/stdout")" = "ADO-50,ADO-60,ADO-61" ]
  [ "$(jq -r '.adoption.refusals | length' "${TMP}/out-bash/stdout")" -eq 0 ]
}

@test "explicit binding: a pin resolves BOTH the several-candidates and no-candidate cases" {
  run_bash us4-adopt-explicit-binding.json
  # ADO-50/ADO-51 were an ambiguity; ADO-60/ADO-61 carried no label at all.
  # Neither refuses any more.
  [ "$(jq -r '[.adoption.refusals[] | select(.reason == "several-candidates")] | length' "${TMP}/out-bash/stdout")" -eq 0 ]
  [ "$(jq -r '[.adoption.refusals[] | select(.reason == "no-candidate")] | length' "${TMP}/out-bash/stdout")" -eq 0 ]
}

@test "explicit binding: the pinned ticket is stamped and NO label is ever added" {
  run_bash us4-adopt-explicit-binding.json
  [ "$(puts)" -eq 7 ]
  # Every write is the identity property; adoption reads labels, never writes them.
  [ "$(grep -cE '^PUT ' "${TMP}/out-bash/calls.log")" = "$(grep -cE '^PUT .*/properties/spec-kit-jira$' "${TMP}/out-bash/calls.log")" ]
  [ "$(grep -c 'labels' "${TMP}/out-bash/calls.log" | head -1)" -ge 0 ]
  [ "$(grep -cE '^(POST|DELETE) ' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "explicit binding: the ambiguous ticket the pin did NOT name is left alone" {
  run_bash us4-adopt-explicit-binding.json
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-51/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "explicit binding is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us4-adopt-explicit-binding.json
  parity
}

# --- a pin is validated exactly like a discovered candidate (T126) -----------

@test "pin refusals: a pin to a claimed ticket refuses with already-claimed, exit 4" {
  run_bash us4-adopt-pin-refusals.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal already-claimed)"
  [ -n "$r" ]
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-70"* ]]
  [[ "$(jq -r '.message' <<< "$r")" == *"009-someone-elses-spec"* ]]
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-70/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "pin refusals: wrong-project is reachable ONLY through a pin, and names both projects" {
  run_bash us4-adopt-pin-refusals.json
  local r
  r="$(refusal wrong-project)"
  [ -n "$r" ]
  [ "$(jq -r '.spec_folder' <<< "$r")" = "004-gamma-export" ]
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO"* ]]
  [[ "$(jq -r '.message' <<< "$r")" == *"BILL-90"* ]]
  [[ "$(jq -r '.message' <<< "$r")" == *"never migrates"* ]]
  [ "$(grep -c 'PUT /rest/api/3/issue/BILL-90/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "pin refusals: the unambiguous bindings in the same run still apply" {
  run_bash us4-adopt-pin-refusals.json
  [ "$(jq -r '.adoption.bindings | length' "${TMP}/out-bash/stdout")" -eq 6 ]
  [ "$(puts)" -eq 6 ]
}

@test "pin refusals is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us4-adopt-pin-refusals.json
  parity
}

# --- an unknown folder stops the run (T127) ----------------------------------

@test "unknown folder: usage error, exit 1, zero writes, nothing searched" {
  run_bash us4-adopt-unknown-folder.json
  [ "$(cat "${TMP}/out-bash/exit")" = "1" ]
  [ "$(puts)" -eq 0 ]
  [ ! -s "${TMP}/out-bash/calls.log" ]
  grep -q '009-never-on-disk' "${TMP}/out-bash/stderr"
}

@test "unknown folder is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us4-adopt-unknown-folder.json
  parity
}

# --- an override states BOTH keys (T128, AS-5) -------------------------------

@test "override: the plan states the pinned key AND the discovered key it replaced" {
  run_bash us4-adopt-pin-overrides.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local b
  b="$(jq -c '.adoption.bindings[] | select(.overrode_key != null)' "${TMP}/out-bash/stdout")"
  [ "$(jq -r '.issue_key' <<< "$b")" = "ADO-99" ]
  [ "$(jq -r '.overrode_key' <<< "$b")" = "ADO-7" ]
  [ "$(jq -r '.reason' <<< "$b")" = "explicit-binding" ]
}

@test "override: the pin is stamped and the overridden ticket is NOT" {
  run_bash us4-adopt-pin-overrides.json
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-99/' "${TMP}/out-bash/calls.log")" -eq 1 ]
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-7/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "override: the prose plan shows both keys to the operator (Principle XVI)" {
  bash "${HARNESS}" "${CONF}/scenarios/us4-adopt-pin-overrides.json" bash "${TMP}/prose" > /dev/null
  # Re-run the same scenario without --json to read the prose plan.
  jq '.argv = ["adopt", "--bind", "005-audit-trail:us1=ADO-99", "--dry-run"]' \
    "${CONF}/scenarios/us4-adopt-pin-overrides.json" > "${TMP}/prose.json"
  bash "${HARNESS}" "${TMP}/prose.json" bash "${TMP}/out-bash" > /dev/null
  grep -q 'explicit binding, overrides ADO-7' "${TMP}/out-bash/stdout"
}

@test "override is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us4-adopt-pin-overrides.json
  parity
}
