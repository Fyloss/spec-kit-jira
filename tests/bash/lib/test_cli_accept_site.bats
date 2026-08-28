#!/usr/bin/env bats
# T027 [032] — the --accept-site flag (contracts/origin-pinning.md §C3.8).
# The PowerShell twin is tests/powershell/lib/Cli.AcceptSite.Tests.ps1; the two
# emit the same key at the same index, which is what keeps the streams
# byte-identical (lib/Cli.psm1's header states that order is normative).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/cli.sh"
}

@test "C3.8 — a well-formed origin is carried through verbatim" {
  run cli_parse config --accept-site https://jira.example.invalid
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"accept_site=https://jira.example.invalid"* ]]
  [[ "${output}" == *"exit=0"* ]]
}

@test "C3.8 — the value is NOT canonicalised by the parser" {
  # The ceremony compares it against the origin it actually reached, and that
  # comparison is origin-aware. Folding here would hide from the operator the
  # exact bytes they typed, which is the one thing this flag exists to surface.
  run cli_parse config --accept-site https://JIRA.Example.INVALID:443
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"accept_site=https://JIRA.Example.INVALID:443"* ]]
}

@test "C3.8 — a value that is not an origin is refused" {
  run cli_parse config --accept-site prod
  [[ "${output}" == *"exit=1"* ]]
  [[ "${output}" == *"--accept-site requires an absolute origin"* ]]
}

@test "C3.8 — a bare hostname is refused (no scheme)" {
  run cli_parse config --accept-site jira.example.invalid
  [[ "${output}" == *"exit=1"* ]]
}

@test "C3.8 — a missing value is refused with the flag's own message" {
  run cli_parse config --accept-site
  [[ "${output}" == *"exit=1"* ]]
  [[ "${output}" == *"--accept-site requires a value (--accept-site <origin>)"* ]]
}

@test "C3.8 — absent means empty, never a default" {
  # A default would accept a changed destination on the operator's behalf,
  # which is precisely the bypass FR-010 forbids.
  run cli_parse config
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"accept_site="* ]]
  [[ "${output}" != *"accept_site=http"* ]]
}

@test "C3.8 — the key is emitted for every command, in the fixed order" {
  # The shared parser emits every key for every command; four of the five
  # commands ignore this one, as they already ignore flags aimed elsewhere.
  local cmd
  for cmd in config reconcile mention feature seed; do
    run cli_parse "${cmd}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"accept_site="* ]]
  done
}

@test "C3.8 — accept_site is emitted between accept_defaults and args" {
  # The emission order is normative for cross-port byte equality. A key
  # inserted at a different index in one port is a silent divergence.
  run cli_parse config
  local keys
  keys="$(printf '%s\n' "${output}" | sed -n 's/^\([a-z_]*\)=.*/\1/p' | tr '\n' ' ')"
  [[ "${keys}" == *"accept_defaults accept_site args"* ]]
}
