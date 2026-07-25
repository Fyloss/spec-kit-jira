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
