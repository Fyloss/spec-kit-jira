#!/usr/bin/env bats
# T020 — Neutral-interchange schema validation (Constitution VIII).
# Valid docs pass; invalid docs fail with an error and DRIVE ZERO WRITES.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  VALID="${ROOT}/tests/conformance/fixtures/neutral-valid.json"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/interchange.sh"
}

@test "a well-formed neutral document validates" {
  run interchange_validate < "${VALID}"
  [ "$status" -eq 0 ]
}

@test "wrong schema_version is rejected" {
  run bash -c "jq '.schema_version=\"2.0\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema_version"* ]]
}

@test "a malformed spec_slug is rejected" {
  run bash -c "jq '.spec_ref.spec_slug=\"bad slug\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spec_slug"* ]]
}

@test "an invalid project_key is rejected" {
  run bash -c "jq '.routing.project_key=\"proj-1\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project_key"* ]]
}

@test "an empty stories array is rejected" {
  run bash -c "jq '.stories=[]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stories"* ]]
}

@test "an invalid priority is rejected" {
  run bash -c "jq '.stories[0].priority_logical=\"P9\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"priority"* ]]
}

@test "invalid JSON input is rejected, not crashed" {
  run bash -c "printf 'not json' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
}

@test "a document still carrying epic.strategy is not an error — it is simply ignored (008 T024/T026, FR-030)" {
  run bash -c "jq '.epic.strategy=\"per_repo\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -eq 0 ]
}

@test "epic.strategy absent is not an error either — the schema no longer requires it (008 T024/T026)" {
  run bash -c "jq 'del(.epic.strategy)' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -eq 0 ]
}

# --- interchange_build assembly (T055) --------------------------------------

@test "interchange_build assembles a schema-valid neutral document" {
  local parse ctx
  parse='{"epic":{"title":"Repo Epic","description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schema_version' <<< "$output")" = "1.0" ]
  [ "$(jq -r '.routing.project_key' <<< "$output")" = "PROJ" ]
  [ "$(jq -r '.epic | has("strategy")' <<< "$output")" = "false" ]
  [ "$(jq -r '.epic.title' <<< "$output")" = "Repo Epic" ]
}

@test "T068 [Phase 5, US2]: interchange_build carries epic.local_id and epic.marker through" {
  local parse ctx
  parse='{"epic":{"title":"Repo Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-1","lines":[2]},"description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.epic.local_id' <<< "$output")" = "3f2a91c04b7e6d18" ]
  [ "$(jq -r '.epic.marker.state' <<< "$output")" = "bound" ]
  [ "$(jq -r '.epic.marker.ticket' <<< "$output")" = "COMP-1" ]
}

@test "T068: epic.local_id is required unless the marker state is absent" {
  local parse ctx
  parse='{"epic":{"title":"E","marker":{"state":"assigned","id":"","lines":[]},"description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","spans":[{"text":"n","marks":[]}]}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"epic.local_id"* ]]
}

@test "T068: an absent marker (dry run on an untouched spec) does not require epic.local_id" {
  local parse ctx
  parse='{"epic":{"title":"E","marker":{"state":"absent","id":"","lines":[]},"description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","spans":[{"text":"n","marks":[]}]}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -eq 0 ]
}

@test "interchange_build refuses an assembly with an invalid project_key (zero writes)" {
  local parse ctx
  parse='{"epic":{"title":"E","description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","spans":[{"text":"n","marks":[]}]}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"bad-key"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project_key"* ]]
}

# --- Phase 2, T025/T027: the task tier (data-model.md §3) -------------------

@test "a story with no tasks key validates unchanged (FR-011 off switch)" {
  run interchange_validate < "${VALID}"
  [ "$status" -eq 0 ]
}

@test "a story with tasks:[] validates (an empty array is a valid array)" {
  run bash -c "jq '.stories[0].tasks=[]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -eq 0 ]
}

# `has("tasks") and ((.tasks | type) != "array")` — once the key is present,
# EVERY non-array type is refused and the per-task rules never run. The twin
# (Interchange.psm1) once tested only for an object here, so null and scalars
# reached its per-task loop and reported task-level errors instead of this one
# (Copilot review, PR #17); each type is pinned so the ports cannot drift again.
@test "story.tasks must be an array — a string" {
  run bash -c "jq '.stories[0].tasks=\"not-an-array\"' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"story.tasks must be an array"* ]]
  [[ "$output" != *"task.title is required"* ]]
}

@test "story.tasks must be an array — null" {
  run bash -c "jq '.stories[0].tasks=null' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"story.tasks must be an array"* ]]
  [[ "$output" != *"task.title is required"* ]]
}

@test "story.tasks must be an array — a number" {
  run bash -c "jq '.stories[0].tasks=7' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"story.tasks must be an array"* ]]
  [[ "$output" != *"task.title is required"* ]]
}

@test "story.tasks must be an array — an object" {
  local obj='{"nope":true}'
  run bash -c "jq --argjson o '${obj}' '.stories[0].tasks=\$o' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"story.tasks must be an array"* ]]
  [[ "$output" != *"task.title is required"* ]]
}

@test "task.local_id is required unless the marker state is absent" {
  local task='{"local_id":"","title":"T","description":{"blocks":[{"type":"paragraph","text":"x"}]},"done":false,"marker":{"state":"assigned","id":"","lines":[]}}'
  run bash -c "jq --argjson t '${task}' '.stories[0].tasks=[\$t]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"task.local_id"* ]]
}

@test "task.local_id absent is fine when the marker state is absent" {
  local task='{"local_id":"","title":"T","description":{"blocks":[{"type":"paragraph","text":"x"}]},"done":false,"marker":{"state":"absent","id":"","lines":[]}}'
  run bash -c "jq --argjson t '${task}' '.stories[0].tasks=[\$t]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -eq 0 ]
}

@test "task.title is required" {
  local task='{"local_id":"1111111111111111","title":"","description":{"blocks":[{"type":"paragraph","text":"x"}]},"done":false,"marker":{"state":"assigned","id":"1111111111111111","lines":[1]}}'
  run bash -c "jq --argjson t '${task}' '.stories[0].tasks=[\$t]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"task.title"* ]]
}

@test "task.description.blocks must be non-empty" {
  local task='{"local_id":"1111111111111111","title":"T","description":{"blocks":[]},"done":false,"marker":{"state":"assigned","id":"1111111111111111","lines":[1]}}'
  run bash -c "jq --argjson t '${task}' '.stories[0].tasks=[\$t]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"task.description.blocks"* ]]
}

@test "task.done must be a boolean" {
  local task='{"local_id":"1111111111111111","title":"T","description":{"blocks":[{"type":"paragraph","text":"x"}]},"done":"false","marker":{"state":"assigned","id":"1111111111111111","lines":[1]}}'
  run bash -c "jq --argjson t '${task}' '.stories[0].tasks=[\$t]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"task.done"* ]]
}

@test "no two tasks in the document share a local_id, even across different stories" {
  local t1='{"local_id":"1111111111111111","title":"T1","description":{"blocks":[{"type":"paragraph","text":"x"}]},"done":false,"marker":{"state":"assigned","id":"1111111111111111","lines":[1]}}'
  local t2='{"local_id":"1111111111111111","title":"T2","description":{"blocks":[{"type":"paragraph","text":"y"}]},"done":false,"marker":{"state":"assigned","id":"1111111111111111","lines":[2]}}'
  run bash -c "jq --argjson t1 '${t1}' --argjson t2 '${t2}' '.stories[0].tasks=[\$t1] | .stories[1].tasks=[\$t2]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"share a local_id"* ]]
}

# The FR-011 off switch itself is covered above ("a story with no tasks key
# validates unchanged"); this one sets a populated tasks array, so it proves
# the opposite: a well-formed task tier passes every rule (Copilot review).
@test "a story with a valid tasks array validates" {
  run bash -c "jq '.stories[0].tasks=[{\"local_id\":\"1111111111111111\",\"title\":\"T\",\"description\":{\"blocks\":[{\"type\":\"paragraph\",\"text\":\"x\"}]},\"done\":false,\"marker\":{\"state\":\"assigned\",\"id\":\"1111111111111111\",\"lines\":[1]}}]' '${VALID}' | { source '${ENGINE_DIR}/interchange.sh'; interchange_validate; }"
  [ "$status" -eq 0 ]
}

@test "interchange_build is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local parse ctx b p
  parse='{"epic":{"title":"Repo Epic","description":{"blocks":[{"type":"paragraph","spans":[{"text":"x","marks":[]}]}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","spans":[{"text":"need","marks":[]}]}]},"priority_logical":"P2","estimation":3}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  b="$(interchange_build "${parse}" "${ctx}")"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Interchange.psm1' -Force; [Console]::Out.Write((Build-JiraNeutralDocument -ParseJson '${parse}' -ContextJson '${ctx}').Document)")"
  [ "${b}" = "${p}" ]
}

@test "both ports agree on validity for the same inputs" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  for mutation in '.' '.schema_version="2.0"' '.routing.project_key="bad-key"' '.stories=[]'; do
    doc="$(jq -c "${mutation}" "${VALID}")"
    if printf '%s' "${doc}" | interchange_validate 2> /dev/null; then bash_ok=0; else bash_ok=1; fi
    if printf '%s' "${doc}" | pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Interchange.psm1' -Force; if (Test-JiraInterchange ([Console]::In.ReadToEnd())) { exit 0 } else { exit 1 }" 2> /dev/null; then ps_ok=0; else ps_ok=1; fi
    [ "${bash_ok}" = "${ps_ok}" ]
  done
}
