#!/usr/bin/env bash
# engine/adoption.sh — Pure label-based adoption engine (003 US1/US2/US4/US6).
#
# This module is NEUTRAL (Constitution VIII): it knows nothing about tickets,
# projects, or any tracker. It performs four pure operations over data the sink
# hands it as opaque JSON —
#
#   * prefix validation       : the operator-declared adoption label prefix,
#   * label derivation        : the three label forms a spec folder implies,
#   * scope and pin resolution: which folders a run considers, and the operator's
#                               explicit overrides,
#   * classification          : every target becomes a binding or one of eight
#                               named refusals, each carrying a remediation.
#
# ⚠️ BOUNDARY CONSTRAINT (research §8). The CI boundary gate greps every file
# under engine/ for the tracker's key shape, its vendor name, and its metadata
# endpoints, and it FAILS ON A MATCH INSIDE A COMMENT TOO. So this file carries
# no example key, not even illustratively, and requirement references are written
# with a space ("FR 009") rather than a hyphen. engine/naming.sh is the
# precedent: it manipulates key numbers using the pattern [A-Z]*-* and documents
# the same constraint in its header.

[[ -n ${_SPECKIT_ENGINE_ADOPTION:-} ]] && return 0
_SPECKIT_ENGINE_ADOPTION=1

: "${EXIT_OK:=0}"
: "${EXIT_USAGE:=1}"
: "${EXIT_CONFIG:=4}"

_adoption_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_adoption_dir}/../lib/output.sh"     # json_canonical only — lib/, never sink/
# shellcheck source=/dev/null
source "${_adoption_dir}/interchange.sh"       # routing_resolve (engine -> engine)

# The label length limit. A prefix plus the longest suffix a folder in scope
# implies must stay at or below it (FR 002).
: "${ADOPTION_LABEL_MAX:=255}"

# The origin recorded on a ticket the bridge created itself. The wire value is
# hyphenated; the spec's prose spelling names the concept, not the literal
# (research §4). A candidate carrying THIS spec's marker with this origin means
# the spec already owns a bridge-created ticket, which is a refusal.
: "${ADOPTION_ORIGIN_BRIDGE:=bridge-created}"
# The origin adoption stamps, and the one an already-adopted candidate carries.
: "${ADOPTION_ORIGIN_HUMAN:=human}"

# =============================================================================
# Label grammar (research §3, data-model §3)
# =============================================================================

# adoption_number_component <folder> — the folder's leading numbering component
# (the digits before its first hyphen), or the empty string when the folder does
# not begin with one.
adoption_number_component() {
  local folder="$1"
  if [[ "${folder}" =~ ^([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# adoption_display_name <folder> <level> [ordinal] — how a target is named in
# every plan line, message, and remediation. The story form reuses the label
# grammar's own separator so an operator can copy it straight into a flag.
adoption_display_name() {
  if [[ "$2" == "story" ]]; then
    printf '%s:us%s' "$1" "$3"
  else
    printf '%s' "$1"
  fi
}

# adoption_labels_for <prefix> <folder> <level> [ordinal] [short-number]
# The exact label values this target implies — the ONLY values ever searched for
# (NFR 6). A feature target implies the full-folder form, plus the short
# numbering form when that number is unique among the folders in scope. A story
# target implies the story form alone. Matching is case-sensitive and exact:
# normalising would collide two distinct labels into one binding.
adoption_labels_for() {
  local prefix="$1" folder="$2" level="$3" ordinal="${4:-}" short="${5:-}"
  local out
  if [[ "${level}" == "story" ]]; then
    out="$(jq -cn --arg v "${prefix}${folder}:us${ordinal}" '[$v]')"
  else
    out="$(jq -cn --arg v "${prefix}${folder}" '[$v]')"
    if [[ -n "${short}" ]]; then
      out="$(jq -c --arg v "${prefix}${short}" '. + [$v]' <<< "${out}")"
    fi
  fi
  json_canonical <<< "${out}"
}

# adoption_longest_suffix <specs-json> — the longest suffix any folder in scope
# appends to the prefix, so the prefix check below is made against the real
# worst case rather than a guess. specs-json: [{folder, story_ordinals:[N,...]}].
adoption_longest_suffix() {
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -r '
    [ .[]
      | (.folder | length) as $fl
      | ( [$fl] + [ (.story_ordinals // [])[] | $fl + 3 + ((. | tostring) | length) ] )[]
    ] | (max // 0)
  ' <<< "${1:-[]}"
  # kcov-excl-stop
}

# adoption_validate_prefix <prefix> [longest-suffix] — the FR 002 rules: the
# prefix is non-empty, carries no whitespace of any kind (labels reject it), and
# stays within the length limit once the longest implied suffix is appended. On
# failure the single located-error line is printed on stdout and the
# configuration exit code is returned, BEFORE anything is searched or written.
adoption_validate_prefix() {
  local prefix="$1" longest="${2:-0}"
  if [[ -z "${prefix}" ]]; then
    printf 'adoption.label_prefix must not be empty\n'
    return "${EXIT_CONFIG}"
  fi
  if [[ "${prefix}" =~ [[:space:]] ]]; then
    printf 'adoption.label_prefix must not contain whitespace\n'
    return "${EXIT_CONFIG}"
  fi
  local total=$((${#prefix} + longest))
  if ((total > ADOPTION_LABEL_MAX)); then
    printf 'adoption.label_prefix is too long: the prefix plus the longest suffix it implies is %s characters, over the %s-character limit\n' \
      "${total}" "${ADOPTION_LABEL_MAX}"
    return "${EXIT_CONFIG}"
  fi
  return 0
}

# =============================================================================
# Scope (data-model §6, FR 026)
# =============================================================================

# adoption_scope <all-folders-json> <scope-json> — the subset of spec folders the
# run considers. An empty scope means every folder on disk. A scope naming a
# folder absent from disk stops the run as a usage error with zero writes; the
# rest are reported out of scope, sorted ascending, and contribute no label to
# any query (which is what makes "zero reads against their tickets" assertable).
# Prints {in_scope, out_of_scope} canonically.
adoption_scope() {
  local all="${1:-[]}" scope="${2:-[]}"
  local unknown
  # `. as $x` is load-bearing: piping into `index(.)` would rebind `.` to the
  # array being searched rather than the element being looked for.
  unknown="$(jq -r --argjson all "${all}" '[ .[] | . as $x | select(($all | index($x)) == null) ] | join(", ")' <<< "${scope}")"
  if [[ -n "${unknown}" ]]; then
    printf 'no such spec folder: %s\n' "${unknown}"
    return "${EXIT_USAGE}"
  fi
  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson all "${all}" --argjson scope "${scope}" '
    ($all | sort) as $a
    | if ($scope | length) == 0
      then {in_scope: $a, out_of_scope: []}
      else {in_scope: [ $a[] | . as $x | select(($scope | index($x)) != null) ],
            out_of_scope: [ $a[] | . as $x | select(($scope | index($x)) == null) ]}
      end
  ' | json_canonical
  # kcov-excl-stop
}

# =============================================================================
# Target derivation (data-model §2)
# =============================================================================

# adoption_targets <specs-json> <prefix> <config-json>
# One `feature` target per spec folder in scope plus one `story` target per user
# story, each carrying the exact labels it implies and the project the existing
# routing resolver binds the folder to. The order is TOTAL and deterministic —
# folder ascending, feature before story, ordinal ascending — so both ports emit
# the same plan bytes.
#
# A numbering component shared by two folders in scope suppresses the short label
# form for BOTH: neither may bind through it. The suppressed value is still
# emitted as a `probe_label` so a ticket carrying it is DISCOVERABLE and can be
# refused by name, rather than silently matching nothing.
#
# specs-json: [{folder, story_ordinals:[N,...]}]. Prints the canonical array.
adoption_targets() {
  local specs="${1:-[]}" prefix="$2" cfg="${3:-\{\}}"

  # Routing is resolved per folder in the shell because the resolver is itself a
  # function; the derivation below is then one pure pass.
  local folders projects='{}' folder key
  folders="$(jq -r '[ .[].folder ] | sort | .[]' <<< "${specs}")"
  while IFS= read -r folder; do
    [[ -z "${folder}" ]] && continue
    key="$(routing_resolve "${folder}" '[]' "${cfg}")" || return $?
    projects="$(jq -c --arg f "${folder}" --arg k "${key}" '. + {($f): $k}' <<< "${projects}")"
  done <<< "${folders}"

  # kcov-excl-start — jq literal (string lines are not statements)
  jq -cn --argjson specs "${specs}" --arg prefix "${prefix}" --argjson projects "${projects}" '
    def numcomp: if test("^[0-9]+-") then capture("^(?<n>[0-9]+)-").n else "" end;
    ($specs | sort_by(.folder)) as $s
    | ( reduce $s[] as $f ({};
          ($f.folder | numcomp) as $n
          | if $n == "" then . else .[$n] = ((.[$n] // []) + [$f.folder]) end) ) as $bynum
    | [ $s[]
        | .folder as $folder
        | ((.story_ordinals // []) | sort) as $ords
        | ($folder | numcomp) as $num
        | ($bynum[$num] // []) as $sharers
        | ($prefix + $num) as $short
        | (($num != "") and (($sharers | length) == 1)) as $unique
        | (($num != "") and (($sharers | length) > 1)) as $shared
        | ( { spec_folder: $folder,
              level: "feature",
              story_ordinal: null,
              project_key: ($projects[$folder] // ""),
              labels: ([$prefix + $folder] + (if $unique then [$short] else [] end)),
              probe_labels: (if $shared then [$short] else [] end),
              short_conflict: (if $shared then {label: $short, folders: $sharers} else null end) },
            ( $ords[]
              | { spec_folder: $folder,
                  level: "story",
                  story_ordinal: .,
                  project_key: ($projects[$folder] // ""),
                  labels: [$prefix + $folder + ":us" + (. | tostring)],
                  probe_labels: [],
                  short_conflict: null } ) ) ]
  ' | json_canonical
  # kcov-excl-stop
}

# =============================================================================
# Explicit bindings (data-model §5, FR 020…FR 022)
# =============================================================================

# adoption_pins_resolve <pins-json> <all-folders-json>
# Parse the operator's repeatable overrides — "<folder>[:us<N>]=<KEY>" — into
# structured pins. The folder must exist on disk: an unknown one stops the whole
# run as a usage error with zero writes (FR 021). The key's SHAPE is deliberately
# NOT checked here; that check lives in the sink (research §9), which is the only
# layer permitted to know what a key looks like. Prints the canonical array.
adoption_pins_resolve() {
  local pins="${1:-[]}" all="${2:-[]}"
  local n i out='[]'
  n="$(jq 'length' <<< "${pins}")"
  for ((i = 0; i < n; i++)); do
    local raw target key folder level ordinal
    raw="$(jq -r ".[${i}]" <<< "${pins}")"
    target="${raw%%=*}"
    key="${raw#*=}"
    if [[ "${raw}" != *=* || -z "${target}" || -z "${key}" ]]; then
      printf 'malformed --bind value: %s (expected <folder>[:us<N>]=<KEY>)\n' "${raw}"
      return "${EXIT_USAGE}"
    fi
    if [[ "${target}" =~ ^(.+):us([0-9]+)$ ]]; then
      folder="${BASH_REMATCH[1]}"
      level="story"
      ordinal="${BASH_REMATCH[2]}"
    else
      folder="${target}"
      level="feature"
      ordinal=""
    fi
    if [[ "$(jq -r --arg f "${folder}" '(index($f) != null)' <<< "${all}")" != "true" ]]; then
      printf 'no such spec folder: %s\n' "${folder}"
      return "${EXIT_USAGE}"
    fi
    out="$(jq -c --arg f "${folder}" --arg l "${level}" --arg o "${ordinal}" --arg k "${key}" \
      '. + [{spec_folder: $f, level: $l,
             story_ordinal: (if $o == "" then null else ($o | tonumber) end),
             issue_key: $k}]' <<< "${out}")"
  done
  json_canonical <<< "${out}"
}

# =============================================================================
# Classification (data-model §7, §8)
# =============================================================================

# _adoption_binding <folder> <level> <ordinal> <key> <reason> <overrode> <status>
_adoption_binding() {
  jq -cn --arg f "$1" --arg l "$2" --arg o "$3" --arg k "$4" --arg r "$5" --arg ov "$6" --arg s "$7" \
    '{spec_folder: $f, level: $l,
      story_ordinal: (if $o == "" then null else ($o | tonumber) end),
      issue_key: $k, reason: $r,
      overrode_key: (if $ov == "" then null else $ov end),
      status: $s}'
}

# _adoption_refusal <folder> <level> <ordinal> <reason> <keys-json> <message> <remediation>
_adoption_refusal() {
  jq -cn --arg f "$1" --arg l "$2" --arg o "$3" --arg r "$4" --argjson k "$5" --arg m "$6" --arg rem "$7" \
    '{spec_folder: $f, level: $l,
      story_ordinal: (if $o == "" then null else ($o | tonumber) end),
      reason: $r, issue_keys: ($k | sort), message: $m, remediation: $rem}'
}

# _adoption_bind_hint <display> — the copy-pasteable override that resolves a
# refusal. It is the whole reason the explicit-binding story is the documented
# answer to the fail-closed story.
_adoption_bind_hint() {
  printf 'spec-kit-jira adopt --bind %s=<ISSUE-KEY>' "$1"
}

# adoption_classify <targets-json> <candidates-json> <pins-json> <repo>
# Turn every target into a binding or one of the eight named refusal classes.
# Candidates are consumed as OPAQUE JSON: {key, project_key, labels, parent_key,
# identity}. Nothing here depends on the order the tracker returned results, on
# titles, on recency, or on issue type — FR 012 forbids any such path from
# existing at all, not merely from being reached.
#
# Story targets are evaluated after their spec's feature target (guaranteed by
# the target ordering), so a feature bound in THIS run is visible to the
# hierarchy checks. Prints {bindings, refusals} canonically.
adoption_classify() {
  local targets="${1:-[]}" candidates="${2:-[]}" pins="${3:-[]}" repo="${4:-}"
  local bindings='[]' refusals='[]' feature_keys='{}'
  local n i
  n="$(jq 'length' <<< "${targets}")"

  for ((i = 0; i < n; i++)); do
    local t folder level ordinal project labels display
    t="$(jq -c ".[${i}]" <<< "${targets}")"
    folder="$(jq -r '.spec_folder' <<< "${t}")"
    level="$(jq -r '.level' <<< "${t}")"
    ordinal="$(jq -r 'if .story_ordinal == null then "" else (.story_ordinal | tostring) end' <<< "${t}")"
    project="$(jq -r '.project_key' <<< "${t}")"
    labels="$(jq -c '.labels' <<< "${t}")"
    display="$(adoption_display_name "${folder}" "${level}" "${ordinal}")"

    # --- Which ticket does this target resolve to? --------------------------
    local pin_key reason='label-match' overrode='' chosen='' cand=''
    pin_key="$(jq -r --arg f "${folder}" --arg l "${level}" --arg o "${ordinal}" \
      'first(.[] | select(.spec_folder == $f and .level == $l
                          and (if .story_ordinal == null then "" else (.story_ordinal | tostring) end) == $o)
             | .issue_key) // ""' <<< "${pins}")"

    # Discovered candidates: those carrying one of this target's binding labels
    # inside its routed project. Ordered by key ascending so a refusal lists
    # them in a stable order across ports.
    local matched keys count
    matched="$(jq -c --argjson want "${labels}" --arg p "${project}" \
      '[ .[] | select(.project_key == $p)
             | select(any(.labels[]?; . as $x | ($want | index($x)) != null)) ] | sort_by(.key)' \
      <<< "${candidates}")"
    keys="$(jq -c '[ .[].key ]' <<< "${matched}")"
    count="$(jq 'length' <<< "${matched}")"

    if [[ -n "${pin_key}" ]]; then
      reason='explicit-binding'
      chosen="${pin_key}"
      # FR 022: when a pin overrides exactly one discovered candidate the plan
      # states BOTH keys.
      if [[ "${count}" == "1" ]]; then
        local disc
        disc="$(jq -r '.[0].key' <<< "${matched}")"
        [[ "${disc}" != "${pin_key}" ]] && overrode="${disc}"
      fi
      cand="$(jq -c --arg k "${pin_key}" 'first(.[] | select(.key == $k)) // null' <<< "${candidates}")"
    else
      # A suppressed short number is an ambiguity the moment a ticket carries it:
      # the label names a number two folders in scope share, so it names no spec.
      local conflict conflict_label conflict_hits
      conflict="$(jq -c '.short_conflict' <<< "${t}")"
      if [[ "${conflict}" != "null" ]]; then
        conflict_label="$(jq -r '.label' <<< "${conflict}")"
        conflict_hits="$(jq -c --arg l "${conflict_label}" \
          '[ .[] | select(any(.labels[]?; . == $l)) | .key ] | sort' <<< "${candidates}")"
        if [[ "$(jq 'length' <<< "${conflict_hits}")" -gt 0 ]]; then
          local sharers msg
          sharers="$(jq -r '.folders | join(", ")' <<< "${conflict}")"
          msg="$(printf 'the short adoption label "%s" names a numbering component shared by the spec folders %s, so it names no single spec' \
            "${conflict_label}" "${sharers}")"
          refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
            'ambiguous-short-number' "${conflict_hits}" "${msg}" \
            "use the full-folder label form, or $(_adoption_bind_hint "${display}")")" '. + [$r]' <<< "${refusals}")"
          continue
        fi
      fi

      if [[ "${count}" == "0" ]]; then
        local searched msg
        searched="$(jq -r 'join(", ")' <<< "${labels}")"
        msg="$(printf 'no accessible ticket carries an adoption label for "%s" (searched: %s)' "${display}" "${searched}")"
        refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
          'no-candidate' '[]' "${msg}" \
          "apply the label in the tracker, or $(_adoption_bind_hint "${display}")")" '. + [$r]' <<< "${refusals}")"
        continue
      fi
      if [[ "${count}" -gt 1 ]]; then
        local all_keys msg first_key
        all_keys="$(jq -r 'join(", ")' <<< "${keys}")"
        first_key="$(jq -r '.[0]' <<< "${keys}")"
        msg="$(printf '"%s" is carried by more than one ticket (%s); adoption never guesses which one a spec means' \
          "${display}" "${all_keys}")"
        refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
          'several-candidates' "${keys}" "${msg}" \
          "spec-kit-jira adopt --bind ${display}=${first_key}")" '. + [$r]' <<< "${refusals}")"
        continue
      fi
      chosen="$(jq -r '.[0].key' <<< "${matched}")"
      cand="$(jq -c '.[0]' <<< "${matched}")"
    fi

    [[ -z "${cand}" ]] && cand='null'

    # --- The routed project owns the binding (FR 005) -----------------------
    local cand_project
    cand_project="$(jq -r 'if . == null then "" else (.project_key // "") end' <<< "${cand}")"
    if [[ -n "${cand_project}" && "${cand_project}" != "${project}" ]]; then
      local msg
      msg="$(printf '"%s" routes to project %s, but %s belongs to project %s; adoption never migrates a ticket' \
        "${display}" "${project}" "${chosen}" "${cand_project}")"
      refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
        'wrong-project' "$(jq -cn --arg k "${chosen}" '[$k]')" "${msg}" \
        "$(_adoption_bind_hint "${display}") naming a ticket in ${project}")" '. + [$r]' <<< "${refusals}")"
      continue
    fi

    # --- Claim checks (FR 011, FR 027) --------------------------------------
    local identity
    identity="$(jq -c 'if . == null then null else (.identity // null) end' <<< "${cand}")"
    if [[ "${identity}" != "null" && -n "${identity}" ]]; then
      local id_repo id_slug id_origin
      id_repo="$(jq -r '.repo // ""' <<< "${identity}")"
      id_slug="$(jq -r '.spec_slug // ""' <<< "${identity}")"
      id_origin="$(jq -r '.origin // ""' <<< "${identity}")"
      if [[ "${id_repo}" == "${repo}" && "${id_slug}" == "${folder}" ]]; then
        if [[ "${id_origin}" == "${ADOPTION_ORIGIN_BRIDGE}" ]]; then
          local msg
          msg="$(printf '"%s" resolves to %s, which this spec already owns as a ticket the bridge created itself' \
            "${display}" "${chosen}")"
          refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
            'spec-owns-bridge-ticket' "$(jq -cn --arg k "${chosen}" '[$k]')" "${msg}" \
            "resolve the collision in the tracker, then re-run: spec-kit-jira adopt --spec ${folder}")" \
            '. + [$r]' <<< "${refusals}")"
          continue
        fi
        # Already adopted by THIS spec: skipped, counted as skipped, never
        # re-stamped — which is what makes an interrupted adoption complete on
        # re-run with exactly one stamp per ticket (FR 027).
        bindings="$(jq -c --argjson b "$(_adoption_binding "${folder}" "${level}" "${ordinal}" \
          "${chosen}" "${reason}" "${overrode}" 'already-adopted')" '. + [$b]' <<< "${bindings}")"
        if [[ "${level}" == "feature" ]]; then
          feature_keys="$(jq -c --arg f "${folder}" --arg k "${chosen}" '. + {($f): $k}' <<< "${feature_keys}")"
        fi
        continue
      fi
      local other msg
      other="$(jq -r '"\(.repo // "?")/\(.spec_slug // "?")"' <<< "${identity}")"
      msg="$(printf '"%s" resolves to %s, which is already claimed by another spec (%s)' \
        "${display}" "${chosen}" "${other}")"
      refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
        'already-claimed' "$(jq -cn --arg k "${chosen}" '[$k]')" "${msg}" \
        "resolve the claim in the tracker, or $(_adoption_bind_hint "${display}")")" '. + [$r]' <<< "${refusals}")"
      continue
    fi

    # --- Hierarchy (FR 014, FR 015) -----------------------------------------
    if [[ "${level}" == "story" ]]; then
      local expected
      expected="$(jq -r --arg f "${folder}" '.[$f] // ""' <<< "${feature_keys}")"
      if [[ -z "${expected}" ]]; then
        local msg
        msg="$(printf '"%s" resolves to %s, but the feature-level ticket of spec "%s" is not bound in this run' \
          "${display}" "${chosen}" "${folder}")"
        refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
          'unbound-parent' "$(jq -cn --arg k "${chosen}" '[$k]')" "${msg}" \
          "bind the spec's feature-level ticket in the same run: $(_adoption_bind_hint "${folder}")")" \
          '. + [$r]' <<< "${refusals}")"
        continue
      fi
      local parent
      parent="$(jq -r 'if . == null then "" else (.parent_key // "") end' <<< "${cand}")"
      if [[ "${parent}" != "${expected}" ]]; then
        local shown msg pkeys
        shown="${parent:-(none)}"
        msg="$(printf '"%s" resolves to %s, whose parent is %s, but the spec is bound to %s' \
          "${display}" "${chosen}" "${shown}" "${expected}")"
        pkeys="$(jq -cn --arg a "${chosen}" --arg b "${parent}" --arg c "${expected}" \
          '[$a, $b, $c] | map(select(. != "")) | unique')"
        refusals="$(jq -c --argjson r "$(_adoption_refusal "${folder}" "${level}" "${ordinal}" \
          'wrong-parent' "${pkeys}" "${msg}" \
          "re-parent ${chosen} under ${expected} in the tracker, then re-run: spec-kit-jira adopt --spec ${folder}")" \
          '. + [$r]' <<< "${refusals}")"
        continue
      fi
    fi

    # --- Bind ----------------------------------------------------------------
    bindings="$(jq -c --argjson b "$(_adoption_binding "${folder}" "${level}" "${ordinal}" \
      "${chosen}" "${reason}" "${overrode}" 'adopt')" '. + [$b]' <<< "${bindings}")"
    if [[ "${level}" == "feature" ]]; then
      feature_keys="$(jq -c --arg f "${folder}" --arg k "${chosen}" '. + {($f): $k}' <<< "${feature_keys}")"
    fi
  done

  jq -cn --argjson b "${bindings}" --argjson r "${refusals}" '{bindings: $b, refusals: $r}' | json_canonical
}
