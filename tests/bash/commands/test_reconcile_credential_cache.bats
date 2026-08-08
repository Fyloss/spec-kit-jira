#!/usr/bin/env bats
# T034/T035/T040 [US3] — the per-run credential cache
# (contracts/credential-cache.md), wired into cmd_reconcile: the OS secret
# store is consulted AT MOST ONCE per reconcile process, however many
# requests (and retries) the run issues, and NOT AT ALL when the run never
# reaches the point of needing a credential. Uses the counting stub from T005
# (tests/bash/helpers/secret_store_stub.bash) — never a wall clock, never a
# machine-wide scan (Constitution XIII).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-task-tier"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/secret_store_stub.bash"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"

  BIN="${BATS_TEST_TMPDIR}/bin"
  COUNTER="${BATS_TEST_TMPDIR}/secret-store.count"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  # The bridge's own resolution order must not be short-circuited by whatever
  # the developer running the suite happens to have exported.
  unset JIRA_API_TOKEN _CRED_SECRET_TOKEN
}

teardown() {
  mock_stop
}

@test "the secret store is consulted exactly once for a run issuing many requests including one retried after a 429 (T034)" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "from-the-store"
  # search/jql is the duplicate-probe's own endpoint (017): a fresh run with
  # no parent marker yet fires it once, best-effort, before creating the
  # parent — a real request this feature's cache must still cover.
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"},"faults":{"search/jql":{"status":429,"retryAfter":0}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  JIRA_MAX_ATTEMPTS=2 PATH="${BIN}:${PATH}" run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  # Sanity: this really was a many-request run, including one retried 429 —
  # otherwise a count of 1 would prove nothing.
  local posts probes
  posts="$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")"
  [ "${posts}" -eq 3 ]
  probes="$(grep -c 'search/jql' "${MOCK_CALLLOG}")"
  [ "${probes}" -eq 2 ]

  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "1" ]
}

@test "zero secret-store consultations for a run that short-circuits on run state (T035)" {
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # The second run's unchanged inputs must short-circuit (021) BEFORE any
  # credential is ever needed — install the stub only now, and unset the
  # environment token, so a wrongly-early prime would be caught.
  helper_secret_store_install "${BIN}" "${COUNTER}" "should-never-be-read"
  unset JIRA_API_TOKEN
  PATH="${BIN}:${PATH}" run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.short_circuited' <<< "$output")" = "true" ]

  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "zero secret-store consultations for a run in a repository with no base URL (T035)" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "should-never-be-read"
  unset SPEC_KIT_JIRA_BASE_URL
  PATH="${BIN}:${PATH}" run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "zero secret-store consultations for a run whose token came from the environment (T035)" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "should-never-be-read"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  PATH="${BIN}:${PATH}" run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # Confirm this really was a many-request run — rung 1 (env) wins regardless
  # of caching, so this is the cache NOT masking a real zero-consultation case.
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 3 ]

  run helper_secret_store_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "the raw token and its derived base64 value are absent from the entire post-run tree, including the state document (T040)" {
  helper_secret_store_install "${BIN}" "${COUNTER}" "TREE-SECRET-TOKEN"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local basic
  basic="$(printf '%s:%s' "${JIRA_EMAIL}" "TREE-SECRET-TOKEN" | base64 | tr -d '\n')"

  PATH="${BIN}:${PATH}" run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  ! grep -rq "TREE-SECRET-TOKEN" "${WORK}"
  ! grep -rq -- "${basic}" "${WORK}"
}
