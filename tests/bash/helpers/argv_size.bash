#!/usr/bin/env bash
# tests/bash/helpers/argv_size.bash — PATH-interposed oversized-argument
# detector.
#
# contracts/argument-size.md §3 (A3.1-A3.4): detects the CAUSE of Linux's
# E2BIG (an oversized single argument), not the symptom (exec failure), so
# the verdict is identical on every host — including macOS, which has no
# per-argument cap and therefore never reproduces the symptom itself.
#
# A shim placed earlier on PATH than jq, sed, awk and curl that measures the
# byte length of every element of $@, appends any element reaching 131072
# bytes (Linux's MAX_ARG_STRLEN, 32 pages) to the report file, then `exec`s
# the real tool — stdout, stderr and exit code pass through untouched. Same
# PATH-interposition, tool set and exec-pass-through shape as
# tests/bash/helpers/spawn_count.bash (research R3, contract A3.4/A5.1:
# reuse, not a second mechanism). Widened from jq-only to the full tool set
# per T035: verified no live call site needs it today (no `awk -v`, no
# `curl --data`/`-d` on the reconcile path — curl bodies travel through a
# stdin config referencing a temp file already), so this is future-proofing
# against a call site introduced tomorrow, not a fix for one that exists.
#
# The measurement itself lives in argv_size_measure.sh, which the shim
# SOURCES: an oversized value cannot be handed to a process on Linux at all,
# so the measurement has to be reachable without an execve carrying it. See
# that file's header, and A2.4 for the boundary the threshold encodes.

# HELPER_ARGV_SIZE_LIMIT — Linux's MAX_ARG_STRLEN, 32 pages. A single
# argument of exactly this many bytes ALREADY fails: `strnlen_user` looks for
# the terminating NUL within the limit and does not find it, so 131072 and
# 131073 both come back as E2BIG. Measured on the Ubuntu CI runner (T039):
# 131071 bytes exec successfully, 131072 and 131073 do not. The threshold is
# therefore "reaches the limit", not "exceeds it".
HELPER_ARGV_SIZE_LIMIT=131072

# helper_argv_size_setup <shim_dir> <report_file> [limit] — populate
# <shim_dir> with an argument-length-measuring shim for jq, sed, awk and
# curl, and truncate <report_file>. Resolves each real tool from the caller's
# PATH *before* prepending <shim_dir> to it, so the shim never recurses into
# itself.
#
# <limit> defaults to HELPER_ARGV_SIZE_LIMIT and is applied on every host
# regardless of that host's own cap (A3.2). It is a parameter only so the
# helper's own self-test can prove the shim fires end-to-end — through PATH,
# with the exec bit set, into the report path it was given — using an
# argument small enough for Linux to actually deliver. Tests that assert
# something about the code under test MUST leave it at the default.
helper_argv_size_setup() {
  local shim_dir="$1" report_file="$2" limit="${3:-${HELPER_ARGV_SIZE_LIMIT}}"
  local tool real src helper_dir measure
  src="${BASH_SOURCE[0]}"
  [[ "${src}" == */* ]] || src="./${src}"
  helper_dir="$(cd -- "${src%/*}" && pwd -P)"
  measure="${helper_dir}/argv_size_measure.sh"
  [[ -r "${measure}" ]] || {
    printf 'argv_size: measurement helper not readable at %s\n' "${measure}" >&2
    return 1
  }
  mkdir -p "${shim_dir}"
  : > "${report_file}"
  for tool in jq sed awk curl; do
    # An unresolvable tool would bake `exec "" "$@"` into the shim: it fires,
    # records nothing, never runs the tool, and every downstream assertion
    # reads the resulting empty report as success. Fail before writing it.
    real="$(command -v "${tool}")" || {
      printf 'argv_size: %s not found on PATH — cannot shim it\n' "${tool}" >&2
      return 1
    }
    cat > "${shim_dir}/${tool}" << SHIM_EOF
#!/bin/sh
ARGV_SIZE_LIMIT=${limit}
ARGV_SIZE_REPORT="${report_file}"
. "${measure}"
exec "${real}" "\$@"
SHIM_EOF
    chmod +x "${shim_dir}/${tool}"
  done
}
