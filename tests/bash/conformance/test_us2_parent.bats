#!/usr/bin/env bats
# T061/T062/T063 [Phase 5, US2] — quickstart Steps 7-9: the first run builds
# the whole hierarchy in one pass, the second run writes nothing, and the
# interrupted-parent window refuses the whole specification.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  MOCK="${CONF}/mock-jira"
  FIRST_RUN="${CONF}/scenarios/us2-parent-first-run.json"
  SECOND_RUN="${CONF}/scenarios/us2-parent-second-run.json"
  INTERRUPTED="${CONF}/scenarios/us2-parent-interrupted.json"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

# --- T061: the first run's call sequence (quickstart Step 7) ---------------

@test "T061: the first run creates the parent first, then every child carrying its key" {
  bash "${HARNESS}" "${FIRST_RUN}" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]

  local calls; calls="$(cat "${TMP}/out/calls.log")"
  # The parent is created first.
  [ "$(sed -n '1p' <<< "${calls}")" = "POST /rest/api/3/issue" ]
  [ "$(sed -n '2p' <<< "${calls}")" = "PUT /rest/api/3/issue/COMP-1/properties/spec-kit-jira" ]
  # Every child creation follows, each stamped immediately.
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "${calls}")" -eq 4 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-[0-9]*/properties/spec-kit-jira$' <<< "${calls}")" -eq 4 ]

}

@test "T061: the specification carries one spec= marker naming the parent, and one story= marker per story naming its child" {
  bash "${HARNESS}" "${FIRST_RUN}" bash "${TMP}/out" > /dev/null
  local spec="${TMP}/out/workdir/specs/001-billing-invoices/spec.md"
  [ "$(grep -c 'speckit-jira spec=[0-9a-f]\{16\} ticket=COMP-1 -->' "${spec}")" -eq 1 ]
  [ "$(grep -c 'speckit-jira story=[0-9a-f]\{16\} ticket=COMP-[2-4] -->' "${spec}")" -eq 3 ]
}

# --- T062: the second run writes nothing (quickstart Step 8) ---------------

@test "T062: the second run reads the parent and every story, and writes nothing" {
  bash "${HARNESS}" "${SECOND_RUN}" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "0" ]
  [ "$(jq -r '.counts.created' "${TMP}/out/stdout")" = "0" ]
  [ "$(jq -r '.counts.updated' "${TMP}/out/stdout")" = "0" ]

  # Only the SECOND run's calls matter here — the harness captures both runs'
  # calls in one cumulative log. Zero write verbs anywhere in the log AFTER
  # the first run's last identity stamp (its final write) isolates exactly
  # the second run's contribution.
  local last_stamp_line; last_stamp_line="$(grep -n '^PUT .*properties/spec-kit-jira$' "${TMP}/out/calls.log" | tail -1 | cut -d: -f1)"
  local after; after="$(tail -n "+$((last_stamp_line + 1))" "${TMP}/out/calls.log")"
  [ -z "$(grep -E '^(POST|PUT|DELETE) ' <<< "${after}")" ]
}

@test "T062: spec.md is byte-identical after the second (unchanged) run" {
  bash "${HARNESS}" "${FIRST_RUN}" bash "${TMP}/first" > /dev/null
  bash "${HARNESS}" "${SECOND_RUN}" bash "${TMP}/second" > /dev/null
  run diff "${TMP}/first/workdir/specs/001-billing-invoices/spec.md" "${TMP}/second/workdir/specs/001-billing-invoices/spec.md"
  [ "$status" -eq 0 ]
}

# --- T063: the interrupted-parent window refuses, no orphan stories --------

@test "T063: a spec= marker left in creating refuses the whole specification (zero writes, no story either)" {
  bash "${HARNESS}" "${INTERRUPTED}" bash "${TMP}/out" > /dev/null
  [ "$(cat "${TMP}/out/exit")" = "4" ]
  [[ "$(cat "${TMP}/out/stderr")" == *"creating"* ]]
  [ -z "$(cat "${TMP}/out/calls.log")" ]
}

# --- Cross-port parity -------------------------------------------------------

@test "both ports agree byte-for-byte on the first run, the second run, and the interrupted refusal (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local scenario
  for scenario in "${FIRST_RUN}" "${SECOND_RUN}" "${INTERRUPTED}"; do
    local name; name="$(basename "${scenario}" .json)"
    bash "${HARNESS}" "${scenario}" bash "${TMP}/${name}-b" > /dev/null
    bash "${HARNESS}" "${scenario}" powershell "${TMP}/${name}-p" > /dev/null
    run diff "${TMP}/${name}-b/stdout" "${TMP}/${name}-p/stdout"
    [ "$status" -eq 0 ]
    run diff "${TMP}/${name}-b/exit" "${TMP}/${name}-p/exit"
    [ "$status" -eq 0 ]
    run diff "${TMP}/${name}-b/calls.log" "${TMP}/${name}-p/calls.log"
    [ "$status" -eq 0 ]
    run diff -r "${TMP}/${name}-b/workdir" "${TMP}/${name}-p/workdir"
    [ "$status" -eq 0 ]
  done
}
