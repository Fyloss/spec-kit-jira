#!/bin/sh
# tests/bash/helpers/argv_size_measure.sh — the argument-length measurement
# itself, factored out of the shim `tests/bash/helpers/argv_size.bash` writes
# (contracts/argument-size.md §3 A3.1).
#
# SOURCED, never executed. That is load-bearing rather than stylistic: Linux
# refuses an `execve` whose single argument reaches `MAX_ARG_STRLEN`, so a
# measurement step that had to be *exec'd* with the oversized value could
# never be reached on the one platform whose limit it exists to measure —
# the value would die in the kernel, before any code of ours ran. `.` keeps
# the caller's positional parameters, so the shim and the shim's own
# self-test both measure the real `$@` in-process, on every host.
#
# Reads two variables from the sourcing shell (neither is exported, so the
# tool the shim goes on to `exec` sees an untouched environment):
#   ARGV_SIZE_LIMIT  — bytes; a length reaching it is recorded (see A2.4)
#   ARGV_SIZE_REPORT — file the recorded lengths are appended to, one per line
if [ -z "${ARGV_SIZE_LIMIT:-}" ] || [ -z "${ARGV_SIZE_REPORT:-}" ]; then
  printf 'argv_size: ARGV_SIZE_LIMIT and ARGV_SIZE_REPORT must both be set\n' >&2
  exit 1
fi

# `-ge`, not `-gt`: a single argument whose length reaches the limit is
# already fatal (A2.4). Getting this wrong reported "no oversized argument"
# about a run Linux refuses to start.
for _argv_size_arg in "$@"; do
  _argv_size_n=$(printf '%s' "${_argv_size_arg}" | wc -c | tr -d '[:space:]')
  if [ "${_argv_size_n}" -ge "${ARGV_SIZE_LIMIT}" ]; then
    printf '%s\n' "${_argv_size_n}" >> "${ARGV_SIZE_REPORT}"
  fi
done
