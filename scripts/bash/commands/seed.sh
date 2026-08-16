#!/usr/bin/env bash
# commands/seed.sh — Moment 2: `speckit.jira.seed` (027, research R1/R7,
# contract seed-cli-contract.md §4/§5).
#
# Agent-invoked, bound to NO hook event (Constitution IV forbids a prompt in
# a lifecycle hook). Validates the pinning markers against `spec.md` as it
# now stands, recomputes the write plan, confirms, then binds, creates, and
# re-parents.
#
# `--parent`/`--story` are accepted here too (contract §2, "feature and seed
# alike"), but only to let the operator RE-STATE the designator set as a
# safety check (S-3/S-4): when neither flag is supplied, the recorded set is
# used as-is and every ordinary decline/resume cycle needs no flags at all,
# exactly as quickstart.md's `seed` / `seed --confirm` pair shows. Supplying
# a different set refuses REF-RESEED before any read.

[[ -n ${_JIRA_CMD_SEED:-} ]] && return 0
_JIRA_CMD_SEED=1

_cmd_seed_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../lib/seed_state.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../engine/pin_marker.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../engine/marker_splice.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../engine/story_marker.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../engine/spec_marker.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../sink/jira/identity.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../sink/jira/designator.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../sink/jira/adoption.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../sink/jira/ticket.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../sink/jira/client.sh"
# shellcheck source=/dev/null
source "${_cmd_seed_dir}/../sink/jira/privacy_guard.sh"

# _seed_emit <json> <json-flag> — print the canonical result.
_seed_emit() {
  local payload="$1" json="$2"
  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${payload}"
  else
    _seed_render_prose "${payload}"
  fi
}

# _seed_render_prose <json> — human prose for the seed result.
_seed_render_prose() {
  local payload="$1"
  if [[ "$(jq -r 'has("confirmation_required")' <<< "${payload}")" == "true" ]]; then
    printf 'Seed: confirmation required\n'
    printf '%s\n' "Write plan"
    local line
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      printf '%s\n' "${line}"
    done <<< "$(jq -r '.confirmation_required.plan[]? // empty' <<< "${payload}")"
  else
    printf 'Seed: active\n'
  fi
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf 'Warning: %s\n' "${line}"
  done <<< "$(jq -r '.warnings[]? // empty' <<< "${payload}")"
}

# _seed_partial_report <bindings> <mode> <target-key> <free-text> <remaining-story-keys>
# — FR-042 (T159): the report of exactly which bindings completed and which
# did not, for the failure path of a `--confirm` run. `bindings` is the
# in-memory array grown ONLY on a successful write, so "remaining" is
# everything else this run intended to bind: the parent designator, when
# `mode` names one and no parent binding is in `bindings` yet, plus every
# story key in `remaining_story_keys` not already in `bindings`.
_seed_partial_report() {
  local bindings="$1" mode="$2" target_key="$3" free_text="$4" rem_keys="$5"
  local parent_desig=""
  if [[ "${mode}" != "none" ]] && [[ "$(jq -r '[.[] | select(.role=="parent")] | length' <<< "${bindings}")" == "0" ]]; then
    if [[ "${mode}" == "create" ]]; then parent_desig="${free_text}"; else parent_desig="${target_key}"; fi
  fi
  jq -cn --argjson b "${bindings}" --argjson rem "${rem_keys}" --arg p "${parent_desig}" '
    ($b | map(select(.role=="story") | .key)) as $done |
    { bindings: $b,
      remaining: (([$p] | map(select(length > 0))) + ($rem - $done)) }
  '
}

# _seed_designator_keys <seed-record-json> — the ordered array of designated
# keys (role=story) recorded in the seed record, for pin_marker_validate.
_seed_designator_keys() {
  jq -c '[.designators[] | select(.role=="story") | .key]' <<< "$1"
}

# _seed_parent_designator <seed-record-json> — the recorded specification-
# role designator object, or empty when none is recorded.
_seed_parent_designator() {
  jq -c '[.designators[] | select(.role=="specification")][0] // empty' <<< "$1"
}

# _seed_ref_message <code> <detail> — REF-DESIGNATOR/REF-HOST/REF-DUPLICATE/
# REF-RESEED message + remediation. Text mirrors spec.md's FR-036 table
# verbatim (the same cases feature.sh's `_feat_ref_message` composes for
# moment 1 — this is moment 2's own copy, since the two files never source
# one another).
_seed_ref_message() {
  local code="$1" detail="$2"
  case "${code}" in
    REF-DESIGNATOR) printf '%s: %s — paste the issue key or the browser URL of the issue; or, for a parent to create, type its title' "${code}" "${detail}" ;;
    REF-HOST) printf '%s: %s — paste a URL from the configured site, or correct the site base URL in the configuration' "${code}" "${detail}" ;;
    REF-DUPLICATE) printf '%s: %s — remove the duplicate designator' "${code}" "${detail}" ;;
    REF-MULTIPROJECT) printf '%s: %s — name issues from one project per specification' "${code}" "${detail}" ;;
    REF-RESEED) printf '%s: %s — re-invoke with the recorded set, or create a new specification' "${code}" "${detail}" ;;
    *) printf '%s: %s' "${code}" "${detail}" ;;
  esac
}

# _seed_decomp_message <violations-json> — one human line per FR-058
# violation (P1-P4 of pin-marker.md §5), naming the offending key/line, in
# `pin_marker_validate`'s own order. All violations are printed together
# (FR-019, Principle XVI) — never one at a time. Used on a FIRST run
# (REF-DECOMP): the drafted decomposition disagreed with the human's.
_seed_decomp_message() {
  jq -r '
    .[] |
    if .kind == "missing" then
      "designated key \(.key) carries no pinning marker — add <!-- speckit-jira pin=\(.key) --> after its user story heading, or re-invoke with a different designator set"
    elif .kind == "orphan" then
      "marker names \(.key), which was not designated (line \(.lines[0])) — remove the marker, or add \(.key) to the designator set"
    elif .kind == "split" then
      "key \(.key) carries more than one marker (line \(.lines | map(tostring) | join(", "))) — keep exactly one"
    elif .kind == "merge" then
      "more than one marker names the same user story (line \(.lines | map(tostring) | join(", "))) — one marker per user story"
    elif .kind == "malformed" then
      "malformed pinning marker at line \(.line) — the pin= value must be non-empty and contain no whitespace"
    elif .kind == "reorder" then
      "the pinned user stories are not in the order the issues were designated — reorder them to match, or re-invoke with the current order"
    else
      "pinning validation failed"
    end
  ' <<< "$1"
}

# _seed_draft_edit_message <violations-json> — the same four properties as
# _seed_decomp_message, worded for a RESUME (REF-DRAFT-EDIT, FR-063): the
# cause is the operator's own edit to spec.md, not the agent's draft, so the
# remediation is "restore it" or "start over" — never "re-invoke with a
# different designator set", which would blame the wrong party.
_seed_draft_edit_message() {
  jq -r '
    .[] |
    if .kind == "missing" then
      "the pinned user story for \(.key) has vanished — restore its heading and the <!-- speckit-jira pin=\(.key) --> marker, or start over with a new specification"
    elif .kind == "orphan" then
      "marker names \(.key), which is no longer designated (line \(.lines[0])) — restore the original designator set, or start over with a new specification"
    elif .kind == "split" then
      "the marker for \(.key) is now duplicated (line \(.lines | map(tostring) | join(", "))) — keep exactly one, or start over with a new specification"
    elif .kind == "merge" then
      "more than one marker now names the same user story (line \(.lines | map(tostring) | join(", "))) — keep one marker per user story, or start over with a new specification"
    elif .kind == "malformed" then
      "the pinning marker at line \(.line) is now malformed — restore its pin=<key> shape, or start over with a new specification"
    elif .kind == "reorder" then
      "a pinning marker has moved out of its designated order — restore the original order, or start over with a new specification"
    else
      "pinning validation failed"
    end
  ' <<< "$1"
}

# _seed_overview_text <content> — the text FR-023's "drafted overview" names:
# everything from the line after the document's H1 (or its very start when
# there is none) up to, but not including, the first user-story anchor.
# Blank lines collapsed to single spaces, trimmed. Reuses pin_marker's own
# anchor scan (R10 — no second pass).
_seed_overview_text() {
  local content="$1"
  local -a anchors=()
  while IFS= read -r a; do anchors+=("${a}"); done < <(pin_marker_anchors "${content}")
  local end=""
  if ((${#anchors[@]} > 0)); then end="${anchors[0]}"; fi
  local h1=0 lineno=0 line lc out=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    lc="${line%$'\r'}"
    if ((h1 == 0)) && [[ -n "${end}" && "${lineno}" -ge "${end}" ]]; then break; fi
    if ((h1 == 0)) && [[ "${lc}" =~ ^#[[:space:]] ]]; then
      h1="${lineno}"
      continue
    fi
    ((h1 == 0)) && [[ -z "${end}" ]] && continue
    [[ -n "${end}" && "${lineno}" -ge "${end}" ]] && break
    out+="${lc} "
  done <<< "${content}"
  printf '%s' "$(_desig_trim "${out}")"
}

# _seed_bound_story_keys <content> <story-keys-json> — the subset already
# carrying a BOUND `story=<id> ticket=<KEY>` marker (R14, a partial run's
# completed bindings) — one pass, no per-key grep.
_seed_bound_story_keys() {
  local content="$1" keys_json="$2" n i
  local result='[]'
  n="$(jq 'length' <<< "${keys_json}")"
  for ((i = 0; i < n; i++)); do
    local k
    k="$(jq -r ".[${i}]" <<< "${keys_json}")"
    if grep -qE "<!-- speckit-jira story=[0-9a-f]{16} ticket=${k} -->" <<< "${content}"; then
      result="$(jq -c --arg k "${k}" '. + [$k]' <<< "${result}")"
    fi
  done
  printf '%s' "${result}" | json_canonical
}

# _seed_plan_entries <mode> <target-key-or-empty> <free-text-or-empty>
# <story-keys-json> <infos-json-object> — builds the plan entries (§5.1):
# an adopt/create line for the parent (when a specification role is
# designated and not yet bound), an adopt line per remaining story, a
# reparent line for each remaining story whose CURRENT parent differs from
# the designated one (mode adopt) or exists at all (mode create — the
# target does not exist yet, so any current parent differs), and a note
# line per remaining story already parented when NO specification role is
# designated at all (FR-061). `infos` maps KEY -> {summary,status,parent}.
_seed_plan_entries() {
  local mode="$1" target_key="$2" free_text="$3" story_keys="$4" infos="$5"
  jq -cn --arg mode "${mode}" --arg tkey "${target_key}" --arg ft "${free_text}" \
    --argjson skeys "${story_keys}" --argjson infos "${infos}" '
    def child_word(n): if n == 1 then "child" else "children" end;
    ( if $mode == "adopt" and $tkey != "" then
        [{verb:"adopt", key:$tkey, role:"specification", summary:(($infos[$tkey].summary) // "")}]
      elif $mode == "create" then
        [{verb:"create", key:null, role:"specification", summary:$ft}]
      else [] end ) as $parent_entry
    | ( $skeys | map({verb:"adopt", key:., role:"story", summary:(($infos[.].summary) // "")}) ) as $story_entries
    | ( if $mode == "none" then []
        else
          ( $skeys
            | map(. as $k | ($infos[$k].parent) as $p
                | select($p != null)
                | select($mode == "create" or ($p.key != $tkey))
                | {key:$k, from_key:$p.key, from_summary:$p.summary, from_status:$p.status})
          ) as $moves
          | ( $moves | group_by(.from_key) | map(.[0].from_key) ) as $from_keys
          | ( $moves | map(. as $m | ($moves | map(select(.from_key == $m.from_key)) | length) as $loses
              | {verb:"reparent", key:$m.key, from_key:$m.from_key, from_summary:$m.from_summary, from_status:$m.from_status, loses:$loses}) )
        end ) as $reparent_entries
    | ( if $mode == "none" then
          $skeys | map(. as $k | ($infos[$k].parent) as $p | select($p != null)
            | {verb:"note", key:$k, parent_key:$p.key, parent_summary:$p.summary})
        else [] end ) as $note_entries
    | $parent_entry + $story_entries + $reparent_entries + $note_entries
  ' | json_canonical
}

# _seed_plan_render <entries-json> — contract §5.1's literal line rendering
# (the byte-pinned format), one jq call over the whole entries array — no
# per-entry spawn (docs/11-process-budget.md). Prints a canonical JSON
# array of line strings (the header "Write plan" is the prose renderer's
# own literal, never stored here).
_seed_plan_render() {
  jq -c '
    def pad(w): (. // "" | tostring) as $s | if ($s|length) < w then $s + (" " * (w - ($s|length))) else $s end;
    def childword(n): if n == 1 then "child" else "children" end;
    map(
      if .verb == "adopt" or .verb == "create" then
        "  " + (.verb|pad(10)) + ((.key // "-")|pad(8)) + (.role|pad(14)) + (.summary // "")
      elif .verb == "reparent" then
        "! " + (.verb|pad(10)) + ((.key // "-")|pad(8)) + "from " + .from_key + " \"" + .from_summary + "\" [" + .from_status + "] - loses " + (.loses|tostring) + " " + childword(.loses)
      elif .verb == "note" then
        "  " + (.verb|pad(10)) + ((.key // "-")|pad(8)) + "stays under " + .parent_key + " \"" + .parent_summary + "\" - re-run naming a parent to group"
      else empty end
    )
  ' <<< "$1" | json_canonical
}

# _seed_plan_delta <old-rendered-lines-json> <new-rendered-lines-json> —
# FR-064: which lines were added, and which have disappeared, vs the
# previously displayed plan.
_seed_plan_delta() {
  jq -cn --argjson old "$1" --argjson new "$2" '{added: ($new - $old), removed: ($old - $new)}' | json_canonical
}

# _seed_scatter_warnings <entries-json> — FR-061: the run-summary half of
# the scatter disclosure (the provenance-shaped half is the "note" entries
# themselves, already in the plan/provenance).
_seed_scatter_warnings() {
  jq -r '
    .[] | select(.verb == "note") |
    "\(.key) stays under \(.parent_key) (\"\(.parent_summary)\") — re-run naming a parent to group it"
  ' <<< "$1"
}

# cmd_seed <argv...> — see the file header.
cmd_seed() {
  local parsed json="false" dry_run="false" confirm="false" args="" exit_code="0" error=""
  local parent_seen="false" parent="" stories=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      confirm) confirm="${value}" ;;
      args) args="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
      parent_seen) parent_seen="${value}" ;;
      parent) parent="${value}" ;;
      stories) stories="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'seed: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  local -a words=()
  read -ra words <<< "${args}"
  local spec_file="${words[0]:-}"
  if [[ -z "${spec_file}" || ! -f "${spec_file}" ]]; then
    printf 'seed: a readable spec file argument is required\n' >&2
    return "$(cli_exit_code usage)"
  fi

  # §4 step 1: read the seed record. Absence distinguishes two states
  # (seed-record.md §4): a specification already carrying an identity
  # marker is BOUND — C-13's idempotent second run, zero writes, exit 0 —
  # while one carrying neither record nor identity is a crash mid-draft,
  # REF-EXISTS. A single grep for the bound story-marker shape is enough:
  # no per-key scan, one pass over the file.
  local record
  if ! record="$(seed_state_read "${spec_file}")"; then
    if grep -qE '<!-- speckit-jira story=[0-9a-f]{16} ticket=' "${spec_file}" 2> /dev/null; then
      _seed_emit "$(jq -cn '{active:true, bindings:[]}' | json_canonical)" "${json}"
      return 0
    fi
    printf 'seed: no seeded-not-bound state was found for %s — REF-EXISTS: retro-seeding is out of scope; create a new specification\n' "${spec_file}" >&2
    return "$(cli_exit_code config)"
  fi

  # --- §4 step 2: compare designator sets, ONLY when the operator resupplied
  # them (S-3/S-4) — an ordinary decline/resume cycle passes neither flag,
  # and the recorded set is used as-is. -----------------------------------
  local base_url="${SPEC_KIT_JIRA_BASE_URL:-}"
  if [[ "${parent_seen}" == "true" || -n "${stories}" ]]; then
    local -a classified=()
    if [[ "${parent_seen}" == "true" ]]; then
      classified+=("$(designator_classify specification "${parent}" "${base_url}")")
    fi
    if [[ -n "${stories}" ]]; then
      local -a story_raws=()
      IFS=$'\x1f' read -r -a story_raws <<< "${stories}"
      local raw
      for raw in "${story_raws[@]}"; do
        classified+=("$(designator_classify story "${raw}" "${base_url}")")
      done
    fi
    local all_json
    all_json="$(printf '%s\n' "${classified[@]}" | jq -s -c .)"
    local refusing refusing_count
    refusing="$(jq -c '[.[] | select(has("refuse"))]' <<< "${all_json}")"
    refusing_count="$(jq 'length' <<< "${refusing}")"
    if ((refusing_count > 0)); then
      local line
      while IFS= read -r line; do
        local code="${line%%:*}" detail="${line#*: }"
        printf 'seed: %s\n' "$(_seed_ref_message "${code}" "designator \"${detail}\" did not resolve")" >&2
      done <<< "$(jq -r '.[] | "\(.refuse): \(.raw)"' <<< "${refusing}")"
      return "$(cli_exit_code config)"
    fi
    local dedupe
    dedupe="$(designator_dedupe "${all_json}")"
    if [[ "$(jq -r '.ok' <<< "${dedupe}")" != "true" ]]; then
      local dups
      dups="$(jq -r '.duplicates | join(", ")' <<< "${dedupe}")"
      printf 'seed: %s\n' "$(_seed_ref_message REF-DUPLICATE "issue(s) named more than once: ${dups}")" >&2
      return "$(cli_exit_code config)"
    fi
    local current_designators
    current_designators="$(jq -c '.designators' <<< "${dedupe}")"
    if [[ "$(seed_state_designators_equal "$(jq -c '.designators' <<< "${record}")" "${current_designators}")" != "true" ]]; then
      printf 'seed: %s\n' "$(_seed_ref_message REF-RESEED "the supplied designator set differs from the one recorded for this specification")" >&2
      return "$(cli_exit_code config)"
    fi
  fi

  # The record is always the authoritative designator source (order, roles,
  # keys) — a resupplied set on this invocation was only a safety check,
  # already proven equal above.
  local story_keys parent_designator pform pkey free_text
  story_keys="$(_seed_designator_keys "${record}")"
  parent_designator="$(_seed_parent_designator "${record}")"
  pform="$(jq -r '.form // ""' <<< "${parent_designator:-{\}}")"
  pkey=""
  free_text=""
  [[ "${pform}" == "key" || "${pform}" == "url" ]] && pkey="$(jq -r '.key' <<< "${parent_designator}")"
  [[ "${pform}" == "free_text" ]] && free_text="$(jq -r '.text' <<< "${parent_designator}")"

  # mode: "adopt" (existing parent named), "create" (free-text parent),
  # "none" (no specification-role designator at all — FR-024/FR-061).
  local mode="none"
  [[ -n "${pkey}" ]] && mode="adopt"
  [[ -n "${free_text}" ]] && mode="create"

  # resume = a prior gate-reach (the decline path) already rendered and
  # recorded a plan_digest. The very first gate-reach after moment 1 always
  # has plan_digest:null.
  local resume="false"
  [[ "$(jq -r '.plan_digest // "null"' <<< "${record}")" != "null" ]] && resume="true"

  local routing
  routing="$(jq -c '.routing // {}' <<< "${record}")"

  # --- R14/FR-042: a partial run's completed bindings are excluded from
  # every remaining step — a key already carrying a BOUND story= marker was
  # finished by an earlier, interrupted invocation; the parent's own
  # spec= marker's "bound" state means the same for it. -------------------
  local spec_content
  spec_content="$(cat "${spec_file}" 2> /dev/null; printf x)"; spec_content="${spec_content%x}"
  local bound_keys remaining_story_keys
  bound_keys="$(_seed_bound_story_keys "${spec_content}" "${story_keys}")"
  remaining_story_keys="$(jq -c --argjson bound "${bound_keys}" '[.[] as $k | select(($bound | index($k)) == null) | $k]' <<< "${story_keys}")"

  local parent_info parent_state parent_bound_key
  parent_info="$(spec_marker_document_info "${spec_content}")"
  parent_state="$(jq -r '.state' <<< "${parent_info}")"
  parent_bound_key=""
  if [[ "${parent_state}" == "bound" ]]; then
    parent_bound_key="$(jq -r '.ticket' <<< "${parent_info}")"
    pkey="${parent_bound_key}"
    mode="adopt" # already exists on disk, whichever way it got there
  elif [[ "${mode}" == "create" && "${parent_state}" == "creating" ]]; then
    printf 'seed: a previous run began creating the parent but did not finish — check Jira for a duplicate before re-invoking; if none was created, remove the <!-- speckit-jira spec=... creating --> marker from spec.md and retry\n' >&2
    return "$(cli_exit_code config)"
  fi

  # --- §4 steps 4-5: resume-only Jira re-read + full refusal re-evaluation
  # (FR-062) — a first gate-reach trusts moment 1's fresh read entirely and
  # issues ZERO requests here (T100's one-way-read guarantee). --------------
  local infos='{}'
  if [[ "${resume}" == "true" ]]; then
    local -a keys=()
    [[ -n "${pkey}" ]] && keys+=("${pkey}")
    local n i
    n="$(jq 'length' <<< "${remaining_story_keys}")"
    for ((i = 0; i < n; i++)); do keys+=("$(jq -r ".[${i}]" <<< "${remaining_story_keys}")"); done

    if ((${#keys[@]} > 0)); then
      local load_rc=0
      adoption_load "${keys[@]}" || load_rc=$?
      if ((load_rc != 0)); then
        printf 'seed: an unreliable read occurred while re-resolving the named issues on resume — the run refuses rather than proceeding without them (FR-038, FR-062)\n' >&2
        return "$(cli_exit_code fail_closed)"
      fi
    fi

    local spec_ref
    spec_ref="$(jq -cn --arg r "${SPEC_KIT_JIRA_REPO:-local/repo}" --arg s "${SPEC_KIT_JIRA_SPEC_SLUG:-spec}" '{repo:$r, spec_slug:$s}')"
    local routed_project dts dtst term
    routed_project="$(jq -r '.project // ""' <<< "${routing}")"
    dts="$(jq -r '.declared_type_specification // ""' <<< "${routing}")"
    dtst="$(jq -r '.declared_type_story // ""' <<< "${routing}")"
    term="$(jq -r '.terminal_statuses_csv // ""' <<< "${routing}")"

    local -a eval_results=()
    if [[ -n "${pkey}" ]]; then
      eval_results+=("$(adoption_evaluate "${routed_project}" specification "${pkey}" "${dts}" "${term}" "${spec_ref}")")
    fi
    n="$(jq 'length' <<< "${remaining_story_keys}")"
    for ((i = 0; i < n; i++)); do
      local skey
      skey="$(jq -r ".[${i}]" <<< "${remaining_story_keys}")"
      eval_results+=("$(adoption_evaluate "${routed_project}" story "${skey}" "${dtst}" "${term}" "${spec_ref}")")
    done
    local eval_json
    if ((${#eval_results[@]} > 0)); then
      eval_json="$(printf '%s\n' "${eval_results[@]}" | jq -s -c .)"
    else
      eval_json='[]'
    fi
    local mp
    mp="$(adoption_multiproject_violation "${remaining_story_keys}")"
    if [[ "$(jq 'length' <<< "${mp}")" -gt 0 ]]; then
      eval_json="$(jq -c --arg msg "$(_seed_ref_message REF-MULTIPROJECT "named story-role issues span more than one project: $(jq -r 'join(", ")' <<< "${mp}")")" \
        '. + [{"code":"REF-MULTIPROJECT","key":"","message":$msg}]' <<< "${eval_json}")"
    fi
    local refusals refusals_count
    refusals="$(adoption_aggregate_refusals "${eval_json}")"
    refusals_count="$(jq 'length' <<< "${refusals}")"
    if ((refusals_count > 0)); then
      while IFS= read -r line; do
        printf 'seed: %s\n' "${line}" >&2
      done <<< "$(jq -r '.[] | "\(.code): \(.message)"' <<< "${refusals}")"
      return "$(cli_exit_code config)"
    fi

    # infos for the plan, from the FRESH read.
    local ij='{}' entry
    if [[ -n "${pkey}" ]]; then
      entry="$(adoption_get "${pkey}")"
      ij="$(jq -c --arg k "${pkey}" --argjson f "$(jq -c '.fields' <<< "${entry}")" \
        '. + {($k): {summary:($f.summary // ""), status:($f.status.name // ""), parent:(if $f.parent then {key:$f.parent.key, summary:($f.parent.fields.summary // ""), status:($f.parent.fields.status.name // "")} else null end)}}' <<< "${ij}")"
    fi
    n="$(jq 'length' <<< "${remaining_story_keys}")"
    for ((i = 0; i < n; i++)); do
      local skey
      skey="$(jq -r ".[${i}]" <<< "${remaining_story_keys}")"
      entry="$(adoption_get "${skey}")"
      ij="$(jq -c --arg k "${skey}" --argjson f "$(jq -c '.fields' <<< "${entry}")" \
        '. + {($k): {summary:($f.summary // ""), status:($f.status.name // ""), parent:(if $f.parent then {key:$f.parent.key, summary:($f.parent.fields.summary // ""), status:($f.parent.fields.status.name // "")} else null end)}}' <<< "${ij}")"
    done
    infos="${ij}"
  else
    # First run: the seed material file moment 1 already wrote — NO Jira
    # read here (T100's one-way-read guarantee for the first gate-reach).
    # The material already carries status/parent (FR-051's "0 additional
    # requests" — Jira's own bulkfetch nests a reduced parent representation
    # inline, so moment 1's single read already had this).
    local short_name material_path material
    short_name="$(basename "$(dirname "${spec_file}")")"
    material_path="${JIRA_CONFIG_DIR:-.specify/jira}/state/${short_name}.seed-material.json"
    if [[ -f "${material_path}" ]]; then
      material="$(cat "${material_path}" 2> /dev/null)"
      infos="$(jq -c '[.[] | {(.key): {summary, status, parent}}] | add // {}' <<< "${material}")"
    fi
  fi

  # §4 step 6: validate the pinning markers against spec.md as it now
  # stands (FR-058, FR-063), over the REMAINING (not-yet-bound) keys only.
  # First run -> REF-DECOMP; resume -> REF-DRAFT-EDIT.
  local violations
  violations="$(pin_marker_validate "${spec_file}" "${remaining_story_keys}")"
  if [[ "$(jq 'length' <<< "${violations}")" -gt 0 ]]; then
    if [[ "${resume}" == "true" ]]; then
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        printf 'seed: REF-DRAFT-EDIT: %s\n' "${line}" >&2
      done <<< "$(_seed_draft_edit_message "${violations}")"
    else
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        printf 'seed: REF-DECOMP: %s\n' "${line}" >&2
      done <<< "$(_seed_decomp_message "${violations}")"
    fi
    return "$(cli_exit_code config)"
  fi

  # FR-053: an empty/whitespace free-text parent already refuses REF-DESIGNATOR
  # at classify time (designator.sh) — nothing further to check here.
  # FR-023: a free-text parent create needs the resolved type id; without
  # one (project never bound, or no hierarchy.specification), refuse before
  # any write rather than let the create fail opaquely against Jira.
  if [[ "${mode}" == "create" && -z "${parent_bound_key}" ]]; then
    local ptid; ptid="$(jq -r '.parent_type_id // ""' <<< "${routing}")"
    if [[ -z "${ptid}" ]]; then
      printf 'seed: the specification-role issue type could not be resolved for this project — run /speckit.jira.config to bind it, then re-invoke\n' >&2
      return "$(cli_exit_code config)"
    fi
  fi

  # §4 step 7: compute the write plan from the CURRENT spec.md.
  local target_key="${pkey}"
  local entries plan
  entries="$(_seed_plan_entries "${mode}" "${target_key}" "${free_text}" "${remaining_story_keys}" "${infos}")"
  plan="$(_seed_plan_render "${entries}")"
  local scatter_warnings
  scatter_warnings="$(_seed_scatter_warnings "${entries}")"

  # §4 step 8: provenance — each named issue to the section it seeded (the
  # parent, when designated, seeds the overview; each story, its section) —
  # and each drafted user story to its source, key or "new".
  local provenance
  provenance="$(pin_marker_provenance "${spec_content}" "${remaining_story_keys}")"
  if [[ "${mode}" != "none" ]]; then
    local prov_src="${target_key}"
    [[ -z "${prov_src}" ]] && prov_src="new"
    provenance="$(jq -c --arg s "${prov_src}" '[{heading:"Overview", source:$s}] + .' <<< "${provenance}" | json_canonical)"
  fi

  # delta vs the previously displayed plan — a resume-only disclosure
  # (FR-064); a first gate-reach has no previous plan to diff against.
  local delta='{}'
  if [[ "${resume}" == "true" ]]; then
    local old_snapshot
    old_snapshot="$(jq -c '.plan_snapshot // []' <<< "${record}")"
    delta="$(_seed_plan_delta "${old_snapshot}" "${plan}")"
  fi

  local warnings_json
  warnings_json="$(jq -Rn '[inputs] | map(select(length > 0))' <<< "${scatter_warnings}")"

  if [[ "${dry_run}" == "true" ]]; then
    _seed_emit "$(jq -cn --argjson plan "${plan}" --argjson prov "${provenance}" --argjson delta "${delta}" --argjson w "${warnings_json}" \
      '{active:true, confirmation_required:{plan:$plan, provenance:$prov, delta:$delta}, warnings:$w}' | json_canonical)" "${json}"
    return 0
  fi

  if [[ "${confirm}" != "true" ]]; then
    # C-7/C-8: zero mutations, exit 0, confirmation_required. The record is
    # rewritten with the freshly rendered plan (same designators, still
    # bindings:[]) so a LATER resume can compute FR-064's delta against it.
    local new_digest doc
    new_digest="$(seed_state_plan_digest "$(jq -r '.[]' <<< "${plan}")")"
    doc="$(seed_state_compose "$(jq -r '.slug' <<< "${record}")" "$(jq -c '.designators' <<< "${record}")" "${new_digest}" "${routing}" "${plan}")"
    seed_state_write "${spec_file}" "${doc}"

    _seed_emit "$(jq -cn --argjson plan "${plan}" --argjson prov "${provenance}" --argjson delta "${delta}" --argjson w "${warnings_json}" \
      '{active:true, confirmation_required:{plan:$plan, provenance:$prov, delta:$delta}, warnings:$w}' | json_canonical)" "${json}"
    return 0
  fi

  # --- FR-065 (T158): the two-tier pre-write privacy guard, over spec.md as
  # it now stands, again before the first Jira mutation — the tier-1 scan in
  # feature.sh covers the seed material before drafting; this is the second
  # required pass. A BLOCK is zero writes of any kind, local or Jira.
  privacy_guard_scan "${spec_content}" "[]" "${SPEC_KIT_JIRA_ALLOWLIST:-[]}" || return $?

  # --confirm: bind every remaining named story (FR-057), adopt or create
  # the parent (FR-022/FR-023), and place/re-parent as designated (FR-025/
  # FR-026) — never when mode is "none" (FR-024, T133's scoping).
  local nl_token nl
  nl_token="$(marker_splice_dominant_nl_token "${spec_content}")"
  if [[ "${nl_token}" == "CRLF" ]]; then nl=$'\r\n'; else nl=$'\n'; fi

  # spec_ref.spec_slug prefers SPEC_KIT_JIRA_SPEC_SLUG (the host's own
  # numbered feature id) — never the recorded seed-state slug.
  local repo spec_ref
  repo="${SPEC_KIT_JIRA_REPO:-local/repo}"
  spec_ref="$(jq -cn --arg r "${repo}" --arg s "${SPEC_KIT_JIRA_SPEC_SLUG:-spec}" '{repo:$r, spec_slug:$s}')"

  local bindings='[]'

  if [[ -n "${parent_bound_key}" ]]; then
    # Already fully bound by an earlier, interrupted run — nothing to do.
    target_key="${parent_bound_key}"
  elif [[ "${mode}" == "adopt" ]]; then
    # Parent adoption (US3): an operator-named existing parent is bound
    # with a new spec= marker, origin:human, role:parent — never created.
    local assigned sm_id
    assigned="$(printf '%s' "${spec_content}" | spec_marker_assign; printf x)"; assigned="${assigned%x}"
    sm_id="$(jq -r '.id' <<< "$(spec_marker_document_info "${assigned}")")"
    spec_content="$(printf '%s' "${assigned}" | spec_marker_record_ticket "${sm_id}" "${pkey}"; printf x)"
    spec_content="${spec_content%x}"
    marker_splice_write_file "${spec_file}" "${spec_content}" > /dev/null
    local rc=0
    identity_write "${pkey}" "${spec_ref}" "human" "" "parent" "" || rc=$?
    if ((rc != 0)); then
      _seed_emit "$(_seed_partial_report "${bindings}" "${mode}" "${pkey}" "${free_text}" "${remaining_story_keys}" | json_canonical)" "${json}"
      return "${rc}"
    fi
    bindings="$(jq -c --arg k "${pkey}" '. + [{key:$k, role:"parent", origin:"human"}]' <<< "${bindings}")"
    target_key="${pkey}"
  elif [[ "${mode}" == "create" ]]; then
    # Parent creation (US2, FR-023): a free-text title creates EXACTLY one
    # specification-role issue, no lookup of any kind. The marker is
    # assigned, then marked "creating" — both written to disk BEFORE the
    # POST (FR-028) — so an interruption between the POST and the record is
    # visible on the next invocation rather than silently retried into a
    # duplicate.
    local assigned sm_id ptid
    assigned="$(printf '%s' "${spec_content}" | spec_marker_assign; printf x)"; assigned="${assigned%x}"
    sm_id="$(jq -r '.id' <<< "$(spec_marker_document_info "${assigned}")")"
    spec_content="$(printf '%s' "${assigned}" | spec_marker_mark_creating "${sm_id}"; printf x)"
    spec_content="${spec_content%x}"
    marker_splice_write_file "${spec_file}" "${spec_content}" > /dev/null

    ptid="$(jq -r '.parent_type_id' <<< "${routing}")"
    local routed_project; routed_project="$(jq -r '.project // ""' <<< "${routing}")"
    local created rc=0
    created="$(ticket_create "${routed_project}" "${free_text}" "${ptid}" '[]' '[]' "${spec_ref}" "parent")" || rc=$?
    if ((rc != 0)); then
      _seed_emit "$(_seed_partial_report "${bindings}" "${mode}" "${target_key}" "${free_text}" "${remaining_story_keys}" | json_canonical)" "${json}"
      return "${rc}"
    fi
    local new_key; new_key="$(jq -r '.key' <<< "${created}")"

    spec_content="$(printf '%s' "${spec_content}" | spec_marker_record_ticket "${sm_id}" "${new_key}"; printf x)"
    spec_content="${spec_content%x}"
    marker_splice_write_file "${spec_file}" "${spec_content}" > /dev/null
    # ticket_create already identity-stamps origin:bridge with the summary
    # recorded (FR-052) — no second identity write here.
    bindings="$(jq -c --arg k "${new_key}" '. + [{key:$k, role:"parent", origin:"bridge"}]' <<< "${bindings}")"
    target_key="${new_key}"
  fi

  local n i
  n="$(jq 'length' <<< "${remaining_story_keys}")"
  for ((i = 0; i < n; i++)); do
    local key sid replacement
    key="$(jq -r ".[${i}]" <<< "${remaining_story_keys}")"

    # Placement / re-parenting (FR-025/FR-026): fires ONLY when a parent is
    # designated (mode != none) and the story's current parent differs.
    if [[ "${mode}" != "none" && -n "${target_key}" ]]; then
      local cur_parent
      cur_parent="$(jq -r --arg k "${key}" '.[$k].parent.key // ""' <<< "${infos}")"
      if [[ "${cur_parent}" != "${target_key}" ]]; then
        local place_body place_rc=0
        place_body="$(jq -cn --arg k "${target_key}" '{fields:{parent:{key:$k}}}')"
        jira_request PUT "${SPEC_KIT_JIRA_BASE_URL:-}/rest/api/3/issue/${key}" "${place_body}" > /dev/null || place_rc=$?
        if ((place_rc != 0)); then
          _seed_emit "$(_seed_partial_report "${bindings}" "${mode}" "${target_key}" "${free_text}" "${remaining_story_keys}" | json_canonical)" "${json}"
          return "${place_rc}"
        fi
      fi
    fi

    sid="$(story_marker_generate_id)"
    replacement="$(story_marker_format "${sid}" bound "${key}")"
    # The identifier is written to disk BEFORE the Jira write (FR-028,
    # docs/08-safety-model.md): an interrupted run leaves exactly the
    # completed replacements, each already recorded — nothing batched.
    spec_content="$(pin_marker_consume "${spec_content}" "${key}" "${replacement}" "${nl}"; printf x)"
    spec_content="${spec_content%x}"
    marker_splice_write_file "${spec_file}" "${spec_content}" > /dev/null
    local story_rc=0
    identity_write "${key}" "${spec_ref}" "human" "${sid}" "story" "" || story_rc=$?
    if ((story_rc != 0)); then
      _seed_emit "$(_seed_partial_report "${bindings}" "${mode}" "${target_key}" "${free_text}" "${remaining_story_keys}" | json_canonical)" "${json}"
      return "${story_rc}"
    fi
    bindings="$(jq -c --arg k "${key}" '. + [{key:$k, role:"story", origin:"human"}]' <<< "${bindings}")"
  done

  seed_state_delete "${spec_file}"
  _seed_emit "$(jq -cn --argjson b "${bindings}" '{active:true, bindings:$b}' | json_canonical)" "${json}"
  return 0
}
