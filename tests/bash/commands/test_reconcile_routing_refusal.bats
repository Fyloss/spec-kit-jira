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

@test "035 C2.6 the message reports all FIVE ranks" {
  run _reconcile_routing_refusal "/x/007-legacy-cleanup" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"Rule route:"* ]]
  [[ "${output}" == *"Team route:"* ]]
  [[ "${output}" == *"Its own record:"* ]]
  [[ "${output}" == *"Your team:"* ]]
  [[ "${output}" == *"Default:"* ]]
}

@test "035 C2.6 the record clause says the specification carries no marker yet" {
  # This refusal is reachable only for an UNBOUND specification: a bound one
  # yields a marker project and resolves at rank 3, and markers naming two
  # projects refuse earlier still. The clause has exactly one honest state.
  run _reconcile_routing_refusal "/x/007-legacy-cleanup" "${CFG}" "${CFG_DIR}" "false" ""
  [[ "${output}" == *"Its own record: no ticket marker"* ]]
}

@test "035 C2.6 the operator-team clause is no longer labelled rank 3" {
  # An operator reading "rank 3" for the person would look for the wrong thing
  # in docs/07-configuration-and-secrets.md, where rank 3 is now the record.
  run grep -c 'Rank 3'"'"'s three states are kept apart' "${ROOT}/scripts/bash/commands/reconcile.sh"
  [ "$output" = "0" ]
}

@test "035 C2.6 the unreachable already-bound branch is gone from both ports" {
  # It named the right answer and acted on none of it. A bound specification
  # cannot reach this refusal any more, so the branch reported a state that
  # cannot occur.
  run grep -c "already bound, so its project is fixed by its own markers" "${ROOT}/scripts/bash/commands/reconcile.sh"
  [ "$output" = "0" ]
  run grep -c "already bound, so its project is fixed by its own markers" "${ROOT}/scripts/powershell/commands/Reconcile.psm1"
  [ "$output" = "0" ]
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

@test "035 C2.6 the `bound` parameter is now inert — it can no longer be true here" {
  # Kept in the signature so no caller changes, but a bound specification never
  # reaches this refusal: it resolves at rank 3. Passing "true" must therefore
  # produce the SAME message as passing "false".
  local as_bound as_unbound
  as_bound="$(_reconcile_routing_refusal "/x/008-bound" "${CFG}" "${CFG_DIR}" "true" "")"
  as_unbound="$(_reconcile_routing_refusal "/x/008-bound" "${CFG}" "${CFG_DIR}" "false" "")"
  [ "${as_bound}" = "${as_unbound}" ]
}

@test "C6.3 the two reachable rank-4 states still produce different messages" {
  # 035 retires the third: "already bound" cannot occur here any more. The two
  # that remain have different remedies — create the file, or uncomment a line
  # — so conflating them would still send one operator to edit a file that is
  # already correct.
  local s1 s2
  s1="$(_reconcile_routing_refusal "/x/007" "${CFG}" "${CFG_DIR}" "false" "")"
  printf '# no team here\n' > "${CFG_DIR}/personal.yml"
  s2="$(_reconcile_routing_refusal "/x/007" "${CFG}" "${CFG_DIR}" "false" "")"
  [ "${s1}" != "${s2}" ]
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
