#!/usr/bin/env bats
# T016 — Run-summary rendering: prose default + --json (run-summary.schema.json),
# plus the WARNING channel. Byte-identical across ports (Constitution VI).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  PS_LIB="${ROOT}/scripts/powershell/lib"
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/output.sh"
}

# --- uri_encode (byte-parity contract, research §11) -------------------------

@test "uri_encode leaves only the unreserved set A-Za-z0-9-_.~ intact" {
  # Regression (003): jq's @uri escapes ! * ' ( and ), which an encoder modelled
  # on encodeURIComponent leaves alone. The adoption JQL carries parentheses, so
  # a divergence there desynchronises the two ports' Jira call logs.
  [ "$(uri_encode "a(b)c!~*'d")" = "a%28b%29c%21~%2A%27d" ]
  [ "$(uri_encode '-_.~')" = '-_.~' ]
  [ "$(uri_encode 'a b')" = 'a+b' ]
}

@test "uri_encode is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local sample='project = "ADO" AND labels IN ("speckit-adopt:003", '"'"'x!*~-_.'"'"')'
  local bash_out ps_out
  bash_out="$(uri_encode "${sample}")"
  ps_out="$(SAMPLE="${sample}" pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Output.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraUriComponent \$env:SAMPLE))
  ")"
  [ "$bash_out" = "$ps_out" ]
}

@test "summary_build_json emits canonical JSON with required keys" {
  run summary_build_json reconcile false 1 2 0 0 0 0
  echo "$output" | jq -e '.schema_version=="1.0" and .command=="reconcile" and .counts.created==1 and .counts.updated==2 and .exit_code==0' > /dev/null
}

@test "summary_build_json validates against run-summary.schema.json (oracle, if available)" {
  json="$(summary_build_json reconcile true 3 0 1 0 0 0)"
  if command -v jsonschema > /dev/null 2>&1; then
    printf '%s' "$json" | jsonschema --instance /dev/stdin "$SCHEMA"
  else
    skip "jsonschema CLI not available"
  fi
}

@test "summary_build_json keys are sorted (canonical)" {
  json="$(summary_build_json config false 0 0 0 0 0 0)"
  # First key after '{' must be 'command' (sorted before 'counts','dry_run','exit_code','schema_version')
  [[ "$json" == '{"command":'* ]]
}

@test "summary_render_prose shows counts and exit" {
  json="$(summary_build_json reconcile false 1 2 3 0 0 0)"
  run bash -c "printf '%s' '$json' | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [[ "$output" == *"reconcile"* ]]
  [[ "$output" == *"Created: 1"* ]]
  [[ "$output" == *"Updated: 2"* ]]
  [[ "$output" == *"Exit: 0"* ]]
}

@test "output_warn writes to the WARNING channel on stderr" {
  run bash -c "source '${LIB_DIR}/output.sh'; output_warn 'a thing happened' 2>&1 1>/dev/null"
  [[ "$output" == "WARNING: a thing happened" ]]
}

@test "summary JSON is byte-identical across ports" {
  bash_out="$(summary_build_json reconcile true 2 1 0 1 0 2)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((New-JiraSummaryJson -Command reconcile -DryRun \$true -Created 2 -Updated 1 -Skipped 0 -Warnings 1 -Errors 0 -ExitCode 2))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "prose is byte-identical across ports" {
  json="$(summary_build_json config false 0 0 0 0 0 0)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}

# T098 — the per-project style audit (FR-003) lives at
# effects.discovery.projects.<KEY>.{style,style_source}. It must reach the
# DEFAULT output, not only --json: prose is the default rendering.

style_audit_json() {
  # Two projects, deliberately declared out of order, so the renderer's own
  # ordering (project key, ordinal) is what is asserted.
  printf '%s' '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":0},"dry_run":false,"effects":{"discovery":{"detail":"2 project(s) discovered","projects":{"WEX":{"style":"company_managed","style_source":"operator"},"IJT":{"style":"team_managed","style_source":"api"}},"status":"written"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"unchanged"},"hooks":{"detail":"lifecycle hooks already registered","status":"unchanged"},"readme":{"detail":"block present","status":"unchanged"}},"exit_code":0,"schema_version":"1.0"}'
}

line_of() {
  # line_of <needle> — 1-based line number of the first match in $output
  printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1
}

@test "prose renders the per-project style audit under the discovery effect (T098)" {
  run bash -c "$(declare -f style_audit_json); style_audit_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"    IJT: team_managed (api)"* ]]
  [[ "$output" == *"    WEX: company_managed (operator)"* ]]
}

@test "the style audit is nested under discovery and ordered by project key (T098)" {
  run bash -c "$(declare -f style_audit_json); style_audit_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  disc_ln="$(line_of '  discovery: ')"
  ijt_ln="$(line_of 'IJT: ')"
  wex_ln="$(line_of 'WEX: ')"
  hooks_ln="$(line_of '  hooks: ')"
  # discovery < IJT < WEX < hooks: ordinal key order, inside the discovery block.
  [ "$disc_ln" -lt "$ijt_ln" ]
  [ "$ijt_ln" -lt "$wex_ln" ]
  [ "$wex_ln" -lt "$hooks_ln" ]
}

@test "an empty projects map adds no style-audit lines (degraded run) (T098)" {
  json='{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":1},"dry_run":false,"effects":{"discovery":{"detail":"0 project(s) discovered","projects":{},"status":"skipped"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"skipped"}},"exit_code":0,"schema_version":"1.0"}'
  run bash -c "printf '%s' '$json' | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^    ')" -eq 0 ]
}

@test "the style-audit prose is byte-identical across ports (T098)" {
  json="$(style_audit_json)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}
