#!/usr/bin/env bash
# hooks/register_hooks.sh — The hook registry READER (003 FR-021 – FR-025, FR-028).
#
# The consuming repository's `.specify/extensions.yml` has exactly ONE writer and
# it is not us: `specify extension add` writes it from the manifest's top-level
# `hooks:` block. Other extensions have entries in it. The operator edits it by
# hand and keeps comments in it. This module reads that file, recognises which
# entries are ours, classifies every declared event, and reports. It never opens
# the file for anything but reading (FR-022, SC-011) — there is no writer here,
# and adding one back would fail tests/bash/ci/test_no_registry_write.bats.
#
# Why the writer was removed rather than narrowed (research R3): this port's YAML
# reader models a deliberately restricted subset — no anchors, no flow
# collections — and drops every comment. Any round-trip through it silently
# damages a file we neither own nor can faithfully reproduce. With registration
# owned by the manifest, we no longer need to write it at all.
#
# Recognition has two rules, and they are not the same rule:
#   * ours     — the entry carries `extension: jira`, the ownership key the host
#                install writes and matches on when it purges and re-adds;
#   * leftover — the entry carries one of our commands and NO `extension` field:
#                the four-field shape every pre-manifest version of this
#                extension wrote. The install's purge predicate is literally
#                `h.get("extension") == manifest.id`, which such an entry never
#                satisfies, so the install adds a SECOND entry beside it rather
#                than replacing it (research R2). Neither the host nor we can
#                remove it — it is reported, with the manual edit (FR-028).
#
# This is the hooks layer, not the engine: it owns the hook/command vocabulary.

[[ -n ${_JIRA_HOOK_REGISTER:-} ]] && return 0
_JIRA_HOOK_REGISTER=1

_register_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_register_hooks_dir}/../lib/config.sh" # config_yaml_to_json (READ only)
# shellcheck source=/dev/null
source "${_register_hooks_dir}/../lib/output.sh" # json_canonical

: "${EXIT_CONFIG:=4}"

# The owning-extension id the host writes into every entry it registers for us.
HOOK_EXTENSION_ID='jira'

# The seven declared lifecycle events (research R9) — one closed set, in
# manifest declaration order. The set has ONE source: lib/config.sh declares it
# as the `hooks.disabled` enum of config.local.schema.json, and this module
# consumes it rather than redeclaring it. The set declared in extension.yml and
# the set classified here must also be identical;
# tests/bash/ci/test_manifest_hooks.bats fails the build when they diverge.
HOOK_EVENTS=("${JIRA_HOOK_EVENT_NAMES[@]}")

# The reconcile command the six after_* events fire.
HOOK_COMMAND='speckit.jira.reconcile'

# The feature-naming command the before_specify event fires (002 US3, FR-013).
HOOK_BEFORE_EVENT='before_specify'
HOOK_BEFORE_COMMAND='speckit.jira.feature'

# The remedies the report names. Each literal is runnable exactly as spelled —
# tests/bash/ci/test_message_command_literals.bats asserts it (FR-018).
HOOK_INSTALL_COMMAND='specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip --force'
HOOK_RELEASE_COMMAND='/speckit.jira.config --enable-hook'

# register_hooks_command_for <event> — the command that event must name.
register_hooks_command_for() {
  if [[ "$1" == "${HOOK_BEFORE_EVENT}" ]]; then
    printf '%s' "${HOOK_BEFORE_COMMAND}"
  else
    printf '%s' "${HOOK_COMMAND}"
  fi
}

# register_hooks_events_json — the seven declared events as a JSON array, in
# declaration order.
register_hooks_events_json() {
  printf '%s\n' "${HOOK_EVENTS[@]}" | jq -cR . | jq -cs .
}

# register_hooks_commands_json — our two commands as a JSON array. This is the
# "one of ours" set the leftover predicate matches on.
register_hooks_commands_json() {
  jq -cn --arg a "${HOOK_BEFORE_COMMAND}" --arg b "${HOOK_COMMAND}" '[$a, $b]'
}

# register_hooks_entry_is_ours <entry-json> — 0 when the entry carries our
# ownership key. This is how we RECOGNISE our entries; it is not a licence to
# edit them (data-model § Hook entry).
register_hooks_entry_is_ours() {
  jq -e --arg id "${HOOK_EXTENSION_ID}" '.extension? == $id' <<< "$1" > /dev/null 2>&1
}

# register_hooks_entry_is_leftover <entry-json> — 0 when the entry names one of
# our commands and carries NO owning extension: the pre-manifest shape the
# install cannot purge (FR-028, research R2).
register_hooks_entry_is_leftover() {
  jq -e --argjson cmds "$(register_hooks_commands_json)" \
    '(has("extension") | not) and (.command? as $c | $cmds | index($c) != null)' \
    <<< "$1" > /dev/null 2>&1
}

# _register_hooks_shape_jq — the canonical eight-field shape as a declarative jq
# program (contracts/hook-registry-entry.md). Prints one line per deviation.
#
# `prompt` is the fussy one on purpose: the host builds its default with an
# f-string, `f"Execute {command}?"`, so the file receives the EXPANDED string and
# never a literal `{command}` placeholder (research R2, verified at
# specify_cli/extensions/__init__.py:3866). An entry carrying the unexpanded
# template did not come from the host, and saying so is the point of reading it.
# shellcheck disable=SC2016  # `\(...)` is jq string interpolation, not shell expansion
# kcov-excl-start — jq literal (string lines are not statements)
_REGISTER_HOOKS_SHAPE_JQ='
[
  (["extension","command","enabled","optional","priority","prompt","description","condition"][]
   | . as $f | if (($e|has($f)) | not) then "missing field: \($f)" else empty end),
  (if ($e|has("extension")) and ($e.extension != $id) then "extension is not \($id)" else empty end),
  (if ($e|has("enabled")) and (($e.enabled|type) != "boolean") then "enabled is not a boolean" else empty end),
  (if ($e|has("optional")) and ($e.optional != false) then "optional must be false — a true entry is offered, not performed" else empty end),
  (if ($e|has("priority")) and (($e.priority|type) != "number") then "priority is not a number" else empty end),
  (if ($e|has("prompt")) and ($e|has("command")) and ($e.prompt != ("Execute " + $e.command + "?"))
   then "prompt is not the host default \"Execute \($e.command)?\" — the host expands it with an f-string, so a {command} placeholder never reaches the file"
   else empty end),
  (if ($e|has("description")) and (($e.description|type) != "string") then "description is not a string" else empty end),
  (if ($e|has("condition")) and ($e.condition != null)
   then "condition is set — a non-empty condition makes agent-driven dispatch skip the hook entirely"
   else empty end)
] | .[]'
# kcov-excl-stop

# register_hooks_entry_shape_errors <entry-json> — print one line per deviation
# from the canonical eight-field shape. Returns non-zero when any was printed.
# We ASSERT the shape when we read and REPORT a deviation; we never correct one,
# because correcting it would mean writing the file.
register_hooks_entry_shape_errors() {
  local errors
  errors="$(jq -r --argjson e "$1" --arg id "${HOOK_EXTENSION_ID}" -n "${_REGISTER_HOOKS_SHAPE_JQ}" 2> /dev/null)"
  [[ -z "${errors}" ]] && return 0
  printf '%s\n' "${errors}"
  return 1
}

# _register_hooks_unsupported_construct <path> — name the YAML construct that
# puts the file outside this reader's subset, or print nothing.
#
# The reader is lenient rather than strict: it would happily parse `key: &anchor`
# as the string "&anchor" and `key: [a, b]` as the string "[a, b]", producing a
# confidently WRONG classification. FR-024 requires the opposite — say we cannot
# read it, and name what defeated us — so the constructs are detected explicitly
# here rather than inferred from a parse failure that never comes.
#
# `[]` and `{}` are excluded: config_to_yaml emits exactly those for empty
# collections, and calling our own output unreadable would be absurd.
_register_hooks_unsupported_construct() {
  local path="$1" raw body value
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%$'\r'}"
    body="${raw#"${raw%%[![:space:]]*}"}"
    [[ -z "${body}" || "${body}" == "#"* ]] && continue
    if [[ "${body}" == "<<:"* ]]; then
      printf 'a YAML merge key (<<:)'
      return 0
    fi
    # The value is whatever follows the first `: ` of a mapping entry, or the
    # `- ` of a sequence item.
    value=""
    if [[ "${body}" == *": "* ]]; then
      value="${body#*: }"
    elif [[ "${body}" == "- "* ]]; then
      value="${body:2}"
    fi
    value="${value#"${value%%[![:space:]]*}"}"
    case "${value}" in
      '&'*) printf 'a YAML anchor (%s)' "${value%% *}"; return 0 ;;
      '*'*) printf 'a YAML alias (%s)' "${value%% *}"; return 0 ;;
      '{}' | '[]') continue ;;
      '{'* | '['*) printf 'a flow collection (%s…)' "${value:0:1}"; return 0 ;;
    esac
  done < "${path}"
  return 0
}

# _register_hooks_unreadable <path> <detail> — the FR-024 result: `unreadable`
# true, the three partition lists EMPTY, and a hint naming the file and, where
# determinable, the construct. It MUST NOT claim the hooks are missing: we have
# no evidence either way, and "your hooks are missing" about a file we merely
# failed to parse is exactly the false, expensive guidance FR-024 forbids.
_register_hooks_unreadable() {
  local path="$1" detail="$2" hint
  hint="unreadable: ${path} could not be read"
  [[ -n "${detail}" ]] && hint="${hint} (${detail})"
  hint="${hint} — no claim is made about the hooks; fix the file, then re-run /speckit.jira.config"
  jq -cn --arg h "${hint}" '{
    present: [], missing: [], disabled: [], held_disabled: [], duplicated: [],
    unreadable: true, repair_hint: $h
  }' | json_canonical
}

# _register_hooks_hint <missing-json> <held-json> <duplicated-json> <path>
# The repair hint, naming the remedy for whatever is not `present` — literally,
# because every literal it contains is checked by the message↔command CI check
# (FR-018). The three remedies are genuinely different in kind:
#   * missing    — the official install DOES register it (one command);
#   * held       — the release flag on the configuration command;
#   * duplicated — a manual edit, because neither the host nor this extension can
#                  remove an entry the host does not recognise as ours. That is
#                  the one place Constitution X's "one-command repair" cannot be
#                  offered honestly (plan.md § Complexity Tracking).
_register_hooks_hint() {
  local missing="$1" held="$2" dup="$3" path="$4"
  local -a clauses=()
  local list

  list="$(jq -r 'join(", ")' <<< "${missing}")"
  if [[ -n "${list}" ]]; then
    clauses+=("missing: ${list} — register them with: ${HOOK_INSTALL_COMMAND}")
  fi

  list="$(jq -r 'join(", ")' <<< "${held}")"
  if [[ -n "${list}" ]]; then
    local first
    first="$(jq -r '.[0]' <<< "${held}")"
    clauses+=("held disabled: ${list} — no bridge step runs for these, whatever the registry says; release one with: ${HOOK_RELEASE_COMMAND} ${first}")
  fi

  list="$(jq -r 'join(", ")' <<< "${dup}")"
  if [[ -n "${list}" ]]; then
    clauses+=("duplicated: ${list} — a pre-manifest entry names our command with no owning extension, so the official install adds a second entry beside it instead of replacing it; remove the entry that has no \"extension: jira\" field under each named event, by hand, from ${path}")
  fi

  ((${#clauses[@]} == 0)) && return 0
  # Joined by hand, not through IFS: `${array[*]}` uses only the FIRST character
  # of IFS, so a two-character separator would silently become ";" here and
  # "; " on the PowerShell port — a cross-port divergence in a string the
  # conformance suite compares byte for byte (Constitution VI).
  local out="" c
  for c in "${clauses[@]}"; do
    out="${out}${out:+; }${c}"
  done
  printf '%s' "${out}"
}

# register_hooks_health <extensions-yml-path> [disabled-events-json]
# READ-ONLY classification of all seven declared events for the run summary.
# Prints the canonical hook_health object of run-summary.schema.json:
#   { present, missing, disabled, held_disabled, duplicated, unreadable,
#     repair_hint? }
#
# `present`, `missing` and `disabled` partition the seven events ONLY when
# `unreadable` is false. `held_disabled` and `duplicated` are cross-cutting
# ANNOTATIONS, not further partitions: an event may be `present` and
# `held_disabled` (an install re-enabled it and the operator has not released
# it), or `present` and `duplicated` (the canonical entry exists beside a
# leftover one).
#
# Computing this writes NOTHING — not to the registry, not anywhere. The
# operator disable record is written by the ceremony, not by this classification
# (research R5 step 1). Returns EXIT_CONFIG (4) when the registry is unreadable.
register_hooks_health() {
  local path="$1" disabled_rec="${2:-[]}" existing="{}"
  [[ -z "${disabled_rec}" ]] && disabled_rec='[]'
  local events
  events="$(register_hooks_events_json)"

  if [[ -f "${path}" ]]; then
    local construct
    construct="$(_register_hooks_unsupported_construct "${path}")"
    if [[ -n "${construct}" ]]; then
      _register_hooks_unreadable "${path}" "${construct}"
      return "${EXIT_CONFIG}"
    fi
    if ! existing="$(config_yaml_to_json "${path}" 2> /dev/null)"; then
      # Surface the located parse-failure message (file, line, content,
      # remediation) rather than a generic label — the stderr from the same
      # call, captured separately since the first call above discarded it.
      local detail
      detail="$(config_yaml_to_json "${path}" 2>&1 1> /dev/null)"
      _register_hooks_unreadable "${path}" "${detail}"
      return "${EXIT_CONFIG}"
    fi
    # Parsing succeeding is not the same as the file being a registry. The
    # reader is lenient by design, so a genuinely broken file can parse into a
    # confidently WRONG structure — `- broken` under an event becomes the string
    # "broken" where a mapping belongs. Checking the shape of what came back is
    # how a broken file is distinguished from an unsupported construct (FR-024),
    # and it is checked only for the events we classify: another extension's
    # event is none of our business.
    local shape
    # `entries` normalises the two forms the host accepts for an event — a single
    # mapping and a list of mappings (`coerce_hook_entries`, research R1) — into
    # one list. The PowerShell twin gets this normalisation for free (and cannot
    # avoid it): PowerShell unwraps a single-element array on return, so a
    # one-entry event arrives there as a bare mapping. Normalising on both sides
    # is what keeps the two reports identical (Constitution VI).
    shape="$(jq -r --argjson events "${events}" '
      def entries: if type == "array" then . elif . == null then [] else [.] end;
      if (has("hooks") | not) then empty
      elif ((.hooks | type) != "object") then "hooks is not a mapping"
      else (.hooks as $h
            | $events[] as $e
            | select($h | has($e))
            | if any(($h[$e] | entries)[]; type != "object")
              then "hooks.\($e) carries an entry that is not a mapping"
              else empty end)
      end' <<< "${existing}" 2> /dev/null | head -n1)"
    if [[ -n "${shape}" ]]; then
      _register_hooks_unreadable "${path}" "${shape}"
      return "${EXIT_CONFIG}"
    fi
  fi

  # An absent registry is NOT unreadable: we read it successfully and found no
  # entries. Every declared event is genuinely missing, and the official install
  # is the remedy.
  local partitions
  # kcov-excl-start — jq literal (string lines are not statements)
  partitions="$(jq -c --argjson events "${events}" --argjson cmds "$(register_hooks_commands_json)" \
    --arg id "${HOOK_EXTENSION_ID}" --arg bevent "${HOOK_BEFORE_EVENT}" \
    --arg bcmd "${HOOK_BEFORE_COMMAND}" --arg cmd "${HOOK_COMMAND}" \
    --argjson held "${disabled_rec}" '
    def entries: if type == "array" then . elif . == null then [] else [.] end;
    (.hooks // {}) as $h
    | reduce $events[] as $e
        ({present: [], missing: [], disabled: [], duplicated: []};
         (if $e == $bevent then $bcmd else $cmd end) as $c
         | ($h[$e] | entries) as $all
         | ($all | map(select(.extension? == $id and .command? == $c))) as $ours
         | ($all | map(select((has("extension") | not) and (.command? as $x | $cmds | index($x) != null)))) as $leftovers
         | (if ($leftovers | length) > 0 then .duplicated += [$e] else . end)
         | (if ($ours | length) == 0 then .missing += [$e]
            elif any($ours[]; .enabled != false) then .present += [$e]
            else .disabled += [$e] end))
    | . + {held_disabled: ($held | map(select(. as $x | $events | index($x) != null)) | unique),
           unreadable: false}
  ' <<< "${existing}")"
  # kcov-excl-stop

  # The "held disabled" clause covers BOTH sources of a withheld event: an entry
  # the registry currently shows as `enabled: false`, and an event in the
  # operator record that the last install re-enabled in the file. They are one
  # situation from the operator's point of view — no bridge step runs — and one
  # flag releases either, so they are reported as one list rather than two.
  local hint
  hint="$(_register_hooks_hint \
    "$(jq -c '.missing' <<< "${partitions}")" \
    "$(jq -c '(.disabled + .held_disabled) | unique' <<< "${partitions}")" \
    "$(jq -c '.duplicated' <<< "${partitions}")" \
    "${path}")"

  # `repair_hint` appears only when something is not `present` — a healthy run
  # says nothing, so a hint in the summary always means there is work to do.
  if [[ -n "${hint}" ]]; then
    jq -c --arg h "${hint}" '. + {repair_hint: $h}' <<< "${partitions}" | json_canonical
  else
    printf '%s' "${partitions}" | json_canonical
  fi
}
