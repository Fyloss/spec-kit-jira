#!/usr/bin/env bats
# T047 [032] — the ceremony's destination record (contracts/origin-pinning.md
# §C3). The PowerShell twin is tests/powershell/commands/Config.BoundSite.Tests.ps1.
#
# The load-bearing case here is C3.7: the refusal a redirected run prints tells
# the operator to run this ceremony. If running it were enough to re-record the
# new destination, that instruction would BE the bypass — an attacker changes
# `base_url`, the operator follows the printed advice, and the redirection is
# accepted in silence. Accepting has to mean naming it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/url_origin.sh"
}

# The ceremony's record decision, in isolation from discovery and the network.
# Mirrors the block at commands/config.sh's write site.
_decide() { # <prior-record> <origin-reached> <--accept-site value>
  local prior="$1" reached="$2" accept="$3" accepted=""
  if [[ -n "${prior}" && "${prior}" != "${reached}" ]]; then
    [[ -z "${accept}" ]] && { printf 'refuse-unaccepted'; return 0; }
    accepted="$(url_origin_canonical "${accept}" 2> /dev/null)" || accepted=""
    [[ "${accepted}" != "${reached}" ]] && { printf 'refuse-names-other'; return 0; }
  fi
  printf 'record'
}

@test "C3.2 — a first bind records the origin the ceremony reached" {
  run _decide "" "https://a.example.invalid" ""
  [ "${output}" = "record" ]
}

@test "C3.6 — an unchanged re-run records the same origin, no churn" {
  run _decide "https://a.example.invalid" "https://a.example.invalid" ""
  [ "${output}" = "record" ]
}

@test "C3.7 — replaying the refusal's instruction records NOTHING (SC-008)" {
  # The whole feature turns on this row. If it ever returns `record`, the
  # control is a speed bump: the attacker's own refusal message becomes the
  # instructions for accepting the attack.
  run _decide "https://a.example.invalid" "https://b.example.invalid" ""
  [ "${output}" = "refuse-unaccepted" ]
}

@test "C3.8 — --accept-site naming a different origin is not an override" {
  # Naming SOME origin is not the point; naming the one actually reached is.
  # Otherwise a pasted invocation from anywhere would unlock any destination.
  run _decide "https://a.example.invalid" "https://b.example.invalid" "https://c.example.invalid"
  [ "${output}" = "refuse-names-other" ]
}

@test "C3.8 — --accept-site naming the reached origin accepts the change" {
  run _decide "https://a.example.invalid" "https://b.example.invalid" "https://b.example.invalid"
  [ "${output}" = "record" ]
}

@test "C3.8 — the accepted value is compared as an origin, not as bytes" {
  # An operator who types a default port, a trailing slash or a capital letter
  # has still named the right destination.
  run _decide "https://a.example.invalid" "https://b.example.invalid" "https://B.Example.INVALID:443/"
  [ "${output}" = "record" ]
}

@test "C3.4 — a ceremony that reached nothing records nothing" {
  # Degraded mode returns before the write site; this pins the invariant that
  # an empty reached-origin can never produce a record.
  run bash -c "source '${ROOT}/scripts/bash/lib/url_origin.sh'; url_origin_canonical '' 2>/dev/null"
  [ "${status}" -ne 0 ]
  [ "${output}" = "" ]
}

@test "SC-003 — binding adds no question and no step for the operator" {
  # The adoption criterion. The ceremony already contacts Jira to resolve ids,
  # so the origin it reached is free: recording it must not introduce a prompt,
  # a flag the operator has to supply, or a second invocation.
  #
  # Proven at the surface that matters — the flag parser. --accept-site is
  # OPTIONAL, and a ceremony invoked without it parses cleanly; if the record
  # had been made to depend on an operator-supplied value, this would fail.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/cli.sh"
  run cli_parse config --json
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"exit=0"* ]]
  [[ "${output}" == *"accept_site="* ]]
  [[ "${output}" != *"accept_site=http"* ]]
}

@test "SC-003 — the record is the origin already resolved, not a new input" {
  # There is no second source to consult: the value written is exactly the
  # canonical form of the destination the run had already resolved.
  run url_origin_canonical "https://Team.Example.INVALID:443/rest"
  [ "${status}" -eq 0 ]
  [ "${output}" = "https://team.example.invalid" ]
}
