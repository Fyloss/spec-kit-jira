#!/usr/bin/env bats
# T034/T035/T040 [US3], updated by 030 (contracts/credential-resolution.md
# C2.6): the per-run credential cache (contracts/credential-cache.md), wired
# into cmd_reconcile — the declared JIRA_PAT_COMMAND is executed AT MOST ONCE
# per reconcile process, however many requests (and retries) the run issues,
# and NOT AT ALL when the run never reaches the point of needing a
# credential. Uses the counting stub from T005 / repurposed by 030 C7.1
# (tests/bash/helpers/secret_store_stub.bash) — never a wall clock, never a
# machine-wide scan (Constitution XIII).
#
# There is no PowerShell twin of this file (measured: tests/powershell/commands/
# holds no credential-cache test, and the only PowerShell users of the shim are
# lib/Credentials.Tests.ps1 and ci/SecretStoreStubHelper.Tests.ps1) — this
# at-most-once claim, at the reconcile-command level, exists in the Bash port
# alone (030, T036e).

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
  COUNTER="${BATS_TEST_TMPDIR}/pat-command.count"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  # The bridge's own resolution order must not be short-circuited by whatever
  # the developer running the suite happens to have exported.
  unset JIRA_API_TOKEN _CRED_SECRET_TOKEN JIRA_PAT_COMMAND
}

teardown() {
  mock_stop
}

@test "JIRA_PAT_COMMAND is executed exactly once for a run issuing many requests including one retried after a 429 (T034)" {
  helper_pat_command_install "${BIN}" "${COUNTER}" "from-the-command"
  # search/jql is the duplicate-probe's own endpoint (017): a fresh run with
  # no parent marker yet fires it once, best-effort, before creating the
  # parent — a real request this feature's cache must still cover.
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"},"faults":{"search/jql":{"status":429,"retryAfter":0}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  JIRA_MAX_ATTEMPTS=2 run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  # Sanity: this really was a many-request run, including one retried 429 —
  # otherwise a count of 1 would prove nothing.
  local posts probes
  posts="$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")"
  [ "${posts}" -eq 3 ]
  probes="$(grep -c 'search/jql' "${MOCK_CALLLOG}")"
  [ "${probes}" -eq 2 ]

  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "1" ]
}

@test "zero JIRA_PAT_COMMAND executions for a run that short-circuits on run state (T035)" {
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  # The second run's unchanged inputs must short-circuit (021) BEFORE any
  # credential is ever needed — install the stub only now, and unset the
  # environment token, so a wrongly-early prime would be caught.
  helper_pat_command_install "${BIN}" "${COUNTER}" "should-never-be-read"
  unset JIRA_API_TOKEN
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.short_circuited' <<< "$output")" = "true" ]

  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "T040 [024]: config_yaml_to_json adds no NEW parse for a run that short-circuits on run state (FR-015)" {
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Deliberately NOT `run` (a `$( … )` subshell): config_yaml_cache_prime is
  # called again inside EVERY invocation of cmd_reconcile (024, T057), and a
  # subshell's own priming is invisible to the parent once it exits — the
  # same reason cred_prime_cache/jira_request_count_prime must run in the
  # main shell. A plain `>` redirect keeps both calls in the test's own
  # shell, so the SAME cache (primed fresh by the first, real, run) is what
  # the second, short-circuited, call and the assertion below both see —
  # the short-circuit itself never reaches the `config` phase, so it never
  # re-primes; a stale-zero count from a never-primed cache would prove
  # nothing, which is why this compares before/after rather than asserting 0.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  local before_team before_local
  before_team="$(config_yaml_parse_count "${JIRA_CONFIG_DIR}/config.yml")"
  before_local="$(config_yaml_parse_count "${JIRA_CONFIG_DIR}/config.local.yml")"
  [ "${before_team}" -gt 0 ]
  [ "${before_local}" -gt 0 ]

  local out
  out="${BATS_TEST_TMPDIR}/second_run.json"
  cmd_reconcile reconcile "${SPEC}" --json > "${out}" 2>&1
  [ "$?" -eq 0 ]
  [ "$(jq -r '.short_circuited' < "${out}")" = "true" ]

  [ "$(config_yaml_parse_count "${JIRA_CONFIG_DIR}/config.yml")" = "${before_team}" ]
  [ "$(config_yaml_parse_count "${JIRA_CONFIG_DIR}/config.local.yml")" = "${before_local}" ]
}

@test "T058 [024]: config.local.yml parses exactly once across a full real run, including apply's hook-health read" {
  # T058 asked where `apply`'s unexplained ~35s on the motivating machine
  # came from. Reading `reconcile.sh` end to end (not measuring) found a
  # THIRD call site nobody had named: `config_hooks_disabled_read` (hook
  # health, "read and reported on every run") sits inside the `apply` phase's
  # timing window, unconditionally — even under --dry-run, even with zero
  # writes — and it re-parses config.local.yml exactly like `config_load`
  # (config phase) and `_reconcile_local_binding_for` (gate phase) do. T057's
  # cache already covers it for free, since all three build the identical
  # "${JIRA_CONFIG_DIR}/config.local.yml" path string — this test is the
  # proof, not a fix: it exercises a REAL, non-short-circuited `cmd_reconcile`
  # call (not the two functions in isolation, as T033 does) and asserts the
  # THIRD site never adds a second parse.
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  [ "$(config_yaml_parse_count "${JIRA_CONFIG_DIR}/config.local.yml")" = "1" ]
}

@test "zero JIRA_PAT_COMMAND executions for a run in a repository with no base URL (T035)" {
  helper_pat_command_install "${BIN}" "${COUNTER}" "should-never-be-read"
  unset SPEC_KIT_JIRA_BASE_URL
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "zero JIRA_PAT_COMMAND executions for a run whose token came from the environment (T035)" {
  helper_pat_command_install "${BIN}" "${COUNTER}" "should-never-be-read"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # Confirm this really was a many-request run — rung 1 (env) wins regardless
  # of caching, so this is the cache NOT masking a real zero-consultation case.
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 3 ]

  run helper_pat_command_count "${COUNTER}"
  [ "${output}" = "0" ]
}

@test "the raw token and its derived base64 value are absent from the entire post-run tree, including the state document (T040)" {
  helper_pat_command_install "${BIN}" "${COUNTER}" "TREE-SECRET-TOKEN"
  local cfg
  cfg="$(mock_write_config '{"projects":{"TASKP":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local basic
  basic="$(printf '%s:%s' "${JIRA_EMAIL}" "TREE-SECRET-TOKEN" | base64 | tr -d '\n')"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  ! grep -rq "TREE-SECRET-TOKEN" "${WORK}"
  ! grep -rq -- "${basic}" "${WORK}"
}
