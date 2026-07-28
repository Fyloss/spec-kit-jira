#!/usr/bin/env bats
# T052 [US1] — Adoption conformance (003 FR-001…FR-007, FR-028, NFR-1, SC-008).
#
# Drives the seven US1 scenarios through the real dispatchers on BOTH ports and
# diffs the captures. For identical inputs the two ports must produce identical
# stdout, stderr, exit codes, Jira call sequences and post-run trees; a
# divergence is a failing test, not a documented quirk.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
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
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stderr" "${TMP}/out-ps/stderr"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/calls.log" "${TMP}/out-ps/calls.log"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

# Count call-log lines matching a pattern.
calls() {
  grep -c "$1" "${TMP}/out-bash/calls.log" || true
}

# --- Scenario 1: the labelled hierarchy (T045) -------------------------------

@test "hierarchy: one identity stamp per adopted ticket, exit 0 (SC-001)" {
  run_bash us1-adopt-hierarchy.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.adoption.bindings | length' "${TMP}/out-bash/stdout")" -eq 7 ]
  [ "$(jq -r '.adoption.refusals | length' "${TMP}/out-bash/stdout")" -eq 0 ]
  [ "$(jq -r '.counts.updated' "${TMP}/out-bash/stdout")" -eq 7 ]
  [ "$(calls '^PUT /rest/api/3/issue/.*/properties/spec-kit-jira$')" -eq 7 ]
}

@test "hierarchy: adoption emits NO other write kind (FR-007)" {
  run_bash us1-adopt-hierarchy.json
  # Every write in the call log is an identity property PUT — no create, no
  # delete, no transition, no comment, no link, no relabel, no content update.
  [ "$(grep -cE '^(POST|DELETE) ' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(grep -cE '^PUT ' "${TMP}/out-bash/calls.log" || true)" -eq 7 ]
  [ "$(grep -cE '^PUT /rest/api/3/issue/[^/]+$' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(grep -cE 'transitions|/comment|issueLink|/remotelink' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
}

@test "hierarchy: every stamp carries origin human (FR-016)" {
  run_bash us1-adopt-hierarchy.json
  [ "$(jq -r '[.actions[] | select(.body.origin != "human")] | length' "${TMP}/out-bash/stdout")" -eq 0 ]
  [ "$(jq -r '[.actions[] | select(.method != "PUT")] | length' "${TMP}/out-bash/stdout")" -eq 0 ]
}

@test "hierarchy: discovery is ONE search for the one routed project (FR-004)" {
  run_bash us1-adopt-hierarchy.json
  [ "$(calls '^GET /rest/api/3/search/jql')" -eq 1 ]
}

@test "hierarchy is byte-identical across ports (NFR-1, SC-008)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-hierarchy.json
  parity
}

# --- Scenario 2: adoption disabled (T046) ------------------------------------

@test "disabled: exit 4, zero candidate reads, zero writes (SC-009)" {
  run_bash us1-adopt-disabled.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  # The gate fires before ANY Jira interaction: the call log is empty.
  [ ! -s "${TMP}/out-bash/calls.log" ]
  [ "$(jq -r '.adoption.enabled' "${TMP}/out-bash/stdout")" = "false" ]
  [ "$(jq -r '.actions | length' "${TMP}/out-bash/stdout")" -eq 0 ]
}

@test "disabled: the message names the configuration key that enables it (FR-001)" {
  run_bash us1-adopt-disabled.json
  grep -q 'adoption.enabled' "${TMP}/out-bash/stderr"
}

@test "disabled is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-disabled.json
  parity
}

# --- Scenario 3: the operator declines (T047) --------------------------------

@test "decline: exit 0, zero writes, the summary reports cancellation (US1 AS-3)" {
  run_bash us1-adopt-decline.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(calls '^PUT ')" -eq 0 ]
  grep -q 'Adoption cancelled' "${TMP}/out-bash/stdout"
}

@test "decline: the plan is still printed in full before the decision" {
  run_bash us1-adopt-decline.json
  grep -q 'Adoption plan' "${TMP}/out-bash/stdout"
  grep -q 'ADO-1' "${TMP}/out-bash/stdout"
}

@test "decline is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-decline.json
  parity
}

# --- Scenario 4: an unnamed label is never guessed at (T048) -----------------

@test "unnamed label: the bare prefix and an absent folder are never adopted (FR-003)" {
  run_bash us1-adopt-unnamed-label.json
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  # The decoys are never stamped and never even read — they are not in the query.
  [ "$(grep -c 'ADO-90' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(grep -c 'ADO-91' "${TMP}/out-bash/calls.log" || true)" -eq 0 ]
  [ "$(jq -r '[.adoption.bindings[] | select(.issue_key == "ADO-90" or .issue_key == "ADO-91")] | length' "${TMP}/out-bash/stdout")" -eq 0 ]
  [ "$(calls '^PUT ')" -eq 7 ]
}

@test "unnamed label is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-unnamed-label.json
  parity
}

# --- Scenario 5: the privacy guard is not exempt (T049) ----------------------

@test "privacy block: exit 9 with ZERO property PUTs in the call log (FR-028)" {
  run_bash us1-adopt-privacy-block.json
  [ "$(cat "${TMP}/out-bash/exit")" = "9" ]
  [ "$(calls '^PUT ')" -eq 0 ]
  grep -q 'BLOCK' "${TMP}/out-bash/stderr"
}

@test "privacy block: the offending value is never echoed (NFR-3)" {
  run_bash us1-adopt-privacy-block.json
  # `grep -c` over several files prints one count PER FILE, so concatenate first.
  [ "$(cat "${TMP}/out-bash/stderr" "${TMP}/out-bash/stdout" | grep -c 'RAWSECRETXYZ' || true)" -eq 0 ]
}

@test "privacy block is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-privacy-block.json
  parity
}

# --- Scenario 6: no project-style branch (T050) ------------------------------

@test "team-managed: binds and stamps identically to company-managed (NFR-5)" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-adopt-team-managed.json" bash "${TMP}/team" > /dev/null
  bash "${HARNESS}" "${CONF}/scenarios/us1-adopt-hierarchy.json" bash "${TMP}/company" > /dev/null
  run diff "${TMP}/team/stdout" "${TMP}/company/stdout"
  [ "$status" -eq 0 ]
  run diff "${TMP}/team/calls.log" "${TMP}/company/calls.log"
  [ "$status" -eq 0 ]
  run diff "${TMP}/team/exit" "${TMP}/company/exit"
  [ "$status" -eq 0 ]
}

@test "team-managed is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-team-managed.json
  parity
}

# --- Scenario 7: an invalid label prefix (T051) ------------------------------

@test "invalid prefix: located configuration error, exit 4, nothing searched (FR-002)" {
  run_bash us1-adopt-invalid-prefix.json
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  [ ! -s "${TMP}/out-bash/calls.log" ]
  grep -q 'label_prefix' "${TMP}/out-bash/stderr"
  grep -q 'whitespace' "${TMP}/out-bash/stderr"
  grep -q 'config.yml' "${TMP}/out-bash/stderr"
}

@test "invalid prefix is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-adopt-invalid-prefix.json
  parity
}
