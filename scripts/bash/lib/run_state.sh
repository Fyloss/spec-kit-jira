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
_RUN_STATE_SCHEMA=1

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

# run_state_compose <spec-path> <base-url> <email> <on-drift> <field-values>
# Prints the canonical JSON document for the current inputs. Returns 1,
# printing nothing, if any required input cannot be hashed.
run_state_compose() {
  local spec_path="$1" base_url="$2" email="$3" on_drift="$4" field_values="$5"
  [[ -f "${spec_path}" ]] || return 1

  local ext_version
  ext_version="$(config_extension_version 2> /dev/null)" || return 1

  local spec_hash
  spec_hash="$(git hash-object --no-filters "${spec_path}" 2> /dev/null)"
  [[ -z "${spec_hash}" ]] && return 1

  local inputs
  inputs="$(jq -cn --arg h "${spec_hash}" '{"spec.md": $h}')"

  local tasks_path
  tasks_path="$(dirname "${spec_path}")/tasks.md"
  inputs="$(_run_state_add_input "${inputs}" "tasks.md" "${tasks_path}")" || return 1

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
    --arg fv "${field_values}" \
    --argjson inputs "${inputs}" \
    '{schema: $schema, extension_version: $ext, base_url: $base, email: $email,
      on_drift: $drift, field_values: $fv, inputs: $inputs}' \
    | json_canonical
}

# run_state_matches <spec-path> <base-url> <email> <on-drift> <field-values>
# Returns 0 only when a recorded document exists, is readable, is valid JSON,
# and is byte-equal to a fresh compose of the same five arguments. Returns 1
# in every other case, including every error — every doubt fails open.
run_state_matches() {
  local spec_path="$1" base_url="$2" email="$3" on_drift="$4" field_values="$5"
  local recorded_path
  recorded_path="$(run_state_path "${spec_path}")"
  [[ -f "${recorded_path}" ]] || return 1

  local recorded
  recorded="$(cat "${recorded_path}" 2> /dev/null)" || return 1
  jq -e . > /dev/null 2>&1 <<< "${recorded}" || return 1

  local fresh
  fresh="$(run_state_compose "${spec_path}" "${base_url}" "${email}" "${on_drift}" "${field_values}")" || return 1

  [[ "${recorded}" == "${fresh}" ]]
}

# run_state_record <spec-path> <base-url> <email> <on-drift> <field-values>
# Composes and writes atomically to a sibling temp file, then renames onto
# the final name. Creates the state directory and its self-ignoring
# .gitignore if absent. Never fails the run: a write error is a warning, not
# an exit code.
run_state_record() {
  local spec_path="$1" base_url="$2" email="$3" on_drift="$4" field_values="$5"
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
  doc="$(run_state_compose "${spec_path}" "${base_url}" "${email}" "${on_drift}" "${field_values}")"
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
