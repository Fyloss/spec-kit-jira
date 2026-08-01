#!/usr/bin/env bats
# T036 [US3] — `teams:` catalogue validation (FR-010/FR-018).
#
# The committed config.yml may declare an OPTIONAL teams catalogue. Load-time
# validation enforces: unique id (^[a-z][a-z0-9]*$) and folder_prefix
# (^[a-z0-9][a-z0-9-]*-$, unique); branch_pattern contains <ID> and
# <FEATURE_NAME> exactly once each with every other character in [a-z0-9/_-]
# (unknown placeholders refused); a valid project key; credential-shaped values
# refused without echoing; an absent section changes nothing.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${DIR}"
}

# write_cfg <teams-yaml-block> — a minimal valid config plus the teams block.
write_cfg() {
  {
    printf 'projects:\n'
    printf '  - key: IJT\n'
    printf 'routing_default: IJT\n'
    if [ -n "${1:-}" ]; then printf '%s\n' "$1"; fi
  } > "${DIR}/config.yml"
}

@test "a valid two-team catalogue loads (exit 0) and survives the merge" {
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
  - id: wex
    project: WEX
    folder_prefix: "wex-"
    branch_pattern: "wex-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.teams | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.teams[0].id' <<< "$output")" = "ijt" ]
}

@test "an absent teams section changes nothing (FR-017)" {
  write_cfg ''
  run config_load "${DIR}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("teams")' <<< "$output")" = "false" ]
}

@test "an invalid team id is refused (exit 4)" {
  write_cfg 'teams:
  - id: IJT
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].id is invalid"* ]]
}

@test "a duplicate team id is refused (exit 4)" {
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
  - id: ijt
    project: WEX
    folder_prefix: "wex-"
    branch_pattern: "wex-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[1].id duplicates an earlier team id"* ]]
}

@test "an invalid or non-unique folder_prefix is refused (exit 4)" {
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "Ijt"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].folder_prefix is invalid"* ]]

  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
  - id: wex
    project: WEX
    folder_prefix: "ijt-"
    branch_pattern: "wex-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[1].folder_prefix duplicates an earlier folder_prefix"* ]]
}

@test "an invalid project key in a team entry is refused (exit 4)" {
  write_cfg 'teams:
  - id: ijt
    project: ijt
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].project is not a valid project key"* ]]
}

@test "branch_pattern must contain <ID> and <FEATURE_NAME> exactly once each" {
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].branch_pattern is invalid"* ]]

  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/feature"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].branch_pattern is invalid"* ]]
}

@test "an unknown placeholder or illegal character in branch_pattern is refused" {
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<TICKET>/<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].branch_pattern is invalid"* ]]

  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "IJT <ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"teams[0].branch_pattern is invalid"* ]]
}

@test "a credential-shaped value in a team entry is refused without echoing (FR-018)" {
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
    contact: someone@example.com'
  run config_load "${DIR}"
  [ "$status" -eq 4 ]
  [[ "$output" != *"someone@example.com"* ]]
  [[ "$output" == *"email address"* ]]
}

@test "the PowerShell port validates byte-identically (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  write_cfg 'teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
  - id: ijt
    project: WEX
    folder_prefix: "wex-"
    branch_pattern: "wex-<ID>/<FEATURE_NAME>"'
  run config_load "${DIR}"
  local bash_status="$status" bash_err
  bash_err="$(config_load "${DIR}" 2>&1 >/dev/null || true)"
  local ps_out
  ps_out="$(CFG_DIR="${DIR}" pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/lib/Config.psm1' -Force
    \$r = Import-JiraConfig -ConfigDir \$env:CFG_DIR
    [Console]::Out.Write(\"\$(\$r.ExitCode)\")
  " 2>/dev/null)"
  [ "$bash_status" = "$ps_out" ]
}
