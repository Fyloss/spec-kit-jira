#!/usr/bin/env bash
# lib/run_state.sh — The run-state short-circuit's document layer (FR-019…
# FR-028, contracts/run-state.md, data-model.md §1).
#
# Every function here is a pure function of its arguments, like lib/config.sh
# and lib/credentials.sh's cred_curl_config — never reads JIRA_EMAIL or
# SPEC_KIT_JIRA_BASE_URL itself. The hashing primitive is `git hash-object
# --no-filters`, the only content hash guaranteed present and identical on
# all three hosts (research R7).
#
# Port infrastructure only: NO Jira knowledge.

[[ -n ${_JIRA_LIB_RUN_STATE:-} ]] && return 0
_JIRA_LIB_RUN_STATE=1

_RUN_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_RUN_STATE_LIB_DIR}/config.sh"   # config_extension_version
# shellcheck source=/dev/null
source "${_RUN_STATE_LIB_DIR}/output.sh"   # json_canonical, output_warn

# Shape version of the run-state document (data-model.md §1). A change to the
# *set* of recorded inputs bumps it, invalidating every existing file.
# 023, contracts/run-state-v2.md C1: 1 -> 2 for `hook_event` and `plan.md`.
# 036, contracts/run-state-v3.md C1: 2 -> 3, because `inputs` stops being three
# fixed documents and becomes the whole artifact set. Every schema-2 file is
# invalidated by the bump, and the first run after an upgrade therefore does
# real work — which is correct rather than wasteful: those artifacts are about
# to be published for the first time and no record says otherwise.
_RUN_STATE_SCHEMA=3

# run_state_path <spec-path> — the recorded document's path for the feature
# directory holding this spec.
run_state_path() {
  local spec_path="$1"
  printf '%s/state/%s.json' "${JIRA_CONFIG_DIR}" "$(basename "$(dirname "${spec_path}")")"
}

# _run_state_add_input <inputs-json> <key> <path> — folds one hashed input
# into <inputs-json> under <key> when <path> exists; leaves it untouched when
# <path> is absent (data-model.md §1 "key omitted"). Prints the updated
# inputs object. Returns 1, printing nothing, if <path> exists but cannot be
# hashed.
_run_state_add_input() {
  local inputs="$1" key="$2" path="$3"
  if [[ ! -f "${path}" ]]; then
    printf '%s' "${inputs}"
    return 0
  fi
  local hash
  hash="$(git hash-object --no-filters "${path}" 2> /dev/null)"
  [[ -z "${hash}" ]] && return 1
  jq -c --arg k "${key}" --arg h "${hash}" '. + {($k): $h}' <<< "${inputs}"
}

# run_state_compose <spec-path> <base-url> <email> <on-drift> <hook-event>
# <field-values> <artifact-set-json> — 023, contracts/run-state-v2.md §2:
# `hook_event` is an explicit argument, never read from
# SPEC_KIT_JIRA_HOOK_EVENT itself, so this module stays a pure function of its
# arguments (the same discipline base_url/email/on_drift/field_values already
# have). Prints the canonical JSON document for the current inputs. Returns 1,
# printing nothing, if any required input cannot be hashed.
#
# 036, contracts/run-state-v3.md C2/C3: the seventh argument is the ARTIFACT
# SET — every publishable file of the feature directory, already carrying the
# `git hash-object --no-filters --stdin-paths` hashes the engine computed in
# ONE call (C3.4). It is passed in rather than built here for two reasons: this
# module is `lib/` and the set is built in `engine/`, which is the wrong
# direction to source; and the reconcile already holds it, so building a second
# one would be a second `git ls-files` for an answer it has.
#
# Under schema 2 this recorded three fixed documents, and a run fired after only
# `research.md` changed found all three hashes matching and short-circuited with
# zero Jira calls — leaving the artifact unpublished forever (C4). That is the
# whole reason for the bump.
run_state_compose() {
  local spec_path="$1" base_url="$2" email="$3" on_drift="$4" hook_event="$5" field_values="$6"
  local artifacts="${7:-[]}"
  [[ -f "${spec_path}" ]] || return 1

  local ext_version
  ext_version="$(config_extension_version 2> /dev/null)" || return 1

  # C3.1/C3.3: the key set IS the artifact set's paths — relative to the
  # feature directory and `/`-separated on every host, because this document is
  # byte-compared across ports and machines. No hashing happens here: the set
  # arrives hashed, which is what makes C5's bounded process budget hold.
  local inputs
  inputs="$(jq -c 'map({key: .path, value: .hash}) | from_entries' <<< "${artifacts}" 2> /dev/null)" || return 1
  [[ -n "${inputs}" && "${inputs}" != "null" ]] || return 1

  # C3.2's "an absent file is not in the set" rule covers the feature
  # directory. It does NOT cover the three configuration files below: they live
  # outside it, they are read on every run, and a change to any of them changes
  # what the run would write. Dropping them would silently weaken the
  # short-circuit into ignoring a re-pointed project — so they keep both their
  # hashing and v2's "key omitted when absent" rule, which is what `personal.yml`
  # being gitignored and frequently absent requires.
  local f
  for f in config.yml config.local.yml personal.yml; do
    inputs="$(_run_state_add_input "${inputs}" "${JIRA_CONFIG_DIR}/${f}" "${JIRA_CONFIG_DIR}/${f}")" || return 1
  done

  jq -cn \
    --argjson schema "${_RUN_STATE_SCHEMA}" \
    --arg ext "${ext_version}" \
    --arg base "${base_url}" \
    --arg email "${email}" \
    --arg drift "${on_drift}" \
    --arg he "${hook_event}" \
    --arg fv "${field_values}" \
    --argjson inputs "${inputs}" \
    '{schema: $schema, extension_version: $ext, base_url: $base, email: $email,
      on_drift: $drift, hook_event: $he, field_values: $fv, inputs: $inputs}' \
    | json_canonical
}

# run_state_matches <spec-path> <base-url> <email> <on-drift> <hook-event>
# <field-values> — returns 0 only when a recorded document exists, is
# readable, is valid JSON, and is byte-equal to a fresh compose of the same
# six arguments. Returns 1 in every other case, including every error —
# every doubt fails open (S1, S9: an unhonoured lifecycle event can never be
# skipped, since `hook_event` is now part of the byte comparison).
run_state_matches() {
  local spec_path="$1" base_url="$2" email="$3" on_drift="$4" hook_event="$5" field_values="$6"
  local artifacts="${7:-[]}"
  local recorded_path
  recorded_path="$(run_state_path "${spec_path}")"
  [[ -f "${recorded_path}" ]] || return 1

  local recorded
  recorded="$(cat "${recorded_path}" 2> /dev/null)" || return 1
  jq -e . > /dev/null 2>&1 <<< "${recorded}" || return 1

  local fresh
  fresh="$(run_state_compose "${spec_path}" "${base_url}" "${email}" "${on_drift}" "${hook_event}" "${field_values}" "${artifacts}")" || return 1

  [[ "${recorded}" == "${fresh}" ]]
}

# run_state_record <spec-path> <base-url> <email> <on-drift> <hook-event>
# <field-values> — composes and writes atomically to a sibling temp file,
# then renames onto the final name. Creates the state directory and its
# self-ignoring .gitignore if absent. Never fails the run: a write error is a
# warning, not an exit code.
run_state_record() {
  local spec_path="$1" base_url="$2" email="$3" on_drift="$4" hook_event="$5" field_values="$6"
  local artifacts="${7:-[]}"
  local recorded_path state_dir
  recorded_path="$(run_state_path "${spec_path}")"
  state_dir="$(dirname "${recorded_path}")"

  if [[ ! -d "${state_dir}" ]] && ! mkdir -p "${state_dir}" 2> /dev/null; then
    output_warn "run-state: could not create ${state_dir}; state not recorded"
    return 0
  fi

  local gitignore="${state_dir}/.gitignore"
  [[ -f "${gitignore}" ]] || printf '*\n' > "${gitignore}" 2> /dev/null

  local doc
  doc="$(run_state_compose "${spec_path}" "${base_url}" "${email}" "${on_drift}" "${hook_event}" "${field_values}" "${artifacts}")"
  if [[ -z "${doc}" ]]; then
    output_warn "run-state: could not compose the state document; state not recorded"
    return 0
  fi

  local tmp="${recorded_path}.tmp.$$"
  if ! printf '%s' "${doc}" > "${tmp}" 2> /dev/null; then
    rm -f "${tmp}" 2> /dev/null
    output_warn "run-state: could not write ${tmp}; state not recorded"
    return 0
  fi
  if ! mv -f "${tmp}" "${recorded_path}" 2> /dev/null; then
    rm -f "${tmp}" 2> /dev/null
    output_warn "run-state: could not rename onto ${recorded_path}; state not recorded"
    return 0
  fi
  return 0
}
