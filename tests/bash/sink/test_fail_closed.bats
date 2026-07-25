#!/usr/bin/env bats
# T067 [US6] — Fail-closed writes (FR-032). An unreliable Jira endpoint (auth
# failure, network error, 404, exhausted 429 retries) must cause zero applied
# writes for the affected spec and a documented, monotonically escalating exit
# code (auth 3, everything else fail-closed 2). A fault mid-sequence ABORTS the
# remaining writes for the spec — no further mutation is attempted once a call is
# unreliable. The PowerShell port fails closed with the identical codes (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

_put() { # _put <issue-key> — a clean PUT action targeting one issue key.
  jq -cn --arg u "${MOCK_BASE_URL}/rest/api/3/issue/$1" '{method:"PUT", url:$u, body:{fields:{summary:"x"}}}'
}

@test "a 401 write fails closed with the auth exit code (3)" {
  mock_start "${MOCK}/configs/faults.json"
  local actions; actions="[$(_put AUTH-1)]"
  run apply_writes "${actions}"
  [ "$status" -eq 3 ]
}

@test "a 404 write fails closed (2)" {
  mock_start "${MOCK}/configs/faults.json"
  run apply_writes "[$(_put MISSING-1)]"
  [ "$status" -eq 2 ]
}

@test "a dropped connection fails closed (2)" {
  mock_start "${MOCK}/configs/faults.json"
  run apply_writes "[$(_put NET-1)]"
  [ "$status" -eq 2 ]
}

@test "an exhausted 429 fails closed (2)" {
  mock_start "${MOCK}/configs/faults.json"
  JIRA_MAX_ATTEMPTS=3 run apply_writes "[$(_put RATE-1)]"
  [ "$status" -eq 2 ]
}

@test "a fault aborts the remaining writes — the second action is never attempted" {
  mock_start "${MOCK}/configs/faults.json"
  # AUTH-1 (401) precedes COMP-9 (would succeed). The abort must stop before COMP-9.
  local actions
  actions="$(jq -cn --argjson a "$(_put AUTH-1)" --argjson b "$(_put COMP-9)" '[$a,$b]')"
  run apply_writes "${actions}"
  [ "$status" -eq 3 ]
  run mock_calls
  [ "$(printf '%s\n' "$output" | grep -c 'issue/AUTH-1')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'issue/COMP-9')" -eq 0 ]
}

@test "the PowerShell port fails closed with identical codes (NFR-1)" {
  mock_start "${MOCK}/configs/faults.json"
  local ps_abs; ps_abs="$(cd "${PS_SINK}" && pwd)"
  local key code_bash code_ps
  for key in AUTH-1 MISSING-1 NET-1; do
    local actions; actions="[$(_put "${key}")]"
    code_bash=0; apply_writes "${actions}" || code_bash=$?
    code_ps="$(ACT="${actions}" pwsh -NoProfile -Command "
      \$env:JIRA_EMAIL='user@example.com'; \$env:JIRA_API_TOKEN='RAWSECRETXYZ'; \$env:JIRA_NO_SLEEP='1'
      Import-Module '${ps_abs}/PlanApply.psm1' -Force
      [Console]::Out.Write((Invoke-JiraApplyWriteSet -ActionsJson \$env:ACT))
    ")"
    [ "${code_bash}" -eq "${code_ps}" ]
  done
}
