#!/usr/bin/env bats
# T024 [Phase 4, US2] — contracts/run-state.md §5: two racing writers each
# read the whole document or none, never half of one; a lost update costs at
# most one extra full reconcile (fail-open direction), never a wrongful skip.
#
# Tested directly at the document layer (`run_state_record`/`run_state_path`/
# `run_state_compose`), not through the CLI: the primitive already exists and
# already implements the sibling-temp-file-then-rename dance (Phase 3, T018),
# so this is a genuine, already-meaningful lock-in test today — not a
# forward-looking guard — even though reconcile.sh does not call it yet.
# "Never wrongly skip" follows from "never observe a partial document": a
# reader that only ever sees a complete document, or none, can only ever
# fail open to a full reconcile on any read trouble (run_state_matches's own
# contract), never mistake a torn read for a match.
#
# Each writer MUST be its own top-level `bash -c` process, not a `( ... ) &`
# subshell of this test's own process: bash's `$$` is fixed at the invoking
# shell's PID and does not change across subshells or background jobs forked
# from the SAME process, only across genuinely separate process launches
# (`$BASHPID` would differ, `$$` would not). `run_state_record`'s temp file is
# named `<path>.tmp.$$`, so two `( ... ) &` subshells of one bats test would
# collide on the identical temp filename — a false-positive "torn write" this
# harness would never see from two real reconcile invocations, which are
# always separate top-level processes with genuinely distinct PIDs.
#
# Constitution XIII test isolation: every spawned writer is identified only
# by the PID this test itself captured via $! and waited on — no pgrep, no
# process-name scan. All file state lives under a single mktemp -d WORK the
# teardown removes; nothing machine-wide is touched or observed.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/run_state.sh"

  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  mkdir -p "${WORK}/specs/021-example"
  SPEC="${WORK}/specs/021-example/spec.md"
  printf '# Feature Specification: Example\n' > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "T024 — two concurrent writers to the same state path never leave a torn document" {
  local path
  path="$(run_state_path "${SPEC}")"

  bash -c "
    source '${LIB_DIR}/run_state.sh'
    for _ in \$(seq 1 30); do
      run_state_record '${SPEC}' 'https://acme.atlassian.net' 'user@example.com' 'abort' ''
    done
  " &
  local pid_a=$!

  bash -c "
    source '${LIB_DIR}/run_state.sh'
    for _ in \$(seq 1 30); do
      run_state_record '${SPEC}' 'https://acme.atlassian.net' 'user@example.com' 'proceed' ''
    done
  " &
  local pid_b=$!

  wait "${pid_a}" "${pid_b}"

  [ -f "${path}" ]
  jq -e . "${path}" > /dev/null

  local doc_a doc_b content
  doc_a="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "abort" "")"
  doc_b="$(run_state_compose "${SPEC}" "https://acme.atlassian.net" "user@example.com" "proceed" "")"
  content="$(cat "${path}")"
  [[ "${content}" == "${doc_a}" || "${content}" == "${doc_b}" ]]
}

@test "T024 — a reader never observes a torn document while a writer hammers the same path" {
  local path
  path="$(run_state_path "${SPEC}")"

  bash -c "
    source '${LIB_DIR}/run_state.sh'
    for _ in \$(seq 1 50); do
      run_state_record '${SPEC}' 'https://acme.atlassian.net' 'user@example.com' 'abort' ''
    done
  " &
  local pid=$!

  local i=0
  while kill -0 "${pid}" 2> /dev/null; do
    if [[ -f "${path}" ]]; then
      jq -e . "${path}" > /dev/null
    fi
    i=$((i + 1))
    [ "${i}" -lt 5000 ] || break
  done

  wait "${pid}"

  [ -f "${path}" ]
  jq -e . "${path}" > /dev/null
}
