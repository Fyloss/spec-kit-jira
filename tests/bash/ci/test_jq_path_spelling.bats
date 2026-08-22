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

# The second spelling, and the one the first fix missed: a mktemp path handed
# to jq as a POSITIONAL argument. `jq -Rs '…' "${f}"` makes jq open ${f};
# `jq '…' < "${f}"` and `… >> "${f}"` do not — there bash owns the file and jq
# only sees a stream. The distinction is the whole rule, so it is encoded here
# rather than left to a reviewer's eye.
@test "no mktemp path reaches jq as a positional argument untranslated (#46)" {
  local bad=""
  bad="$(awk '
    FNR == 1 { delete v; nv = 0 }
    match($0, /[A-Za-z_][A-Za-z0-9_]*="?\$\(mktemp/) {
      s = substr($0, RSTART)
      sub(/="?\$\(mktemp.*/, "", s)
      v[++nv] = s
    }
    { if (buf == "") start = FNR }
    /\\$/ { sub(/\\$/, " "); buf = buf $0; next }
    { buf = buf $0; check(); buf = "" }
    END { if (buf != "") check() }
    function check(  line, i, n) {
      line = buf
      sub(/#.*/, "", line)
      if (line !~ /jq /) return
      if (line ~ /json_path_arg/) return
      for (i = 1; i <= nv; i++) {
        n = "\\$\\{?" v[i] "\\}?"
        # A reference preceded by < or > is a shell redirection: bash opens it.
        if (line ~ n && line !~ ("[<>] *\"?" n)) {
          printf "%s:%d: [%s] %s\n", FILENAME, start, v[i], buf
          return
        }
      }
    }
  ' "${PORT_FILES[@]}")"
  [ -z "${bad}" ] || {
    printf 'a mktemp path is handed to jq to open, untranslated:\n%s\n' "${bad}" >&2
    printf 'Wrap it: "$(json_path_arg "${f}")".\n' >&2
    return 1
  }
}

# The third shape, and the one that defeated both guards above: a jq filter
# written as a MULTI-LINE single-quoted string, whose path operand sits on the
# closing line — ten lines below the `jq` token, with no backslash to join them.
#
#     material_content="$(jq -c '
#       …ten lines of filter…
#     ' "${combined_file}" | json_canonical)"        <- feature.sh:583
#
# Joining by quote parity was tried and abandoned: an apostrophe in any comment
# ("the caller's own bytes") desyncs the parity for the rest of the file, and
# the buffer was measurably still open from thirty lines earlier. A runtime
# guard was tried too — a recording `cygpath` plus a `jq` shim — and could not
# separate the port's own calls from the mock's inside one scenario.
#
# So the rule keys on the shape itself: a line that is a closing filter quote
# followed immediately by a path operand. Distinctive enough to carry no false
# positive across the port today, and it reports feature.sh:583 on the commit
# before the fix.
@test "a multi-line jq filter's path operand is translated (#46)" {
  local bad=""
  bad="$(awk "/^[ \t]*'[ \t]+\"\\\$\\{[A-Za-z_]/ && !/json_path_arg/ {
    printf \"%s:%d: %s\n\", FILENAME, FNR, \$0
  }" "${PORT_FILES[@]}")"
  [ -z "${bad}" ] || {
    printf 'a multi-line jq filter hands its operand over untranslated:\n%s\n' "${bad}" >&2
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
