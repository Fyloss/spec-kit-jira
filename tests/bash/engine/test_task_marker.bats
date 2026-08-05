#!/usr/bin/env bats
# T007/T011 [Phase 2] — The durable task identifier: generation, grammar, and
# the byte-preserving splice into tasks.md (contracts/task-tier.md §1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/task_marker.sh"
}

# --- Grammar: valid / ignored / malformed -----------------------------------

@test "valid form: task= alone" {
  run task_marker_parse_line '<!-- speckit-jira task=7f3a9c1e40b2d85a -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "assigned" ]
  [ "$(jq -r '.id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
}

@test "valid form: task= + ticket=" {
  run task_marker_parse_line '<!-- speckit-jira task=7f3a9c1e40b2d85a ticket=PROJ-412 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "bound" ]
  [ "$(jq -r '.ticket' <<< "$output")" = "PROJ-412" ]
}

@test "valid form: task= + creating" {
  run task_marker_parse_line '<!-- speckit-jira task=7f3a9c1e40b2d85a creating -->'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.state' <<< "$output")" = "creating" ]
}

@test "a story= body parses as none here (non-collision)" {
  run task_marker_parse_line '<!-- speckit-jira story=7f3a9c1e40b2d85a -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "a spec= body parses as none here (non-collision)" {
  run task_marker_parse_line '<!-- speckit-jira spec=7f3a9c1e40b2d85a -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "ignored: identifier fails the shape" {
  run task_marker_parse_line '<!-- speckit-jira task=NOTHEX -->'
  [ "$(jq -r '.kind' <<< "$output")" = "none" ]
}

@test "malformed: ticket key fails the shape" {
  run task_marker_parse_line '<!-- speckit-jira task=7f3a9c1e40b2d85a ticket=proj-412 -->'
  [ "$(jq -r '.kind' <<< "$output")" = "malformed" ]
  [ "$(jq -r '.id' <<< "$output")" = "7f3a9c1e40b2d85a" ]
}

@test "reading tolerates extra whitespace and a trailing CR" {
  run task_marker_parse_line $'<!--   speckit-jira   task=7f3a9c1e40b2d85a   ticket=PROJ-412   -->\r'
  [ "$(jq -r '.kind' <<< "$output")" = "valid" ]
  [ "$(jq -r '.ticket' <<< "$output")" = "PROJ-412" ]
}

# --- Splice: assignment -------------------------------------------------------

@test "assign inserts a marker line immediately after each unmarked task line" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222"
  local doc out
  doc=$'- [ ] T001 [P] First task\n\n- [ ] T002 [P] Second task\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *$'- [ ] T001 [P] First task\n<!-- speckit-jira task=1111111111111111 -->'* ]]
  [[ "${out}" == *$'- [ ] T002 [P] Second task\n<!-- speckit-jira task=2222222222222222 -->'* ]]
}

@test "a file with no recognisable task yields no anchors and is returned unchanged" {
  local doc out
  doc=$'# Tasks\n\nNothing to see here.\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

@test "assign is idempotent: a fully-marked document is returned byte-identical" {
  local doc out
  doc=$'- [ ] T001 First task\n<!-- speckit-jira task=1111111111111111 -->\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

@test "assign never disturbs a byte outside the inserted lines" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  local doc out
  doc=$'- [ ] T001   Weird   spacing\n\n  Indented continuation.\n\ttab continuation.\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *$'  Indented continuation.\n\ttab continuation.'* ]]
}

@test "assign adopts CRLF when the file is dominantly CRLF" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  local doc out
  doc=$'- [ ] T001 First task\r\n\r\nBody.\r\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira task=1111111111111111 -->"$'\r\n'* ]]
}

@test "a malformed marker attempt still counts as present: assign adds no second marker" {
  local doc out
  doc=$'- [ ] T001 First task\n<!-- speckit-jira task=NOTHEX-BUT-LOOKS-LIKE-ONE ticket=bad -->\n'
  # The "id" here fails the hex shape so the WHOLE line parses as "none" —
  # use a valid-id/bad-tail form instead to exercise "malformed still counts".
  doc=$'- [ ] T001 First task\n<!-- speckit-jira task=1111111111111111 ticket=bad -->\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

@test "descending insertion order means an earlier anchor's line number is never shifted" {
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  local doc out
  doc=$'- [ ] T001 First\n- [ ] T002 Second\n- [ ] T003 Third\n'
  out="$(printf '%s' "${doc}" | task_marker_assign; printf x)"; out="${out%x}"
  [[ "${out}" == *$'- [ ] T001 First\n<!-- speckit-jira task=1111111111111111 -->\n- [ ] T002 Second\n<!-- speckit-jira task=2222222222222222 -->\n- [ ] T003 Third\n<!-- speckit-jira task=3333333333333333 -->'* ]]
}

# --- Splice: state transitions ------------------------------------------------

@test "mark_creating replaces a bare assigned line with the creating state" {
  local doc out
  doc=$'- [ ] T001 First task\n<!-- speckit-jira task=1111111111111111 -->\n'
  out="$(printf '%s' "${doc}" | task_marker_mark_creating '["1111111111111111"]'; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira task=1111111111111111 creating -->"* ]]
  [[ "${out}" != *"<!-- speckit-jira task=1111111111111111 -->"* ]]
}

@test "record_ticket replaces a creating line with the bound state" {
  local doc out
  doc=$'- [ ] T001 First task\n<!-- speckit-jira task=1111111111111111 creating -->\n'
  out="$(printf '%s' "${doc}" | task_marker_record_ticket "1111111111111111" "PROJ-412"; printf x)"; out="${out%x}"
  [[ "${out}" == *"<!-- speckit-jira task=1111111111111111 ticket=PROJ-412 -->"* ]]
}

@test "record_ticket is a no-op when the id has no marker line" {
  local doc out
  doc=$'- [ ] T001 First task\n'
  out="$(printf '%s' "${doc}" | task_marker_record_ticket "1111111111111111" "PROJ-412"; printf x)"; out="${out%x}"
  [ "${out}" = "${doc}" ]
}

@test "task_marker_section_info reports duplicate when a task's own span carries two marker attempts" {
  local doc info
  doc=$'- [ ] T001 First task\n<!-- speckit-jira task=1111111111111111 -->\n<!-- speckit-jira task=2222222222222222 -->\n'
  info="$(task_marker_section_info "${doc}" 2 3)"
  [ "$(jq -r '.state' <<< "${info}")" = "duplicate" ]
}

# --- Cross-port parity --------------------------------------------------------

@test "the PowerShell port assigns byte-identical markers (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222"
  local doc b p
  doc=$'- [ ] T001 First task\n\n- [ ] T002 Second task\n'
  b="$(printf '%s' "${doc}" | task_marker_assign)"
  p="$(printf '%s' "${doc}" | SPEC_KIT_JIRA_ID_SOURCE='1111111111111111 2222222222222222' pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/TaskMarker.psm1' -Force
    \$doc = [Console]::In.ReadToEnd()
    [Console]::Out.Write((Set-JiraTaskMarkerAssign -Text \$doc))")"
  [ "${b}" = "${p}" ]
}

@test "the PowerShell port parses grammar identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local p
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/TaskMarker.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraTaskMarkerInfo -Line '<!-- speckit-jira task=7f3a9c1e40b2d85a ticket=PROJ-412 -->'))")"
  [ "$(jq -r '.kind' <<< "${p}")" = "valid" ]
  [ "$(jq -r '.ticket' <<< "${p}")" = "PROJ-412" ]
}
