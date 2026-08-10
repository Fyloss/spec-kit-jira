#!/usr/bin/env bats
# T114a [Phase 8, 022] — a repository scaffolded from
# templates/config.yml.template validates with zero schema errors, and
# `config_task_mirror_for` returns the empty string for every declared
# project: the template documents the setting without recording a choice
# (contract §3 `inert`, FR-002, FR-011).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/output.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  TEMPLATE="${ROOT}/templates/config.yml.template"
}

@test "the shipped template parses as valid YAML with zero schema errors" {
  local json; json="$(config_yaml_to_json "${TEMPLATE}")"
  local errs; errs="$(_cfg_schema_errors "${json}")"
  [ -z "${errs}" ]
}

@test "task_mirror is commented out — config_task_mirror_for returns empty for every declared project" {
  local json; json="$(config_yaml_to_json "${TEMPLATE}")"
  [ "$(jq -r 'has("task_mirror")' <<< "${json}")" = "false" ]
  local pkey
  while IFS= read -r pkey; do
    [ -z "${pkey}" ] && continue
    [ "$(config_task_mirror_for "${pkey}" "${json}")" = "" ]
  done < <(jq -r '.projects[].key' <<< "${json}")
}

@test "field_defaults is likewise commented out — the template records no default" {
  local json; json="$(config_yaml_to_json "${TEMPLATE}")"
  [ "$(jq -r 'has("field_defaults")' <<< "${json}")" = "false" ]
}
