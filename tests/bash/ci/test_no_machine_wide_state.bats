#!/usr/bin/env bats
# T009a/T009b [018, Phase 2] — FR-008 / Constitution XIII's test-isolation
# rule, and the check that must precede every concurrency raise this feature
# makes (T021, T027, T031). No file under tests/ may identify a process,
# port, or directory by a machine-wide scan: a wider fan-out turns a
# name-pattern match or a fixed path into a cross-scenario collision that a
# narrow one never exercised. Every such identifier must instead come from
# something the caller itself recorded: a PID from "dollar-bang", an
# OS-assigned ephemeral port, a path from the temp-file maker.
#
# Two occurrences exist today and cannot be "fixed" because they are not
# code: they are comments in the harness and its test explaining why a
# process-name scan would be wrong, using the anti-pattern's own name to say
# so. T009b allowlists them here, by file and line, with the identifier the
# surrounding code actually uses instead (MOCK_PID, recorded from the last
# background PID — see tests/conformance/mock-jira/lib.sh:123). Recorded in
# baseline.md so a future reader does not have to rediscover why the
# allowlist exists.
#
# This guard file is deliberately excluded from its own scans (via --exclude
# below): its comments and case-statement literals name the very patterns it
# looks for, and a self-match would not be a real defect.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  TESTS_DIR="${ROOT}/tests"
  SELF="test_no_machine_wide_state.bats"
}

# file:line pairs explicitly reviewed and confirmed to be prose, not a scan a
# runtime path executes.
_is_allowlisted() {
  local hit="$1"
  case "${hit}" in
    "${TESTS_DIR}/bash/conformance/test_run_scenario.bats:109") return 0 ;;
    "${TESTS_DIR}/conformance/run-scenario.sh:115") return 0 ;;
    *) return 1 ;;
  esac
}

# Process-name and port scans: unambiguous anti-patterns wherever they occur
# (code or comment), so this check reads every test source EXCEPT itself, and
# still excludes comment-only lines — a line whose first non-blank character
# is "#" documents the pattern rather than executing it.
_scan() {
  local pattern="$1"
  grep -rnE "${pattern}" "${TESTS_DIR}" \
    --include='*.sh' --include='*.bats' --include='*.ps1' \
    --exclude="${SELF}" 2> /dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true
}

@test "no file under tests/ scans for a process by name (pgrep -f / pidof)" {
  offenders=""
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    loc="${hit%%:*}"
    _is_allowlisted "${loc}" || offenders="${offenders}${hit}"$'\n'
  done < <(_scan 'pgrep -f|pidof ')
  [ -z "${offenders}" ] || { printf 'machine-wide process scan found:\n%s' "${offenders}"; false; }
}

@test "no file under tests/ scans for a port machine-wide (lsof -i)" {
  offenders=""
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    loc="${hit%%:*}"
    _is_allowlisted "${loc}" || offenders="${offenders}${hit}"$'\n'
  done < <(_scan 'lsof -i')
  [ -z "${offenders}" ] || { printf 'machine-wide port scan found:\n%s' "${offenders}"; false; }
}

@test "the mock backend records its PID from a captured background PID, not a name scan" {
  run grep -n 'MOCK_PID=' "${TESTS_DIR}/conformance/mock-jira/lib.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'MOCK_PID=$!'* ]]
}

@test "no harness or mock script hard-codes a shared /tmp path" {
  # Scoped to the actual runtime code (harness .sh, non-Pester mock .ps1),
  # never *.bats/*.Tests.ps1: a test FILE'S OWN fixture data can legitimately
  # contain an arbitrary string that happens to look like a path (e.g. a
  # Jira field value such as spec_ref.folder) without that string being an
  # identifier this harness creates or scans for.
  offenders=""
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    loc="${hit%%:*}"
    _is_allowlisted "${loc}" || offenders="${offenders}${hit}"$'\n'
  done < <(grep -rnE '(^|[^a-zA-Z0-9_/])/tmp/[a-zA-Z0-9_.-]+' \
      "${TESTS_DIR}/conformance" "${TESTS_DIR}/coverage" "${TESTS_DIR}/run-bash.sh" \
      --include='*.sh' 2> /dev/null \
    | grep -v 'mktemp' \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)
  [ -z "${offenders}" ] || { printf 'hard-coded shared /tmp path found:\n%s' "${offenders}"; false; }
}
