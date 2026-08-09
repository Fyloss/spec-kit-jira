#!/usr/bin/env bash
# tests/bash/helpers/secret_store_stub.bash — a counting stand-in for the OS
# secret store.
#
# Feature 021's SC-004 says the store is consulted AT MOST ONCE per reconcile,
# whatever the number of requests and retries. That is a counting claim, and it
# is asserted by a counter this helper records — never by a wall clock, and
# never by a machine-wide scan (Constitution XIII: a test identifies the state
# it observes by an identifier it recorded itself).
#
# Why a PATH shim and not the `_CRED_SECRET_TOKEN` seam. The seam is a VALUE,
# and `_cred_from_secret_manager` reads it and returns BEFORE reaching
# `command -v security`:
#
#     if [[ -n "${_CRED_SECRET_TOKEN:-}" ]]; then printf '%s' …; return 0; fi
#     if command -v security …; then security find-generic-password …
#
# A test driven by that seam therefore never executes the code whose cost SC-004
# is about, and would report "one consultation" on a bridge that shelled out
# forty times. The shim replaces the tool instead, so the real branch runs and
# every invocation is recorded.
#
# Both `security` and `secret-tool` are installed, and `_cred_from_secret_manager`
# prefers `security`. That is deliberate: it makes the exercised branch the same
# one on macOS, on Linux, and on the CI runners, so a count is comparable across
# hosts instead of depending on which tool the host happens to ship.

# helper_secret_store_install <bindir> <counter-file> [token] [exit-code]
#
#   bindir       — a directory the caller puts FIRST on PATH. Use a run-scoped
#                  one (`${BATS_TEST_TMPDIR}/bin`); never a shared path.
#   counter-file — one line appended per invocation. The caller creates and owns
#                  it, which is what makes the count the test's own recording.
#   token        — what the store returns. Empty (the default) stands for "no
#                  entry of that name", which the bridge must treat as a silent
#                  fall-through to the gitignored `.env`.
#   exit-code    — the tool's exit status, default 0. A non-zero code stands for
#                  a store that is present but failing (an unregistered or locked
#                  vault); the bridge must still fall through silently, and the
#                  attempt must still COUNT, because it cost a process spawn.
helper_secret_store_install() {
  local bindir="$1" counter="$2" token="${3-}" rc="${4:-0}" tool
  mkdir -p "${bindir}"
  : > "${counter}"
  for tool in security secret-tool; do
    cat > "${bindir}/${tool}" << STUB
#!/usr/bin/env bash
# Counting stand-in for ${tool}, written by helper_secret_store_install.
printf '%s\n' "${tool}" >> "${counter}"
[ -n "${token}" ] && printf '%s' "${token}"
exit ${rc}
STUB
    chmod +x "${bindir}/${tool}"
  done
}

# helper_secret_store_count <counter-file> — how many times the store was asked.
#
# A missing file is 0: a run that never reached the store (the token came from
# the environment, or the run short-circuited before any request) must read as
# zero rather than as an error, because that is the outcome US3 asserts for
# three of its cases.
helper_secret_store_count() {
  local counter="$1" n=0 _line
  [[ -f "${counter}" ]] || { printf '0'; return 0; }
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _line="${_line%$'\r'}"
    [[ -n "${_line}" ]] && n=$((n + 1))
  done < "${counter}"
  printf '%s' "${n}"
}
