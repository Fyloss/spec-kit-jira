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
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash_out="$(summary_build_json reconcile true 2 1 0 1 0 2)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((New-JiraSummaryJson -Command reconcile -DryRun \$true -Created 2 -Updated 1 -Skipped 0 -Warnings 1 -Errors 0 -ExitCode 2))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "prose is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
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
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  json="$(style_audit_json)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}

# --- T083 [Phase 9] — the §7.1 per-role audit, in prose (010) --------------

role_audit_json() {
  printf '%s' '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":0},"dry_run":false,"effects":{"discovery":{"detail":"1 project(s) discovered","projects":{"CONSUMER":{"style":"company_managed","style_source":"api","roles":{"specification":{"logical_name":"Epic","source":"declared"},"story":{"logical_name":"Tâche","source":"derived"},"task":{"logical_name":"Sous-tâche","source":"operator"}}}},"status":"written"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"unchanged"},"hooks":{"detail":"lifecycle hooks already registered","status":"unchanged"},"readme":{"detail":"block present","status":"unchanged"}},"exit_code":0,"schema_version":"1.0"}'
}

@test "prose renders one role-audit line per resolved role, under the project's style line (010, contract §7.1)" {
  run bash -c "$(declare -f role_audit_json); role_audit_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"specification: Epic (declared)"* ]]
  [[ "$output" == *"story: Tâche (derived)"* ]]
  [[ "$output" == *"task: Sous-tâche (operator)"* ]]
}

@test "the role-audit prose is byte-identical across ports, including non-ASCII names (010)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  json="$(role_audit_json)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}

# =============================================================================
# T054/T055 [Phase 7] — the run summary reports recognised/assigned/skipped
# (Phase 3/4/6), in both JSON and prose form.
# =============================================================================

_output_wrapper() {
  printf '%s' "$1" | summary_render_prose
}

@test "prose renders Recognised/Assigned when the summary carries them (reconcile)" {
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":3,"warnings":0,"errors":0,"recognised":3,"assigned":0},"actions":[],"hook_health":{},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recognised: 3, Assigned: 0"* ]]
  [[ "$output" == *"Skipped: 3"* ]]
}

@test "prose omits Recognised/Assigned for a command that never reports them (config)" {
  local json='{"schema_version":"1.0","command":"config","dry_run":false,"counts":{"created":0,"updated":0,"skipped":0,"warnings":0,"errors":0},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Recognised"* ]]
}

@test "the PowerShell port renders Recognised/Assigned identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":3,"warnings":0,"errors":0,"recognised":3,"assigned":0},"actions":[],"hook_health":{},"exit_code":0}'
  local b p
  b="$(printf '%s' "${json}" | summary_render_prose)"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Output.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json '${json}'))")"
  [ "${b}" = "${p}" ]
}

# =============================================================================
# T181 [Phase 14, Convergence] — counts.transitioned reaches the PROSE report
# too, not only --json (FR-037). Conditional presence mirrors counts.transitioned
# itself: present in the JSON, rendered; absent, no "Transitioned" line at all.
# =============================================================================

@test "prose renders Transitioned when the summary carries counts.transitioned" {
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":1,"skipped":0,"warnings":0,"errors":0,"transitioned":2},"actions":[],"hook_health":{},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Transitioned: 2"* ]]
}

@test "prose omits Transitioned when counts.transitioned is absent (no event, or no role declares a step)" {
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":0,"warnings":0,"errors":0},"actions":[],"hook_health":{},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Transitioned"* ]]
}

@test "the PowerShell port renders Transitioned identically (T181)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":1,"skipped":0,"warnings":0,"errors":0,"transitioned":2},"actions":[],"hook_health":{},"exit_code":0}'
  local b p
  b="$(printf '%s' "${json}" | summary_render_prose)"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Output.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json '${json}'))")"
  [ "${b}" = "${p}" ]
}
