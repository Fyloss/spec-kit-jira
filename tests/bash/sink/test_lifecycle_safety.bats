#!/usr/bin/env bats
# T069 [US6] — Jira-side lifecycle safety (FR-035, FR-036, FR-037). The lifecycle
# planner folds the drift decision, Flagged withholding, and human-link
# preservation over the planned content actions:
#   - A disk-phase regression against a post-scope ticket withholds the transition
#     by default (content still reconciles) and needs --on-drift=proceed.
#   - A Flagged ticket has its transition withheld and surfaced; the bridge NEVER
#     emits a flag set/remove.
#   - The bridge NEVER emits a link mutation, so human links are untouched; a
#     transition past open blockers adds an info note naming them, without blocking.
# plan_lifecycle is pure; the PowerShell port folds identically (proven in bats).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  DOC='{"stories":[{"local_id":"s1"}]}'
  # A content update that genuinely changes (kept unless a halt drops it).
  ACTIONS='[{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}]'
}

@test "a post-scope regression withholds the transition by default, content still reconciles (FR-035)" {
  local lc
  lc="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"Done", category:"post-scope", target:"To Do", transition_id:"11"}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  # The content PUT survives; NO transition action is emitted.
  [ "$(jq '[.actions[] | select(.method=="PUT")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"--on-drift=proceed"* ]]
}

@test "--on-drift=proceed pulls a regressed post-scope ticket backward (FR-035)" {
  local lc
  lc="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h", on_drift:"proceed",
    tickets:{s1:{key:"K-1", status:"Done", category:"post-scope", target:"To Do", transition_id:"11"}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 1 ]
}

@test "a Flagged ticket withholds its transition, surfaces the flag, and never sets or removes it (FR-036)" {
  local lc
  lc="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"In Progress", category:"mapped", target:"Done", transition_id:"31", flagged:true}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  # No transition emitted; the flag is surfaced in a warning.
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"Flagged"* ]]
  # The bridge emits NO flag mutation of any kind.
  [ "$(jq '[.actions[] | select((.url|test("flag";"i")) or (.body|tostring|test("impediment";"i")))] | length' <<< "$output")" -eq 0 ]
}

@test "human links are never mutated; a transition past open blockers adds an info note (FR-037)" {
  local lc
  lc="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"To Do", category:"mapped", target:"In Progress", transition_id:"21", blockers:["K-9","K-10"]}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  # The transition proceeds (forward move) …
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 1 ]
  # … the bridge emits NO link mutation (no DELETE, no issueLink endpoint) …
  [ "$(jq '[.actions[] | select((.method=="DELETE") or (.url|test("issueLink";"i")))] | length' <<< "$output")" -eq 0 ]
  # … and an info note names the open blockers without blocking the transition.
  [[ "$(jq -r '.notes[0]' <<< "$output")" == *"K-9"* ]]
  [[ "$(jq -r '.notes[0]' <<< "$output")" == *"K-10"* ]]
}

@test "T105 -- an unclassified status withholds the move while content still mirrors (U1)" {
  local lc
  lc="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"Weird Status", category:"unknown", target:"In Progress", transition_id:"21"}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  [ "$(jq '[.actions[] | select(.method=="PUT")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 0 ]
  [[ "$(jq -r '.warnings[0]' <<< "$output")" == *"unclassified"* ]]
}

@test "T107 -- a parent in a halted/Flagged/backward-drift situation produces the SAME warning wording as a story (U8)" {
  # The parent and a story share the SAME per-ticket body by construction
  # (023, research R6) — this test proves it concretely for two rules
  # rather than merely asserting the architecture.
  local doc2 actions2 parent_action2
  doc2="$(jq -cn '{stories:[{local_id:"s1"}]}')"
  actions2='[{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}]'
  parent_action2='{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}'

  local lc_story lc_parent
  lc_story="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"Blocked", category:"halted", target:"In Progress", transition_id:"21"}}}')"
  lc_parent="$(jq -cn '{order:{specification:["To Do","In Progress","Done"]}, base_url:"http://h", parent_local_id:"s1",
    tickets:{s1:{key:"K-1", status:"Blocked", category:"halted", target:"In Progress", transition_id:"21", role:"specification"}}}')"

  local story_out parent_out
  story_out="$(plan_lifecycle "${actions2}" "${doc2}" "${lc_story}")"
  parent_out="$(plan_lifecycle '[]' '{"stories":[]}' "${lc_parent}" "${parent_action2}")"

  local story_warn parent_warn
  story_warn="$(jq -r '.warnings[0]' <<< "${story_out}")"
  parent_warn="$(jq -r '.warnings[0]' <<< "${parent_out}")"
  [ "${story_warn}" = "${parent_warn}" ]
  [[ "${story_warn}" == *"halted"* ]]
}

@test "a halted parent's content write is dropped exactly like a halted story's (U8, contract §5)" {
  # A story's halted content is dropped by exclusion from .actions (kept
  # unconditionally excludes the parent, since the parent's write is a
  # SEPARATE code path in the caller) — the parent instead needs its own
  # explicit signal, parent_content_dropped, or the caller has no way to
  # learn a halted parent's content must stay unwritten too.
  local parent_action2
  parent_action2='{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}'
  local lc_parent
  lc_parent="$(jq -cn '{order:{specification:["To Do","In Progress","Done"]}, base_url:"http://h", parent_local_id:"s1",
    tickets:{s1:{key:"K-1", status:"Blocked", category:"halted", target:"In Progress", transition_id:"21", role:"specification"}}}')"
  run plan_lifecycle '[]' '{"stories":[]}' "${lc_parent}" "${parent_action2}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent_content_dropped' <<< "$output")" = "true" ]
}

@test "an UNhalted parent's content write is kept (parent_content_dropped stays false)" {
  local parent_action2
  parent_action2='{"method":"PUT","url":"http://h/rest/api/3/issue/K-1","body":{"fields":{"summary":"New"}}}'
  local lc_parent
  lc_parent="$(jq -cn '{order:{specification:["To Do","In Progress","Done"]}, base_url:"http://h", parent_local_id:"s1",
    tickets:{s1:{key:"K-1", status:"To Do", category:"mapped", target:"In Progress", transition_id:"21", role:"specification"}}}')"
  run plan_lifecycle '[]' '{"stories":[]}' "${lc_parent}" "${parent_action2}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent_content_dropped' <<< "$output")" = "false" ]
}

@test "the PowerShell port folds the lifecycle rules byte-identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps_abs; ps_abs="$(cd "${ROOT}/scripts/powershell/sink/jira" && pwd)"
  local lc
  lc="$(jq -cn '{order:{story:["To Do","In Progress","Done"]}, base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"To Do", category:"mapped", target:"In Progress", transition_id:"21", blockers:["K-9"]}}}')"
  local bash_out ps_out
  bash_out="$(plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}")"
  ps_out="$(A="${ACTIONS}" D="${DOC}" L="${lc}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraLifecyclePlan -ContentActionsJson \$env:A -NeutralDocJson \$env:D -LifecycleContextJson \$env:L))
  ")"
  [ "$bash_out" = "$ps_out" ]
}
