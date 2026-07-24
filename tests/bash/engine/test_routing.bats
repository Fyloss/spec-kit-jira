#!/usr/bin/env bats
# T076 [US8] — Routing resolution (FR-041, FR-042).
#
# The routing engine is PURE: given a spec folder name, the labels declared in
# the spec, and the team config's ordered `routing` rules plus `routing_default`,
# it resolves the ONE project a spec reconciles against. First matching rule wins;
# an unmatched spec falls back to routing_default; a spec that matches nothing with
# no default configured is refused (EXIT_CONFIG). A rule matches only when EVERY
# condition it declares (folder_prefix and/or spec_label) holds, so one repository
# can route distinct specs to distinct projects of mixed styles.
# The PowerShell port resolves byte-identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/engine"
  PS_ENGINE="${ROOT}/.specify/extensions/jira/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
  CFG='{
    "routing": [
      {"match": {"folder_prefix": "billing-"}, "project": "BILL"},
      {"match": {"spec_label": "infra"}, "project": "INFRA"},
      {"match": {"folder_prefix": "sec-", "spec_label": "audit"}, "project": "SEC"}
    ],
    "routing_default": "COMP"
  }'
}

@test "a folder-prefix rule routes the spec to its project (FR-041)" {
  run routing_resolve "billing-payments" '[]' "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "BILL" ]
}

@test "a spec-label rule routes the spec to its project (FR-041)" {
  run routing_resolve "001-networking" '["infra"]' "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "INFRA" ]
}

@test "the first matching rule wins over later ones (FR-041)" {
  # 'billing-' matches the first rule even though the label would match the second.
  run routing_resolve "billing-core" '["infra"]' "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "BILL" ]
}

@test "a multi-condition rule matches only when every condition holds (FR-041)" {
  # Both the prefix and the label are required for the SEC rule.
  run routing_resolve "sec-hardening" '["audit"]' "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "SEC" ]
}

@test "a multi-condition rule is skipped when only one condition holds" {
  # The prefix matches but the label is absent, so the SEC rule is skipped and the
  # spec falls through to routing_default.
  run routing_resolve "sec-hardening" '[]' "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "COMP" ]
}

@test "an unmatched spec falls back to routing_default (FR-041)" {
  run routing_resolve "999-orphan" '[]' "${CFG}"
  [ "$status" -eq 0 ]
  [ "$output" = "COMP" ]
}

@test "no match and no routing_default is refused with EXIT_CONFIG (FR-041)" {
  # Capture stdout separately so the refusal message on stderr does not count as a
  # routed project key: a refused spec emits ZERO project on stdout.
  local out rc=0
  out="$(routing_resolve "999-orphan" '[]' '{"routing":[{"match":{"folder_prefix":"x-"},"project":"X"}]}' 2> /dev/null)" || rc=$?
  [ "$rc" -eq 4 ]
  [ -z "$out" ]
}

@test "a config with only routing_default routes everything to it (FR-042)" {
  run routing_resolve "anything" '["whatever"]' '{"routing_default":"SOLO"}'
  [ "$status" -eq 0 ]
  [ "$output" = "SOLO" ]
}

@test "the PowerShell port resolves byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps_abs
  ps_abs="$(cd "${PS_ENGINE}" && pwd)"
  # folder, labels, and the resolved project each port should agree on.
  local cases=(
    'billing-payments|[]|BILL'
    '001-networking|["infra"]|INFRA'
    'sec-hardening|["audit"]|SEC'
    'sec-hardening|[]|COMP'
    '999-orphan|[]|COMP'
  )
  local c
  for c in "${cases[@]}"; do
    local folder="${c%%|*}" rest="${c#*|}"
    local labels="${rest%%|*}"
    local bash_out ps_out
    bash_out="$(routing_resolve "${folder}" "${labels}" "${CFG}")"
    ps_out="$(RT_FOLDER="${folder}" RT_LABELS="${labels}" RT_CFG="${CFG}" pwsh -NoProfile -Command "
      Import-Module '${ps_abs}/Interchange.psm1' -Force
      \$r = Resolve-JiraRouting -FolderName \$env:RT_FOLDER -LabelsJson \$env:RT_LABELS -RoutingConfigJson \$env:RT_CFG
      [Console]::Out.Write(\$r.ProjectKey)
    ")"
    [ "$bash_out" = "$ps_out" ]
  done
}
