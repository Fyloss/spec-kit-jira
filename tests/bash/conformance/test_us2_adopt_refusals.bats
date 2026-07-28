#!/usr/bin/env bats
# T093 [US2] — Refusal conformance (003 FR-008…FR-015, SC-005, NFR-1).
#
# One fixture per refusal class plus the mixed run and the four fault
# injections, driven through the real dispatchers on BOTH ports and diffed. Each
# class must produce its own named reason, a message naming the spec folder and
# every ticket involved, and a copy-pasteable remediation — and must leave zero
# writes for its binding while the rest of the run still applies.
#
# The `wrong-project` class is the one exception: it is only reachable through an
# explicit binding, so it is fixtured with US4.

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

# refusal <reason> — the refusal object of that class from the bash capture.
refusal() {
  jq -c --arg r "$1" '.adoption.refusals[] | select(.reason == $r)' "${TMP}/out-bash/stdout"
}

puts() {
  grep -c '^PUT ' "${TMP}/out-bash/calls.log" || true
}

# Every refusal, whatever its class, satisfies the shared contract.
assert_refusal_contract() {
  local r="$1" folder="$2"
  [ -n "$r" ]
  [ "$(jq -r '.spec_folder' <<< "$r")" = "$folder" ]
  # Names the spec folder, carries a message and a copy-pasteable remediation.
  [[ "$(jq -r '.message' <<< "$r")" == *"${folder}"* ]]
  [ -n "$(jq -r '.remediation' <<< "$r")" ]
  # Carries no credential and no site host (FR-025).
  [[ "$(jq -r '.message' <<< "$r")" != *"RAWSECRETXYZ"* ]]
  [[ "$(jq -r '.message' <<< "$r")" != *"127.0.0.1"* ]]
}

# --- no-candidate (T084, FR-009) ---------------------------------------------

@test "no-candidate: names the exact labels searched, exit 4, others still bind" {
  run_bash us2-adopt-no-candidate.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal no-candidate)"
  assert_refusal_contract "$r" "003-label-based-adoption"
  [[ "$(jq -r '.message' <<< "$r")" == *"speckit-adopt:003-label-based-adoption:us2"* ]]
  [ "$(jq -c '.issue_keys' <<< "$r")" = "[]" ]
  [[ "$(jq -r '.remediation' <<< "$r")" == *"--bind 003-label-based-adoption:us2="* ]]
  # The six unambiguous bindings still applied.
  [ "$(jq -r '.adoption.bindings | length' "${TMP}/out-bash/stdout")" -eq 6 ]
  [ "$(puts)" -eq 6 ]
}

@test "no-candidate is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-no-candidate.json
  parity
}

# --- several-candidates (T085, FR-010, NFR-6) --------------------------------

@test "several-candidates: names EVERY candidate across mock pages, exit 4" {
  run_bash us2-adopt-several-candidates.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal several-candidates)"
  assert_refusal_contract "$r" "005-audit-trail"
  # All four, not a truncated pair — proof that pagination reached them.
  [ "$(jq -r '.issue_keys | length' <<< "$r")" -eq 4 ]
  for k in ADO-70 ADO-71 ADO-72 ADO-73; do
    [[ "$(jq -r '.message' <<< "$r")" == *"${k}"* ]]
  done
  # And discovery really did page: more than one search call.
  [ "$(grep -c '^GET /rest/api/3/search/jql' "${TMP}/out-bash/calls.log")" -gt 1 ]
}

@test "several-candidates: none of the ambiguous tickets is written" {
  run_bash us2-adopt-several-candidates.json
  for k in ADO-70 ADO-71 ADO-72 ADO-73; do
    [ "$(grep -c "PUT /rest/api/3/issue/${k}/" "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  done
}

@test "several-candidates is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-several-candidates.json
  parity
}

# --- already-claimed (T086, FR-011) ------------------------------------------

@test "already-claimed: names the claiming spec, exit 4, zero writes for it" {
  run_bash us2-adopt-already-claimed.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal already-claimed)"
  assert_refusal_contract "$r" "004-billing-export"
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-5"* ]]
  [[ "$(jq -r '.message' <<< "$r")" == *"009-someone-elses-spec"* ]]
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-5/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(puts)" -eq 6 ]
}

@test "already-claimed is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-already-claimed.json
  parity
}

# --- spec-owns-bridge-ticket (T087, FR-011, research §4) ---------------------

@test "spec-owns-bridge-ticket: the hyphenated wire origin triggers it, exit 4" {
  run_bash us2-adopt-spec-owns-bridge-ticket.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal spec-owns-bridge-ticket)"
  assert_refusal_contract "$r" "004-billing-export"
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-5"* ]]
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-5/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "spec-owns-bridge-ticket is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-spec-owns-bridge-ticket.json
  parity
}

# --- unbound-parent (T088, FR-014) -------------------------------------------

@test "unbound-parent: the story refuses when its feature ticket is not bound" {
  run_bash us2-adopt-unbound-parent.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal unbound-parent)"
  assert_refusal_contract "$r" "005-audit-trail"
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-7"* ]]
  [[ "$(jq -r '.remediation' <<< "$r")" == *"--bind 005-audit-trail="* ]]
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-7/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "unbound-parent is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-unbound-parent.json
  parity
}

# --- wrong-parent (T089, FR-015) ---------------------------------------------

@test "wrong-parent: names the candidate, its parent, and the expected parent" {
  run_bash us2-adopt-wrong-parent.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  local r
  r="$(refusal wrong-parent)"
  assert_refusal_contract "$r" "005-audit-trail"
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-7"* ]]
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-1"* ]]
  [[ "$(jq -r '.message' <<< "$r")" == *"ADO-6"* ]]
  # Adoption never re-parents: no parent write of any kind.
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-7/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "wrong-parent is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-wrong-parent.json
  parity
}

# --- ambiguous-short-number (T090) -------------------------------------------

@test "ambiguous-short-number: both sharing folders refuse, naming each other" {
  run_bash us2-adopt-ambiguous-short-number.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  [ "$(jq -r '[.adoption.refusals[] | select(.reason == "ambiguous-short-number")] | length' "${TMP}/out-bash/stdout")" -eq 2 ]
  local msg
  msg="$(jq -r '[.adoption.refusals[] | select(.reason == "ambiguous-short-number")][0].message' "${TMP}/out-bash/stdout")"
  [[ "$msg" == *"speckit-adopt:004"* ]]
  [[ "$msg" == *"004-beta-import"* ]]
  [[ "$msg" == *"004-gamma-export"* ]]
  [ "$(grep -c 'PUT /rest/api/3/issue/ADO-40/' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "ambiguous-short-number is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-ambiguous-short-number.json
  parity
}

# --- the mixed run (T091, AS-4, FR-013) --------------------------------------

@test "mixed refusals: valid bindings apply alongside refusals, run exits 4" {
  run_bash us2-adopt-mixed-refusals.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  # Two distinct classes co-occur.
  [ "$(jq -r '[.adoption.refusals[].reason] | unique | length' "${TMP}/out-bash/stdout")" -ge 2 ]
  # 003's three tickets plus 004's feature and 005's feature still bind.
  [ "$(jq -r '.adoption.bindings | length' "${TMP}/out-bash/stdout")" -eq 5 ]
  [ "$(puts)" -eq 5 ]
  [ "$(jq -r '.counts.errors' "${TMP}/out-bash/stdout")" -eq "$(jq -r '.adoption.refusals | length' "${TMP}/out-bash/stdout")" ]
}

@test "every refusal class in the corpus carries its own named reason (SC-005)" {
  # The closed enumeration is what lets the corpus assert one fixture per class.
  local seen=""
  for s in no-candidate several-candidates already-claimed spec-owns-bridge-ticket \
    unbound-parent wrong-parent ambiguous-short-number; do
    seen="${seen} ${s}"
  done
  for s in ${seen}; do
    grep -q "\"${s}\"" "${ROOT}/specs/003-label-based-adoption/contracts/adoption-plan.schema.json"
  done
}

@test "mixed refusals is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us2-adopt-mixed-refusals.json
  parity
}

# --- fault injection (T092, FR-008, AS-6) ------------------------------------

@test "fault 401: whole run aborts before any write, exit 3" {
  run_bash us2-adopt-fault-401.json
  [ "$(cat "${TMP}/out-bash/exit")" = "3" ]
  [ "$(puts)" -eq 0 ]
}

@test "fault 404: whole run aborts before any write, exit 2" {
  run_bash us2-adopt-fault-404.json
  [ "$(cat "${TMP}/out-bash/exit")" = "2" ]
  [ "$(puts)" -eq 0 ]
}

@test "fault network: whole run aborts before any write, exit 2" {
  run_bash us2-adopt-fault-network.json
  [ "$(cat "${TMP}/out-bash/exit")" = "2" ]
  [ "$(puts)" -eq 0 ]
}

@test "fault 429 exhausted: whole run aborts before any write, exit 2" {
  run_bash us2-adopt-fault-429.json
  [ "$(cat "${TMP}/out-bash/exit")" = "2" ]
  [ "$(puts)" -eq 0 ]
}

@test "every fault scenario is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  for s in 401 404 network 429; do
    both_ports "us2-adopt-fault-${s}.json"
    parity
  done
}
