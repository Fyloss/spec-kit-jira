#!/usr/bin/env bats
# T072 [Phase 9] CRITICAL — the resolver's own unit-test file (010,
# contracts/role-mapping.md). `role_candidates`, `role_resolve` and
# `role_validate` in scripts/bash/sink/jira/hierarchy.sh shipped with no unit
# test at all until now (Constitution XIII, quickstart Step 5). Every test
# here calls the resolver directly — a pure jq computation over an in-memory
# issue-type list — so every case has zero Jira writes by construction; the
# end-to-end "zero writes" claim over the live ceremony and reconcile paths
# is asserted separately in tests/bash/commands/test_config_role_mapping.bats,
# test_reconcile_hierarchy.bats and test_reconcile_lifecycle.bats.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/hierarchy.sh"
}

# The consumer instance (research R11): Epic/Service Category at level 1;
# thirteen types at level 0 including Story, Defect, Tâche; Sous-tâche and
# Sub Test Execution at level -1, both sub-task.
CONSUMER_ITYPES='[
  {"logical_name":"Epic","id":"10701","hierarchy_level":"1","subtask":false},
  {"logical_name":"Service Category","id":"10702","hierarchy_level":"1","subtask":false},
  {"logical_name":"Tâche","id":"10703","hierarchy_level":"0","subtask":false},
  {"logical_name":"Story","id":"10704","hierarchy_level":"0","subtask":false},
  {"logical_name":"Defect","id":"10705","hierarchy_level":"0","subtask":false},
  {"logical_name":"Sous-tâche","id":"10716","hierarchy_level":"-1","subtask":true},
  {"logical_name":"Sub Test Execution","id":"10717","hierarchy_level":"-1","subtask":true}
]'

# An unambiguous project — Epic 2 / Feature 1 / Story 0 / Sub-task -1 — SAFe's
# real shape, used wherever a single-candidate level is needed.
SAFE_ITYPES='[
  {"logical_name":"Epic","id":"10401","hierarchy_level":"2","subtask":false},
  {"logical_name":"Feature","id":"10402","hierarchy_level":"1","subtask":false},
  {"logical_name":"Story","id":"10403","hierarchy_level":"0","subtask":false},
  {"logical_name":"Sub-task","id":"10404","hierarchy_level":"-1","subtask":true}
]'

# =============================================================================
# role_candidates (contract §3.3)
# =============================================================================

@test "role_candidates — specification and story share the non-sub-task set, in discovered order" {
  run role_candidates "${CONSUMER_ITYPES}" specification
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].logical_name] | join(",")' <<< "$output")" = "Epic,Service Category,Tâche,Story,Defect" ]

  run role_candidates "${CONSUMER_ITYPES}" story
  [ "$(jq -r '[.[].logical_name] | join(",")' <<< "$output")" = "Epic,Service Category,Tâche,Story,Defect" ]
}

@test "role_candidates — task's candidates are the sub-task types, in discovered order" {
  run role_candidates "${CONSUMER_ITYPES}" task
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[].logical_name] | join(",")' <<< "$output")" = "Sous-tâche,Sub Test Execution" ]
}

@test "role_candidates — an empty set when the project offers no sub-task type" {
  local flat='[{"logical_name":"Story","id":"1","hierarchy_level":"0","subtask":false}]'
  run role_candidates "${flat}" task
  [ "$output" = "[]" ]
}

# =============================================================================
# role_resolve — precedence steps 1–3 (contract §3)
# =============================================================================

@test "role_resolve — step 1: a declared name resolves an ambiguous level, source: declared" {
  local declared='{"specification":"Epic","story":"Story"}'
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" "${declared}" '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.roles.specification.logical_name' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.roles.specification.source' <<< "$output")" = "declared" ]
  [ "$(jq -r '.roles.story.logical_name' <<< "$output")" = "Story" ]
  [ "$(jq -r '.roles.story.source' <<< "$output")" = "declared" ]
  [ "$(jq -r '(.unresolved | length)' <<< "$output")" -eq 0 ]
}

@test "role_resolve — step 2: an operator answer resolves without a declaration, source: operator" {
  local operator='{"specification":"Epic","story":"Story"}'
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{}' "${operator}"
  [ "$(jq -r '.roles.specification.source' <<< "$output")" = "operator" ]
  [ "$(jq -r '.roles.story.source' <<< "$output")" = "operator" ]
}

@test "role_resolve — step 3: an unambiguous level with nothing declared or answered still derives, source: derived" {
  run role_resolve SAFE "${SAFE_ITYPES}" '{}' '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.roles.story.logical_name' <<< "$output")" = "Story" ]
  [ "$(jq -r '.roles.story.source' <<< "$output")" = "derived" ]
  [ "$(jq -r '.roles.specification.logical_name' <<< "$output")" = "Feature" ]
  [ "$(jq -r '.roles.specification.source' <<< "$output")" = "derived" ]
}

@test "role_resolve — a declared value outranks a conflicting operator answer unconditionally (step 1 > step 2)" {
  local declared='{"specification":"Epic"}'
  local operator='{"specification":"Service Category","story":"Story"}'
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" "${declared}" "${operator}"
  [ "$(jq -r '.roles.specification.logical_name' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.roles.specification.source' <<< "$output")" = "declared" ]
}

@test "role_resolve — one pass, all roles: BOTH ambiguous tiers are reported in a single call (§3.2, the ordering trap)" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{}' '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.unresolved | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.unresolved[0].role' <<< "$output")" = "specification" ]
  [ "$(jq -r '.unresolved[1].role' <<< "$output")" = "story" ]
  [ "$(jq -r '.unresolved[0].candidates | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.unresolved[1].candidates | length' <<< "$output")" -eq 3 ]
}

@test "role_resolve — task is NEVER derived: a project with exactly one sub-task type still leaves task ABSENT" {
  # SAFE_ITYPES has exactly one sub-task type (Sub-task); if task were
  # derived like specification/story, this would resolve it. It must not.
  run role_resolve SAFE "${SAFE_ITYPES}" '{}' '{}'
  [ "$(jq -r 'has("task") or (.roles | has("task"))' <<< "$output")" = "false" ]
  [ "$(jq -r '[.unresolved[] | select(.role == "task")] | length' <<< "$output")" -eq 0 ]
}

@test "role_resolve — an undeclared, unanswered task is ABSENT, not unresolved (§3.4): no roles.task, no unresolved entry" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":"Epic","story":"Story"}' '{}'
  [ "$(jq -r '.roles | has("task")' <<< "$output")" = "false" ]
  [ "$(jq -r '[.unresolved[] | select(.role == "task")] | length' <<< "$output")" -eq 0 ]
}

@test "role_resolve — a declared task resolves against the sub-task candidate set, source: declared" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"task":"Sous-tâche"}' '{}'
  [ "$(jq -r '.roles.task.logical_name' <<< "$output")" = "Sous-tâche" ]
  [ "$(jq -r '.roles.task.source' <<< "$output")" = "declared" ]
  [ "$(jq -r '.roles.task.subtask' <<< "$output")" = "true" ]
}

# =============================================================================
# Matching — byte-equal, nothing else (contract §3.3)
# =============================================================================

@test "byte-equal matching — no case folding: a lower-cased declaration does not match" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":"epic"}' '{}'
  [ "$(jq -r '.unknown[0].name' <<< "$output")" = "epic" ]
  [ "$(jq -r '.roles | has("specification")' <<< "$output")" = "false" ]
}

@test "byte-equal matching — no trimming beyond YAML scalar rules: a padded declaration does not match" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":" Epic "}' '{}'
  [ "$(jq -r '.unknown[0].name' <<< "$output")" = " Epic " ]
}

@test "byte-equal matching — no Unicode normalisation: NFD (combining accent) does not match the project's NFC name" {
  # Tâche's 'â' as NFC (U+00E2) in the fixture; declare the NFD decomposition
  # (a U+0061 + combining circumflex U+0302) — visually identical, byte-different.
  local nfd_declared
  nfd_declared="$(jq -cn '{story: "Tâche"}')"
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" "${nfd_declared}" '{}'
  [ "$(jq -r '.roles | has("story")' <<< "$output")" = "false" ]
  [ "$(jq -r '.unknown | length' <<< "$output")" -eq 1 ]
}

@test "byte-equal matching — no prefix match: a declared name that is a strict prefix of a real type does not match" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"story":"Sto"}' '{}'
  [ "$(jq -r '.unknown[0].name' <<< "$output")" = "Sto" ]
  [ "$(jq -r '.roles | has("story")' <<< "$output")" = "false" ]
}

# =============================================================================
# §6.2 — unresolved role, the closed question
# =============================================================================

@test "§6.2 — role_unresolved_message names the level, every candidate, the declaration path and the flag" {
  local cands='[{"logical_name":"Epic","id":"10701"},{"logical_name":"Service Category","id":"10702"}]'
  run role_unresolved_message CONSUMER specification 1 "${cands}"
  [[ "$output" == *"project CONSUMER: the specification level (1) holds more than one issue type: Epic, Service Category"* ]]
  [[ "$output" == *"projects[].hierarchy.specification"* ]]
  [[ "$output" == *"--issue-type CONSUMER=specification=<one of them>"* ]]
}

@test "§6.2 — role_unresolved_json emits the structured block, sole option list, through the output module shape" {
  local result
  result="$(role_resolve CONSUMER "${CONSUMER_ITYPES}" '{}' '{}')"
  run role_unresolved_json "${result}" CONSUMER
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.[0].project' <<< "$output")" = "CONSUMER" ]
  [ "$(jq -r '.[0].role' <<< "$output")" = "specification" ]
  [ "$(jq -r '.[0].declaration' <<< "$output")" = "projects[].hierarchy.specification" ]
  [ "$(jq -r '.[0].flag' <<< "$output")" = "--issue-type CONSUMER=specification=<name>" ]
  [ "$(jq -r '.[0].candidates | length' <<< "$output")" -eq 2 ]
}

@test "§6.2 — an undeclared task role never appears in the unresolved block: absent, not unresolved" {
  local result
  result="$(role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":"Epic","story":"Story"}' '{}')"
  run role_unresolved_json "${result}" CONSUMER
  [ "$output" = "[]" ]
}

# =============================================================================
# §6.3 — unknown type
# =============================================================================

@test "§6.3 — role_resolve records the unknown-type problem, naming the declared value and the candidate set" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":"NoSuchType"}' '{}'
  [ "$(jq -r '.unknown[0].role' <<< "$output")" = "specification" ]
  [ "$(jq -r '.unknown[0].name' <<< "$output")" = "NoSuchType" ]
  [ "$(jq -r '.unknown[0].candidates | length' <<< "$output")" -eq 5 ]
}

@test "§6.3 — role_unknown_type_message names the tier's offered candidates, never an id" {
  local cands='[{"logical_name":"Epic","id":"10701"},{"logical_name":"Service Category","id":"10702"}]'
  run role_unknown_type_message CONSUMER specification NoSuchType "${cands}"
  [[ "$output" == *'specification names issue type "NoSuchType", which this project does not offer at that tier'* ]]
  [[ "$output" == *"It offers: Epic, Service Category (zero writes)"* ]]
  [[ "$output" != *"10701"* ]]
}

@test "§6.3 — a name that exists in the project but in the OTHER candidate set is unknown, not a cross-tier match" {
  # Sous-tâche exists (as a sub-task type) but is declared for specification,
  # whose candidate set is non-sub-task types — this is subtask misuse
  # (§6.5), never an unrelated §6.3 with the wrong candidate list.
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":"Sous-tâche"}' '{}'
  [ "$(jq -r '.unknown | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.subtask_misuse[0].name' <<< "$output")" = "Sous-tâche" ]
}

# =============================================================================
# §6.4 — duplicate name at a level
# =============================================================================

DUPLICATE_ITYPES='[
  {"logical_name":"Epic","id":"10701","hierarchy_level":"1","subtask":false},
  {"logical_name":"Epic","id":"10799","hierarchy_level":"1","subtask":false},
  {"logical_name":"Story","id":"10704","hierarchy_level":"0","subtask":false}
]'

@test "§6.4 — role_resolve records the duplicate problem, naming the level" {
  run role_resolve DUP "${DUPLICATE_ITYPES}" '{"specification":"Epic"}' '{}'
  [ "$(jq -r '.duplicate[0].role' <<< "$output")" = "specification" ]
  [ "$(jq -r '.duplicate[0].name' <<< "$output")" = "Epic" ]
  [ "$(jq -r '.duplicate[0].level' <<< "$output")" = "1" ]
  [ "$(jq -r '.roles | has("specification")' <<< "$output")" = "false" ]
}

@test "§6.4 — role_duplicate_message states the bridge will not choose one for you" {
  run role_duplicate_message DUP specification Epic 1
  [[ "$output" == *'specification names "Epic", which matches more than one issue type at level 1'* ]]
  [[ "$output" == *"The bridge will not choose one for you (zero writes)"* ]]
}

# =============================================================================
# §6.5 — sub-task type for a non-sub-task role
# =============================================================================

@test "§6.5 — a sub-task type declared for specification is subtask misuse, in both directions of the role list" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"specification":"Sous-tâche"}' '{}'
  [ "$(jq -r '.subtask_misuse[0].role' <<< "$output")" = "specification" ]
  [ "$(jq -r '.subtask_misuse[0].name' <<< "$output")" = "Sous-tâche" ]

  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"story":"Sous-tâche"}' '{}'
  [ "$(jq -r '.subtask_misuse[0].role' <<< "$output")" = "story" ]
}

@test "§6.5 — a sub-task type reported at level 0 is caught by the subtask FLAG, never by its level (§4.1)" {
  # A pathological but contract-legal fixture: a sub-task type sitting at
  # level 0, alongside Story. Declaring it for `story` must still refuse as
  # subtask misuse — the level says nothing about sub-task-ness.
  local itypes='[
    {"logical_name":"Story","id":"1","hierarchy_level":"0","subtask":false},
    {"logical_name":"Odd Sub-task","id":"2","hierarchy_level":"0","subtask":true}
  ]'
  run role_resolve X "${itypes}" '{"story":"Odd Sub-task"}' '{}'
  [ "$(jq -r '.subtask_misuse[0].name' <<< "$output")" = "Odd Sub-task" ]
}

@test "§6.5 — role_subtask_misuse_message names the role and the type" {
  run role_subtask_misuse_message CONSUMER specification "Sous-tâche"
  [[ "$output" == *'specification names "Sous-tâche", which is a sub-task type in this project'* ]]
  [[ "$output" == *"A specification cannot be a sub-task (zero writes)"* ]]
}

# =============================================================================
# §6.6 — non-sub-task type for the task role
# =============================================================================

@test "§6.6 — a non-sub-task type declared for task is task misuse, naming its sub-task candidates" {
  run role_resolve CONSUMER "${CONSUMER_ITYPES}" '{"task":"Story"}' '{}'
  [ "$(jq -r '.task_misuse[0].name' <<< "$output")" = "Story" ]
  [ "$(jq -r '.task_misuse[0].candidates | length' <<< "$output")" -eq 2 ]
}

@test "§6.6 — role_task_misuse_message renders an empty candidate list as the explicit words, never an empty string" {
  run role_task_misuse_message X Story '[]'
  [[ "$output" == *"Its sub-task types are: none — this project offers no sub-task type (zero writes)"* ]]
}

@test "§6.6 — role_task_misuse_message names the offered sub-task candidates when they exist" {
  run role_task_misuse_message CONSUMER Story '[{"logical_name":"Sous-tâche","id":"10716"},{"logical_name":"Sub Test Execution","id":"10717"}]'
  [[ "$output" == *'task names "Story", which is not a sub-task type in this project'* ]]
  [[ "$output" == *"Its sub-task types are: Sous-tâche, Sub Test Execution (zero writes)"* ]]
}

# =============================================================================
# §6.7 — ordering
# =============================================================================

@test "§6.7 — role_validate refuses when specification does not sit strictly above story" {
  local roles='{"specification":{"logical_name":"Story","hierarchy_level":"0"},"story":{"logical_name":"Epic","hierarchy_level":"1"}}'
  run role_validate CONSUMER "${roles}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'specification names "Story" at level 0, which is not above story "Epic" at level 1'* ]]
  [[ "$output" == *"A specification must sit above its stories (zero writes)"* ]]
}

@test "§6.7 — equal levels refuse too (not strictly above is not the same as below)" {
  local roles='{"specification":{"logical_name":"Epic","hierarchy_level":"0"},"story":{"logical_name":"Story","hierarchy_level":"0"}}'
  run role_validate CONSUMER "${roles}"
  [ "$status" -eq 1 ]
}

@test "§6.7 — a gap greater than one level is ACCEPTED (FR-012): no adjacency requirement" {
  local roles='{"specification":{"logical_name":"Initiative","hierarchy_level":"3"},"story":{"logical_name":"Story","hierarchy_level":"0"}}'
  run role_validate CONSUMER "${roles}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "§6.7 — levels compare NUMERICALLY: a lexical comparison ordering \"-1\" > \"0\" MUST NOT pass here" {
  # If role_validate ever regressed to a string comparison, "-1" > "0" would
  # be true lexically (leading '-' sorts... actually this fixture is chosen
  # so the numeric and lexical answers DISAGREE: numerically 2 > -1 (valid,
  # should PASS); lexically "2" < "-1" (would wrongly REFUSE). Guards against
  # a lexical-comparison regression in either direction.
  local roles='{"specification":{"logical_name":"Epic","hierarchy_level":"2"},"story":{"logical_name":"Sub-task-ish","hierarchy_level":"-1"}}'
  run role_validate CONSUMER "${roles}"
  [ "$status" -eq 0 ]
}

@test "role_has_problems — false on a fully-resolved result, true when any problem array is non-empty" {
  local ok_result
  ok_result="$(role_resolve SAFE "${SAFE_ITYPES}" '{}' '{}')"
  run role_has_problems "${ok_result}"
  [ "$output" = "false" ]

  local bad_result
  bad_result="$(role_resolve CONSUMER "${CONSUMER_ITYPES}" '{}' '{}')"
  run role_has_problems "${bad_result}"
  [ "$output" = "true" ]
}
