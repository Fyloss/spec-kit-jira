#!/usr/bin/env bats
# T082/T083/T086/T087 [US5] — the task tier's own completion pass (contract
# §6). plan_lifecycle_tasks is PURE: every transition candidate, chosen
# transition, or withheld field arrives already resolved by the caller's
# discovery_task_transition read; this function only decides what to do with
# what it is handed. plan_lifecycle_tasks never routes through plan_lifecycle
# — task completion is a binary done/not-done model, not a named multi-status
# order, and every divergence names the ticket key, never a status.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
}

@test "a newly checked task with exactly one done-category destination plans a transition (FR-029)" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-2", forward:{transition_id:"31", candidates:[{id:"31",name:"Terminé"}], withheld_field:null}}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$status" -eq 0 ]
  [ "$(jq '.actions | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.actions[0].url' <<< "$output")" = "http://h/rest/api/3/issue/K-2/transitions" ]
  [ "$(jq -r '.actions[0].body.transition.id' <<< "$output")" = "31" ]
}

@test "a sub-task already done-category has no forward entry at all, plans nothing and issues no read (FR-031)" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$status" -eq 0 ]
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [ "$(jq '.warnings | length' <<< "$output")" -eq 0 ]
}

@test "a task checked and reworded in the same run keeps both its content PUT and its transition POST" {
  local content='[{"method":"PUT","url":"http://h/rest/api/3/issue/K-2","body":{"fields":{"summary":"New"}},"role":"task"}]'
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-2", forward:{transition_id:"31", candidates:[{id:"31",name:"Done"}], withheld_field:null}}}}')"
  run plan_lifecycle_tasks "${content}" "${cc}"
  [ "$status" -eq 0 ]
  [ "$(jq '[.actions[] | select(.method=="PUT")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 1 ]
}

@test "zero done-category destinations plans no transition and reports one warning naming the issue (FR-030)" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-3", forward:{transition_id:null, candidates:[], withheld_field:null}}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [ "$(jq '.warnings | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"K-3"* ]]
}

@test "two or more done-category destinations plans no transition and names the candidates" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-4", forward:{transition_id:null, candidates:[{id:"31",name:"Fait"},{id:"51",name:"Annulé"}], withheld_field:null}}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"K-4"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"Fait"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"Annulé"* ]]
}

@test "a transition gated behind a required field is withheld and named, no recorded default sent (FR-041)" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-5", forward:{transition_id:null, candidates:[{id:"41",name:"Fermer"}], withheld_field:{logical_name:"Résolution",field_id:"resolution"}}}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"K-5"* ]]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"Résolution"* ]]
  # No transition body of any kind was constructed for this ticket.
  [ "$(jq '[.actions[] | select(.url == "http://h/rest/api/3/issue/K-5/transitions")] | length' <<< "$output")" -eq 0 ]
}

@test "a sub-task completed in Jira while its task is unchecked reports the divergence by key (FR-032)" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-6", already_done_diverged:true}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [ "$(jq '.warnings | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"K-6"* ]]
}

@test "an operator-authorised backward pull moves the sub-task back and still reports the divergence (FR-032)" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-7", already_done_diverged:true, backward:{transition_id:"21", candidates:[{id:"21",name:"En cours"}], withheld_field:null}}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$(jq '.actions | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.actions[0].body.transition.id' <<< "$output")" = "21" ]
  [ "$(jq '.warnings | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"K-7"* ]]
}

@test "without authorisation the backward pull never moves the sub-task, only the divergence is reported" {
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{t1:{key:"K-8", already_done_diverged:true, backward:null}}}')"
  run plan_lifecycle_tasks '[]' "${cc}"
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [ "$(jq '.warnings | length' <<< "$output")" -eq 1 ]
}

@test "the PowerShell port folds the task lifecycle rules byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps_abs; ps_abs="$(cd "${ROOT}/scripts/powershell/sink/jira" && pwd)"
  local content='[{"method":"PUT","url":"http://h/rest/api/3/issue/K-2","body":{"fields":{"summary":"New"}},"role":"task"}]'
  local cc
  cc="$(jq -cn '{base_url:"http://h", tasks:{
    t1:{key:"K-2", forward:{transition_id:"31", candidates:[{id:"31",name:"Terminé"}], withheld_field:null}},
    t2:{key:"K-7", already_done_diverged:true, backward:{transition_id:"21", candidates:[{id:"21",name:"En cours"}], withheld_field:null}, blockers:["K-9"]}
  }}')"
  local bash_out ps_out
  bash_out="$(plan_lifecycle_tasks "${content}" "${cc}")"
  ps_out="$(A="${content}" C="${cc}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraTaskLifecyclePlan -ContentActionsJson \$env:A -CompletionContextJson \$env:C))
  ")"
  [ "$bash_out" = "$ps_out" ]
}
