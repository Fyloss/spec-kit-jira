#!/usr/bin/env bats
# T040 [US3] — Pure naming engine (FR-015).
#
# The naming engine is PURE: pattern expansion with <ID>/<FEATURE_NAME>, the
# ticket number stripped of an OPAQUE key's project prefix, the descriptive
# slug, and the folder short-name with the team prefix never duplicated. `/` in
# a pattern yields git branch hierarchy only — the folder component stays flat.
# The engine file carries no Jira knowledge and no issue-key-shaped literal
# (Constitution VIII, boundary grep below).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/naming.sh"
}

@test "naming_ticket_number strips the project-key prefix of an opaque key" {
  run naming_ticket_number "IJT-42"
  [ "$output" = "42" ]
  run naming_ticket_number "AB_C2-1234"
  [ "$output" = "1234" ]
}

@test "naming_ticket_number leaves a non-key-shaped value untouched" {
  run naming_ticket_number "42"
  [ "$output" = "42" ]
}

@test "naming_expand_pattern substitutes <ID> and <FEATURE_NAME>" {
  run naming_expand_pattern "ijt-<ID>/<FEATURE_NAME>" "42" "invoice-export"
  [ "$output" = "ijt-42/invoice-export" ]
  run naming_expand_pattern "team/x-<ID>_<FEATURE_NAME>" "7" "onboarding"
  [ "$output" = "team/x-7_onboarding" ]
}

@test "naming_slug builds a folder-safe slug from a description" {
  run naming_slug "Invoice Export"
  [ "$output" = "invoice-export" ]
  run naming_slug "  Fix: rounding (v2)  "
  [ "$output" = "fix-rounding-v2" ]
}

@test "naming_short_name prefixes the slug and never duplicates the prefix (FR-015)" {
  run naming_short_name "ijt-" "invoice-export"
  [ "$output" = "ijt-invoice-export" ]
  run naming_short_name "ijt-" "ijt-invoice-export"
  [ "$output" = "ijt-invoice-export" ]
}

@test "a pattern's / creates git hierarchy only — the folder component stays flat" {
  run naming_expand_pattern "ijt-<ID>/<FEATURE_NAME>" "42" "invoice-export"
  [[ "$output" == *"/"* ]]
  run naming_short_name "ijt-" "invoice-export"
  [[ "$output" != *"/"* ]]
}

@test "the engine file contains no issue-key-shaped text (Constitution VIII)" {
  ! grep -qE '[A-Z][A-Z0-9_]+-[0-9]+' "${ENGINE_DIR}/naming.sh"
  ! grep -qiE 'jira|atlassian|createmeta' "${ENGINE_DIR}/naming.sh"
}

@test "the PowerShell port names byte-identically (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local bash_out ps_out
  bash_out="$(naming_expand_pattern "ijt-<ID>/<FEATURE_NAME>" "$(naming_ticket_number "IJT-42")" "$(naming_slug "Invoice Export")")|$(naming_short_name "ijt-" "$(naming_slug "ijt invoice export")")"
  ps_out="$(pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/engine/Naming.psm1' -Force
    \$n = Get-JiraTicketNumber -Key 'IJT-42'
    \$s = Get-JiraFeatureSlug -Description 'Invoice Export'
    \$b = Expand-JiraBranchPattern -Pattern 'ijt-<ID>/<FEATURE_NAME>' -Id \$n -FeatureName \$s
    \$f = Get-JiraShortName -FolderPrefix 'ijt-' -Slug (Get-JiraFeatureSlug -Description 'ijt invoice export')
    [Console]::Out.Write(\"\$b|\$f\")
  ")"
  [ "$bash_out" = "$ps_out" ]
}
