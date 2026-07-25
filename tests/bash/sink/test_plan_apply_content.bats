#!/usr/bin/env bats
# T052 [US3] — plan_writes content rules (FR-017, FR-018). The spec's P1/P2/P3
# priority resolves to the project priority field BY LOGICAL NAME; the declared
# estimation is written to the discovered estimation field ON CREATE ONLY and is
# NEVER re-sent on update. plan_writes produces the neutral action set; the
# PowerShell port emits an identical set (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
}

DOC='{
  "stories": [
    {"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},
     "acceptance_criteria":[{"given":["g"],"when":["w"],"then":["t"]}],
     "priority_logical":"P1","estimation":5}
  ]
}'

CTX_CREATE='{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "estimation_field_id":"customfield_30044",
  "tickets":{}
}'

CTX_UPDATE='{
  "base_url":"https://mock",
  "story_type_id":"10002",
  "priority_ids":{"P1":"1","P2":"2","P3":"3"},
  "estimation_field_id":"customfield_30044",
  "tickets":{"s1":"ABC-1"}
}'

@test "create action maps the P1 priority to the project priority id (FR-017)" {
  run plan_writes "${DOC}" "${CTX_CREATE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.[0].body.fields.priority.id' <<< "$output")" = "1" ]
}

@test "estimation is written on CREATE to the discovered field (FR-018)" {
  run plan_writes "${DOC}" "${CTX_CREATE}"
  [ "$(jq -r '.[0].body.fields.customfield_30044' <<< "$output")" = "5" ]
}

@test "the created story description carries the ADF panel (rich content)" {
  run plan_writes "${DOC}" "${CTX_CREATE}"
  [ "$(jq -r '.[0].body.fields.description.type' <<< "$output")" = "doc" ]
  [ "$(jq '[.[0].body.fields.description.content[] | select(.type=="panel")] | length' <<< "$output")" -eq 1 ]
}

@test "update action NEVER re-sends the estimation field (FR-018)" {
  run plan_writes "${DOC}" "${CTX_UPDATE}"
  [ "$(jq -r '.[0].method' <<< "$output")" = "PUT" ]
  [ "$(jq -r '.[0].url' <<< "$output")" = "https://mock/rest/api/3/issue/ABC-1" ]
  # No estimation field on update.
  [ "$(jq 'has("customfield_30044") | not' <<< "$(jq -c '.[0].body.fields' <<< "$output")")" = "true" ]
  # Priority is still updated.
  [ "$(jq -r '.[0].body.fields.priority.id' <<< "$output")" = "1" ]
}

@test "the PowerShell port produces an identical create action set (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(plan_writes "${DOC}" "${CTX_CREATE}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraPlanWriteSet -NeutralDocJson '$(printf '%s' "${DOC}" | jq -c .)' -PlanContextJson '$(printf '%s' "${CTX_CREATE}" | jq -c .)'))")"
  [ "${b}" = "${p}" ]
}
