#!/usr/bin/env bats
# T089/T090 [US12] — Privacy guard WARN tier and allowlist without false positives
# (FR-053). On top of the BLOCK tier (US11), the guard merely WARNS on generic
# shapes (emails, UUIDs) — it never blocks them. Confluence links and domains
# declared in `.extensionignore` (gitignore syntax) or `config.privacy.allowlist`
# produce NEITHER a block NOR a warning — a BLOCK-tier false positive on
# allowlisted content is a failing test. `.extensionignore` paths are excluded
# from both parsing and scanning. The PowerShell port behaves identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/.specify/extensions/jira/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/privacy_guard.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

# --- WARN tier: generic shapes warn but never block -------------------------

@test "a generic email warns but does not block (FR-053)" {
  run privacy_guard_scan '{"text":"contact alice@example.com for access"}'
  [ "$status" -eq 0 ]
  run privacy_guard_warn_reason '{"text":"contact alice@example.com for access"}'
  [ "$status" -eq 0 ]
  [ "$output" = "email address" ]
}

@test "a generic UUID warns but does not block (FR-053)" {
  local p='{"id":"550e8400-e29b-41d4-a716-446655440000"}'
  run privacy_guard_scan "$p"
  [ "$status" -eq 0 ]
  run privacy_guard_warn_reason "$p"
  [ "$output" = "UUID" ]
}

@test "clean content produces neither a block nor a warning" {
  run privacy_guard_scan '{"text":"Add the billing feature"}'
  [ "$status" -eq 0 ]
  run privacy_guard_warn_reason '{"text":"Add the billing feature"}'
  [ -z "$output" ]
}

# --- Allowlist: no block, no warning, no false positive ---------------------

@test "an allowlisted Atlassian host produces neither block nor warning (FR-053)" {
  local p='{"text":"see https://ourco.atlassian.net/wiki/spaces/OPS/pages/1"}'
  local allow='["ourco.atlassian.net"]'
  # Without the allowlist this WOULD block (US11) — the allowlist suppresses it.
  run privacy_guard_scan "$p" '[]' "${allow}"
  [ "$status" -eq 0 ]
  run privacy_guard_warn_reason "$p" "${allow}"
  [ -z "$output" ]
}

@test "an allowlisted email domain produces no warning (FR-053)" {
  local p='{"text":"contact alice@allowed.example for access"}'
  run privacy_guard_warn_reason "$p" '["allowed.example"]'
  [ -z "$output" ]
}

@test "a NON-allowlisted Atlassian host still blocks — US11 preserved (FR-052)" {
  run privacy_guard_scan '{"text":"leak acme-corp.atlassian.net"}' '[]' '["ourco.atlassian.net"]'
  [ "$status" -eq 9 ]
}

# --- .extensionignore path exclusion (parse + scan) -------------------------

@test ".extensionignore paths are excluded from parse + scan (FR-053)" {
  local ignore="${WORK}/.extensionignore"
  printf '%s\n' '# comment' 'secrets/' '*.key' 'specs/private.md' > "${ignore}"
  run privacy_path_excluded 'secrets/creds.txt' "${ignore}"
  [ "$status" -eq 0 ]
  run privacy_path_excluded 'id_rsa.key' "${ignore}"
  [ "$status" -eq 0 ]
  run privacy_path_excluded 'specs/private.md' "${ignore}"
  [ "$status" -eq 0 ]
  run privacy_path_excluded 'specs/public.md' "${ignore}"
  [ "$status" -ne 0 ]
}

# --- Allowlist loading (merge .extensionignore + config.privacy.allowlist) --

@test "privacy_allowlist_load merges .extensionignore and config allowlist" {
  local ignore="${WORK}/.extensionignore"
  printf '%s\n' '# comment' '' 'ourco.atlassian.net' 'docs.example.com/' > "${ignore}"
  run privacy_allowlist_load "${ignore}" '["extra.example.org"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '. | index("ourco.atlassian.net")' <<< "$output")" != "null" ]
  [ "$(jq -r '. | index("extra.example.org")' <<< "$output")" != "null" ]
}

# --- Cross-port parity ------------------------------------------------------

@test "the PowerShell port warns / allowlists identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps
  ps="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/PrivacyGuard.psm1' -Force
    \$a = Get-JiraPrivacyWarnReason -Payload '{\"t\":\"alice@example.com\"}'
    \$b = Get-JiraPrivacyWarnReason -Payload '{\"id\":\"550e8400-e29b-41d4-a716-446655440000\"}'
    \$c = Test-JiraPrivacyBlock -Payload '{\"t\":\"ourco.atlassian.net\"}' -AllowlistJson '[\"ourco.atlassian.net\"]'
    \$d = Test-JiraPrivacyBlock -Payload '{\"t\":\"acme-corp.atlassian.net\"}' -AllowlistJson '[\"ourco.atlassian.net\"]'
    [Console]::Out.Write(\"\$a|\$b|\$c|\$d\")
  ")"
  [ "$ps" = "email address|UUID|0|9" ]
}
