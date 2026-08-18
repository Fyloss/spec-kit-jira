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
      printf 'Unmapped: %s is a %s, a type this project declares for no role — proposed as a %s; it needs no %s, and --reuse yes --parent <key|title> gives it one\n' \
        "$(jq -r ".issues[${i}].key" <<< "${q}")" "$(jq -r ".issues[${i}].type" <<< "${q}")" \
        "${story_type:-Story}" "${spec_type:-Epic}"
    fi
  done
  for ((i = 0; i < n; i++)); do
    if [[ "$(jq -r ".issues[${i}].halted" <<< "${q}")" == "true" ]]; then
      printf 'Halted: %s is in %s, halted — --reuse yes would be refused (REF-TERMINAL); answer --reuse no, reopen it, or name another\n' \
        "$(jq -r ".issues[${i}].key" <<< "${q}")" "$(jq -r ".issues[${i}].status" <<< "${q}")"
    fi
  done
  if jq -e '[.issues[] | select(.role=="story")] | length > 0' <<< "${q}" > /dev/null; then
    printf 'Drafted: user stories drafted beyond these become new %s issues beneath the same %s — named issues are reused, never duplicated\n' \
      "${story_type:-Story}" "${spec_type:-Epic}"
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

# _feat_designator_role_evaluate <role> <key> <own-type> <other-type>
# <routed-project> <terminal-csv> <spec-ref-json> — 029, contract
# feature-question-contract.md, R11 (FR-022/FR-036/FR-039): adoption_evaluate
# collapses "type matches neither declared role" and "type matches the OTHER
# role's declared type" into one REF-ROLE, and R11 requires the two to
# diverge on the designator path exactly as they do on the auto-detected
# question. A key whose type equals its OWN role's declared type, or for
# which no type is declared at all, is unchanged from adoption_evaluate's
# existing behaviour (still runs REF-ROUTING/REF-TERMINAL/REF-CLAIMED/
# REF-THIN). A key genuinely misplaced — its type is the OTHER role's
# declared type — still refuses via adoption_evaluate's own REF-ROLE
# message, unchanged. Only the third case is new: a type matching NEITHER
# declared type refuses with FR-039's container wording when designated as
# the specification/parent role, and is accepted with no type refusal at
# all when designated as story (R11 — unmapped content needs no parent).
_feat_designator_role_evaluate() {
  local role="$1" key="$2" own_type="$3" other_type="$4" routed_project="$5" \
    terminal_csv="$6" spec_ref="$7"
  if [[ -z "${own_type}" ]]; then
    adoption_evaluate "${routed_project}" "${role}" "${key}" "" "${terminal_csv}" "${spec_ref}"
    return
  fi
  local entry actual
  entry="$(adoption_get "${key}" 2> /dev/null || true)"
  actual="$(jq -r '.fields.issuetype.name // ""' <<< "${entry}")"
  if [[ -z "${actual}" || "${actual}" == "${own_type}" ]]; then
    adoption_evaluate "${routed_project}" "${role}" "${key}" "${own_type}" "${terminal_csv}" "${spec_ref}"
    return
  fi
  if [[ -n "${other_type}" && "${actual}" == "${other_type}" ]]; then
    adoption_evaluate "${routed_project}" "${role}" "${key}" "${own_type}" "${terminal_csv}" "${spec_ref}"
    return
  fi
  if [[ "${role}" == "specification" ]]; then
    jq -cn --arg k "${key}" --arg found "${actual}" \
      '{code:"REF-ROLE", key:$k, message:("issue " + $k + " has type " + $found + ", declared for no role — the specification role is the container, and this feature never changes an existing issue type; supply a title instead of a key: --reuse yes --parent \"<title>\" --story " + $k)}' \
      | json_canonical
    return
  fi
  adoption_evaluate "${routed_project}" "${role}" "${key}" "" "${terminal_csv}" "${spec_ref}"
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
  local ptype stype pterm sterm
  ptype="$(_feat_declared_type_for specification "${eff_project}" "${merged}")"
  stype="$(_feat_declared_type_for story "${eff_project}" "${merged}")"
  pterm="$(_feat_halted_csv_for "${eff_project}" "${merged}")"
  sterm="$(_feat_halted_csv_for "${eff_project}" "${merged}")"
  local -a eval_results=()
  if [[ -n "${pkey}" ]]; then
    eval_results+=("$(_feat_designator_role_evaluate specification "${pkey}" "${ptype}" "${stype}" "${eff_project}" "${pterm}" "${spec_ref}")")
  fi
  n="$(jq 'length' <<< "${stories_json}")"
  for ((i = 0; i < n; i++)); do
    local skey
    skey="$(jq -r ".[${i}].key" <<< "${stories_json}")"
    eval_results+=("$(_feat_designator_role_evaluate story "${skey}" "${stype}" "${ptype}" "${eff_project}" "${sterm}" "${spec_ref}")")
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
    # 029/T119 (FR-037): the escape every refusal reachable here carries,
    # composed once by the aggregator and appended once — never duplicated
    # into each refusal class, which is how the fifth copy ends up
    # different from the other four.
    local esc_spec="${ptype:-specification-role issue}" esc_story="${stype:-story-role issue}"
    printf 'feature: decline, and the extension creates a new %s plus one %s per drafted user story\n' \
      "${esc_spec}" "${esc_story}" >&2
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

  # 029, contract mention-grammar.md §1-§3: the mention evaluation is a pure
  # string operation on argv alone, needing no configuration — it moves to
  # the top of cmd_feature (before the four early pass-through exits, R4) so
  # both the usage-error gate below and the missing-configuration report
  # (US6) can consult it without a second detection pass.
  local -a words=()
  read -ra words <<< "${args}"
  local mentions_json
  mentions_json="$(_feat_detect_mentions "${words[@]}")"
  local has_mention="false"
  [[ "$(jq 'length' <<< "${mentions_json}")" -gt 0 ]] && has_mention="true"
  local ticket_key="" desc=""
  if [[ "${has_mention}" == "true" ]]; then
    ticket_key="$(jq -r '.[0].key' <<< "${mentions_json}")"
    desc="${words[*]:1}"
  else
    desc="${words[*]}"
  fi

  # 029, contract feature-question-contract.md §2 rows 2-3 (FR-015): decided
  # from argv alone, before any configuration read or Jira request — an
  # unconfigured repository or an unreadable key must never mask a
  # mis-scripted invocation. Row 1 (an invalid --reuse value) already exited
  # inside cli_parse, above.
  local has_designator="false"
  [[ "${parent_seen}" == "true" || -n "${stories}" ]] && has_designator="true"
  if [[ -n "${reuse}" && "${has_mention}" != "true" && "${has_designator}" != "true" ]]; then
    printf 'feature: --reuse %s answers a question that was never posed — no ticket is mentioned and no designator is supplied\n' "${reuse}" >&2
    return "$(cli_exit_code usage)"
  fi
  if [[ "${reuse}" == "no" && "${has_designator}" == "true" ]]; then
    printf 'feature: --reuse no contradicts the designators supplied with it — designators name issues to reuse\n' >&2
    return "$(cli_exit_code usage)"
  fi

  local dir="${JIRA_CONFIG_DIR:-.specify/jira}"

  # 029, contract feature-question-contract.md §5 (FR-026-FR-028, research
  # R5): a mentioned ticket met with silence is the same defect class one
  # layer earlier — an operator who named something and got nothing back.
  # Gated on has_mention so a run naming nothing stays byte-identical to
  # the current release (FR-028); never issues a Jira request (FR-027).
  local no_config_msg='no team configuration found — .specify/jira/config.yml is missing, unreadable, or declares no teams; run /speckit.jira.config to create one'
  local no_selection_msg='no team selected in .specify/jira/personal.yml — that selection is your own and no script writes it for you; run /speckit.jira.config to select one'

  # (1) No committed catalogue at all ⇒ pass-through (FR-017).
  if [[ ! -f "${dir}/config.yml" ]]; then
    if [[ "${has_mention}" == "true" ]]; then
      _feat_emit "$(jq -cn --arg w "${no_config_msg}" '{active:false, warnings:[$w]}')" "${json}"
    else
      _feat_emit '{"active":false}' "${json}"
    fi
    return 0
  fi
  local merged
  if ! merged="$(config_load "${dir}" 2> /dev/null)"; then
    if [[ "${has_mention}" == "true" ]]; then
      _feat_emit "$(jq -cn --arg w "${no_config_msg}" '{active:false, warnings:[$w]}')" "${json}"
    else
      _feat_emit '{"active":false}' "${json}"
    fi
    return 0
  fi

  # The resolution chokepoint (030, contracts/connection-settings.md C1.5):
  # seed SPEC_KIT_JIRA_BASE_URL / JIRA_EMAIL, environment first, using the
  # `merged` config JUST validated above — no second config_load, and no
  # second base_url validation to silently contradict the pass-through
  # treatment a malformed config.yml already received a few lines up.
  config_resolve_connection "${dir}" "${merged}" || return $?

  local team_count
  team_count="$(jq -r '(.teams // []) | length' <<< "${merged}")"
  if [[ "${team_count}" -eq 0 ]]; then
    if [[ "${has_mention}" == "true" ]]; then
      _feat_emit "$(jq -cn --arg w "${no_config_msg}" '{active:false, warnings:[$w]}')" "${json}"
    else
      _feat_emit '{"active":false}' "${json}"
    fi
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
    if [[ "${has_mention}" == "true" ]]; then
      _feat_emit "$(jq -cn --arg w "${no_selection_msg}" '{active:false, warnings:[$w]}')" "${json}"
    else
      _feat_emit '{"active":false}' "${json}"
    fi
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

  # (4) Description is required once a team is in play (FR-013 precedes
  # naming). words/mentions_json/ticket_key/desc are already computed above.
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
    # 029/FR-029: "reuse" also needs the wide field set to derive each
    # detected issue's role — it is a second invocation, not the question
    # path FR-017 bounds, so the extra field cost here is expected.
    local wants_wide="${about_to_ask}"
    [[ "${reuse}" == "yes" ]] && wants_wide="true"

    # Mentioned key: validate (read). A fail-closed read never falls back.
    local validated
    validated="$(ticket_validate "${ticket_key}" "${wants_wide}")" || return $?
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

    # (029, FR-029/FR-030/FR-038) — "reuse" with no designator is the
    # operator accepting the question's own proposal: every detected issue,
    # in the role already derived. Auto-routes into 027's designator path
    # with synthesized --parent/--story equivalents, so the result is
    # byte-identical to typing them (US3 AC1). Falls back to the
    # which-issues follow-up in exactly one case — no role could be derived
    # at all, because the routed project declares no hierarchy (FR-035): a
    # proposal holding story-role issues and no specification-role one is
    # NOT that case (FR-038) and still routes, with no parent.
    if [[ "${reuse}" == "yes" ]]; then
      local q_payload rc=0
      q_payload="$(_feat_compose_reuse_question "${mentions_json}" "${validated}" "${eff_project}" "${merged}")" || rc=$?
      ((rc != 0)) && return "${rc}"

      local no_hierarchy="false"
      if [[ "$(jq -r '.reuse_required.declines_to.specification' <<< "${q_payload}")" == "null" \
        && "$(jq -r '.reuse_required.declines_to.story' <<< "${q_payload}")" == "null" ]]; then
        no_hierarchy="true"
      fi

      if [[ "${no_hierarchy}" == "true" ]]; then
        # Contract §3.1: "reuse_issues_required carries the identical object" —
        # so it is composed FROM the question rather than rebuilt. Rebuilding it
        # from ticket_key alone dropped every issue past the leading one (FR-034)
        # and stripped the survivor of summary/type/status, which the prose then
        # rendered as `Detected: IJT-40 (, )`.
        _feat_emit "$(jq -cn --argjson q "${q_payload}" \
          '{active:true, reuse_issues_required: ($q.reuse_required + {reason:"designators required"})}' | json_canonical)" "${json}"
        return 0
      fi

      # First specification-role issue wins the parent slot; every other
      # detected issue (including any further specification-role match)
      # becomes a story-role designator — never silently dropped.
      local auto_parent="" auto_stories="" n_q i_q
      n_q="$(jq '.reuse_required.issues | length' <<< "${q_payload}")"
      for ((i_q = 0; i_q < n_q; i_q++)); do
        local role_q key_q
        role_q="$(jq -r ".reuse_required.issues[${i_q}].role" <<< "${q_payload}")"
        key_q="$(jq -r ".reuse_required.issues[${i_q}].key" <<< "${q_payload}")"
        if [[ "${role_q}" == "specification" && -z "${auto_parent}" ]]; then
          auto_parent="${key_q}"
        else
          [[ -n "${auto_stories}" ]] && auto_stories+=$'\x1f'
          auto_stories+="${key_q}"
        fi
      done

      local auto_parent_seen="false"
      [[ -n "${auto_parent}" ]] && auto_parent_seen="true"
      _feat_seed_from_designators "${json}" "${dry_run}" "${desc}" "${eff_id}" "${eff_project}" \
        "${prefix}" "${pattern}" "${override_used}" "${merged}" \
        "${auto_parent_seen}" "${auto_parent}" "${auto_stories}"
      return $?
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
      _feat_fallback "${json}" 'Jira is not configured for creating a ticket yet'
      return 0
    fi

    # Run in the CURRENT shell (stdout to a temp file, not a command
    # substitution) so JIRA_LAST_STATUS is visible here on failure —
    # 029/T132 (FR-041) names the cause, and a subshell would hide it
    # (sink/jira/identity.sh:76-77 records the same hazard).
    local created rc=0 tmp_created
    tmp_created="$(mktemp)"
    ticket_create "${eff_project}" "${desc}" "${typeid}" '[]' '[]' "${spec_ref}" > "${tmp_created}" || rc=$?
    created="$(cat "${tmp_created}")"
    rm -f "${tmp_created}"
    if ((rc == 9)); then
      return 9
    elif ((rc != 0)); then
      local cause
      if ((rc == "$(cli_exit_code auth)")); then
        cause='Jira rejected the credentials'
      elif [[ "${JIRA_LAST_STATUS:-0}" == "0" ]]; then
        cause='Jira is unreachable'
      elif [[ "${JIRA_LAST_STATUS:-}" == "404" ]]; then
        cause='the target project could not be found or is not visible'
      else
        cause="Jira returned an error (status ${JIRA_LAST_STATUS:-unknown})"
      fi
      _feat_fallback "${json}" "${cause}"
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

# _feat_fallback <json-flag> <cause> — the FR-016 non-blocking fallback:
# {active:false} plus exactly one warning; one WARNING: line on stderr;
# exit 0. 029/T132 (FR-041): the shipped text claimed reconciliation "will
# attach it later" — false, since a create that never happened has nothing
# to attach; the following reconcile creates a fresh issue instead. <cause>
# is composed by the caller from the exit code the failed call already
# returned, never invented here.
_feat_fallback() {
  local json="$1" cause="$2"
  local msg="${cause} — proceeding without a ticket; the next reconcile creates a new issue for this specification"
  printf 'WARNING: %s\n' "${msg}" >&2
  _feat_emit "$(jq -cn --arg w "${msg}" '{active:false, warnings:[$w]}' | json_canonical)" "${json}"
}
