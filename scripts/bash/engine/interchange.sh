#!/usr/bin/env bash
# engine/interchange.sh — Neutral interchange document validation.
#
# The neutral document is the ONLY object crossing the engine->sink interface
# (Constitution VIII). It is validated here BEFORE any write; a validation
# failure blocks the write and surfaces an error (zero writes).
#
# NEUTRAL layer: zero Jira identifiers, never sources sink/. The validation
# rules below encode contracts/neutral-interchange.schema.json.

[[ -n ${_JIRA_ENGINE_INTERCHANGE:-} ]] && return 0
_JIRA_ENGINE_INTERCHANGE=1

: "${EXIT_CONFIG:=4}" # engine stays standalone-testable without lib/cli.sh

_interchange_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_interchange_dir}/../lib/output.sh" # json_canonical only — lib/, never sink/

# The validation program: emits a JSON array of human-readable error strings
# (empty array => valid). Kept as a jq program so the rules are declarative.
# kcov-excl-start — jq literal (string lines are not statements)
_INTERCHANGE_ERRORS_JQ='
[
  (if (.schema_version != "1.0") then "schema_version must be \"1.0\"" else empty end),
  (if (.spec_ref | type) != "object" then "spec_ref is required"
   else
     (if ((.spec_ref.repo // "") | length) < 1 then "spec_ref.repo is required" else empty end),
     (if ((.spec_ref.folder // "") | length) < 1 then "spec_ref.folder is required" else empty end),
     (if ((.spec_ref.spec_slug // "") | test("^[0-9]{3}-[a-z0-9-]+$") | not)
      then "spec_ref.spec_slug is malformed" else empty end)
   end),
  (if ((.routing.project_key // "") | test("^[A-Z][A-Z0-9_]+$") | not)
   then "routing.project_key is invalid" else empty end),
  (if (.epic | type) != "object" then "epic is required"
   else
     (if ((.epic.title // "") | length) < 1 then "epic.title is required" else empty end),
     (if (.epic.strategy | IN("per_repo","per_feature") | not) then "epic.strategy is invalid" else empty end),
     (if ((.epic.description.blocks // []) | length) < 1 then "epic.description.blocks must be non-empty" else empty end)
   end),
  (if (.stories | type) != "array" or (.stories | length) < 1 then "stories must be a non-empty array"
   else
     (.stories[] | if ((.local_id // "") | length) < 1 then "story.local_id is required" else empty end),
     (.stories[] | if ((.title // "") | length) < 1 then "story.title is required" else empty end),
     (.stories[] | if (.priority_logical | IN("P1","P2","P3") | not) then "story.priority_logical is invalid" else empty end),
     (.stories[] | if ((.description.blocks // []) | length) < 1 then "story.description.blocks must be non-empty" else empty end)
   end)
]'
# kcov-excl-stop

# interchange_validate — read a neutral document on stdin; return 0 if valid,
# non-zero (with errors on stderr) otherwise. A failure means ZERO writes.
interchange_validate() {
  local doc errors
  doc="$(cat)"
  errors="$(printf '%s' "${doc}" | jq -c "${_INTERCHANGE_ERRORS_JQ}" 2> /dev/null)" || {
    printf 'interchange: input is not valid JSON\n' >&2
    return 1
  }
  if [[ "${errors}" == "[]" ]]; then
    return 0
  fi
  printf '%s' "${errors}" | jq -r '.[]' | while IFS= read -r line; do
    printf 'interchange: %s\n' "${line}" >&2
  done
  return 1
}

# interchange_build <parse-json> <context-json> — assemble the neutral document
# from the engine's parse output plus the routing/strategy decisions the parser
# does not own (US3, T055). The parser produces the CONTENT (epic title +
# description, stories); the assembly injects `spec_ref`, `routing.project_key`,
# and the `epic.strategy` from config. The result is VALIDATED against the schema
# before it is returned: an invalid document surfaces an error and returns
# non-zero — a validation failure blocks every downstream write (Constitution VIII).
#
# context-json: { spec_ref:{repo,spec_slug,folder}, project_key, epic_strategy }
interchange_build() {
  local parse="$1" ctx="$2" doc

  # kcov-excl-start — jq literal (string lines are not statements)
  doc="$(jq -cn \
    --argjson parse "${parse}" --argjson ctx "${ctx}" '
    {
      schema_version: "1.0",
      spec_ref: $ctx.spec_ref,
      routing: { project_key: ($ctx.project_key // "") },
      epic: {
        strategy: ($ctx.epic_strategy // ""),
        title: ($parse.epic.title // ""),
        description: ($parse.epic.description // {blocks: []})
      },
      stories: ($parse.stories // [])
    }' | json_canonical)"
  # kcov-excl-stop

  if ! printf '%s' "${doc}" | interchange_validate; then
    return 1
  fi
  printf '%s' "${doc}"
}

# routing_resolve <folder-name> <labels-json> <routing-config-json> — resolve the
# ONE project a spec reconciles against (US8, FR 041, FR 042). Inputs: the spec
# folder's basename (tested against each rule's folder_prefix), the labels declared
# in the spec (a JSON array, tested against each rule's spec_label), and the team
# config's `routing` rules plus `routing_default`. First matching rule wins; a rule
# matches only when EVERY condition it declares holds (a rule with no condition is
# skipped). An unmatched spec falls back to routing_default; a spec that matches
# nothing with no default is refused with EXIT_CONFIG (zero writes downstream).
# PURE: no Jira reads or writes. Prints the resolved project key on stdout.
routing_resolve() {
  local folder="$1" labels="$2" cfg="$3" key
  # kcov-excl-start — jq literal (string lines are not statements)
  key="$(jq -r --arg folder "${folder}" --argjson labels "${labels}" '
    (.routing // []) as $rules
    | ( first(
          $rules[]
          | .match as $m
          | select(($m | type) == "object")
          | select(($m | has("folder_prefix")) or ($m | has("spec_label")))
          | select(
              (if ($m | has("folder_prefix")) then ($folder | startswith($m.folder_prefix)) else true end)
              and
              (if ($m | has("spec_label")) then (($labels | index($m.spec_label)) != null) else true end)
            )
          | .project
        ) // null
      ) as $matched
    | ( $folder | sub("^[0-9]+-"; "") ) as $flat
    | ( first( (.teams // [])[]
          | . as $t
          | select($flat | startswith($t.folder_prefix))
          | $t.project
        ) // null ) as $team_route
    | ( $matched // $team_route // .routing_default // "" )
  ' <<< "${cfg}")"
  # kcov-excl-stop

  if [[ -z "${key}" ]]; then
    printf 'routing: no routing rule matched and no routing_default is configured\n' >&2
    return "${EXIT_CONFIG}"
  fi
  printf '%s' "${key}"
}
