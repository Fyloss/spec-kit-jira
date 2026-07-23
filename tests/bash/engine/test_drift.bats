#!/usr/bin/env bats
# T068 [US6] — Status-category-aware drift classification (FR-031, FR-034, FR-035).
#
# The drift engine is PURE: given a ticket's current status, its classification
# category, the disk-inferred target, the operator's phase-ordered status
# sequence, and the --on-drift mode, it decides the transition's fate and never
# silently overwrites Jira-side progress. It performs zero Jira reads or writes.
#
#   halted     -> halt all writes, surface two remediations.
#   unknown    -> withhold the transition, name the drift, suggest classifying.
#   post-scope -> never backward drift; a regressed disk phase aborts by default
#                 (content still reconciles) and needs --on-drift=proceed.
#   mapped     -> a ticket advanced Jira-side is withheld and named, never a
#                 silent overwrite; --on-drift=proceed pulls it back.
# The PowerShell port classifies byte-identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/engine"
  PS_ENGINE="${ROOT}/.specify/extensions/jira/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/drift.sh"
  ORDER='["To Do","In Progress","In Review","Done"]'
}

@test "a halted status halts all writes and surfaces two remediations (FR-034)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"Blocked", current_category:"halted", target_status:"Done", order:$o, on_drift:"abort"}')"
  run drift_evaluate "${in}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<< "$output")" = "halt" ]
  [ "$(jq -r '.content_writes' <<< "$output")" = "false" ]
  [ "$(jq -r '.remediations | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 1 ]
}

@test "an unknown status withholds the transition and suggests classifying it (FR-034)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"Investigating", current_category:"unknown", target_status:"Done", order:$o}')"
  run drift_evaluate "${in}"
  [ "$(jq -r '.decision' <<< "$output")" = "withhold" ]
  [ "$(jq -r '.content_writes' <<< "$output")" = "true" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"classify"* ]]
}

@test "a post-scope status is never backward drift when aligned (FR-034)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"Done", current_category:"post-scope", target_status:"Done", order:$o}')"
  run drift_evaluate "${in}"
  [ "$(jq -r '.decision' <<< "$output")" = "transition" ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
}

@test "a regressed disk phase against a post-scope ticket aborts by default (FR-035)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"Done", current_category:"post-scope", target_status:"In Progress", order:$o, on_drift:"abort"}')"
  run drift_evaluate "${in}"
  # The backward transition is withheld, but content may still reconcile.
  [ "$(jq -r '.decision' <<< "$output")" = "withhold" ]
  [ "$(jq -r '.content_writes' <<< "$output")" = "true" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"--on-drift=proceed"* ]]
}

@test "--on-drift=proceed pulls a post-scope ticket backward (FR-035)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"Done", current_category:"post-scope", target_status:"In Progress", order:$o, on_drift:"proceed"}')"
  run drift_evaluate "${in}"
  [ "$(jq -r '.decision' <<< "$output")" = "transition" ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 1 ]
}

@test "a mapped ticket advanced Jira-side is withheld and named, never silently overwritten (FR-031)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"In Review", current_category:"mapped", target_status:"In Progress", order:$o, on_drift:"abort"}')"
  run drift_evaluate "${in}"
  [ "$(jq -r '.decision' <<< "$output")" = "withhold" ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"drift"* ]]
}

@test "--on-drift=proceed lets a mapped ticket be pulled back (FR-031)" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"In Review", current_category:"mapped", target_status:"In Progress", order:$o, on_drift:"proceed"}')"
  run drift_evaluate "${in}"
  [ "$(jq -r '.decision' <<< "$output")" = "transition" ]
}

@test "a mapped forward move transitions cleanly with no warning" {
  local in
  in="$(jq -cn --argjson o "${ORDER}" '{current_status:"To Do", current_category:"mapped", target_status:"In Progress", order:$o}')"
  run drift_evaluate "${in}"
  [ "$(jq -r '.decision' <<< "$output")" = "transition" ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
}

@test "the PowerShell port classifies byte-identically (NFR-1)" {
  local cases=(
    '{"current_status":"Blocked","current_category":"halted","target_status":"Done","order":["To Do","Done"],"on_drift":"abort"}'
    '{"current_status":"Done","current_category":"post-scope","target_status":"To Do","order":["To Do","In Progress","Done"],"on_drift":"proceed"}'
    '{"current_status":"In Review","current_category":"mapped","target_status":"In Progress","order":["To Do","In Progress","In Review","Done"],"on_drift":"abort"}'
    '{"current_status":"Investigating","current_category":"unknown","target_status":"Done","order":["To Do","Done"]}'
  )
  local ps_abs
  ps_abs="$(cd "${PS_ENGINE}" && pwd)"
  local in
  for in in "${cases[@]}"; do
    local bash_out ps_out
    bash_out="$(drift_evaluate "${in}")"
    ps_out="$(DRIFT_IN="${in}" pwsh -NoProfile -Command "
      Import-Module '${ps_abs}/Drift.psm1' -Force
      [Console]::Out.Write((Get-JiraDriftDecision -InputJson \$env:DRIFT_IN))
    ")"
    [ "$bash_out" = "$ps_out" ]
  done
}
