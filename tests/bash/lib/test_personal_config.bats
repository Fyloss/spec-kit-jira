#!/usr/bin/env bats
# T038 [US3] — Personal team selection loader (FR-011/FR-012/FR-018).
#
# `.specify/jira/personal.yml` is human-owned, gitignored, OPTIONAL, never
# written by any script. Loader rules: absent file => inactive; unknown `team`
# => located error naming the file and listing the valid catalogue ids (exit 4);
# `override` passes the catalogue-entry validation; credential-shaped values are
# refused without echoing.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  DIR="$(mktemp -d)"
  TEAMS='{"teams":[{"id":"ijt","project":"IJT","folder_prefix":"ijt-","branch_pattern":"ijt-<ID>/<FEATURE_NAME>"},{"id":"wex","project":"WEX","folder_prefix":"wex-","branch_pattern":"wex-<ID>/<FEATURE_NAME>"}]}'
}

teardown() {
  rm -rf "${DIR}"
}

@test "an absent personal file is inactive (exit 0, {active:false})" {
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "false" ]
}

@test "a valid selection is active with its team id" {
  printf 'team: ijt\n' > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(jq -r '.team' <<< "$output")" = "ijt" ]
  [ "$(jq -r '.override' <<< "$output")" = "null" ]
}

@test "an unknown team is a located error listing the valid catalogue ids (exit 4)" {
  printf 'team: zzz\n' > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"personal.yml"* ]]
  [[ "$output" == *"unknown team"* ]]
  [[ "$output" == *"ijt"* ]]
  [[ "$output" == *"wex"* ]]
}

@test "a selection with no catalogue at all is refused (exit 4)" {
  printf 'team: ijt\n' > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" '{}'
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown team"* ]]
}

@test "a valid override loads and is reported" {
  {
    printf 'team: ijt\n'
    printf 'override:\n'
    printf '  folder_prefix: "special-"\n'
    printf '  branch_pattern: "special-<ID>/<FEATURE_NAME>"\n'
  } > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.override.folder_prefix' <<< "$output")" = "special-" ]
}

@test "an override failing the catalogue-entry validation is refused (exit 4)" {
  {
    printf 'team: ijt\n'
    printf 'override:\n'
    printf '  branch_pattern: "Bad Pattern"\n'
  } > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"override.branch_pattern is invalid"* ]]
}

@test "an unknown key in the personal file is refused (exit 4)" {
  printf 'team: ijt\ntoken: something\n' > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown personal key: token"* ]]
}

@test "a credential-shaped value is refused without echoing (FR-018)" {
  printf 'team: someone@example.com\n' > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  [ "$status" -eq 4 ]
  [[ "$output" != *"someone@example.com"* ]]
  [[ "$output" == *"email address"* ]]
}

@test "the PowerShell port loads byte-identically (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  printf 'team: ijt\n' > "${DIR}/personal.yml"
  run config_personal_load "${DIR}" "${TEAMS}"
  local bash_out="$output" ps_out
  ps_out="$(P_DIR="${DIR}" P_TEAMS="${TEAMS}" pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/lib/Config.psm1' -Force
    \$r = Import-JiraPersonalConfig -ConfigDir \$env:P_DIR -MergedJson \$env:P_TEAMS
    [Console]::Out.Write(\$r.Json)
  ")"
  [ "$bash_out" = "$ps_out" ]
}
