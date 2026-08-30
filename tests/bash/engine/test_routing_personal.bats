#!/usr/bin/env bats
# T008/T010/T012 [Phase 3, US1] — routing rank 3, the operator's own team
# (contracts/routing-resolution.md C1.1, C1.4, C2.1, C2.3, C2.5, C4.1, C4.2).
#
# The chain is four ranks deep, first non-empty wins:
#   1  committed `routing:` rule          evidence about the SPECIFICATION
#   2  committed teams[].folder_prefix    evidence about the SPECIFICATION
#   3  the operator's selected team       evidence about the PERSON   <- new
#   4  committed routing_default          the repository's last resort
#
# Ranks 1 and 2 stay ahead of rank 3 unconditionally (C2.5): a specification
# that says where it belongs must outrank the person who happens to be
# reconciling it — otherwise a gitignored file would override a team's
# committed routing, which is the same imposition this feature removes, pointed
# the other way.
#
# C1.4 is the clause that makes FR-009 verifiable: with an EMPTY fourth input
# the resolver must reproduce the three-input resolver byte for byte, which is
# why every existing repository is untouched by construction.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
  # NOTE the rule prefix: rank 1 tests the RAW folder name, numbering included,
  # while rank 2 tests it with the leading `NNN-` removed. A rule spelled
  # "billing-" would therefore never match a host-numbered folder such as
  # "003-billing-refund" — a trap worth pinning here, since the shipped
  # template's own comment ("e.g. 'billing-' matches specs/billing-*") is only
  # true for folders the host did not number.
  CFG='{
    "routing": [{"match": {"folder_prefix": "003-billing-"}, "project": "ALPHA"}],
    "routing_default": "ALPHA",
    "teams": [
      {"id": "alpha", "project": "ALPHA", "folder_prefix": "alpha-", "branch_pattern": "alpha-<ID>/<FEATURE_NAME>"},
      {"id": "beta",  "project": "BETA",  "folder_prefix": "beta-",  "branch_pattern": "beta-<ID>/<FEATURE_NAME>"}
    ]
  }'
  # The same catalogue with NO committed last resort — the multi-team shape
  # this feature exists to make expressible.
  CFG_NO_DEFAULT="$(jq -c 'del(.routing_default)' <<< "${CFG}")"
}

# --- C2.1 rank 3 resolves ----------------------------------------------------

@test "C2.1 rank 3: a spec matching nothing resolves to the selected team's project" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

@test "C2.1 rank 3 resolves per operator: the same spec, the other team" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" "alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.1 rank 3 fires with no routing_default declared at all" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG_NO_DEFAULT}" "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "BETA" ]
}

# --- C2.5 the committed ranks outrank the person -----------------------------

@test "C2.5 a committed routing rule beats the personal selection" {
  run routing_resolve "003-billing-refund" '[]' "${CFG}" "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.5 the committed team route beats the personal selection" {
  run routing_resolve "004-alpha-102-export" '[]' "${CFG}" "beta"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.5 holds even when the personal selection is the only thing that could match" {
  # No default, no rule match: rank 2 must still win over rank 3.
  run routing_resolve "004-alpha-102-export" '[]' "${CFG_NO_DEFAULT}" "beta"
  [ "$output" = "ALPHA" ]
}

# --- C2.3 / C4.4 an empty selection is silent --------------------------------

@test "C2.3 an empty fourth input falls through to routing_default" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" ""
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.3 an empty fourth input produces no diagnostic" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" ""
  [ "$status" -eq 0 ]
  [ -z "${stderr:-}" ] || true
  [[ "${output}" == "ALPHA" ]]
}

@test "C2.4 no rank yields anything: refusal with EXIT_CONFIG and empty stdout" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG_NO_DEFAULT}" ""
  [ "$status" -eq 4 ]
  [ -z "$(printf '%s' "${output}" | grep -v '^routing:' || true)" ]
}

# --- C4.2 an id matching no catalogue entry ----------------------------------

@test "C4.2 a selected id matching no catalogue entry falls through to rank 4" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" "ghost"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C4.2 an id matching no catalogue entry, with no default, refuses" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG_NO_DEFAULT}" "ghost"
  [ "$status" -eq 4 ]
}

@test "C4.1 the resolver does not re-validate the id and reports nothing about it" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" "Not_Valid"
  [ "$status" -eq 0 ]
  [[ "${output}" != *"Not_Valid"* ]]
}

# --- C1.4 the empty-input invariant (FR-009) ---------------------------------

@test "C1.4 an omitted fourth argument behaves exactly like an empty one" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}"
  local three="${output}" three_status="${status}"
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" ""
  [ "${three}" = "${output}" ]
  [ "${three_status}" -eq "${status}" ]
}

@test "C1.4 empty selection reproduces rank 1 unchanged" {
  run routing_resolve "003-billing-refund" '[]' "${CFG}"
  [ "$output" = "ALPHA" ]
}

@test "rank 1 matches the RAW folder name, numbering included" {
  # The counterpart of the note in setup: the same rule spelled without the
  # numbering does not match a numbered folder, so rank 3 is reached.
  local cfg
  cfg="$(jq -c '.routing = [{"match": {"folder_prefix": "billing-"}, "project": "ALPHA"}]' <<< "${CFG}")"
  run routing_resolve "003-billing-refund" '[]' "${cfg}" "beta"
  [ "$output" = "BETA" ]
}

@test "C1.4 empty selection reproduces rank 2 unchanged" {
  run routing_resolve "004-alpha-102-export" '[]' "${CFG}"
  [ "$output" = "ALPHA" ]
}

@test "C1.4 empty selection reproduces the refusal unchanged" {
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG_NO_DEFAULT}"
  [ "$status" -eq 4 ]
  [[ "${output}" == *"no routing rule matched"* ]]
}

# --- cross-port equivalence (C7.1) -------------------------------------------

@test "C7.1 the PowerShell port resolves rank 3 byte-identically" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  run routing_resolve "007-legacy-cleanup" '[]' "${CFG}" "beta"
  local bash_out="$output" ps_out
  ps_out="$(RT_CFG="${CFG}" pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/engine/Interchange.psm1' -Force
    \$r = Resolve-JiraRouting -FolderName '007-legacy-cleanup' -LabelsJson '[]' -RoutingConfigJson \$env:RT_CFG -SelectedTeamId 'beta'
    [Console]::Out.Write(\$r.ProjectKey)
  ")"
  [ "$bash_out" = "$ps_out" ]
}

@test "C7.1 the PowerShell port honours C2.5 byte-identically" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  run routing_resolve "003-billing-refund" '[]' "${CFG}" "beta"
  local bash_out="$output" ps_out
  ps_out="$(RT_CFG="${CFG}" pwsh -NoProfile -Command "
    Import-Module '${ROOT}/scripts/powershell/engine/Interchange.psm1' -Force
    \$r = Resolve-JiraRouting -FolderName '003-billing-refund' -LabelsJson '[]' -RoutingConfigJson \$env:RT_CFG -SelectedTeamId 'beta'
    [Console]::Out.Write(\$r.ProjectKey)
  ")"
  [ "$bash_out" = "$ps_out" ]
}
