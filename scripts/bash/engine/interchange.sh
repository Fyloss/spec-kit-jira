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
source "${_interchange_dir}/../lib/output.sh" # json_canonical/json_build only — lib/, never sink/

# The validation program: emits a JSON array of human-readable error strings
# (empty array => valid). Kept as a jq program so the rules are declarative.
# The mark/span/block defs below encode data-model.md §5 rules 1-5 (feature
# 016): block-type enum (now including ordered_list), per-type required
# field, span shape, mark shape, and href matching ^https?://. Rule 5 is the
# schema-level backstop for FR-006 — even a tokenizer bug cannot get a
# non-http target to Jira as a live link, because a validation failure blocks
# every downstream write (Constitution VIII).
# shellcheck disable=SC2016  # single-quoted jq program; `$k`/`$t` are jq variables, not shell
# kcov-excl-start — jq literal (string lines are not statements)
# shellcheck disable=SC2016  # $ids is a jq variable (`as $ids`), not shell expansion
_INTERCHANGE_ERRORS_JQ='
def mark_errors:
  (.kind // "") as $k |
  (if (["bold","italic","monospace","strikethrough","link"] | index($k)) == null
   then "mark.kind is invalid" else empty end),
  (if .kind == "link" then
     (if (has("href") | not) then "mark.href is required for a link mark"
      elif ((.href // "") | test("^https?://[^ \t\n]+$") | not) then "mark.href must be an absolute http(s) URL"
      else empty end)
   else
     (if has("href") then "mark.href is forbidden for a non-link mark" else empty end)
   end);
def span_errors:
  (if (.text | type) != "string" then "span.text is required" else empty end),
  (if (.marks | type) != "array" then "span.marks is required" else empty end),
  ((.marks // [])[]? | mark_errors);
def inline_errors: (.[]? | span_errors);
def block_errors:
  (.type) as $t |
  (if (["heading","paragraph","bullet_list","ordered_list","code","panel_ref"] | index($t)) == null
   then "block.type is invalid" else empty end),
  (if ($t == "heading" or $t == "paragraph") then
     (if (has("spans") | not) then "block.spans is required for a \($t) block" else (.spans | inline_errors) end)
   else empty end),
  (if ($t == "bullet_list" or $t == "ordered_list") then
     (if (has("items") | not) then "block.items is required for a \($t) block" else ((.items // [])[]? | inline_errors) end)
   else empty end),
  (if ($t == "code") and (has("text") | not) then "block.text is required for a code block" else empty end),
  (if ($t == "panel_ref") and (has("ref") | not) then "block.ref is required for a panel_ref block" else empty end);
def blocks_errors: ((.blocks // [])[]? | block_errors);
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
     (if ((.epic.description.blocks // []) | length) < 1 then "epic.description.blocks must be non-empty" else empty end),
     (.epic.description // {} | blocks_errors),
     (if ((.epic.marker.state // "absent") != "absent") and (((.epic.local_id // "") | test("^[0-9a-f]{16}$")) | not)
      then "epic.local_id is required and must be 16 hex characters unless the marker state is absent" else empty end)
   end),
  (if (.stories | type) != "array" or (.stories | length) < 1 then "stories must be a non-empty array"
   else
     (.stories[] | if ((.local_id // "") | length) < 1 then "story.local_id is required" else empty end),
     (.stories[] | if ((.title // "") | length) < 1 then "story.title is required" else empty end),
     (.stories[] | if (.priority_logical | IN("P1","P2","P3") | not) then "story.priority_logical is invalid" else empty end),
     (.stories[] | if ((.description.blocks // []) | length) < 1 then "story.description.blocks must be non-empty" else empty end),
     (.stories[] | .description // {} | blocks_errors),
     (.stories[] | (.acceptance_criteria // [])[]? | ((.given // [])[]?, (.when // [])[]?, (.then // [])[]?) | inline_errors),
     (.stories[] | (.design // [])[]? | select(.kind == "guidance") | .value | inline_errors)
   end),
  # Phase 2, T025/T027, data-model.md §3: the task tier — validated only for
  # a story that carries a "tasks" key at all (its absence is the off switch,
  # FR-011); each rule blocks every write of the run, as the story rules do.
  # The per-task rules below select on the TYPE of that key as well, not just
  # its presence. Reason: `.tasks[]?` iterates the VALUES of an object, so an
  # object-valued `tasks` fed `.title` a boolean and killed the whole jq
  # program — reported to the operator as "input is not valid JSON" instead of
  # the story-level error on the next line. A string, a number and null were
  # already inert here, `[]?` yielding nothing for them (Copilot review, #17).
  # NOTE: no apostrophes in this comment — it sits inside a single-quoted jq
  # program, where one would close the string and break the whole file.
  (.stories[]? | if has("tasks") and ((.tasks | type) != "array") then "story.tasks must be an array" else empty end),
  (.stories[]? | select(has("tasks") and ((.tasks | type) == "array")) | .tasks[]? |
    if (((.marker.state // "absent") != "absent") and (((.local_id // "") | test("^[0-9a-f]{16}$")) | not))
    then "task.local_id is required and must be 16 hex characters unless the marker state is absent" else empty end),
  (.stories[]? | select(has("tasks") and ((.tasks | type) == "array")) | .tasks[]? | if ((.title // "") | length) < 1 then "task.title is required" else empty end),
  (.stories[]? | select(has("tasks") and ((.tasks | type) == "array")) | .tasks[]? | if ((.description.blocks // []) | length) < 1 then "task.description.blocks must be non-empty" else empty end),
  # 016, FR-019: a task description obeys the SAME inline model every other
  # description position obeys. Without this rule the task tier was the one
  # place a pre-016 raw-string paragraph could pass validation and render as
  # literal punctuation, which is exactly what feature 012 shipped.
  (.stories[]? | select(has("tasks") and ((.tasks | type) == "array")) | .tasks[]? | .description // {} | blocks_errors),
  (.stories[]? | select(has("tasks") and ((.tasks | type) == "array")) | .tasks[]? | if (.done | type) != "boolean" then "task.done must be a boolean" else empty end),
  ( ( [ .stories[]? | select(has("tasks") and ((.tasks | type) == "array")) | .tasks[]? | (.local_id // "") | select(length > 0) ] ) as $ids
    | if ($ids | length) != ($ids | unique | length) then "two tasks share a local_id" else empty end ),
  # 036, data-model.md §4: the artifact set crosses the engine->sink boundary
  # INSIDE this document, so it is validated here like everything else that
  # crosses it — a failure blocks every write of the run (Constitution VIII).
  #
  # The key is OPTIONAL: a document built before any artifact exists, or by a
  # path that does not publish, omits it entirely. Its ABSENCE is the off
  # switch, exactly as it is for the task tier above.
  #
  # The absolute-path rule is the one with teeth. A path relative to the
  # feature directory is a neutral fact; an absolute one carries the operator
  # home directory into a document written to disk and compared byte-for-byte
  # across ports and machines (Constitution VI). Same reason the `..` rule
  # exists: a path escaping the feature directory is not this feature record.
  #
  # The type guard mirrors the task tier note above: `.artifacts[]?` iterates
  # the VALUES of an object, which would feed `.path` a string and kill the
  # whole jq program with "input is not valid JSON" instead of reporting the
  # error on the next line.
  (if has("artifacts") and ((.artifacts | type) != "array") then "artifacts must be an array" else empty end),
  (select(has("artifacts") and ((.artifacts | type) == "array")) | .artifacts[]? |
     (if ((.path // "") | length) < 1 then "artifact.path is required" else empty end),
     (if ((.path // "") | startswith("/")) then "artifact.path must be relative to the feature directory, never absolute" else empty end),
     (if ((.path // "") | test("(^|/)\\.\\.(/|$)")) then "artifact.path must not escape the feature directory" else empty end),
     (if ((.hash // "") | test("^[0-9a-f]{40}$") | not) then "artifact.hash must be 40 hexadecimal characters" else empty end),
     (if ((.size | type) != "number") or (.size < 0) then "artifact.size must be a non-negative integer" else empty end),
     (if ((.attachment_name // "") | length) < 1 then "artifact.attachment_name is required" else empty end)
  )
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
# from the engine's parse output plus the routing decisions the parser does
# not own (US3, T055). The parser produces the CONTENT (epic title +
# description, stories); the assembly injects `spec_ref` and
# `routing.project_key`. The result is VALIDATED against the schema before it
# is returned: an invalid document surfaces an error and returns non-zero — a
# validation failure blocks every downstream write (Constitution VIII).
#
# `epic.strategy` is gone (008 T026, FR-030): the field, its validation rule,
# and the `epic_strategy` context key are retired together, not deleted one
# at a time.
#
# context-json: { spec_ref:{repo,spec_slug,folder}, project_key }
interchange_build() {
  local parse="$1" ctx="$2" doc

  # `parse` is the whole parse result, stories included, so it grows with the
  # specification exactly as parse_spec's own `stories` does — the same #46
  # category-B defect one step downstream, and the one that fires next once
  # parse_spec stops spelling its array into a command line. Bound from a file
  # through json_build for the same reason and with the same measurement
  # behind it (engine/parse.sh, issue #46).
  local rc=0
  # kcov-excl-start — jq literal (string lines are not statements)
  # shellcheck disable=SC2016  # a jq filter: $parse/$ctx are jq variables
  doc="$(json_build '
    {
      schema_version: "1.0",
      spec_ref: $ctx.spec_ref,
      routing: { project_key: ($ctx.project_key // "") },
      epic: {
        title: ($parse.epic.title // ""),
        description: ($parse.epic.description // {blocks: []}),
        local_id: ($parse.epic.local_id // ""),
        marker: ($parse.epic.marker // {state:"absent", id:"", lines:[]})
      },
      stories: ($parse.stories // [])
    }' parse "${parse}" ctx "${ctx}")" || rc=$?
  # kcov-excl-stop
  # json_canonical is applied to the CAPTURED value, not inside the pipeline
  # above: it exits 0 on empty input, which would swallow a json_build failure
  # and hand interchange_validate an empty document to refuse for the wrong
  # reason.
  ((rc == 0)) || return "${rc}"
  doc="$(printf '%s' "${doc}" | json_canonical)"

  if ! printf '%s' "${doc}" | interchange_validate; then
    return 1
  fi
  printf '%s' "${doc}"
}

# routing_resolve <folder-name> <labels-json> <routing-config-json> [team-id]
# Resolve the ONE project a spec reconciles against (US8, FR 041, FR 042; 033
# FR-001, contracts/routing-resolution.md C1.1–C2.5).
#
# FIVE ranks, first non-empty wins:
#   1  a committed `routing:` rule whose every declared condition holds;
#   2  a committed `teams[]` entry whose folder_prefix prefixes the de-numbered
#      folder name;
#   3  [marker-project] — the project the SPECIFICATION'"'"'S OWN bound markers
#      record (035);
#   4  the `project` of the `teams[]` entry whose id equals [team-id] — the team
#      the OPERATOR selected in their gitignored personal.yml (033);
#   5  `routing_default`, which is optional since 033.
# Nothing left: refused with EXIT_CONFIG (zero writes downstream).
#
# A rule matches only when EVERY condition it declares holds (a rule with no
# condition is skipped, and an empty-string condition counts as undeclared — the
# shipped template's placeholder rule must not become a match-everything rule
# that shadows the implicit team route).
#
# Ranks 1 and 2 stay ahead of ranks 3 and 4 unconditionally (033 C2.5, 035
# C2.3). They reason about where the specification BELONGS; rank 3 reports only
# where it currently LIVES, and rank 4 reasons about the PERSON. A team that
# commits a decision must still be able to move a specification, and a
# gitignored file must never override a team's committed routing.
#
# Rank 3 is the 035 repair. 033 suppressed rank 4 for a bound specification,
# citing "the specification itself records which project it lives in" — and then
# never read that record, so resolution fell through to `routing_default`, free
# to name a different project entirely. What the run DOES when ranks 1 or 2
# contradict the record is the command layer's business (035 C3.2), not the
# resolver's: this function still only answers "which project".
#
# [marker-project] is OPTIONAL and MAY be empty (035 C2.5); empty is not an
# error, produces no diagnostic, and yields output byte-identical to the
# four-input resolver for every possible configuration — the clause that makes
# "every existing repository is untouched" true by construction.
#
# [team-id] is OPTIONAL and MAY be empty; empty is not an error and produces no
# diagnostic (C2.3). It arrives already validated against the catalogue by
# config_personal_load, so this function neither re-validates nor reports on it
# (C4.1) — an id matching no entry simply contributes nothing (C4.2).
#
# With [team-id] empty the whole resolution is byte-identical to the
# three-input resolver this replaces (C1.4). That is what makes FR-009 —
# "every existing repository is untouched" — true by construction rather than
# by inspection.
#
# PURE: no Jira reads or writes, and no file opened (C1.2). ONE external
# process for the whole resolution, whatever the catalogue's size (C1.3) — the
# rank-3 lookup is folded into the jq programme that already runs.
# Prints the resolved project key on stdout.
routing_resolve() {
  local folder="$1" labels="$2" cfg="$3" team="${4:-}" marker="${5:-}" key
  # kcov-excl-start — jq literal (string lines are not statements)
  key="$(jq -r --arg folder "${folder}" --argjson labels "${labels}" --arg team "${team}" --arg marker "${marker}" '
    (.routing // []) as $rules
    | ( first(
          $rules[]
          | .match as $m
          | select(($m | type) == "object")
          | ($m.folder_prefix // "") as $mfp
          | ($m.spec_label // "") as $msl
          | select(($mfp != "") or ($msl != ""))
          | select(
              (if ($mfp != "") then ($folder | startswith($mfp)) else true end)
              and
              (if ($msl != "") then (($labels | index($msl)) != null) else true end)
            )
          | .project
        ) // null
      ) as $matched
    | ( $folder | sub("^[0-9]+-"; "") ) as $flat
    | ( first( (.teams // [])[]
          | . as $t
          | select((($t.folder_prefix // "") != "") and ($flat | startswith($t.folder_prefix)))
          | $t.project
        ) // null ) as $team_route
    | ( first( (.teams // [])[]
          | select($team != "" and (.id // "") == $team)
          | .project
        ) // null ) as $personal_route
    | ( if $marker == "" then null else $marker end ) as $marker_route
    | ( $matched // $team_route // $marker_route // $personal_route // .routing_default // "" )
  ' <<< "${cfg}")"
  # kcov-excl-stop

  if [[ -z "${key}" ]]; then
    printf 'routing: no routing rule matched and no routing_default is configured\n' >&2
    return "${EXIT_CONFIG}"
  fi
  printf '%s' "${key}"
}
