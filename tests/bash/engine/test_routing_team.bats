#!/usr/bin/env bats
# T081 [US3] — Implicit team→project route (US3 scenario 6, data-model §4,
# analyze remediation A3).
#
# When no explicit routing rule matches, a spec folder whose flat name carries
# a catalogue team's folder_prefix (after the numbering component) routes to
# that team's project, before routing_default. Explicit rules always win; with
# no catalogue the behaviour is unchanged. The catalogue arrives as opaque data
# — the engine keeps zero Jira knowledge.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
  CFG_TEAMS='{
    "routing": [],
    "routing_default": "COMP",
    "teams": [
      {"id": "ijt", "project": "IJT", "folder_prefix": "ijt-", "branch_pattern": "ijt-<ID>/<FEATURE_NAME>"},
      {"id": "wex", "project": "WEX", "folder_prefix": "wex-", "branch_pattern": "wex-<ID>/<FEATURE_NAME>"}
    ]
  }'
}

@test "a team-prefixed folder routes to the team's project with no explicit rule (scenario 6)" {
  run routing_resolve "003-ijt-invoice-export" '[]' "${CFG_TEAMS}"
  [ "$status" -eq 0 ]
  [ "$output" = "IJT" ]
  run routing_resolve "004-wex-onboarding" '[]' "${CFG_TEAMS}"
  [ "$output" = "WEX" ]
}

@test "an explicit routing rule still wins over the implicit team route" {
  local cfg
  cfg="$(jq -c '.routing = [{"match": {"folder_prefix": "003-"}, "project": "BILL"}]' <<< "${CFG_TEAMS}")"
  run routing_resolve "003-ijt-invoice-export" '[]' "${cfg}"
  [ "$output" = "BILL" ]
}

@test "a non-team folder still falls back to routing_default" {
  run routing_resolve "005-plain-feature" '[]' "${CFG_TEAMS}"
  [ "$output" = "COMP" ]
}

@test "no catalogue: behaviour unchanged (routing_default)" {
  run routing_resolve "003-ijt-invoice-export" '[]' '{"routing": [], "routing_default": "COMP"}'
  [ "$output" = "COMP" ]
}

@test "the PowerShell port resolves the implicit route byte-identically (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  run routing_resolve "003-ijt-invoice-export" '[]' "${CFG_TEAMS}"
  local bash_out="$output" ps_out
  ps_out="$(RT_CFG="${CFG_TEAMS}" pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/Interchange.psm1' -Force
    \$r = Resolve-JiraRouting -FolderName '003-ijt-invoice-export' -LabelsJson '[]' -RoutingConfigJson \$env:RT_CFG
    [Console]::Out.Write(\$r.ProjectKey)
  ")"
  [ "$bash_out" = "$ps_out" ]
}
