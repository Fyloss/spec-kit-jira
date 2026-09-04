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
# This is a TARGETED guard, not a JSON Schema validator. It checks the things
# that actually drifted — an undeclared top-level key, an undeclared effect, an
# out-of-enum effect status — using `jq` alone, so it adds no dependency
# (Constitution XIV). A real validator needs one, and would buy little here: the
# schema's remaining constraints are types on fields both ports build from
# literals.
#
# 036 added a fourth class, and it is the reason this file grew rather than a
# second guard appearing beside it: `artifacts[]` is the first summary key whose
# drift lives INSIDE an array element, where the top-level check sees nothing.
# A withholding reason added to one port's classifier and not to the schema is
# exactly the seven-item drift these suites exist to prevent, one level down.

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
    # 036: the artifact entry. Every path is defaulted, so a schema that has not
    # yet declared `artifacts` reports every key as undeclared — which is the
    # red these callers are meant to see — instead of erroring out and being
    # mistaken for a passing run.
    | (($schema.properties.artifacts.items.properties) // {}) as $artp
    | (($artp | keys)) as $art
    | (($artp.action.enum) // []) as $aact
    | (($artp.reason.enum) // []) as $arsn
    | [ ($d | keys[] | select(. as $k | $top | index($k) | not)
          | "top-level key not declared by the schema: \(.)"),
        ((($d.effects) // {}) | keys[] | select(. as $k | $eff | index($k) | not)
          | "effects key not declared by the schema: \(.)"),
        ((($d.effects) // {}) | to_entries[] | select(.value.status != null)
          | select(.value.status as $v | $st | index($v) | not)
          | "effects.\(.key).status not in the schema enum: \(.value.status)"),
        # The index is carried through so a failure names WHICH artifact; a
        # message that always said [0] would be worse than no message.
        ((($d.artifacts) // []) | to_entries[] | . as $e
          | $e.value | keys[] | select(. as $k | $art | index($k) | not)
          | "artifacts[\($e.key)] key not declared by the schema: \(.)"),
        ((($d.artifacts) // []) | to_entries[]
          | select(.value.action != null)
          | select(.value.action as $v | $aact | index($v) | not)
          | "artifacts[\(.key)].action not in the schema enum: \(.value.action)"),
        ((($d.artifacts) // []) | to_entries[]
          | select(.value.reason != null)
          | select(.value.reason as $v | $arsn | index($v) | not)
          | "artifacts[\(.key)].reason not in the schema enum: \(.value.reason)") ]
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
