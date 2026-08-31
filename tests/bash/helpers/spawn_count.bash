#!/usr/bin/env bash
# tests/bash/helpers/spawn_count.bash — PATH-interposed external-process counter.
#
# contracts/spawn-budget.md §4 (C4.1-C4.4): a shim placed earlier on PATH than
# the real tool, for jq, sed, awk, and curl, that appends one line per
# invocation to a count file then `exec`s the real tool — the invoked tool's
# own stdout, stderr, and exit code pass through untouched.
#
# COUNTING RUNS AND TIMING RUNS MUST BE SEPARATE RUNS (research R4). The shim
# costs a process per call and measured a 61% wall-clock distortion on the
# reference scenario (91 515 ms -> 147 774 ms). Never read a duration from a
# run made under `helper_spawn_count_setup`'s PATH.

# helper_spawn_count_setup <shim_dir> <count_file> [extra-tool...] — populate
# <shim_dir> with a counting shim for jq, sed, awk, and curl — plus any extra
# tools named by the caller — and truncate <count_file>. Resolves each real
# tool from the caller's PATH *before* prepending <shim_dir> to it, so the shim
# never recurses into itself.
#
# The extra-tool arguments were added by 036: the artifact set's whole budget
# is `git` invocations (one `ls-files`, one `hash-object --stdin-paths`), and a
# helper that cannot see `git` reports 0 for a per-item implementation exactly
# as it does for a correct one. The default four are unchanged, so every
# existing caller is unaffected.
helper_spawn_count_setup() {
  local shim_dir="$1" count_file="$2"
  shift 2
  local tool real
  mkdir -p "${shim_dir}"
  : > "${count_file}"
  for tool in jq sed awk curl "$@"; do
    # An unresolvable tool would bake `exec "" "$@"` into the shim: the count
    # file would stay empty, and an empty count file reads as "0 spawns" —
    # a budget assertion passing on an instrument that never worked. Fail
    # before writing it.
    real="$(command -v "${tool}")" || {
      printf 'spawn_count: %s not found on PATH — cannot shim it\n' "${tool}" >&2
      return 1
    }
    cat > "${shim_dir}/${tool}" << SHIM_EOF
#!/bin/sh
printf '%s\n' "${tool}" >> "${count_file}"
exec "${real}" "\$@"
SHIM_EOF
    chmod +x "${shim_dir}/${tool}"
  done
}

# helper_spawn_count_total <count_file> — total invocations across every
# shimmed tool.
helper_spawn_count_total() {
  local file="$1"
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  wc -l < "${file}" | tr -d '[:space:]'
}

# helper_spawn_count_for <count_file> <tool> — invocations of one tool.
helper_spawn_count_for() {
  local file="$1" tool="$2" n
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  n="$(grep -c -x -- "${tool}" "${file}" 2> /dev/null)" || true
  printf '%s' "${n:-0}"
}
