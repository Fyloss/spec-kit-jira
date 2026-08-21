#!/usr/bin/env bats
# #46 — Every path handed to jq must be spelled for the jq that will OPEN it.
#
# The jq on PATH under git-bash is a NATIVE Windows binary, and it resolves none
# of MSYS's virtual paths. Two spellings reach it and neither works:
#
#   /dev/fd/N    from a `<(…)` process substitution
#   /tmp/tmp.X   from mktemp
#
# Measured 2026-08-20 on the Windows probe (run 32410922051): 115 of 231
# conformance scenarios died this way, producing an empty stdout and an exit
# code the corpus then reported as a byte divergence. Neither guard below can
# fail on a POSIX host for the right reason — the defect is Windows-only — so
# these are SOURCE guards, following the test_no_style_branch.bats convention.
# The corpus on the probe is the behavioural test.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PORT_FILES=(
    "${ROOT}"/scripts/bash/lib/*.sh
    "${ROOT}"/scripts/bash/engine/*.sh
    "${ROOT}"/scripts/bash/commands/*.sh
    "${ROOT}"/scripts/bash/sink/jira/*.sh
  )
}

# A `<(…)` whose text begins AFTER the `jq` is an argument to jq — a path jq
# must open. One that begins BEFORE it is the safe, common shape
# (`done < <(jq …)`), where bash reads and jq only writes.
#
# Continuation lines are JOINED first. Every site this guard exists to catch
# spans two lines — `jq -cn \` then `--slurpfile p_f <(…)` — so the obvious
# line-at-a-time rule matches none of them. Verified against the pre-fix files
# from git: the joined form reports all four, the line-at-a-time form reported
# zero and would have shipped as a guard that guards nothing.
@test "no jq invocation is handed a process substitution to open (#46)" {
  local bad=""
  bad="$(awk '
    function flush(  line, j, p) {
      line = buf
      sub(/#.*/, "", line)
      j = index(line, "jq ")
      p = index(line, "<(")
      if (j > 0 && p > j) printf "%s:%d: %s\n", FILENAME, start, buf
      buf = ""
    }
    { if (buf == "") start = FNR }
    /\\$/ { sub(/\\$/, " "); buf = buf $0; next }
    { buf = buf $0; flush() }
    END { if (buf != "") flush() }
  ' "${PORT_FILES[@]}")"
  [ -z "${bad}" ] || {
    printf 'a process substitution is passed to jq as a path to open:\n%s\n' "${bad}" >&2
    printf 'Use a real file: `f="$(mktemp)"` then `"$(json_path_arg "${f}")"`.\n' >&2
    return 1
  }
}

# The translation has exactly two homes — lib/output.sh's json_path_arg for jq
# and sink/jira/client.sh's _jira_curl_path for curl. It used to be inlined at
# four sites, and the fifth site that needed it simply never got a copy; that
# is the failure mode this guard removes.
@test "cygpath is called only from the two sanctioned path helpers (#46)" {
  local bad=""
  bad="$(awk '
    FILENAME ~ /lib\/output\.sh$/ { next }
    FILENAME ~ /sink\/jira\/client\.sh$/ { next }
    { line = $0; sub(/#.*/, "", line) }
    line ~ /cygpath/ { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
  ' "${PORT_FILES[@]}")"
  [ -z "${bad}" ] || {
    printf 'cygpath called outside json_path_arg / _jira_curl_path:\n%s\n' "${bad}" >&2
    return 1
  }
}

@test "json_path_arg exists and is the helper the guards name" {
  grep -q '^json_path_arg()' "${ROOT}/scripts/bash/lib/output.sh"
}

# Behaviour, on this host: with no native path style declared, the path is
# returned byte-for-byte. This is what makes the change inert on macOS and
# Linux — the whole corpus is green there before and after.
@test "json_path_arg returns a POSIX path unchanged when the style is not native" {
  run bash -c '
    JIRA_PATH_STYLE=posix
    source "'"${ROOT}"'/scripts/bash/lib/output.sh"
    json_path_arg /tmp/tmp.ABC123
  '
  [ "${status}" -eq 0 ]
  [ "${output}" = "/tmp/tmp.ABC123" ]
}
