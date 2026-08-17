#!/usr/bin/env bats
# Guard for the pwsh mock's readiness budget.
#
# The reported defect: `mock_start … powershell` gave a pwsh cold start
# exactly 10s to bind its socket and write the ready file. A contended CI
# runner routinely exceeds that — 009's research measured the cold start at
# 0.5–1.0s locally, and the runner is an order of magnitude slower — so the
# harness reddened whichever unrelated test happened to call `mock_start`
# next. It surfaced on PR #41 as `test_config_child_type.bats: not ok 5 the
# PowerShell port resolves the child type identically (NFR-1)`, which reads
# like a port divergence even though the assertion never ran: `mock_start`
# had already returned 1.
#
# The budget bounds only a *live* child — both ports detect an exited mock
# separately and immediately (`kill -0` here, `HasExited` there) — so a
# generous ceiling costs a genuine failure nothing. Two things must not
# drift: the ports holding DIFFERENT budgets, which would be a Constitution
# VI divergence in the harness itself, and the failure message going stale
# against the value it reports.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_SH="${ROOT}/tests/conformance/mock-jira/lib.sh"
  MOCK_PSM1="${ROOT}/tests/conformance/mock-jira/Mock.psm1"
}

# Both ports declare the budget as a named constant precisely so this guard
# can read it without parsing a loop bound.
bash_budget() {
  awk -F= '/^_MOCK_READY_TIMEOUT_S=/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "${LIB_SH}"
}

pwsh_budget() {
  awk '/\$mockReadyTimeoutSeconds[[:space:]]*=/ { gsub(/[^0-9]/, "", $0); print; exit }' "${MOCK_PSM1}"
}

@test "the bash port declares the readiness budget as a named constant" {
  [ -n "$(bash_budget)" ]
}

@test "the PowerShell port declares the readiness budget as a named constant" {
  [ -n "$(pwsh_budget)" ]
}

@test "both ports hold the same readiness budget (NFR-1, Constitution VI)" {
  local b p
  b="$(bash_budget)"
  p="$(pwsh_budget)"
  [ -n "${b}" ]
  [ -n "${p}" ]
  [ "${b}" = "${p}" ]
}

@test "the budget clears the 10s cold start that flaked on a CI runner" {
  local b
  b="$(bash_budget)"
  [ -n "${b}" ]
  [ "${b}" -ge 30 ]
}

@test "neither port reports a budget it no longer enforces" {
  # The literal "10s" in the message outlived the value twice over only
  # because it was spelled out by hand; both messages now interpolate the
  # constant, so a future bump cannot leave the operator a lie to debug.
  #
  # `run` rather than `! grep`: bash exempts a `!`-inverted command from
  # errexit, so the bare negation silently guards nothing under bats.
  run grep -qF 'within 10s' "${LIB_SH}"
  [ "${status}" -ne 0 ]
  grep -qF 'within ${_MOCK_READY_TIMEOUT_S}s' "${LIB_SH}"
  grep -qF 'within ${mockReadyTimeoutSeconds}s' "${MOCK_PSM1}"
}
