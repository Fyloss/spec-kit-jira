#!/usr/bin/env bats
# T088 [016, Phase 8] — a module-property guard: engine/markdown.sh and its
# PowerShell mirror Markdown.psm1 open no file for writing (FR-000,
# quickstart.md §8). FR-000 claims the ABSENCE of a write path, and one
# passing reconcile scenario cannot prove absence — this checks the property
# of the module directly, so a future edit that adds a write path fails here
# rather than going unnoticed.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  BASH_MOD="${ROOT}/scripts/bash/engine/markdown.sh"
  PS_MOD="${ROOT}/scripts/powershell/engine/Markdown.psm1"
}

# _md_no_redirect <file> — true (grep exit 1) when FILE contains no shell
# output-redirection to a string/variable/device target. Matches the shape a
# real write takes (`> "${f}"`, `>> '/tmp/x'`) — `>` flanked by whitespace on
# both sides, immediately followed by a quote or `$` sigil — while leaving the
# markdown grammar's own quoted '>' character (the blockquote marker, matched
# and compared as data throughout this module) alone.
_md_no_redirect() {
  ! grep -qE '[[:space:]]>{1,2}[[:space:]]+["'"'"'$]' "$1"
}

@test "engine/markdown.sh opens no file for writing" {
  [ -f "${BASH_MOD}" ]
  _md_no_redirect "${BASH_MOD}"
  ! grep -qE '\btee\b|\bcp\b[[:space:]]|\bmv\b[[:space:]]' "${BASH_MOD}"
}

@test "engine/Markdown.psm1 opens no file for writing" {
  [ -f "${PS_MOD}" ]
  _md_no_redirect "${PS_MOD}"
  ! grep -qiE 'Out-File|Set-Content|Add-Content|StreamWriter|WriteAllText|WriteAllBytes|Copy-Item|Move-Item|New-Item[[:space:]]+-ItemType[[:space:]]+File' "${PS_MOD}"
}

@test "the guard itself catches a planted write (sanity check)" {
  local planted="${BATS_TEST_TMPDIR}/planted.sh"
  printf '%s\n' 'echo hi > "${some_file}"' > "${planted}"
  run _md_no_redirect "${planted}"
  [ "$status" -ne 0 ]
}
