#!/usr/bin/env bash
# commands/feature.sh — Ticket-first feature naming (002 US3, FR-013…FR-017).
#
# `cmd_feature <argv...>` is the deterministic step registered as the
# `before_specify` hook. It loads the committed `teams:` catalogue and the
# human-owned `.specify/jira/personal.yml` selection, resolves the effective
# team (honouring a cross-team `--use-team` confirmation), resolves the Jira
# ticket BEFORE naming (validate a mentioned key, else guarded-create one), and
# emits the branch name and flat folder short-name.
#
# Non-blocking by construction (FR-016/FR-017): no team selected ⇒
# {active:false}; Jira unreachable or a create refused ⇒ {active:false} plus one
# warning. The host specify flow then proceeds exactly as it does today.

[[ -n ${_JIRA_CMD_FEATURE:-} ]] && return 0
_JIRA_CMD_FEATURE=1

_cmd_feature_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/config.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../engine/naming.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../sink/jira/ticket.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../sink/jira/designator.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../sink/jira/adoption.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../lib/seed_state.sh"
# shellcheck source=/dev/null
source "${_cmd_feature_dir}/../sink/jira/privacy_guard.sh"

# _feat_designator_number_source <parent-classified-json-or-empty>
# <stories-classified-json-array> — FR-059/research R9: which key supplies
# the naming engine's number. `engine/naming.sh` gains zero lines — this
# selects WHICH key is handed to the existing `naming_ticket_number`.
# Prints the key and returns 0 for shapes 1-4; returns 1 and prints nothing
# for shape 5 (free-text parent, no stories) — NOT a refusal, the caller
# falls through to the ordinary description-derived naming unchanged.
_feat_designator_number_source() {
  local parent_json="${1:-}" stories_json="${2:-[]}"
  if [[ -n "${parent_json}" ]]; then
    local form
    form="$(jq -r '.form // empty' <<< "${parent_json}")"
    if [[ "${form}" == "key" || "${form}" == "url" ]]; then
      jq -r '.key' <<< "${parent_json}"
      return 0
    fi
  fi
  local first_story
  first_story="$(jq -r '[.[] | select(.role=="story")] | sort_by(.position) | .[0].key // empty' <<< "${stories_json}")"
  if [[ -n "${first_story}" ]]; then
    printf '%s' "${first_story}"
    return 0
  fi
  return 1
}

# _feat_resolved_slug <parent-classified-json-or-empty> <stories-classified-json-array>
# <description> — FR-059: the resolved slug. Shapes 1-4 (a key/URL resolves)
# derive the slug from that KEY via the existing `naming_slug` (so the
# folder carries the ticket, "ticket-first folder naming" per the spec's
# Assumptions); shape 5 and the no-designator case fall through to the
# ordinary description-derived slug, unchanged (C-1). Zero new engine code:
# `naming_slug` is reused unmodified, only fed a different argument.
_feat_resolved_slug() {
  local parent_json="${1:-}" stories_json="${2:-[]}" desc="$3" key
  if key="$(_feat_designator_number_source "${parent_json}" "${stories_json}")"; then
    naming_slug "${key}"
  else
    naming_slug "${desc}"
  fi
}

# _feat_declared_type_for <role> <project-key> <merged-config-json> — the
# committed `projects[].hierarchy.<role>` issue-type name, or empty when the
# project declares no hierarchy or no mapping for that role (adoption_evaluate
# skips the REF-ROLE check on an empty declared type).
_feat_declared_type_for() {
  local role="$1" pkey="$2" merged="$3"
  jq -r --arg k "${pkey}" --arg r "${role}" \
    '[.projects[]? | select(.key == $k)][0].hierarchy[$r] // ""' <<< "${merged}"
}

# _feat_halted_csv_for <project-key> <merged-config-json> — the committed
# `projects[].halted_statuses` as a comma-separated list, or empty.
_feat_halted_csv_for() {
  local pkey="$1" merged="$2"
  jq -r --arg k "${pkey}" \
    '([.projects[]? | select(.key == $k)][0].halted_statuses // []) | join(",")' <<< "${merged}"
}

# _feat_reduce_mention <raw> — 029, contract mention-grammar.md §1-§3: does
# <raw> reduce to a Jira issue key, either directly (the shape already used
# at commands/feature.sh:474) or via a browser URL (reusing
# designator_reduce_url_candidate — never a second reduction implementation,
# per the contract's own "reuse is normative, not advisory"). Prints the
# reduced key and returns 0 on a match; prints nothing and returns 1
# otherwise.
_feat_reduce_mention() {
  local raw="$1"
  if [[ "${raw}" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
    printf '%s' "${raw}"
    return 0
  fi
  if [[ "${raw}" == *"://"* ]]; then
    local candidate
    if candidate="$(designator_reduce_url_candidate "${raw}")" \
      && [[ "${candidate}" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi
  return 1
}

# _feat_detect_mentions <word...> — 029, contract mention-grammar.md §1-§3:
# the gate + scan. Prints a JSON array of {"raw":..,"key":..} in argv order.
# The gate (§1 rule 1): if the LEADING positional does not itself reduce to
# a key, prints "[]" — no further token is examined, and the run stays
# byte-identical to the current release. Once the gate is open, every
# remaining token that reduces to a key is detected too (§1 rule 2); the
# leading positional's own detection is always first, so naming derives from
# it alone regardless of what follows (§1 rule 3). No external process is
# spawned per word (docs/11-process-budget.md) — one jq call composes the
# whole result.
_feat_detect_mentions() {
  local -a words=("$@")
  if [[ ${#words[@]} -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  _feat_reduce_mention "${words[0]}" > /dev/null || {
    printf '[]'
    return 0
  }
  # Every reduction above is pure bash (no spawn); the whole scan is
  # therefore composed into ONE jq call, never one per detected token
  # (docs/11-process-budget.md's spirit, even off the reconcile path).
  local pairs="" w key
  for w in "${words[@]}"; do
    if key="$(_feat_reduce_mention "${w}")"; then
      pairs+="${w}"$'\x1f'"${key}"$'\x1e'
    fi
  done
  jq -cn --arg pairs "${pairs}" '
    ($pairs | rtrimstr("") | split("")) as $entries
    | [$entries[] | split("") | {raw: .[0], key: .[1]}]
  '
}

# _feat_compose_reuse_question <mentions-json> <primary-wide-json> <eff-project>
# <merged-config-json> — 029, contract feature-question-contract.md §3/§3.1:
# compose the reuse_required payload (FR-001-FR-005, FR-025, FR-031,
# FR-033-FR-036, FR-040). mentions-json is _feat_detect_mentions' output
# (>=1 entries, gate already open); primary-wide-json is ticket_validate's
# WIDE result for mentions_json[0] — already read by the caller, no request
# here. Every issue beyond the first is resolved via adoption_load/
# adoption_get, the SAME bulk-read the designator path already uses — at
# most one further request regardless of count (FR-017, FR-034). Fails
# closed (propagating the exit code) if that bulk read is unreliable —
# consistent with Constitution III's default read posture. Prints the
# canonical JSON payload and returns 0 on success.
_feat_compose_reuse_question() {
  local mentions_json="$1" primary_json="$2" eff_project="$3" merged="$4"
  local n
  n="$(jq 'length' <<< "${mentions_json}")"

  local -a extra_keys=()
  local i
  for ((i = 1; i < n; i++)); do
    extra_keys+=("$(jq -r ".[${i}].key" <<< "${mentions_json}")")
  done
  if ((${#extra_keys[@]} > 0)); then
    adoption_load "${extra_keys[@]}" || return "$(cli_exit_code fail_closed)"
  fi

  local spec_type story_type halted_csv
  spec_type="$(_feat_declared_type_for specification "${eff_project}" "${merged}")"
  story_type="$(_feat_declared_type_for story "${eff_project}" "${merged}")"
  halted_csv="$(_feat_halted_csv_for "${eff_project}" "${merged}")"
  local no_hierarchy="false"
  [[ -z "${spec_type}" && -z "${story_type}" ]] && no_hierarchy="true"

  local entries_file
  entries_file="$(mktemp)"
  for ((i = 0; i < n; i++)); do
    local key summary type status
    if ((i == 0)); then
      key="$(jq -r '.key' <<< "${primary_json}")"
      summary="$(jq -r '.summary // ""' <<< "${primary_json}")"
      type="$(jq -r '.type // ""' <<< "${primary_json}")"
      status="$(jq -r '.status // ""' <<< "${primary_json}")"
    else
      key="$(jq -r ".[${i}].key" <<< "${mentions_json}")"
      local entry
      if ! entry="$(adoption_get "${key}")"; then
        rm -f "${entries_file}"
        return "$(cli_exit_code fail_closed)"
      fi
      summary="$(jq -r '.fields.summary // ""' <<< "${entry}")"
      type="$(jq -r '.fields.issuetype.name // ""' <<< "${entry}")"
      status="$(jq -r '.fields.status.name // ""' <<< "${entry}")"
    fi

    # Role derivation (FR-035/FR-036, R11 — the unmapped/misplaced split's
    # third case: matching neither declared type is not a mistake, it is
    # proposed in the story role and needs no parent).
    local role="null" unmapped="false"
    if [[ "${no_hierarchy}" != "true" ]]; then
      if [[ -n "${spec_type}" && "${type}" == "${spec_type}" ]]; then
        role='"specification"'
      elif [[ -n "${story_type}" && "${type}" == "${story_type}" ]]; then
        role='"story"'
      else
        role='"story"'
        unmapped="true"
      fi
    fi

    local halted="false"
    if [[ -n "${halted_csv}" && -n "${status}" ]]; then
      local -a halted_list
      IFS=',' read -ra halted_list <<< "${halted_csv}"
      local hs
      for hs in "${halted_list[@]}"; do
        [[ "${hs}" == "${status}" ]] && { halted="true"; break; }
      done
    fi

    jq -cn --arg k "${key}" --arg s "${summary}" --arg t "${type}" --arg st "${status}" \
      --argjson role "${role}" --argjson um "${unmapped}" --argjson h "${halted}" \
      '{key:$k, summary:$s, type:$t, status:$st, role:$role, unmapped:$um, halted:$h}' >> "${entries_file}"
  done

  local issues_json
  issues_json="$(jq -sc '.' "${entries_file}")"
  rm -f "${entries_file}"

  local declines_json
  if [[ "${no_hierarchy}" == "true" ]]; then
    declines_json='{"specification":null,"story":null}'
  else
    declines_json="$(jq -cn --arg s "${spec_type}" --arg t "${story_type}" \
      '{specification: (if $s=="" then null else $s end), story: (if $t=="" then null else $t end)}')"
  fi

  jq -cn --argjson issues "${issues_json}" --argjson declines "${declines_json}" \
    '{active:true, reuse_required:{issues:$issues, declines_to:$declines}}' | json_canonical
}

# _feat_render_reuse_prose <payload> — 029: the prose form of a reuse_required
# (or reuse_issues_required) payload, pinned to the same content the JSON
# shape carries. Every line is its own printf (never a multi-line jq -r),
# which is what keeps Windows' CRLF-emitting jq build out of this path
# (docs/10-windows-portability.md, T022).
_feat_render_reuse_prose() {
  local payload="$1" key
  key="reuse_required"
  jq -e 'has("reuse_required")' <<< "${payload}" > /dev/null 2>&1 || key="reuse_issues_required"
  local q
  q="$(jq -c ".${key}" <<< "${payload}")"

  printf 'Feature: reuse decision required\n'
  local n i
  n="$(jq '.issues | length' <<< "${q}")"
  for ((i = 0; i < n; i++)); do
    printf 'Detected: %s (%s, %s) %s\n' \
      "$(jq -r ".issues[${i}].key" <<< "${q}")" \
      "$(jq -r ".issues[${i}].type // \"\"" <<< "${q}")" \
      "$(jq -r ".issues[${i}].status // \"\"" <<< "${q}")" \
      "$(jq -r ".issues[${i}].summary // \"\"" <<< "${q}")"
  done

  local spec_type story_type
  spec_type="$(jq -r '.declines_to.specification // ""' <<< "${q}")"
  story_type="$(jq -r '.declines_to.story // ""' <<< "${q}")"

  if [[ -z "${spec_type}" && -z "${story_type}" ]]; then
    if [[ "$(jq -r '.reason // ""' <<< "${q}")" == "designators required" ]]; then
      printf 'Missing: which issues to reuse — this run cannot derive it without designators\n'
    else
      printf 'Missing: this project declares no hierarchy, so no placement can be proposed\n'
    fi
    printf 'Answers: re-invoke with --parent <key|title> and one --story <key> per issue to reuse\n'
  else
    local clause="" spec_keys="" story_keys=""
    for ((i = 0; i < n; i++)); do
      local role
      role="$(jq -r ".issues[${i}].role" <<< "${q}")"
      if [[ "${role}" == "specification" ]]; then
        [[ -n "${spec_keys}" ]] && spec_keys+=", "
        spec_keys+="$(jq -r ".issues[${i}].key" <<< "${q}")"
      elif [[ "${role}" == "story" ]]; then
        [[ -n "${story_keys}" ]] && story_keys+=", "
        story_keys+="$(jq -r ".issues[${i}].key" <<< "${q}")"
      fi
    done
    [[ -n "${spec_keys}" ]] && clause="${spec_keys} as the ${spec_type} of this specification"
    if [[ -n "${story_keys}" ]]; then
      [[ -n "${clause}" ]] && clause+=", and "
      clause+="${story_keys} as a ${story_type} beneath it"
    fi
    printf 'Attach %s?\n' "${clause}"
    printf 'Source: the detected issues'\'' content is what spec.md will be written from\n'
    printf 'Answers: --reuse yes attaches them as proposed · --reuse no creates a new %s, plus one %s per drafted user story\n' \
      "${spec_type:-Epic}" "${story_type:-Story}"
  fi

  for ((i = 0; i < n; i++)); do
    if [[ "$(jq -r ".issues[${i}].unmapped" <<< "${q}")" == "true" ]]; then
      printf 'Unmapped: %s is a %s, a type this project declares for no role — proposed as a Story; it needs no Epic, and --reuse yes --parent <key|title> gives it one\n' \
        "$(jq -r ".issues[${i}].key" <<< "${q}")" "$(jq -r ".issues[${i}].type" <<< "${q}")"
    fi
  done
  for ((i = 0; i < n; i++)); do
    if [[ "$(jq -r ".issues[${i}].halted" <<< "${q}")" == "true" ]]; then
      printf 'Halted: %s is in %s, halted — --reuse yes would be refused (REF-TERMINAL); answer --reuse no, reopen it, or name another\n' \
        "$(jq -r ".issues[${i}].key" <<< "${q}")" "$(jq -r ".issues[${i}].status" <<< "${q}")"
    fi
  done
  if jq -e '[.issues[] | select(.role=="story")] | length > 0' <<< "${q}" > /dev/null; then
    printf 'Drafted: user stories drafted beyond these become new Stories beneath the same Epic — named issues are reused, never duplicated\n'
  fi
}

# _feat_ref_message <code> <detail> — compose the message + remediation for
# a moment-1 refusal class not already carrying one (designator.sh and
# adoption_dedupe/multiproject return only a code; adoption_evaluate already
# composes its own). Text mirrors spec.md's FR-036 table verbatim.
_feat_ref_message() {
  local code="$1" detail="$2"
  case "${code}" in
    REF-DESIGNATOR) printf '%s: %s — paste the issue key or the browser URL of the issue; or, for a parent to create, type its title' "${code}" "${detail}" ;;
    REF-HOST) printf '%s: %s — paste a URL from the configured site, or correct the site base URL in the configuration' "${code}" "${detail}" ;;
    REF-DUPLICATE) printf '%s: %s — remove the duplicate designator' "${code}" "${detail}" ;;
    REF-MULTIPROJECT) printf '%s: %s — name issues from one project per specification' "${code}" "${detail}" ;;
    REF-EXISTS) printf '%s: %s — retro-seeding is out of scope; create a new specification' "${code}" "${detail}" ;;
    *) printf '%s: %s' "${code}" "${detail}" ;;
  esac
}

# _feat_seed_from_designators <json> <dry-run> <desc> <eff-id> <eff-project>
# <prefix> <pattern> <override-used> <merged-config-json> <parent-seen>
# <parent-raw> <stories-joined> — moment 1's designator path (027, contract
# seed-cli-contract.md §3, research R1). Zero Jira mutations. Emits via
# _feat_emit and returns the exit code.
_feat_seed_from_designators() {
  local json="$1" dry_run="$2" desc="$3" eff_id="$4" eff_project="$5" \
    prefix="$6" pattern="$7" override_used="$8" merged="$9" \
    parent_seen="${10}" parent_raw="${11}" stories_joined="${12}"
  local base_url="${SPEC_KIT_JIRA_BASE_URL:-}"

  # --- §3 steps 1-2: parse + classify, REF-DESIGNATOR / REF-HOST -----------
  local -a classified=()
  if [[ "${parent_seen}" == "true" ]]; then
    classified+=("$(designator_classify specification "${parent_raw}" "${base_url}")")
  fi
  local -a story_raws=()
  if [[ -n "${stories_joined}" ]]; then
    IFS=$'\x1f' read -r -a story_raws <<< "${stories_joined}"
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
      printf 'feature: %s\n' "$(_feat_ref_message "${code}" "designator \"${detail}\" did not resolve")" >&2
    done <<< "$(jq -r '.[] | "\(.refuse): \(.raw)"' <<< "${refusing}")"
    return "$(cli_exit_code config)"
  fi

  # --- §3 step 3: de-duplicate -----------------------------------------------
  local dedupe
  dedupe="$(designator_dedupe "${all_json}")"
  if [[ "$(jq -r '.ok' <<< "${dedupe}")" != "true" ]]; then
    local dups
    dups="$(jq -r '.duplicates | join(", ")' <<< "${dedupe}")"
    printf 'feature: %s\n' "$(_feat_ref_message REF-DUPLICATE "issue(s) named more than once: ${dups}")" >&2
    return "$(cli_exit_code config)"
  fi
  local designators
  designators="$(jq -c '.designators' <<< "${dedupe}")"
  local parent_json stories_json
  parent_json="$(jq -c '[.[] | select(.role=="specification")][0] // empty' <<< "${designators}")"
  stories_json="$(jq -c '[.[] | select(.role=="story")] | sort_by(.position)' <<< "${designators}")"

  # --- resolved slug / short-name (FR-059) ----------------------------------
  local bare_slug short_name synth_spec_path
  bare_slug="$(_feat_resolved_slug "${parent_json}" "${stories_json}" "${desc}")"
  short_name="$(naming_short_name "${prefix}" "${bare_slug}")"
  synth_spec_path="specs/${short_name}/spec.md"

  # --- §3 step 4: folder exists? -> REF-EXISTS ------------------------------
  if [[ -d "specs/${short_name}" ]]; then
    printf 'feature: %s\n' "$(_feat_ref_message REF-EXISTS "the specification folder specs/${short_name} already exists")" >&2
    return "$(cli_exit_code config)"
  fi

  # --- §3 step 5: one bulkfetch ----------------------------------------------
  local pkey=""
  [[ -n "${parent_json}" ]] && pkey="$(jq -r 'if (.form=="key" or .form=="url") then .key else empty end' <<< "${parent_json}")"
  local -a keys=()
  [[ -n "${pkey}" ]] && keys+=("${pkey}")
  local n i
  n="$(jq 'length' <<< "${stories_json}")"
  for ((i = 0; i < n; i++)); do
    keys+=("$(jq -r ".[${i}].key" <<< "${stories_json}")")
  done

  if ((${#keys[@]} > 0)); then
    local load_rc=0
    adoption_load "${keys[@]}" || load_rc=$?
    if ((load_rc != 0)); then
      printf 'feature: an unreliable read occurred while resolving the named issues — designators were supplied, so the run refuses rather than proceeding without them (FR-038)\n' >&2
      return "$(cli_exit_code fail_closed)"
    fi
  fi

  # --- §3 steps 6-12: per-key and set-wide refusal classes, aggregated -----
  # spec_ref.spec_slug prefers SPEC_KIT_JIRA_SPEC_SLUG (the host's own
  # numbered feature id), exactly as the existing ticket-create path already
  # does below — never the resolved short_name, which is this extension's
  # OWN ticket-based folder name and a different identifier entirely.
  local spec_ref
  spec_ref="$(jq -cn --arg r "${SPEC_KIT_JIRA_REPO:-local/repo}" --arg s "${SPEC_KIT_JIRA_SPEC_SLUG:-spec}" '{repo:$r, spec_slug:$s}')"
  local -a eval_results=()
  if [[ -n "${pkey}" ]]; then
    local ptype pterm
    ptype="$(_feat_declared_type_for specification "${eff_project}" "${merged}")"
    pterm="$(_feat_halted_csv_for "${eff_project}" "${merged}")"
    eval_results+=("$(adoption_evaluate "${eff_project}" specification "${pkey}" "${ptype}" "${pterm}" "${spec_ref}")")
  fi
  local stype sterm
  stype="$(_feat_declared_type_for story "${eff_project}" "${merged}")"
  sterm="$(_feat_halted_csv_for "${eff_project}" "${merged}")"
  n="$(jq 'length' <<< "${stories_json}")"
  for ((i = 0; i < n; i++)); do
    local skey
    skey="$(jq -r ".[${i}].key" <<< "${stories_json}")"
    eval_results+=("$(adoption_evaluate "${eff_project}" story "${skey}" "${stype}" "${sterm}" "${spec_ref}")")
  done
  local eval_json
  if ((${#eval_results[@]} > 0)); then
    eval_json="$(printf '%s\n' "${eval_results[@]}" | jq -s -c .)"
  else
    eval_json='[]'
  fi

  local story_keys_json mp
  story_keys_json="$(jq -c '[.[].key]' <<< "${stories_json}")"
  mp="$(adoption_multiproject_violation "${story_keys_json}")"
  if [[ "$(jq 'length' <<< "${mp}")" -gt 0 ]]; then
    eval_json="$(jq -c --arg msg "$(_feat_ref_message REF-MULTIPROJECT "named story-role issues span more than one project: $(jq -r 'join(", ")' <<< "${mp}")")" \
      '. + [{"code":"REF-MULTIPROJECT","key":"","message":$msg}]' <<< "${eval_json}")"
  fi

  local refusals refusals_count
  refusals="$(adoption_aggregate_refusals "${eval_json}")"
  refusals_count="$(jq 'length' <<< "${refusals}")"
  if ((refusals_count > 0)); then
    while IFS= read -r line; do
      printf 'feature: %s\n' "${line}" >&2
    done <<< "$(jq -r '.[] | "\(.code): \(.message)"' <<< "${refusals}")"
    return "$(cli_exit_code config)"
  fi

  # --- naming (FR-059/R9): the SAME key feeds naming_ticket_number ---------
  local desig_key="" number=""
  if desig_key="$(_feat_designator_number_source "${parent_json}" "${stories_json}")"; then
    number="$(naming_ticket_number "${desig_key}")"
  else
    desig_key=""
  fi
  local branch_name=""
  [[ -n "${number}" ]] && branch_name="$(naming_expand_pattern "${pattern}" "${number}" "${bare_slug}")"

  # --- §3 step 15 (material) precedes 13-14 (record): FR-065 requires the scan
  # to run "before it is handed to the drafting agent", and a BLOCK is zero
  # writes of any kind — so the seed record must not be written before the
  # scan clears. A named issue's description has no size ceiling, so it must
  # never reach jq via --arg/--argjson (an execve argv, capped at 128 KiB on
  # Linux — docs/11-process-budget.md). Every entry is concatenated in-process
  # (a bash string op, not a spawn) into ONE temp file, then read by exactly
  # one jq invocation over that file — R10's "no jq per designator".
  local combined="[" first="true" role key entry_json
  if [[ -n "${pkey}" ]]; then
    entry_json="$(adoption_get "${pkey}")"
    combined+="{\"role\":\"specification\",\"key\":\"${pkey}\",\"entry\":${entry_json}}"
    first="false"
  fi
  n="$(jq 'length' <<< "${stories_json}")"
  for ((i = 0; i < n; i++)); do
    key="$(jq -r ".[${i}].key" <<< "${stories_json}")"
    entry_json="$(adoption_get "${key}")"
    [[ "${first}" == "false" ]] && combined+=","
    combined+="{\"role\":\"story\",\"key\":\"${key}\",\"entry\":${entry_json}}"
    first="false"
  done
  combined+="]"
  local combined_file
  combined_file="$(mktemp)"
  printf '%s' "${combined}" > "${combined_file}"
  local material_content
  material_content="$(jq -c '
    def adf_text: if (. | type) == "string" then . else ([.. | .text? // empty] | join(" ")) end;
    [.[] | {
      role, key,
      summary:(.entry.fields.summary // ""),
      description:(.entry.fields.description | adf_text),
      status:(.entry.fields.status.name // ""),
      parent:(if .entry.fields.parent then
          {key:.entry.fields.parent.key, summary:(.entry.fields.parent.fields.summary // ""), status:(.entry.fields.parent.fields.status.name // "")}
        else null end)
    }]
  ' "${combined_file}" | json_canonical)"
  rm -f "${combined_file}"

  # --- FR-065: the two-tier pre-write privacy guard, over the seed material,
  # before it is handed to the drafting agent. A BLOCK is zero writes of any
  # kind — local or Jira — including the seed record below.
  privacy_guard_scan "${material_content}" "[]" "${SPEC_KIT_JIRA_ALLOWLIST:-[]}" || return $?

  # --- §3 steps 13-14: slug + seed record -----------------------------------
  # The material path is DETERMINISTIC (a sibling of the seed record, under
  # the same state directory) rather than a fresh `mktemp` path: a random
  # OS temp path in the emitted JSON would never be byte-identical across a
  # conformance run's two ports (NFR-1/Constitution VI), even though the
  # material's CONTENT already is.
  local seed_material_path=""
  if [[ "${dry_run}" != "true" ]]; then
    # routing: the routed project, the declared types/terminal statuses
    # moment 1 already resolved from config.yml, and the RESOLVED numeric
    # type ids from config.local.yml (parent_type.id/child_type.id, the same
    # fields reconcile.sh's own binding already carries) — recorded so a
    # resume (FR-062) can re-evaluate every refusal class from Jira alone,
    # and so a free-text parent create (FR-023) has the type id it needs,
    # without moment 2 ever opening config.yml/personal.yml/config.local.yml
    # itself.
    local local_binding parent_type_id child_type_id
    local_binding="$(jq -c --arg k "${eff_project}" '.resolved_ids[$k] // empty' <<< "$(_cfg_local_json "${JIRA_CONFIG_DIR:-.specify/jira}" 2> /dev/null)" 2> /dev/null)"
    parent_type_id="$(jq -r '.parent_type.id // ""' <<< "${local_binding:-{\}}" 2> /dev/null)"
    child_type_id="$(jq -r '.child_type.id // ""' <<< "${local_binding:-{\}}" 2> /dev/null)"
    local routing
    routing="$(jq -cn --arg p "${eff_project}" \
      --arg dts "$(_feat_declared_type_for specification "${eff_project}" "${merged}")" \
      --arg dtst "$(_feat_declared_type_for story "${eff_project}" "${merged}")" \
      --arg term "$(_feat_halted_csv_for "${eff_project}" "${merged}")" \
      --arg ptid "${parent_type_id}" --arg ctid "${child_type_id}" \
      '{project:$p, declared_type_specification:$dts, declared_type_story:$dtst, terminal_statuses_csv:$term,
        parent_type_id:$ptid, child_type_id:$ctid}')"
    local doc
    doc="$(seed_state_compose "${short_name}" "${designators}" "" "${routing}" "[]")"
    seed_state_write "${synth_spec_path}" "${doc}"
    seed_material_path="${JIRA_CONFIG_DIR:-.specify/jira}/state/${short_name}.seed-material.json"
    printf '%s' "${material_content}" > "${seed_material_path}"
  fi

  local ticket_key_json="null" num_json="null" branch_json="null" material_json="null" action="none"
  if [[ -n "${desig_key}" ]]; then
    ticket_key_json="$(jq -Rn --arg v "${desig_key}" '$v')"
    num_json="$(jq -Rn --arg v "${number}" '$v')"
    branch_json="$(jq -Rn --arg v "${branch_name}" '$v')"
    action="adopted"
  fi
  [[ -n "${seed_material_path}" ]] && material_json="$(jq -Rn --arg v "${seed_material_path}" '$v')"

  _feat_emit "$(jq -cn --arg t "${eff_id}" --argjson tk "${ticket_key_json}" --argjson num "${num_json}" \
    --arg act "${action}" --argjson bn "${branch_json}" --arg sn "${short_name}" --argjson ou "${override_used}" \
    --argjson sm "${material_json}" \
    '{active:true, team:$t, ticket:{key:$tk, number:$num, action:$act},
      branch_name:$bn, short_name:$sn, override_used:$ou, warnings:[], seed_material:$sm}' | json_canonical)" "${json}"
  return 0
}

# _feat_emit <json> <json-flag> — print the canonical result (JSON or prose).
_feat_emit() {
  local payload="$1" json="$2"
  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${payload}"
  else
    _feat_render_prose "${payload}"
  fi
}

# _feat_render_prose <json> — render the feature result as human prose (the
# default output). The payload is feature-shaped (contracts/
# feature-cli-contract.md) — never a run summary, so the run-summary renderer
# does not apply. Byte-identical to the PowerShell twin (NFR-1).
_feat_render_prose() {
  local payload="$1"
  if [[ "$(jq -r '.active' <<< "${payload}")" != "true" ]]; then
    printf 'Feature: inactive\n'
  elif [[ "$(jq -r 'has("reuse_required") or has("reuse_issues_required")' <<< "${payload}")" == "true" ]]; then
    _feat_render_reuse_prose "${payload}"
    return
  elif [[ "$(jq -r 'has("confirmation_required")' <<< "${payload}")" == "true" ]]; then
    printf 'Feature: confirmation required\n'
    printf 'Ticket: %s (team: %s)\n' \
      "$(jq -r '.confirmation_required.ticket' <<< "${payload}")" \
      "$(jq -r '.confirmation_required.ticket_team // "—"' <<< "${payload}")"
    printf 'Selected team: %s\n' "$(jq -r '.confirmation_required.selected_team' <<< "${payload}")"
  else
    printf 'Feature: active (team: %s)\n' "$(jq -r '.team' <<< "${payload}")"
    printf 'Ticket: %s (%s)\n' \
      "$(jq -r '.ticket.key // "—"' <<< "${payload}")" \
      "$(jq -r '.ticket.action' <<< "${payload}")"
    printf 'Branch: %s\n' "$(jq -r '.branch_name // "—"' <<< "${payload}")"
    printf 'Folder: %s\n' "$(jq -r '.short_name' <<< "${payload}")"
    printf 'Override used: %s\n' "$(jq -r '.override_used' <<< "${payload}")"
  fi
  local w
  while IFS= read -r w; do
    [[ -z "${w}" ]] && continue
    printf 'Warning: %s\n' "${w}"
  done <<< "$(jq -r '.warnings[]? // empty' <<< "${payload}")"
}

# cmd_feature <argv...> — see the file header. Echoes the result to stdout;
# returns the exit code.
cmd_feature() {
  local parsed json="false" dry_run="false" args="" use_team="" exit_code="0" error=""
  local parent_seen="false" parent="" stories="" reuse="" accept_defaults="false"
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      use_team) use_team="${value}" ;;
      reuse) reuse="${value}" ;;
      accept_defaults) accept_defaults="${value}" ;;
      args) args="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
      parent_seen) parent_seen="${value}" ;;
      parent) parent="${value}" ;;
      stories) stories="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'feature: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  local dir="${JIRA_CONFIG_DIR:-.specify/jira}"

  # (1) No committed catalogue at all ⇒ pass-through (FR-017).
  if [[ ! -f "${dir}/config.yml" ]]; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi
  local merged
  if ! merged="$(config_load "${dir}" 2> /dev/null)"; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi
  local team_count
  team_count="$(jq -r '(.teams // []) | length' <<< "${merged}")"
  if [[ "${team_count}" -eq 0 ]]; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi

  # (2) Personal selection (human-owned; validated; never written). An invalid
  #     file fails closed with a located error (exit 4).
  local personal
  personal="$(config_personal_load "${dir}" "${merged}")" || return $?
  local p_active p_team p_override
  p_active="$(jq -r '.active' <<< "${personal}")"
  p_team="$(jq -r '.team // ""' <<< "${personal}")"
  p_override="$(jq -c '.override // null' <<< "${personal}")"

  # No selection and no cross-team answer ⇒ pass-through (FR-017).
  if [[ "${p_active}" != "true" && -z "${use_team}" ]]; then
    _feat_emit '{"active":false}' "${json}"
    return 0
  fi

  # (3) Effective team resolution.
  local eff_id override_used="false" override='null'
  if [[ -n "${use_team}" ]]; then
    if ! jq -e --arg id "${use_team}" '([.teams[].id] | index($id)) != null' <<< "${merged}" > /dev/null; then
      printf 'feature: unknown team "%s" — valid teams: %s\n' \
        "${use_team}" "$(jq -r '[.teams[].id] | join(", ")' <<< "${merged}")" >&2
      return "$(cli_exit_code config)"
    fi
    eff_id="${use_team}"
  else
    eff_id="${p_team}"
    override="${p_override}"
    [[ "${override}" != "null" ]] && override_used="true"
  fi

  # (4) Description is required once a team is in play (FR-013 precedes naming).
  #     The optional leading positional is a mentioned issue key or a
  #     browser URL reducing to one (029, contract mention-grammar.md §1-§3).
  #     Naming derives from the leading positional's own detection alone
  #     (§1 rule 3); any further detected key stays part of the description,
  #     unchanged from before this feature.
  local -a words=()
  read -ra words <<< "${args}"
  local mentions_json
  mentions_json="$(_feat_detect_mentions "${words[@]}")"
  local ticket_key="" desc=""
  if [[ "$(jq 'length' <<< "${mentions_json}")" -gt 0 ]]; then
    ticket_key="$(jq -r '.[0].key' <<< "${mentions_json}")"
    desc="${words[*]:1}"
  else
    desc="${words[*]}"
  fi
  if [[ -z "${desc}" ]]; then
    printf 'feature: a feature description is required\n' >&2
    return "$(cli_exit_code usage)"
  fi

  # Resolve the effective team entry and its naming rule.
  local team_entry prefix pattern eff_project
  team_entry="$(jq -c --arg id "${eff_id}" '.teams[] | select(.id == $id)' <<< "${merged}")"
  eff_project="$(jq -r '.project' <<< "${team_entry}")"
  if [[ "${override}" != "null" ]]; then
    prefix="$(jq -r --argjson o "${override}" --argjson t "${team_entry}" '($o.folder_prefix // $t.folder_prefix)' <<< 'null')"
    pattern="$(jq -r --argjson o "${override}" --argjson t "${team_entry}" '($o.branch_pattern // $t.branch_pattern)' <<< 'null')"
  else
    prefix="$(jq -r '.folder_prefix' <<< "${team_entry}")"
    pattern="$(jq -r '.branch_pattern' <<< "${team_entry}")"
  fi

  local slug
  slug="$(naming_slug "${desc}")"

  # (027, US1/US3): designators supplied ⇒ moment 1's seed-from-Jira path
  # takes over ticket resolution and naming entirely (contract
  # seed-cli-contract.md §3). Byte-identical to the release below when
  # neither flag is supplied (C-1, US5).
  if [[ "${parent_seen}" == "true" || -n "${stories}" ]]; then
    _feat_seed_from_designators "${json}" "${dry_run}" "${desc}" "${eff_id}" "${eff_project}" \
      "${prefix}" "${pattern}" "${override_used}" "${merged}" "${parent_seen}" "${parent}" "${stories}"
    return $?
  fi

  # (5) Ticket resolution BEFORE naming.
  local number action ticket_key_out
  if [[ -n "${ticket_key}" ]]; then
    # 029: known from argv and the loaded configuration alone, before the
    # read (contract §7) — mention present (guaranteed here), no designator
    # (guaranteed: the designator branch above already returned), no answer,
    # not unattended.
    local about_to_ask="false"
    [[ -z "${reuse}" && "${accept_defaults}" != "true" ]] && about_to_ask="true"

    # Mentioned key: validate (read). A fail-closed read never falls back.
    local validated
    validated="$(ticket_validate "${ticket_key}" "${about_to_ask}")" || return $?
    local ticket_project ticket_team
    ticket_project="$(jq -r '.project // ""' <<< "${validated}")"
    ticket_team="$(jq -r --arg p "${ticket_project}" '([.teams[] | select(.project == $p) | .id] | first) // ""' <<< "${merged}")"

    # Cross-team confirmation (only when the operator did not answer it).
    if [[ -z "${use_team}" ]]; then
      if [[ -z "${ticket_team}" || "${ticket_team}" != "${p_team}" ]]; then
        local tt_json
        if [[ -z "${ticket_team}" ]]; then tt_json='null'; else tt_json="$(jq -Rn --arg v "${ticket_team}" '$v')"; fi
        _feat_emit "$(jq -cn --arg tk "${ticket_key}" --argjson tt "${tt_json}" --arg st "${p_team}" \
          '{active:true, confirmation_required:{ticket:$tk, ticket_team:$tt, selected_team:$st}}' | json_canonical)" "${json}"
        return 0
      fi
    fi

    # (029, FR-025/R6) — the reuse question, immediately after the cross-team
    # question and before naming. Zero writes either way, so --dry-run
    # predicts it by definition (FR-020): the question never performs
    # anything to begin with.
    if [[ "${about_to_ask}" == "true" ]]; then
      local q_payload rc=0
      q_payload="$(_feat_compose_reuse_question "${mentions_json}" "${validated}" "${eff_project}" "${merged}")" || rc=$?
      ((rc != 0)) && return "${rc}"
      _feat_emit "${q_payload}" "${json}"
      return 0
    fi

    # (029, FR-013/FR-014) — an unattended run is never asked; it proceeds
    # exactly as "create new" would, and states that the question was
    # suppressed and which answer was assumed.
    local suppressed_warning=""
    if [[ -z "${reuse}" && "${accept_defaults}" == "true" ]]; then
      suppressed_warning="the reuse question was suppressed by --accept-defaults; assumed answer: create new"
    fi

    # (029, FR-029/FR-030) — "reuse" with no designator is the operator
    # accepting the question's own proposal. Full auto-routing into the
    # designator path from the derived roles is Phase 4 work (US2); until it
    # lands, this returns the which-issues follow-up unconditionally rather
    # than risk silently duplicating the mentioned ticket by falling through
    # to the create-new path a "reuse" answer never meant.
    if [[ "${reuse}" == "yes" ]]; then
      _feat_emit "$(jq -cn --arg tk "${ticket_key}" \
        '{active:true, reuse_issues_required:{issues:[{key:$tk}], declines_to:{specification:null,story:null}, reason:"designators required"}}' | json_canonical)" "${json}"
      return 0
    fi

    number="$(naming_ticket_number "${ticket_key}")"
    ticket_key_out="$(jq -Rn --arg v "${ticket_key}" '$v')"
    if [[ "${dry_run}" == "true" ]]; then action="would-attach"; else action="attached"; fi
  else
    # No mentioned key: guarded create in the effective team's project.
    if [[ "${dry_run}" == "true" ]]; then
      # Predict only — zero Jira calls, no branch (no number yet).
      local short_dry
      short_dry="$(naming_short_name "${prefix}" "${slug}")"
      _feat_emit "$(jq -cn --arg t "${eff_id}" --arg sn "${short_dry}" --argjson ou "${override_used}" \
        '{active:true, team:$t, ticket:{key:null, number:null, action:"would-create"},
          branch_name:null, short_name:$sn, override_used:$ou, warnings:[]}' | json_canonical)" "${json}"
      return 0
    fi

    # An unset/empty plan context is the normal before_specify state (the
    # context only exists after /plan): default to valid JSON so the read
    # yields an empty typeid and the FR-016 fallback below runs — the entry
    # point's errexit must never see a failing jq here.
    local typeid plan_ctx="${SPEC_KIT_JIRA_PLAN_CONTEXT:-}"
    [[ -z "${plan_ctx}" ]] && plan_ctx='{}'
    typeid="$(jq -r '.story_type_id // ""' <<< "${plan_ctx}" 2> /dev/null)" || typeid=""
    local spec_ref
    spec_ref="$(jq -cn --arg r "${SPEC_KIT_JIRA_REPO:-local/repo}" --arg s "${SPEC_KIT_JIRA_SPEC_SLUG:-spec}" \
      '{repo:$r, spec_slug:$s}')"

    if [[ -z "${typeid}" || -z "${SPEC_KIT_JIRA_BASE_URL:-}" ]]; then
      _feat_fallback "${json}"
      return 0
    fi

    # The `|| rc=$?` guard keeps the entry point's errexit from aborting the
    # ceremony before the FR-016 fallback can run.
    local created rc=0
    created="$(ticket_create "${eff_project}" "${desc}" "${typeid}" '[]' '[]' "${spec_ref}")" || rc=$?
    if ((rc == 9)); then
      return 9
    elif ((rc != 0)); then
      _feat_fallback "${json}"
      return 0
    fi
    local created_key
    created_key="$(jq -r '.key' <<< "${created}")"
    number="$(naming_ticket_number "${created_key}")"
    ticket_key_out="$(jq -Rn --arg v "${created_key}" '$v')"
    action="created"
  fi

  # (6) Naming (pure engine).
  local branch_name short_name
  branch_name="$(naming_expand_pattern "${pattern}" "${number}" "${slug}")"
  short_name="$(naming_short_name "${prefix}" "${slug}")"

  # 029, FR-014: an unattended run's suppressed question is stated here, not
  # silently applied — the only warning this path can carry beyond the
  # existing empty array.
  local warnings_json='[]'
  if [[ -n "${suppressed_warning:-}" ]]; then
    warnings_json="$(jq -cn --arg w "${suppressed_warning}" '[$w]')"
  fi

  _feat_emit "$(jq -cn --arg t "${eff_id}" --argjson tk "${ticket_key_out}" --arg num "${number}" \
    --arg act "${action}" --arg bn "${branch_name}" --arg sn "${short_name}" --argjson ou "${override_used}" \
    --argjson w "${warnings_json}" \
    '{active:true, team:$t, ticket:{key:$tk, number:$num, action:$act},
      branch_name:$bn, short_name:$sn, override_used:$ou, warnings:$w}' | json_canonical)" "${json}"
  return 0
}

# _feat_fallback <json-flag> — the FR-016 non-blocking fallback: {active:false}
# plus exactly one warning; one WARNING: line on stderr; exit 0.
_feat_fallback() {
  local json="$1"
  local msg="could not resolve a ticket in Jira — proceeding without one (reconciliation will attach it later)"
  printf 'WARNING: %s\n' "${msg}" >&2
  _feat_emit "$(jq -cn --arg w "${msg}" '{active:false, warnings:[$w]}' | json_canonical)" "${json}"
}
