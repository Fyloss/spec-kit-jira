#!/usr/bin/env bats
# T057 [032] — the credential producer's own refusal (contracts/origin-pinning.md
# §C6, SC-005). The PowerShell twin is
# tests/powershell/lib/Credentials.PinnedOrigin.Tests.ps1.
#
# SC-005 asks for this to be reachable WITHOUT going through the transport, and
# that is the point of the suite: the gate at the connection chokepoint already
# refuses a redirected destination once, with a located message. What is proven
# here is the second, structural line — a future call site that builds its own
# URL cannot obtain a credential by forgetting to ask the gate.
#
# The token is a sentinel throughout so that "no part of it appears" is a
# meaningful assertion rather than a vacuous one.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/credentials.sh"
  export JIRA_API_TOKEN="SENTINELTOKEN0123456789"
  unset SPEC_KIT_JIRA_BASE_URL
  cred_pin_origin ""
}

teardown() {
  unset JIRA_API_TOKEN SPEC_KIT_JIRA_BASE_URL
}

@test "C6.4 — with no verified destination the producer refuses" {
  run cred_curl_config "user@example.com" "https://anything.example.invalid/rest"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"verified no Jira destination"* ]]
}

@test "C6.1 — a request to the pinned origin is authorised" {
  cred_pin_origin "https://ok.example.invalid"
  run cred_curl_config "user@example.com" "https://ok.example.invalid/rest/api/3/issue/X-1"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Authorization: Basic"* ]]
}

@test "C6.1 — a request to any other origin is refused" {
  cred_pin_origin "https://ok.example.invalid"
  run cred_curl_config "user@example.com" "https://evil.example.invalid/rest"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not bound to"* ]]
}

@test "C6.1 — the comparison is by origin, not by byte equality" {
  # A default port, a trailing slash and a capital letter still name the same
  # destination; refusing them would break real call sites for no gain.
  cred_pin_origin "https://ok.example.invalid"
  run cred_curl_config "user@example.com" "https://OK.Example.INVALID:443/rest/api/3/issue/X-1"
  [ "${status}" -eq 0 ]
}

@test "C6.1 — a same-host different-scheme request is refused" {
  cred_pin_origin "https://ok.example.invalid"
  run cred_curl_config "user@example.com" "http://ok.example.invalid/rest"
  [ "${status}" -ne 0 ]
}

@test "FR-011 — an environment-supplied destination stands in for the pin" {
  # No chokepoint ran, but the destination came from the environment, which is
  # the case FR-011 declares exempt and for which the chokepoint would have
  # pinned this very origin. config.yml is read ONLY by the chokepoint, so a
  # file-supplied destination cannot be in play here.
  export SPEC_KIT_JIRA_BASE_URL="https://env.example.invalid"
  run cred_curl_config "user@example.com" "https://env.example.invalid/rest"
  [ "${status}" -eq 0 ]
}

@test "FR-011 — the environment fallback does not authorise a different origin" {
  export SPEC_KIT_JIRA_BASE_URL="https://env.example.invalid"
  run cred_curl_config "user@example.com" "https://elsewhere.example.invalid/rest"
  [ "${status}" -ne 0 ]
}

@test "C6.2 — a caller passing no URL keeps the old behaviour" {
  # So the check cannot break a call site that has not been taught about it;
  # every such site is still covered by the gate itself.
  run cred_curl_config "user@example.com"
  [ "${status}" -eq 0 ]
}

@test "C4.10 — no refusal echoes any part of the credential" {
  cred_pin_origin "https://ok.example.invalid"
  run cred_curl_config "user@example.com" "https://evil.example.invalid/rest"
  [[ "${output}" != *"SENTINELTOKEN"* ]]
}

@test "C6.3 — the pinned origin is not exported to a child process" {
  # A spawned child must not inherit it, the same rule the credential cache
  # states for itself.
  cred_pin_origin "https://ok.example.invalid"
  run env
  [[ "${output}" != *"_CRED_PINNED_ORIGIN"* ]]
}
