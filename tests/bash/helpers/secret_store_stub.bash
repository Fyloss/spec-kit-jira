#!/usr/bin/env bash
# tests/bash/helpers/secret_store_stub.bash — counting PATH stand-ins (030,
# contracts/credential-resolution.md C7.1).
#
# Repurposed, not deleted, from feature 021's secret-store shim. Two distinct
# stand-ins now live here, because this feature retires the hardcoded probe
# and replaces it with an operator-declared command:
#
#   * helper_pat_command_install — a counting stand-in for the program named
#     by JIRA_PAT_COMMAND. Discharges C2.6 (at most once per run), the exact
#     claim feature 021 built this counting design for — a count is a count,
#     not a wall clock, and never a machine-wide scan (Constitution XIII).
#
#   * helper_secret_store_install — `security` / `secret-tool` stand-ins that
#     must NEVER be invoked (C1.3a): the hardcoded probe is gone, so planting a
#     real token under either tool's service name and confirming resolution
#     still fails, with the counter reading zero, is the proof of C1.3.
#
# Both use the SAME counter format/reader, so a single count helper serves
# either — `helper_pat_command_count` and `helper_secret_store_count` are
# aliases of one implementation, named for what each caller is counting.

# helper_pat_command_install <bindir> <counter-file> [token] [exit-code]
#
#   bindir       — a directory the caller puts FIRST on PATH. Use a run-scoped
#                  one (`${BATS_TEST_TMPDIR}/bin`); never a shared path.
#   counter-file — one line appended per invocation. The caller creates and owns
#                  it, which is what makes the count the test's own recording.
#   token        — what the command prints on stdout. Empty (the default)
#                  stands for C3.7 (exit 0, empty output — still a failure).
#   exit-code    — the command's exit status, default 0. A non-zero code
#                  stands for C3.5, and the attempt still COUNTS, because it
#                  cost a process spawn.
#
# Sets JIRA_PAT_COMMAND to the installed program's path — the caller need not
# repeat it. Prints the program's absolute path too, for a caller that wants
# to declare a DIFFERENT (unresolvable) name to exercise C3.4 instead.
helper_pat_command_install() {
  local bindir="$1" counter="$2" token="${3-}" rc="${4:-0}"
  local prog="${bindir}/spec-kit-jira-pat-helper"
  mkdir -p "${bindir}"
  : > "${counter}"
  cat > "${prog}" << STUB
#!/usr/bin/env bash
# Counting stand-in for a credential-retrieval command, written by
# helper_pat_command_install.
printf 'x\n' >> "${counter}"
[ -n "${token}" ] && printf '%s' "${token}"
exit ${rc}
STUB
  chmod +x "${prog}"
  export JIRA_PAT_COMMAND="${prog}"
  printf '%s' "${prog}"
}

# helper_secret_store_install <bindir> <counter-file> [token] [exit-code]
#
# Installs `security` and `secret-tool` stand-ins on PATH that WOULD return a
# token if invoked. Used only to prove they are NOT invoked (C1.3a) — the
# hardcoded probe this feature deletes used to reach exactly these names.
helper_secret_store_install() {
  local bindir="$1" counter="$2" token="${3-}" rc="${4:-0}" tool
  mkdir -p "${bindir}"
  : > "${counter}"
  for tool in security secret-tool; do
    cat > "${bindir}/${tool}" << STUB
#!/usr/bin/env bash
# Counting stand-in for ${tool}, written by helper_secret_store_install.
# Its count must stay zero — this program must never be invoked (030, C1.3a).
printf '%s\n' "${tool}" >> "${counter}"
[ -n "${token}" ] && printf '%s' "${token}"
exit ${rc}
STUB
    chmod +x "${bindir}/${tool}"
  done
}

# helper_pat_command_count <counter-file> — how many times the retrieval
# command was actually executed.
#
# A missing file is 0: a run that never reached the command (the token came
# from the environment, or the run short-circuited before any request) must
# read as zero rather than as an error.
helper_pat_command_count() {
  local counter="$1" n=0 _line
  [[ -f "${counter}" ]] || { printf '0'; return 0; }
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _line="${_line%$'\r'}"
    [[ -n "${_line}" ]] && n=$((n + 1))
  done < "${counter}"
  printf '%s' "${n}"
}

# helper_secret_store_count <counter-file> — same reader, named for the other
# stand-in's caller (C1.3a: this count must be zero).
helper_secret_store_count() {
  helper_pat_command_count "$1"
}
