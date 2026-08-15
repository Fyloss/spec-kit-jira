#!/usr/bin/env bash
# lib/seed_state.sh — The seeded-not-bound record's document layer (027,
# research R8, contracts/seed-record.md).
#
# A sibling of lib/run_state.sh's `<feature-dir>.json`, but a SEPARATE
# document (research R8): the run-state schema's own comment states that a
# change to the set of recorded inputs bumps its version and invalidates
# every existing file, so folding this in would cost every consumer of the
# extension a full-reconcile penalty. Port infrastructure only: NO Jira
# knowledge — every function is a pure function of its arguments.

[[ -n ${_JIRA_LIB_SEED_STATE:-} ]] && return 0
_JIRA_LIB_SEED_STATE=1

_SEED_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_SEED_STATE_LIB_DIR}/config.sh"   # config_extension_version
# shellcheck source=/dev/null
source "${_SEED_STATE_LIB_DIR}/output.sh"   # json_canonical, output_warn

# Shape version of the seed record (data-model.md §5).
_SEED_STATE_SCHEMA=1

# seed_state_path <spec-path> — the recorded document's path for the
# feature directory holding this spec. A sibling of run_state_path's
# <feature-dir>.json.
seed_state_path() {
  local spec_path="$1"
  printf '%s/state/%s.seed.json' "${JIRA_CONFIG_DIR}" "$(basename "$(dirname "${spec_path}")")"
}

# seed_state_compose <slug> <designators-json> <plan-digest> [<routing-json>]
# [<plan-snapshot-json>] — prints the canonical JSON document (§2).
# `bindings` is always an explicit empty array (FR-049 — a statement, not a
# silence); `plan_digest` is omitted (null) when <plan-digest> is empty.
# `routing` (default `{}`) carries the routed project key and the declared
# types/terminal statuses moment 1 already resolved from `config.yml` — an
# additive field so moment 2 (FR-062's resume) can re-evaluate every
# refusal class from Jira alone, without re-opening `config.yml`/
# `personal.yml` itself (those stay moment-1-only concerns). `plan_snapshot`
# (default `[]`) is the last-rendered plan entries, kept so a resume can
# compute FR-064's added/vanished delta structurally; `plan_digest` remains
# the byte-check the contract names.
seed_state_compose() {
  local slug="$1" designators="$2" plan_digest="${3:-}" routing="${4:-{\}}" plan_snapshot="${5:-[]}"
  local ext_version
  ext_version="$(config_extension_version 2> /dev/null)" || ext_version=""
  local digest_json
  if [[ -z "${plan_digest}" ]]; then
    digest_json='null'
  else
    digest_json="$(jq -Rn --arg v "${plan_digest}" '$v')"
  fi
  jq -cn \
    --argjson schema "${_SEED_STATE_SCHEMA}" \
    --arg ext "${ext_version}" \
    --arg slug "${slug}" \
    --argjson designators "${designators}" \
    --argjson digest "${digest_json}" \
    --argjson routing "${routing}" \
    --argjson snapshot "${plan_snapshot}" \
    '{schema_version:$schema, extension_version:$ext, slug:$slug, designators:$designators, bindings:[], plan_digest:$digest, routing:$routing, plan_snapshot:$snapshot}' \
    | json_canonical
}

# seed_state_designators_equal <recorded-designators-json> <current-designators-json>
# — §3, FR-041: "the same" when, for each role, the ordered list of reduced
# keys is equal, and the free-text parent value is byte-equal when present.
# Prints "true" or "false".
seed_state_designators_equal() {
  local recorded="$1" current="$2"
  jq -n --argjson a "${recorded}" --argjson b "${current}" '
    def norm_spec(x): (x | map(select(.role=="specification")) | .[0]) as $p
      | if $p == null then null
        elif $p.form == "free_text" then {t:$p.text}
        else {k:$p.key} end;
    def norm_stories(x): x | map(select(.role=="story")) | sort_by(.position) | map(.key);
    (norm_spec($a) == norm_spec($b)) and (norm_stories($a) == norm_stories($b))
  '
}

# seed_state_plan_digest <rendered-plan-text> — the digest FR-064 names, via
# this repo's one content-hash primitive (research: `git hash-object`,
# shared with `lib/run_state.sh`'s own spec.md hash).
seed_state_plan_digest() {
  printf '%s' "$1" | git hash-object --stdin
}

# seed_state_read <spec-path> — print the recorded document, or return 1
# (printing nothing) when absent, unreadable, or invalid JSON.
seed_state_read() {
  local spec_path="$1" path content
  path="$(seed_state_path "${spec_path}")"
  [[ -f "${path}" ]] || return 1
  content="$(cat "${path}" 2> /dev/null)" || return 1
  jq -e . > /dev/null 2>&1 <<< "${content}" || return 1
  printf '%s' "${content}"
}

# seed_state_write <spec-path> <doc-json> — write atomically to a sibling
# temp file, then rename onto the final name. Creates the state directory
# and its self-ignoring .gitignore if absent (a sibling of run_state's own,
# so both share one ignore rule).
seed_state_write() {
  local spec_path="$1" doc="$2" path state_dir
  path="$(seed_state_path "${spec_path}")"
  state_dir="$(dirname "${path}")"

  if [[ ! -d "${state_dir}" ]] && ! mkdir -p "${state_dir}" 2> /dev/null; then
    output_warn "seed-state: could not create ${state_dir}; state not recorded"
    return 0
  fi
  local gitignore="${state_dir}/.gitignore"
  [[ -f "${gitignore}" ]] || printf '*\n' > "${gitignore}" 2> /dev/null

  local tmp="${path}.tmp.$$"
  if ! printf '%s' "${doc}" > "${tmp}" 2> /dev/null; then
    rm -f "${tmp}" 2> /dev/null
    output_warn "seed-state: could not write ${tmp}; state not recorded"
    return 0
  fi
  if ! mv -f "${tmp}" "${path}" 2> /dev/null; then
    rm -f "${tmp}" 2> /dev/null
    output_warn "seed-state: could not rename onto ${path}; state not recorded"
    return 0
  fi
  return 0
}

# seed_state_delete <spec-path> — remove the record (§4: deleted on
# success, not marked done). A no-op when absent.
seed_state_delete() {
  local spec_path="$1" path
  path="$(seed_state_path "${spec_path}")"
  rm -f "${path}" 2> /dev/null
  return 0
}
