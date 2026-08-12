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
# byte length of every element of $@, appends any element exceeding 131072
# bytes (Linux's MAX_ARG_STRLEN, 32 pages) to the report file, then `exec`s
# the real tool — stdout, stderr and exit code pass through untouched. Same
# PATH-interposition, tool set and exec-pass-through shape as
# tests/bash/helpers/spawn_count.bash (research R3, contract A3.4/A5.1:
# reuse, not a second mechanism). Widened from jq-only to the full tool set
# per T035: verified no live call site needs it today (no `awk -v`, no
# `curl --data`/`-d` on the reconcile path — curl bodies travel through a
# stdin config referencing a temp file already), so this is future-proofing
# against a call site introduced tomorrow, not a fix for one that exists.

# helper_argv_size_setup <shim_dir> <report_file> — populate <shim_dir> with
# an argument-length-measuring shim for jq, sed, awk and curl, and truncate
# <report_file>. Resolves each real tool from the caller's PATH *before*
# prepending <shim_dir> to it, so the shim never recurses into itself.
helper_argv_size_setup() {
  local shim_dir="$1" report_file="$2" tool real
  mkdir -p "${shim_dir}"
  : > "${report_file}"
  for tool in jq sed awk curl; do
    real="$(command -v "${tool}")"
    cat > "${shim_dir}/${tool}" << SHIM_EOF
#!/bin/sh
for a in "\$@"; do
  n=\$(printf '%s' "\$a" | wc -c | tr -d '[:space:]')
  if [ "\${n}" -gt 131072 ]; then
    printf '%s\n' "\${n}" >> "${report_file}"
  fi
done
exec "${real}" "\$@"
SHIM_EOF
    chmod +x "${shim_dir}/${tool}"
  done
}
