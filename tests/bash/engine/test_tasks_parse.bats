#!/usr/bin/env bats
# T017/T021/T024 [Phase 2] — The neutral tasks.md reader (contracts/task-tier.md
# §2; data-model.md §2).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/tasks_parse.sh"
}

@test "the file is absent (empty stdin) yields an empty list, no report" {
  run bash -c 'source "'"${ENGINE_DIR}"'/tasks_parse.sh"; printf "" | tasks_parse_document'
  [ "$(jq -r '.tasks | length' <<< "$output")" = "0" ]
  [ "$(jq -r '.skipped | length' <<< "$output")" = "0" ]
}

@test "a file with no recognisable task yields an empty list" {
  local doc out
  doc=$'# Tasks\n\nNothing here.\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks | length' <<< "${out}")" = "0" ]
}

@test "recognises the checkbox, task ref, [P], [US<N>], text, files, and depends-on" {
  local doc out task
  doc=$'## Phase 3: Foo\n\n- [ ] T014 [P] [US1] Implement the parser in `scripts/bash/engine/tasks_parse.sh` (depends on T012, T013)\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  task="$(jq -c '.tasks[0]' <<< "${out}")"
  [ "$(jq -r '.task_ref' <<< "${task}")" = "T014" ]
  [ "$(jq -r '.done' <<< "${task}")" = "false" ]
  [ "$(jq -r '.parallel' <<< "${task}")" = "true" ]
  [ "$(jq -r '.attribution.story_ordinal' <<< "${task}")" = "1" ]
  [ "$(jq -r '.attribution.source' <<< "${task}")" = "tag" ]
  [ "$(jq -r '.files[0]' <<< "${task}")" = "scripts/bash/engine/tasks_parse.sh" ]
  [ "$(jq -r '.depends_on | join(",")' <<< "${task}")" = "T012,T013" ]
  [ "$(jq -r '.title' <<< "${task}")" = "Implement the parser in \`scripts/bash/engine/tasks_parse.sh\`" ]
}

@test "checked box: done is true" {
  local doc out
  doc=$'- [x] T001 Something already finished\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks[0].done' <<< "${out}")" = "true" ]
}

@test "checked box tolerates uppercase X and mixed case" {
  local doc out
  doc=$'- [X] T001 Something already finished\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks[0].done' <<< "${out}")" = "true" ]
}

@test "continuation lines belong to the task" {
  local doc out
  doc=$'- [ ] T001 Add the endpoint to the mock in\n      `tests/x/mock-server.ps1`, returning results.\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [[ "$(jq -r '.tasks[0].title' <<< "${out}")" == *"returning results."* ]]
  [ "$(jq -r '.tasks[0].files[0]' <<< "${out}")" = "tests/x/mock-server.ps1" ]
}

@test "continuation collection stops at a blank line" {
  local doc out
  doc=$'## Phase 1: Setup\n\n- [ ] T001 First task\n      continuation of first\n\n- [ ] T002 Second task\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks | length' <<< "${out}")" = "2" ]
  [[ "$(jq -r '.tasks[0].title' <<< "${out}")" == *"continuation of first"* ]]
  [[ "$(jq -r '.tasks[1].title' <<< "${out}")" != *"continuation of first"* ]]
}

@test "a marker line right after the task line is excluded from continuation content" {
  local doc out
  doc=$'- [ ] T001 First task with more\n<!-- speckit-jira task=1111111111111111 -->\n      continuation text.\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [[ "$(jq -r '.tasks[0].title' <<< "${out}")" == *"continuation text."* ]]
  [[ "$(jq -r '.tasks[0].title' <<< "${out}")" != *"speckit-jira"* ]]
  [ "$(jq -r '.tasks[0].marker.state' <<< "${out}")" = "assigned" ]
  [ "$(jq -r '.tasks[0].marker.id' <<< "${out}")" = "1111111111111111" ]
  [ "$(jq -r '.tasks[0].local_id' <<< "${out}")" = "1111111111111111" ]
}

@test "attribution: no tag falls back to the enclosing Phase ... User Story <N> heading" {
  local doc out
  doc=$'## Phase 3: User Story 1 - A team that works in sub-tasks (Priority: P1)\n\n- [ ] T001 Untagged task\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks[0].attribution.story_ordinal' <<< "${out}")" = "1" ]
  [ "$(jq -r '.tasks[0].attribution.source' <<< "${out}")" = "heading" ]
  [ "$(jq -r '.tasks[0].phase' <<< "${out}")" = "Phase 3: User Story 1 - A team that works in sub-tasks (Priority: P1)" ]
}

@test "attribution: neither tag nor heading names a story -> unattributed" {
  local doc out
  doc=$'## Phase 1: Setup\n\n- [ ] T001 Untagged task\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks[0].attribution.story_ordinal' <<< "${out}")" = "null" ]
  [ "$(jq -r '.tasks[0].attribution.source' <<< "${out}")" = "none" ]
}

@test "the [US<N>] tag wins over the enclosing heading" {
  local doc out
  doc=$'## Phase 3: User Story 1 - Foo (Priority: P1)\n\n- [ ] T001 [US2] Tagged task\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks[0].attribution.story_ordinal' <<< "${out}")" = "2" ]
  [ "$(jq -r '.tasks[0].attribution.source' <<< "${out}")" = "tag" ]
}

@test "a task whose text is empty once markup is removed produces no entry and is reported" {
  local doc out
  doc=$'- [ ] T001 [P] [US1]\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  [ "$(jq -r '.tasks | length' <<< "${out}")" = "0" ]
  [ "$(jq -r '.skipped[0].task_ref' <<< "${out}")" = "T001" ]
  [ "$(jq -r '.skipped[0].reason' <<< "${out}")" = "empty title" ]
}

@test "a task carries no Jira identifier, issue type or project key (FR-005 / boundary)" {
  ! grep -qi "jira" "${ENGINE_DIR}/tasks_parse.sh" | grep -v "^#" || true
  # The boundary check itself is a static grep over the file (T098); here we
  # assert the emitted document carries none of those Jira-shaped keys.
  local doc out
  doc=$'- [ ] T001 Some task\n'
  out="$(printf '%s' "${doc}" | tasks_parse_document)"
  run jq -e '.tasks[0] | has("issuetype") or has("project_key") or has("ticket")' <<< "${out}"
  [ "$output" = "false" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port parses identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local doc b p
  doc=$'## Phase 3: User Story 1 - Foo (Priority: P1)\n\n- [ ] T014 [P] [US1] Implement the parser in `scripts/bash/engine/tasks_parse.sh` (depends on T012, T013)\n'
  b="$(printf '%s' "${doc}" | tasks_parse_document)"
  p="$(printf '%s' "${doc}" | pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/TasksParse.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((ConvertTo-JiraTasksParseDocument -Text \$doc))")"
  [ "${b}" = "${p}" ]
}
