#!/usr/bin/env bats
# T018b/T039 — Guard for tests/bash/helpers/argv_size.bash (contracts/argument-
# size.md §2 A2.1/A2.4, §3 A3.1). Without this, T019's "the report file is
# empty" is satisfied equally by a correct run and by a shim that never fired —
# wrong PATH order, wrong report path, or a non-executable shim would all
# produce an empty file just as silently as a genuinely passing run.
#
# The guard is in two halves, and the split is the whole lesson of T039:
#
#   * the PLUMBING half fires the shim for real, through PATH, and therefore
#     uses a lowered limit — an argument at the real limit cannot be handed to
#     a process on Linux at all (that is what the limit means), so a
#     PATH-fired assertion at 131072 bytes is not a test of our code, it is a
#     test of the kernel, and it can only ever pass on macOS;
#   * the BOUNDARY half measures the real threshold in-process, by sourcing
#     the same argv_size_measure.sh the shim sources, so the oversized value
#     never has to survive an execve.
#
# The original of this file asserted the boundary cases through PATH and was
# green on macOS and red on Ubuntu CI with "Argument list too long" (exit
# 126) — the exact platform blindness the helper exists to remove, reproduced
# in the helper's own guard.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/argv_size.bash"
  SHIM_DIR="${BATS_TEST_TMPDIR}/argv_size_shims"
  REPORT_FILE="${BATS_TEST_TMPDIR}/argv_size.log"
  helper_argv_size_setup "${SHIM_DIR}" "${REPORT_FILE}"
}

# Builtins only, by doubling: no spawn, and no word-splitting of ~131 000
# positional parameters the way `printf 'a%.0s' $(seq 1 n)` needed. Measured
# on this fixture's largest value (131 073 bytes, four builds): doubling
# 0.016 s, the `seq` form it replaces 0.178 s, and `${s// /a}` over a
# space-padded string — the obvious builtin-only alternative — 20.564 s, which
# is why it is not used here.
_arg_of() {
  local n="$1" s='a'
  while ((${#s} < n)); do s+="${s}"; done
  printf '%s' "${s:0:n}"
}

# Measure <n> bytes against the real limit without going through an execve:
# `.` inherits this function's positional parameters, so the value is built
# and measured inside one shell. This is the same file, and the same
# comparison, the shim runs.
# <limit> is optional and defaults to the shipped one. It is a parameter so the
# per-host boundary cases below can each measure against the constant they are
# actually about — Linux's per-argument cap and Windows' command-line cap are
# different numbers and both must stay pinned, while the DEFAULT is the tighter
# of the two.
_measured_in_process() {
  local val
  val="$(_arg_of "$1")"
  local ARGV_SIZE_LIMIT="${2:-${HELPER_ARGV_SIZE_LIMIT}}" ARGV_SIZE_REPORT="${REPORT_FILE}"
  set -- "${val}"
  # shellcheck source=/dev/null
  source "${HELPERS}/argv_size_measure.sh"
}

@test "Linux's per-argument cap is MAX_ARG_STRLEN, 32 pages" {
  [ "${HELPER_ARGV_SIZE_LIMIT_LINUX}" = "131072" ]
}

# Measured on a real Windows 11 host, 2026-08-22 (#46 B): 32700 bytes exec
# fine, 33000 do not. That is CreateProcess's lpCommandLine cap — the WHOLE
# command line, not one argument — and it binds four times tighter than Linux.
@test "Windows' command-line cap is CreateProcess's 32767" {
  [ "${HELPER_ARGV_SIZE_LIMIT_WINDOWS}" = "32767" ]
}

# The one that matters. This constant was Linux's 131072 until #46, and that is
# the whole reason a detector built for the oversized-argument defect sat green
# while four conformance scenarios failed on windows-latest: their payloads
# were ~40-67 KB, over Windows' cap and under Linux's. The default must be the
# tightest cap across supported hosts or the helper's promise of a verdict
# "identical on every host" is false for the host with the smallest budget.
@test "the shipped default is the TIGHTEST cap across supported hosts" {
  [ "${HELPER_ARGV_SIZE_LIMIT}" = "${HELPER_ARGV_SIZE_LIMIT_WINDOWS}" ]
  [ "${HELPER_ARGV_SIZE_LIMIT}" -lt "${HELPER_ARGV_SIZE_LIMIT_LINUX}" ]
}

# The band between the two caps — fatal on Windows, survivable on Linux. This
# is where every category-B scenario of #46 lived, and where the old default
# recorded nothing at all.
@test "an argument between the Windows and Linux caps is recorded by default" {
  _measured_in_process 43475
  [ "$(cat "${REPORT_FILE}")" = "43475" ]
}

@test "an argument of 131073 bytes is recorded against the Linux cap" {
  _measured_in_process 131073 "${HELPER_ARGV_SIZE_LIMIT_LINUX}"
  [ "$(wc -l < "${REPORT_FILE}" | tr -d '[:space:]')" = "1" ]
  [ "$(cat "${REPORT_FILE}")" = "131073" ]
}

# The boundary case, and the reason T039 exists. 131072 bytes is not a
# survivable argument on Linux: MAX_ARG_STRLEN bounds the search for the
# terminating NUL, so a string filling the limit exactly has no room left for
# it and execve returns E2BIG — measured on the Ubuntu CI runner, where both
# 131072 and 131073 came back as "Argument list too long". A threshold that
# waved 131072 through therefore reported "no oversized argument" about a run
# that cannot start.
@test "the boundary value 131072 bytes IS recorded — Linux refuses an argument that fills the limit" {
  _measured_in_process 131072 "${HELPER_ARGV_SIZE_LIMIT_LINUX}"
  [ "$(wc -l < "${REPORT_FILE}" | tr -d '[:space:]')" = "1" ]
  [ "$(cat "${REPORT_FILE}")" = "131072" ]
}

@test "an argument of 131071 bytes is not recorded — it is the largest one Linux will exec" {
  _measured_in_process 131071 "${HELPER_ARGV_SIZE_LIMIT_LINUX}"
  [ ! -s "${REPORT_FILE}" ]
}

# The same boundary rule on the other cap: "reaches the limit" is fatal, one
# byte under it is not.
@test "the boundary value 32767 bytes IS recorded against the Windows cap" {
  _measured_in_process 32767 "${HELPER_ARGV_SIZE_LIMIT_WINDOWS}"
  [ "$(cat "${REPORT_FILE}")" = "32767" ]
}

@test "an argument of 32766 bytes is not recorded against the Windows cap" {
  _measured_in_process 32766 "${HELPER_ARGV_SIZE_LIMIT_WINDOWS}"
  [ ! -s "${REPORT_FILE}" ]
}

# Proof-of-life for the interposition itself: PATH order, the exec bit, and
# the report path, exercised by a real invocation of the real tool. The limit
# is lowered so the argument that crosses it is one every host can deliver.
@test "the shim fires through PATH and records what it measured" {
  local dir="${BATS_TEST_TMPDIR}/lowered" report="${BATS_TEST_TMPDIR}/lowered.log"
  helper_argv_size_setup "${dir}" "${report}" 1024
  local val; val="$(_arg_of 2048)"
  PATH="${dir}:${PATH}" jq -n --arg v "${val}" '$v | length' > /dev/null
  [ "$(wc -l < "${report}" | tr -d '[:space:]')" = "1" ]
  [ "$(cat "${report}")" = "2048" ]
}

@test "the shim fires through PATH and stays silent below the limit" {
  local dir="${BATS_TEST_TMPDIR}/lowered2" report="${BATS_TEST_TMPDIR}/lowered2.log"
  helper_argv_size_setup "${dir}" "${report}" 1024
  local val; val="$(_arg_of 1023)"
  PATH="${dir}:${PATH}" jq -n --arg v "${val}" '$v | length' > /dev/null
  [ ! -s "${report}" ]
}

# T035 widened the tool set from jq alone; nothing asserted the other three
# shims fire. Each tool is handed an argument it rejects, and rejects without
# performing any I/O — curl's is a `file:///` URL specifically so the suite
# resolves no name and opens no socket. The measurement happens before the
# `exec`, so the record stands whatever the tool then makes of its arguments.
@test "every shimmed tool measures its arguments, not just jq" {
  local dir="${BATS_TEST_TMPDIR}/tools" report="${BATS_TEST_TMPDIR}/tools.log"
  helper_argv_size_setup "${dir}" "${report}" 1024
  local val; val="$(_arg_of 2048)"
  PATH="${dir}:${PATH}" jq -n --arg v "${val}" 1 > /dev/null 2>&1 || true
  PATH="${dir}:${PATH}" sed "${val}" /dev/null > /dev/null 2>&1 || true
  PATH="${dir}:${PATH}" awk "${val}" /dev/null > /dev/null 2>&1 || true
  PATH="${dir}:${PATH}" curl --connect-timeout 1 "file:///${val}" > /dev/null 2>&1 || true
  [ "$(wc -l < "${report}" | tr -d '[:space:]')" = "4" ]
  run awk -v lim=1024 '$1 < lim { bad = 1 } END { exit (bad ? 1 : 0) }' "${report}"
  [ "${status}" -eq 0 ]
}

@test "the shim delegates stdout transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n '1 + 1'
  [ "${status}" -eq 0 ]
  [ "${output}" = "2" ]
}

@test "the shim delegates a non-zero exit code transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n 'error("boom")'
  [ "${status}" -ne 0 ]
}

@test "the shim delegates stderr transparently" {
  run env PATH="${SHIM_DIR}:${PATH}" jq -n 'error("boom-marker")'
  [[ "${output}" == *"boom-marker"* ]]
}

# The other half of "loud, not silently empty": if a tool cannot be resolved,
# the generated shim would carry `exec "" "$@"` — it would fire, record
# nothing useful, and never run the tool, while every assertion downstream
# reads an empty report as success. PATH is curated down to the externals the
# helper itself needs (`bash`, `mkdir`, `cat`, `chmod`) plus three of the four
# shimmed tools, so `jq` is the only thing missing.
@test "the helper refuses to build a shim for a tool it cannot resolve" {
  local fake="${BATS_TEST_TMPDIR}/fakepath" t
  mkdir -p "${fake}"
  for t in bash mkdir cat chmod sed awk curl; do
    ln -s "$(command -v "${t}")" "${fake}/${t}"
  done
  run env -i PATH="${fake}" bash -c '
    source "'"${HELPERS}"'/argv_size.bash"
    helper_argv_size_setup "'"${BATS_TEST_TMPDIR}"'/absent_shims" "'"${BATS_TEST_TMPDIR}"'/absent.log"
  '
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"jq"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/absent_shims/sed" ]
}

# A misconfigured shim must be loud, not silently empty: an unset report path
# is the failure mode this whole file guards against.
@test "the measurement refuses to run without a report path" {
  run bash -c 'ARGV_SIZE_LIMIT=1024 source "'"${HELPERS}"'/argv_size_measure.sh"'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ARGV_SIZE_REPORT"* ]]
}

@test "an unfired shim leaves the report file empty" {
  [ ! -s "${REPORT_FILE}" ]
}
