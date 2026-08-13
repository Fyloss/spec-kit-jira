#!/usr/bin/env bats
# 018, T070 [US2] — FR-023, contract managed-description §4, summary-record
# §2: a ticket whose content write is suppressed acquires no boundary on
# that run, and acquires it on the first run allowed to write.
#
# Clarified (spec.md, "Clarifications", session 2026-08-05): of the three
# causes FR-023 names, only `halted` actually suppresses content today —
# `drift.sh`'s own contract (FR-035/FR-036, feature 015/016, proven in
# tests/bash/sink/test_lifecycle_safety.bats) withholds ONLY the transition
# for a flagged ticket or an unresolved-drift ticket; their content,
# including the boundary, keeps reconciling exactly as before this feature.
# This file proves both halves: `halted` withholds the boundary (and
# everything else) entirely, and neither the flag nor unresolved drift
# regressed into doing the same.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  MARKER="$(adf_managed_marker)"
  DOC='{"stories":[{"local_id":"s1"}]}'
  # A content update carrying the fresh boundary a migration would render —
  # the shape plan_writes now produces unconditionally (018, T026).
  BOUNDARY_BODY="$(jq -cn --arg m "${MARKER}" '{fields:{summary:"Story One", description:{type:"doc", version:1, content:[
    {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]},
    {type:"paragraph", content:[{type:"text", text:"Story body."}]}
  ]}}}')"
  ACTIONS="$(jq -cn --argjson b "${BOUNDARY_BODY}" '[{method:"PUT", url:"http://h/rest/api/3/issue/K-1", body:$b}]')"
  # The ticket's current description carries no marker — the run would
  # otherwise be a first-time migration (a genuine content change), so
  # dropping it can only be attributed to the suppression, never to
  # zero-churn.
  CURRENT_DESC='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"stale"}]}]}'
}

@test "T070 (FR-023) — a halted ticket acquires no boundary on this run" {
  local lc
  lc="$(jq -cn --argjson cur "${CURRENT_DESC}" '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"Blocked", category:"halted", target:"In Progress", transition_id:"11",
              current:{summary:"Story One", description:$cur}}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  [ "$(jq '.actions | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"halted"* ]]
}

@test "T070 (FR-023) — the SAME ticket acquires the boundary on the first run it is allowed to write" {
  local lc
  lc="$(jq -cn --argjson cur "${CURRENT_DESC}" '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"In Progress", category:"mapped", target:"In Progress",
              current:{summary:"Story One", description:$cur}}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  [ "$(jq '.actions | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -c '.actions[0].body.fields.description' <<< "$output")" == *"${MARKER}"* ]]
}

@test "T070 (FR-023) — a flagged ticket's boundary still reconciles; only its transition is withheld (FR-036 unaffected)" {
  local lc
  lc="$(jq -cn --argjson cur "${CURRENT_DESC}" '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"In Progress", category:"mapped", target:"Done", transition_id:"31", flagged:true,
              current:{summary:"Story One", description:$cur}}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  [ "$(jq '[.actions[] | select(.method=="PUT")] | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -c '.actions[0].body.fields.description' <<< "$output")" == *"${MARKER}"* ]]
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 0 ]
}

@test "T070 (FR-023) — an unresolved-drift ticket's boundary still reconciles; only its transition is withheld (FR-035 unaffected)" {
  local lc
  lc="$(jq -cn --argjson cur "${CURRENT_DESC}" '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"Done", category:"post-scope", target:"To Do", transition_id:"11",
              current:{summary:"Story One", description:$cur}}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  [ "$(jq '[.actions[] | select(.method=="PUT")] | length' <<< "$output")" -eq 1 ]
  [[ "$(jq -c '.actions[0].body.fields.description' <<< "$output")" == *"${MARKER}"* ]]
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"--on-drift=proceed"* ]]
}

@test "the PowerShell port folds the halted-suppression rule byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps_abs; ps_abs="$(cd "${ROOT}/scripts/powershell/sink/jira" && pwd)"
  local lc
  lc="$(jq -cn --argjson cur "${CURRENT_DESC}" '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"Blocked", category:"halted", target:"In Progress", transition_id:"11",
              current:{summary:"Story One", description:$cur}}}}')"
  local bash_out ps_out
  bash_out="$(plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}")"
  ps_out="$(A="${ACTIONS}" D="${DOC}" L="${lc}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraLifecyclePlan -ContentActionsJson \$env:A -NeutralDocJson \$env:D -LifecycleContextJson \$env:L))
  ")"
  [ "$bash_out" = "$ps_out" ]
}
