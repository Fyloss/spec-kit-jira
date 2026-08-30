#!/usr/bin/env bash
# tests/bash/helpers/summary_schema.bash — one reading of "does this run summary
# declare everything it emits", shared by the config and reconcile schema suites.
#
# `contracts/run-summary.schema.json` is the published contract for `--json`
# output, and its `additionalProperties: false` means an undeclared key makes the
# summary INVALID, not merely undocumented. Until these suites existed the schema
# was named in four source comments and ZERO assertions, and it had drifted seven
# items behind both ports across three features — so every ceremony summary was
# invalid against its own contract, on every run, for that whole period.
#
# Deliberately its own file rather than a copy in each suite: the two commands
# reach the summary through completely different harnesses (config needs the HTTP
# mock, reconcile mostly does not), but they must be judged against ONE reading of
# the contract. Two copies of this jq program would drift the same way the schema
# did.
#
# This is a TARGETED guard, not a JSON Schema validator. It checks the three
# things that actually drifted — an undeclared top-level key, an undeclared
# effect, an out-of-enum effect status — using `jq` alone, so it adds no
# dependency (Constitution XIV). A real validator needs one, and would buy little
# here: the schema's remaining constraints are types on fields both ports build
# from literals.

# helper_summary_violations <summary-json> <schema-path> — print one line per
# undeclared key or out-of-enum status. Silence means conformant.
#
# The schema path is REQUIRED rather than defaulted: every caller must be able to
# point this at an older copy of the schema to prove the guard red, and a default
# makes that the unusual spelling instead of the obvious one.
helper_summary_violations() {
  local summary="$1" schema="$2"
  jq -rn --slurpfile s "${schema}" --argjson d "${summary}" '
    $s[0] as $schema
    | ($schema.properties | keys) as $top
    | ($schema.properties.effects.properties | keys) as $eff
    | ($schema["$defs"].effect.properties.status.enum) as $st
    | [ ($d | keys[] | select(. as $k | $top | index($k) | not)
          | "top-level key not declared by the schema: \(.)"),
        ((($d.effects) // {}) | keys[] | select(. as $k | $eff | index($k) | not)
          | "effects key not declared by the schema: \(.)"),
        ((($d.effects) // {}) | to_entries[] | select(.value.status != null)
          | select(.value.status as $v | $st | index($v) | not)
          | "effects.\(.key).status not in the schema enum: \(.value.status)") ]
    | .[]'
}

# helper_summary_assert_conformant <summary-json> <schema-path> <label> — fail the
# calling test, naming every violation, when the summary does not conform.
helper_summary_assert_conformant() {
  local violations
  violations="$(helper_summary_violations "$1" "$2")"
  [[ -z "${violations}" ]] && return 0
  printf '%s summary violates its own published contract:\n%s\n' "$3" "${violations}" >&2
  return 1
}
