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
  lc="$(jq -cn '{order:["To Do","In Progress","Done"], base_url:"http://h",
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
  lc="$(jq -cn '{order:["To Do","In Progress","Done"], base_url:"http://h", on_drift:"proceed",
    tickets:{s1:{key:"K-1", status:"Done", category:"post-scope", target:"To Do", transition_id:"11"}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$(jq '[.actions[] | select(.url|endswith("/transitions"))] | length' <<< "$output")" -eq 1 ]
}

@test "a Flagged ticket withholds its transition, surfaces the flag, and never sets or removes it (FR-036)" {
  local lc
  lc="$(jq -cn '{order:["To Do","In Progress","Done"], base_url:"http://h",
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
  lc="$(jq -cn '{order:["To Do","In Progress","Done"], base_url:"http://h",
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

# --- an ADOPTED ticket is never hard-deleted (003 T108, FR-017) --------------

@test "an adopted ticket is never hard-deleted — the write path emits no DELETE at all" {
  # An adopted ticket carries origin `human`, and a human-origin ticket is
  # excluded from hard deletion for the rest of its life (003 FR-017). The
  # guarantee is STRUCTURAL here: the bridge has no delete path whatsoever, so
  # there is nothing an adopted ticket could fall through into.
  local lc
  lc="$(jq -cn '{order:["To Do","In Progress","Done"], base_url:"http://h",
    tickets:{s1:{key:"K-1", origin:"human", status:"Done", category:"post-scope",
                 target:"To Do", transition_id:"11"}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  [ "$(jq '[.actions[] | select(.method == "DELETE")] | length' <<< "$output")" -eq 0 ]
}

@test "no module in the write path can emit a hard deletion (003 T108, FR-017)" {
  # The exclusion cannot be forgotten because the capability does not exist:
  # neither port's sources contain a DELETE verb anywhere.
  run bash -c "grep -rlE '\"DELETE\"|'\''DELETE'\''|-Method[[:space:]]+DELETE' '${ROOT}/scripts' | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "the most a prune may do to an adopted ticket is detach its identity (FR-017)" {
  # If a future prune ever runs, the ONLY endpoint it could touch on a
  # human-origin ticket is the identity property — never the issue itself.
  local lc
  lc="$(jq -cn '{order:[], base_url:"http://h",
    tickets:{s1:{key:"K-1", origin:"human"}}}')"
  run plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}"
  [ "$status" -eq 0 ]
  # Every emitted action targets the issue for CONTENT; none removes it.
  [ "$(jq '[.actions[] | select(.method == "DELETE" or (.url | test("/archive|/delete")))] | length' <<< "$output")" -eq 0 ]
}

@test "the PowerShell port folds the lifecycle rules byte-identically (NFR-1)" {
  local ps_abs; ps_abs="$(cd "${ROOT}/scripts/powershell/sink/jira" && pwd)"
  local lc
  lc="$(jq -cn '{order:["To Do","In Progress","Done"], base_url:"http://h",
    tickets:{s1:{key:"K-1", status:"To Do", category:"mapped", target:"In Progress", transition_id:"21", blockers:["K-9"]}}}')"
  local bash_out ps_out
  bash_out="$(plan_lifecycle "${ACTIONS}" "${DOC}" "${lc}")"
  ps_out="$(A="${ACTIONS}" D="${DOC}" L="${lc}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraLifecyclePlan -ContentActionsJson \$env:A -NeutralDocJson \$env:D -LifecycleContextJson \$env:L))
  ")"
  [ "$bash_out" = "$ps_out" ]
}
