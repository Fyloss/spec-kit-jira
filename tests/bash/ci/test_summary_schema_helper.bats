#!/usr/bin/env bats
# Guard for tests/bash/helpers/summary_schema.bash.
#
# Two suites assert that a run summary declares every key and status it emits,
# and both do it through `helper_summary_violations`. If that helper silently
# read nothing — a mistyped jq path, a schema whose shape moved — both suites
# would go green while checking nothing at all, which is the exact failure mode
# they exist to prevent. This project has shipped inert guards before.
#
# So the helper is exercised here against summaries with KNOWN violations, one
# per detected class, plus a conformant one. A guard nobody has watched fail is
# not known to work.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/summary_schema.bash"
}

@test "the schema itself is readable and has the shape the helper indexes into" {
  # The helper reaches six paths. If any of them moved, every violation list
  # would come back empty and every caller would pass vacuously.
  [ -f "${SCHEMA}" ]
  [ "$(jq -r '.properties | type' "${SCHEMA}")" = "object" ]
  [ "$(jq -r '.properties.effects.properties | type' "${SCHEMA}")" = "object" ]
  [ "$(jq -r '.["$defs"].effect.properties.status.enum | type' "${SCHEMA}")" = "array" ]
  [ "$(jq -r '.["$defs"].effect.properties.status.enum | length' "${SCHEMA}")" -gt 0 ]
  # 036 T052 — the artifact entry, whose three paths drift the same way.
  [ "$(jq -r '.properties.artifacts.items.properties | type' "${SCHEMA}")" = "object" ]
  [ "$(jq -r '.properties.artifacts.items.properties.action.enum | length' "${SCHEMA}")" -gt 0 ]
  [ "$(jq -r '.properties.artifacts.items.properties.reason.enum | length' "${SCHEMA}")" -gt 0 ]
}

# ---- 036 T052: the artifacts[] entry -----------------------------------------
#
# `artifacts` is the fourth thing the ports emit that the published contract can
# fall behind, and the first one whose drift lives INSIDE an array element —
# where the top-level key check above sees nothing at all. A withholding reason
# added to a port and not to the schema is precisely the shape of the seven-item
# drift these suites were written for.

@test "an undeclared artifact key is detected" {
  local out
  out="$(helper_summary_violations \
    '{"command":"reconcile","artifacts":[{"path":"spec.md","action":"published","gremlin":1}]}' \
    "${SCHEMA}")"
  [[ "${out}" == *"artifacts[0] key not declared by the schema: gremlin"* ]]
}

@test "an out-of-enum artifact action is detected" {
  local out
  out="$(helper_summary_violations \
    '{"command":"reconcile","artifacts":[{"path":"spec.md","action":"teleported"}]}' \
    "${SCHEMA}")"
  [[ "${out}" == *"artifacts[0].action not in the schema enum: teleported"* ]]
}

@test "an out-of-enum withholding reason is detected" {
  local out
  out="$(helper_summary_violations \
    '{"command":"reconcile","artifacts":[{"path":"a.md","action":"published"},{"path":"spec.md","action":"withheld","reason":"the-dog-ate-it"}]}' \
    "${SCHEMA}")"
  # The index is the SECOND entry: an operator reading this needs to know which
  # artifact, and a helper that always said `[0]` would be worse than silent.
  [[ "${out}" == *"artifacts[1].reason not in the schema enum: the-dog-ate-it"* ]]
}

@test "a conformant artifacts array produces no output at all" {
  local out
  out="$(helper_summary_violations \
    '{"schema_version":"1.0","command":"reconcile","artifacts":[
       {"path":"spec.md","attachment_name":"spec.md","hash":"abc","action":"published"},
       {"path":"contracts/api.md","attachment_name":"contracts__api.md","action":"unchanged"},
       {"path":"assets/demo.mov","attachment_name":"assets__demo.mov","action":"withheld","reason":"oversized","size":41943040,"limit":10485760},
       {"path":"checklists/api.md","attachment_name":"checklists__api.md","action":"withheld","reason":"name-collision","collides_with":"contracts__api.md"}
     ],"exit_code":0}' "${SCHEMA}")"
  [ -z "${out}" ]
}

@test "a summary with no artifacts array at all is still clean" {
  # Every pre-036 summary omits the key entirely, and the helper must not read
  # that absence as a violation — nor error out on it.
  local out
  out="$(helper_summary_violations '{"schema_version":"1.0","command":"reconcile","exit_code":0}' "${SCHEMA}")"
  [ -z "${out}" ]
}

@test "an undeclared top-level key is detected" {
  local out
  out="$(helper_summary_violations '{"command":"config","gremlin":1}' "${SCHEMA}")"
  [[ "${out}" == *"top-level key not declared by the schema: gremlin"* ]]
}

@test "an undeclared effect is detected" {
  local out
  out="$(helper_summary_violations '{"command":"config","effects":{"bogus":{"status":"written"}}}' "${SCHEMA}")"
  [[ "${out}" == *"effects key not declared by the schema: bogus"* ]]
}

@test "an out-of-enum effect status is detected" {
  local out
  out="$(helper_summary_violations '{"command":"config","effects":{"discovery":{"status":"nope"}}}' "${SCHEMA}")"
  [[ "${out}" == *"effects.discovery.status not in the schema enum: nope"* ]]
}

@test "a conformant summary produces no output at all" {
  local out
  out="$(helper_summary_violations '{"schema_version":"1.0","command":"config","effects":{"discovery":{"status":"written"}},"exit_code":0}' "${SCHEMA}")"
  [ -z "${out}" ]
}

@test "the helper reports against an OLDER schema — the red-proof spelling works" {
  # Every caller must be able to point the helper at a previous copy of the
  # schema to demonstrate the guard red. That is why the path is a required
  # argument rather than a default, and this asserts the spelling still works.
  local old out
  old="${BATS_TEST_TMPDIR}/old-schema.json"
  jq 'del(.properties.effects.properties.personal)' "${SCHEMA}" > "${old}"
  out="$(helper_summary_violations '{"command":"config","effects":{"personal":{"status":"created"}}}' "${old}")"
  [[ "${out}" == *"effects key not declared by the schema: personal"* ]]
  # …and the same summary is clean against the CURRENT schema.
  out="$(helper_summary_violations '{"command":"config","effects":{"personal":{"status":"created"}}}' "${SCHEMA}")"
  [ -z "${out}" ]
}
