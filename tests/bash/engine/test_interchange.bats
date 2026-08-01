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
  parse='{"epic":{"title":"Repo Epic","description":{"blocks":[{"type":"paragraph","text":"x"}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},"priority_logical":"P1"}]}'
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
  parse='{"epic":{"title":"Repo Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"bound","id":"3f2a91c04b7e6d18","ticket":"COMP-1","lines":[2]},"description":{"blocks":[{"type":"paragraph","text":"x"}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.epic.local_id' <<< "$output")" = "3f2a91c04b7e6d18" ]
  [ "$(jq -r '.epic.marker.state' <<< "$output")" = "bound" ]
  [ "$(jq -r '.epic.marker.ticket' <<< "$output")" = "COMP-1" ]
}

@test "T068: epic.local_id is required unless the marker state is absent" {
  local parse ctx
  parse='{"epic":{"title":"E","marker":{"state":"assigned","id":"","lines":[]},"description":{"blocks":[{"type":"paragraph","text":"x"}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","text":"n"}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"epic.local_id"* ]]
}

@test "T068: an absent marker (dry run on an untouched spec) does not require epic.local_id" {
  local parse ctx
  parse='{"epic":{"title":"E","marker":{"state":"absent","id":"","lines":[]},"description":{"blocks":[{"type":"paragraph","text":"x"}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","text":"n"}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -eq 0 ]
}

@test "interchange_build refuses an assembly with an invalid project_key (zero writes)" {
  local parse ctx
  parse='{"epic":{"title":"E","description":{"blocks":[{"type":"paragraph","text":"x"}]}},"stories":[{"local_id":"s1","title":"S","description":{"blocks":[{"type":"paragraph","text":"n"}]},"priority_logical":"P1"}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"bad-key"}'
  run interchange_build "${parse}" "${ctx}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project_key"* ]]
}

@test "interchange_build is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local parse ctx b p
  parse='{"epic":{"title":"Repo Epic","description":{"blocks":[{"type":"paragraph","text":"x"}]}},"stories":[{"local_id":"s1","title":"A story","description":{"blocks":[{"type":"paragraph","text":"need"}]},"priority_logical":"P2","estimation":3}]}'
  ctx='{"spec_ref":{"repo":"acme/app","spec_slug":"001-feature","folder":"specs/001-feature"},"project_key":"PROJ"}'
  b="$(interchange_build "${parse}" "${ctx}")"
  p="$(pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Interchange.psm1' -Force; [Console]::Out.Write((Build-JiraNeutralDocument -ParseJson '${parse}' -ContextJson '${ctx}').Document)")"
  [ "${b}" = "${p}" ]
}

@test "both ports agree on validity for the same inputs" {
  for mutation in '.' '.schema_version="2.0"' '.routing.project_key="bad-key"' '.stories=[]'; do
    doc="$(jq -c "${mutation}" "${VALID}")"
    if printf '%s' "${doc}" | interchange_validate 2> /dev/null; then bash_ok=0; else bash_ok=1; fi
    if printf '%s' "${doc}" | pwsh -NoProfile -Command "Import-Module '${PS_ENGINE}/Interchange.psm1' -Force; if (Test-JiraInterchange ([Console]::In.ReadToEnd())) { exit 0 } else { exit 1 }" 2> /dev/null; then ps_ok=0; else ps_ok=1; fi
    [ "${bash_ok}" = "${ps_ok}" ]
  done
}
