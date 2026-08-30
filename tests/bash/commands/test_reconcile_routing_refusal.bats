#!/usr/bin/env bats
# T043/T045/T047 [Phase 5, US3] — the four-finding routing refusal
# (contracts/routing-resolution.md C6.1-C6.5, spec FR-007).
#
# The conformance corpus proves these messages byte-identical across ports. What
# it cannot do is assert the ABSENCE of a phrase, or enumerate the three rank-3
# states from one fixture — a scenario is one run against one repository. That
# is what this file is for.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  CFG_DIR="${WORK}/.specify/jira"
  CFG='{"projects":[{"key":"ALPHA"}],"routing":[{"match":{"folder_prefix":"003-billing-"},"project":"ALPHA"}]}'
  CFG_EMPTY='{"projects":[{"key":"ALPHA"}]}'
  CFG_TEAMS='{"projects":[{"key":"ALPHA"}],"routing":[],"teams":[{"id":"beta","project":"BETA","folder_prefix":"beta-"}]}'
}

teardown() {
  rm -rf "${WORK}"
}

# --- C6.2 every rank is reported, not only the last -------------------------

@test "C6.2 the message reports all four ranks" {
  run _reconcile_routing_refusal "/x/007-legacy-cleanup" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"Rule route:"* ]]
  [[ "${output}" == *"Team route:"* ]]
  [[ "${output}" == *"Your team:"* ]]
  [[ "${output}" == *"Default:"* ]]
}

@test "C6.2 the message names the specification it could not place" {
  run _reconcile_routing_refusal "/x/007-legacy-cleanup" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *'"007-legacy-cleanup"'* ]]
}

@test "C6.1 the message states that nothing was written" {
  run _reconcile_routing_refusal "/x/007-legacy-cleanup" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"zero writes"* ]]
}

@test "C6.2 rank 1 distinguishes 'none declared' from 'none matched'" {
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"none of the 1 routing rules matched"* ]]
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG_EMPTY}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"no routing rules are declared"* ]]
}

@test "C6.2 rank 2 distinguishes 'no catalogue' from 'no prefix matched'" {
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"no teams: catalogue is declared"* ]]
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG_TEAMS}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"none of the 1 team folder prefixes matched"* ]]
}

# --- C6.3 the three rank-3 states are kept apart -----------------------------

@test "C6.3 state 1: no personal.yml at all" {
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"personal.yml does not exist"* ]]
}

@test "C6.3 state 2: personal.yml exists but selects no team" {
  printf '# no team here\n' > "${CFG_DIR}/personal.yml"
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"declares no team: key"* ]]
  [[ "${output}" != *"does not exist"* ]]
}

@test "C6.3 state 3: the specification is already bound, so rank 3 never ran" {
  run _reconcile_routing_refusal "/x/008-bound" "${CFG}" "${CFG_DIR}" "true" ""
  [[ "${output}" == *"already bound"* ]]
  # The operator must NOT be told to select a team: it would not have helped.
  [[ "${output}" != *"no team is selected"* ]]
}

@test "C6.3 the three states produce three different messages" {
  local s1 s2 s3
  s1="$(_reconcile_routing_refusal "/x/007" "${CFG}" "${CFG_DIR}" "false" "")"
  printf '# no team here\n' > "${CFG_DIR}/personal.yml"
  s2="$(_reconcile_routing_refusal "/x/007" "${CFG}" "${CFG_DIR}" "false" "")"
  s3="$(_reconcile_routing_refusal "/x/007" "${CFG}" "${CFG_DIR}" "true" "")"
  [ "${s1}" != "${s2}" ]
  [ "${s2}" != "${s3}" ]
  [ "${s1}" != "${s3}" ]
}

# --- C6.5 routing_default is not prescribed as the sole remedy ---------------

@test "C6.5 the message does not prescribe routing_default as the only fix" {
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" != *"add routing_default to config.yml"* ]]
}

@test "C6.5 all three remedies are offered, in one sentence" {
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"add a rule or a teams: entry"* ]]
  [[ "${output}" == *"select your team in"* ]]
  [[ "${output}" == *"or declare routing_default in"* ]]
}

@test "C6.2 rank 4 says the key is absent when it is" {
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"routing_default is not declared"* ]]
}

@test "the message is a single line" {
  # It travels through the hook-context WARNING, which is one line by contract.
  run _reconcile_routing_refusal "/x/007-legacy" "${CFG}" "${CFG_DIR}" "false" ""
  [ "$(printf '%s' "${output}" | awk 'END{print NR}')" -eq 1 ]
}
