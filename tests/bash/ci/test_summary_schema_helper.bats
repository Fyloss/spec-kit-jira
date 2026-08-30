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
  # The helper reaches three paths. If any of them moved, every violation list
  # would come back empty and every caller would pass vacuously.
  [ -f "${SCHEMA}" ]
  [ "$(jq -r '.properties | type' "${SCHEMA}")" = "object" ]
  [ "$(jq -r '.properties.effects.properties | type' "${SCHEMA}")" = "object" ]
  [ "$(jq -r '.["$defs"].effect.properties.status.enum | type' "${SCHEMA}")" = "array" ]
  [ "$(jq -r '.["$defs"].effect.properties.status.enum | length' "${SCHEMA}")" -gt 0 ]
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
