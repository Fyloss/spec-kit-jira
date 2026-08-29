#!/usr/bin/env bats
# T011-T013 — the request counter tells the truth (spec FR-036, FR-037,
# contracts/request-counting.md). `jira_request` is invoked through `$( … )`
# at 15 of its 28 call sites, so an in-shell-variable increment made there is
# discarded when that subshell exits (research R2): the reference scenario
# issues 123 requests and the pre-fix report attributes 0 to every phase.
# `calls.log` — the harness's own record of what the mock actually received —
# is the ground truth every assertion here is checked against, never the
# instrument's own prior output.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/calls_log.bash"
  SCENARIO="${ROOT}/tests/conformance/scenarios/us021-prefetch-count-61.json"
  OUTDIR="${BATS_TMPDIR}/request_count_$$_${BATS_TEST_NUMBER:-0}"
}

teardown() {
  rm -rf "${OUTDIR}"
}

_run_with_timing() {
  SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_TIMING=1" \
    bash "${ROOT}/tests/conformance/run-scenario.sh" "${SCENARIO}" bash "${OUTDIR}" > /dev/null
}

# --- V1/V2: summed counts equal calls.log, and phase attribution is real ----

@test "T011: summed per-phase request counts equal calls.log's total (V1)" {
  _run_with_timing
  local total_calls total_reported
  total_calls="$(helper_calls_total "${OUTDIR}/calls.log")"
  total_reported="$(grep '^timing: total' "${OUTDIR}/stderr" | sed -E 's/^timing: total +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  [ "${total_calls}" -gt 0 ]
  [ -n "${total_reported}" ]
  [ "${total_reported}" = "${total_calls}" ]
}

@test "T011: no single phase reports zero requests when it issued some (V2, read phases carry the reads)" {
  _run_with_timing
  # recognition and plan/apply are the phases that issue requests on this
  # scenario (a fresh 61-item spec: recognition reads, plan/apply write);
  # prereq/state/config/gate never call jira_request and must legitimately
  # stay at 0 — asserting them at 0 too documents that this is attribution,
  # not "every phase gets a share of the total".
  local recognition_req
  recognition_req="$(grep '^timing: recognition' "${OUTDIR}/stderr" | sed -E 's/^timing: recognition +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  [ "${recognition_req}" -gt 0 ]

  local prereq_req state_req
  prereq_req="$(grep '^timing: prereq' "${OUTDIR}/stderr" | sed -E 's/^timing: prereq +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  state_req="$(grep '^timing: state' "${OUTDIR}/stderr" | sed -E 's/^timing: state +[0-9]+ ms +([0-9]+) requests.*/\1/')"
  [ "${prereq_req}" = "0" ]
  [ "${state_req}" = "0" ]
}

# --- V3: a retried request increments the counter once per attempt ---------

@test "T012: a retried request increments the counter once per attempt (V3)" {
  ROOT2="${ROOT}"
  LIB="${ROOT2}/scripts/bash"
  local mock_calls_file="${BATS_TMPDIR}/mock_curl_calls_$$"
  rm -f "${mock_calls_file}"
  run env JIRA_NO_SLEEP=1 JIRA_MAX_ATTEMPTS=3 MOCK_CALLS_FILE="${mock_calls_file}" bash -c '
    source "'"${LIB}"'/lib/cli.sh"
    source "'"${LIB}"'/lib/credentials.sh"
    source "'"${LIB}"'/sink/jira/client.sh"
    jira_request_count_prime
    # Curl runs on the far side of a pipe (a subshell), so a plain shell
    # variable cannot track "which attempt is this" across invocations —
    # only a file survives, the same reason the real counter is one.
    curl() {
      printf x >> "${MOCK_CALLS_FILE}"
      local n; n="$(wc -c < "${MOCK_CALLS_FILE}")"
      if (( n < 3 )); then printf "429"; else printf "200"; fi
    }
    export -f curl
    # 032, C6.4 — declare the destination the way the connection chokepoint
    # does in production; without it the credential producer rightly refuses.
    export SPEC_KIT_JIRA_BASE_URL="https://example.invalid"
    JIRA_EMAIL=user@example.com JIRA_API_TOKEN=tok jira_request GET "https://example.invalid/x" > /dev/null 2>&1 || true
    printf "count=%s" "$(jira_request_count)"
  '
  rm -f "${mock_calls_file}"
  [[ "${output}" == *"count=3"* ]]
}

# --- V5: fail-open — a counting failure never changes the outcome ----------

@test "T013: with the counter file unwritable, the run's outcome is unaffected (V5, fail-open)" {
  ROOT2="${ROOT}"
  LIB="${ROOT2}/scripts/bash"
  RCFILE="${BATS_TEST_TMPDIR}/rc"
  # V5 claims one thing: a counting failure does not change the RUN'S OUTCOME.
  # The outcome is the exit status, so that is what is asserted — written to a
  # file by the subshell itself rather than parsed out of merged stdout+stderr.
  #
  # The previous form matched `"${output}" == "survived rc=0"*`, anchored on the
  # PREFIX of the two streams combined. That conflates "the outcome is right"
  # with "nothing else printed anything", so any diagnostic on stderr — from
  # this code or from the environment — reddened it while the outcome was fine.
  # It passed on macOS, under Linux bash, under bats 1.10, and in a full local
  # suite of the same 2599 tests, and failed only on the CI runner: exactly the
  # signature of an assertion measuring something other than its subject.
  run bash -c '
    source "'"${LIB}"'/lib/cli.sh"
    source "'"${LIB}"'/lib/credentials.sh"
    source "'"${LIB}"'/sink/jira/client.sh"
    _JIRA_REQUEST_COUNT_FILE="/nonexistent-dir-xyz/count.log"
    curl() { printf "%s" "200"; }
    export -f curl
    # 032, C6.4 — declare the destination the way the connection chokepoint
    # does in production; without it the credential producer rightly refuses.
    export SPEC_KIT_JIRA_BASE_URL="https://example.invalid"
    JIRA_EMAIL=user@example.com JIRA_API_TOKEN=tok jira_request GET "https://example.invalid/x" > /dev/null
    printf "%s" "$?" > "'"${RCFILE}"'"
    printf "count=%s" "$(jira_request_count)"
  '
  [ "${status}" -eq 0 ]
  # The outcome itself: unchanged by the counter being unwritable.
  [ "$(cat "${RCFILE}")" -eq 0 ]
  # And the counter fails open rather than erroring.
  [[ "${output}" == *"count=0"* ]]
}

@test "T013: an unprimed counter file reads as zero rather than erroring" {
  ROOT2="${ROOT}"
  LIB="${ROOT2}/scripts/bash"
  run bash -c '
    source "'"${LIB}"'/sink/jira/client.sh"
    printf "%s" "$(jira_request_count)"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" = "0" ]
}
