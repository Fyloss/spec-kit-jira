#!/usr/bin/env bats
# T064 [032] — the destination pin's refusal under a lifecycle hook
# (contracts/origin-pinning.md §C5, SC-006). Modelled on
# test_reconcile_stale_binding.bats, which pins the same guarantee for the
# stale-binding refusal.
#
# Two things are proven here that the conformance corpus structurally cannot:
#
#   * Constitution III's hook contract — an `after_*` step must never fail the
#     host command. The corpus runs the bridge directly, never as a hook, so
#     only a per-port suite can set SPEC_KIT_JIRA_HOOK_CONTEXT and observe the
#     downgrade.
#   * That the LOCATED message survives the downgrade. Reconcile's chokepoint
#     call site substitutes a generic "team configuration could not be loaded"
#     line for whatever the library reported; if that substitution ever comes
#     back, the operator loses both origins and the accepting invocation on
#     exactly the path a hook takes, and every conformance scenario still
#     passes because none of them runs under a hook.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-032-origin-mismatch" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  # The gate only applies to a FILE-supplied destination (C4.3): with this set,
  # FR-011 exempts the run and nothing below would fire.
  unset SPEC_KIT_JIRA_BASE_URL SPEC_KIT_JIRA_HOOK_CONTEXT SPEC_KIT_JIRA_PLAN_CONTEXT
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}

@test "C4.5 — outside a hook the mismatch refuses with exit 4 and zero requests" {
  mock_start "${MOCK}/configs/default.json"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "${status}" -eq 4 ]
  [[ "${output}" == *"this checkout is bound to"* ]]

  run mock_calls
  [ -z "${output}" ]
}

@test "C5.1 — under a hook it downgrades to one WARNING and exit 0" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_HOOK_CONTEXT="after_specify"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^WARNING: ' <<< "${output}")" -eq 1 ]
}

@test "C5.2 — the located message survives the hook downgrade" {
  # The regression this exists for: the chokepoint call site replacing the
  # pin's message with the generic configuration-load line.
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_HOOK_CONTEXT="after_specify"
  run cmd_reconcile reconcile "${SPEC}" --json
  [[ "${output}" == *"declared.example.invalid"* ]]
  [[ "${output}" == *"other.example.invalid"* ]]
  [[ "${output}" == *"--accept-site"* ]]
  [[ "${output}" != *"the team configuration could not be loaded"* ]]
}

@test "C5.1 — a hook refusal still issues zero requests" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_HOOK_CONTEXT="after_specify"
  run cmd_reconcile reconcile "${SPEC}" --json
  run mock_calls
  [ -z "${output}" ]
}

@test "C5.3 — the downgrade holds for every registered lifecycle event" {
  # SC-006 names all seven. A guarantee proven for one event and assumed for
  # the others is the shape of defect this project has shipped before.
  local event
  for event in after_specify after_plan after_tasks after_analyze after_implement after_clarify before_specify; do
    mock_start "${MOCK}/configs/default.json"
    export SPEC_KIT_JIRA_HOOK_CONTEXT="${event}"
    run cmd_reconcile reconcile "${SPEC}" --json
    [ "${status}" -eq 0 ] || {
      printf 'event %s exited %s\n' "${event}" "${status}" >&2
      return 1
    }
    [ "$(grep -c '^WARNING: ' <<< "${output}")" -eq 1 ] || {
      printf 'event %s did not emit exactly one WARNING\n' "${event}" >&2
      return 1
    }
    mock_stop
  done
}

@test "C4.10 — no refusal path echoes any part of the credential" {
  # SC-007, at maximum verbosity. The token is a sentinel here so a substring
  # match is meaningful.
  mock_start "${MOCK}/configs/default.json"
  export JIRA_API_TOKEN="SENTINELTOKEN0123456789"
  run cmd_reconcile reconcile "${SPEC}" --json --verbose
  [[ "${output}" != *"SENTINELTOKEN"* ]]
}

@test "C4.11 — no refusal path prompts or blocks on stdin (FR-006)" {
  # A hook has nobody to answer. Running with stdin closed proves the refusal
  # terminates on its own rather than waiting for input — a wait is
  # indistinguishable from a hang to the operator, and Principle IV forbids it.
  #
  # The watchdog is hand-rolled on purpose: `timeout(1)` is not present on a
  # default macOS host, which is exactly why lib/credentials.sh bounds its own
  # retrieval command this way rather than shelling out to it.
  mock_start "${MOCK}/configs/default.json"

  local out="${BATS_TEST_TMPDIR}/out" rcfile="${BATS_TEST_TMPDIR}/rc"
  (
    # bats runs with errexit; without this the subshell dies on the bridge's
    # own non-zero exit before it can record what that exit actually was.
    set +e
    cd "${ROOT}" || exit 1
    bash scripts/bash/spec-kit-jira.sh reconcile --json "${SPEC}" < /dev/null > "${out}" 2>&1
    printf '%s' "$?" > "${rcfile}"
  ) &
  local pid=$!

  local waited=0 alive=1
  while [ "${waited}" -lt 200 ]; do
    kill -0 "${pid}" 2> /dev/null || { alive=0; break; }
    sleep 0.1
    waited=$((waited + 1))
  done

  if [ "${alive}" -eq 1 ]; then
    kill -TERM "${pid}" 2> /dev/null
    wait "${pid}" 2> /dev/null || true
    printf 'the refusal was still running after 20s — it blocked or prompted\n' >&2
    return 1
  fi

  wait "${pid}" 2> /dev/null || true
  [ "$(cat "${rcfile}")" -eq 4 ]
}

@test "C4.5 — a refusal writes nothing at all (T055)" {
  # The refusal must not helpfully record what it just refused: that would make
  # the first redirected run bind the checkout to the attacker's host.
  mock_start "${MOCK}/configs/default.json"
  local before after
  before="$(cat "${JIRA_CONFIG_DIR}/config.local.yml")"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "${status}" -eq 4 ]
  after="$(cat "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "${before}" = "${after}" ]
}

@test "C4.12 — no committed value can switch the gate off (T056b)" {
  # FR-015. A key that looks like an off switch must not become one: the team
  # schema refuses an unknown key outright, so the run fails closed either way
  # — what must never happen is a clean pass.
  mock_start "${MOCK}/configs/default.json"
  local cfg="${JIRA_CONFIG_DIR}/config.yml"
  printf 'pin_enforcement: false\nverify_destination: false\n' >> "${cfg}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "${status}" -ne 0 ]

  run mock_calls
  [ -z "${output}" ]
}
