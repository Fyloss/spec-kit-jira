#!/usr/bin/env bats
# #46 category B — a whole-spec aggregate must never travel through argv.
#
# THE MEASUREMENT THAT PRODUCED THIS GUARD
#
# `tests/bash/sink/test_argv_size.bats` already detects oversized arguments
# portably, and it did not catch this. Its threshold is Linux's MAX_ARG_STRLEN
# (131072). Windows' limit is CreateProcess's command line, and it is FOUR
# TIMES TIGHTER — measured on a real Windows 11 host, 2026-08-22:
#
#     32700 bytes: OK      33000 bytes: Argument list too long
#
# The parse phase's `stories` array costs ~660 bytes per story (measured: a
# 10-story spec yields 6607 bytes), so it crosses Windows' cap at ~50 stories
# and Linux's at ~200. Every scenario between those two bounds fails on
# windows-latest and passes everywhere else — which is exactly the four
# category-B scenarios of issue #46:
#
#     us021-prefetch-count-61   us021-prefetch-count-101
#     us021-prefetch-count-61-deleted   us023-sixty-stories-due
#
# Reproduced locally before the fix (us023-sixty-stories-due, bash port):
#
#     output.sh: line 69: jq: Argument list too long
#     reconcile: the specification could not be parsed (zero writes)   [exit 4]
#
# WHY A SOURCE GUARD
#
# The behavioural proof needs a ~50-story spec through `parse_spec`, and the
# parse phase spawns per line: a 10-story spec takes ~52s on Windows, so the
# honest behavioural test costs minutes and would be the slowest thing in the
# unit suite. The rule is lexical anyway — a growing value either reaches argv
# or it does not — so it is pinned here, in the shape the #46 category-A guards
# established (tests/bash/ci/test_jq_path_spelling.bats). The corpus on the
# Windows probe remains the behavioural test.
#
# `AGENTS.md` states the rule this enforces, and states it as one inseparable
# pair: batch the loop AND keep the batched payload out of argv. This guard is
# the second half.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PARSE="${ROOT}/scripts/bash/engine/parse.sh"
  INTERCHANGE="${ROOT}/scripts/bash/engine/interchange.sh"
}

# _fn_body <file> <name> — the lines of shell function <name>, from its
# `name() {` header to the closing brace in column 0. Every function in the
# port is written in that shape, which is what makes this reliable.
_fn_body() {
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) *\\{" { inside = 1 }
    inside { print }
    inside && /^\}/ { exit }
  ' "$1"
}

# The aggregate each function assembles, and the variable that carries it.
# Both grow with the size of the specification, so neither may be spelled
# into a command line. Extending this list is how a new whole-document
# payload gets the same protection.
#
#   parse_spec       ${stories}   every story, with its parsed description
#   interchange_build ${parse}    the whole parse result, stories included

@test "parse_spec does not pass the stories aggregate through argv (#46 B)" {
  local body bad
  body="$(_fn_body "${PARSE}" parse_spec)"
  [ -n "${body}" ] || {
    printf 'parse_spec not found in %s — the guard cannot see its subject\n' "${PARSE}" >&2
    return 1
  }
  # Continuation lines are joined first: the call site spans three lines, so a
  # line-at-a-time rule would match none of it — the mistake #46's category-A
  # guards were rewritten to avoid.
  bad="$(printf '%s\n' "${body}" | awk '
    { if (buf == "") start = FNR }
    /\\$/ { sub(/\\$/, " "); buf = buf $0; next }
    { buf = buf $0; check(); buf = "" }
    END { if (buf != "") check() }
    function check(  line) {
      line = buf
      sub(/#.*/, "", line)
      if (line !~ /--argjson[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+"\$\{stories\}"/) return
      printf "%d: %s\n", start, buf
    }
  ')"
  [ -z "${bad}" ] || {
    printf 'parse_spec spells the whole stories array into a command line:\n%s\n' "${bad}" >&2
    printf 'Route it through json_build, which binds each value from a file.\n' >&2
    return 1
  }
}

@test "interchange_build does not pass the parse aggregate through argv (#46 B)" {
  local body bad
  body="$(_fn_body "${INTERCHANGE}" interchange_build)"
  [ -n "${body}" ] || {
    printf 'interchange_build not found in %s\n' "${INTERCHANGE}" >&2
    return 1
  }
  bad="$(printf '%s\n' "${body}" | awk '
    { if (buf == "") start = FNR }
    /\\$/ { sub(/\\$/, " "); buf = buf $0; next }
    { buf = buf $0; check(); buf = "" }
    END { if (buf != "") check() }
    function check(  line) {
      line = buf
      sub(/#.*/, "", line)
      if (line !~ /--argjson[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+"\$\{parse\}"/) return
      printf "%d: %s\n", start, buf
    }
  ')"
  [ -z "${bad}" ] || {
    printf 'interchange_build spells the whole parse result into a command line:\n%s\n' "${bad}" >&2
    printf 'Route it through json_build, which binds each value from a file.\n' >&2
    return 1
  }
}

# The positive half. A guard that only forbids a spelling passes just as well
# when the call site is deleted, so it is paired with the assertion that the
# sanctioned mechanism is the one actually in use.
@test "both whole-spec assemblies go through json_build (#46 B)" {
  local fn
  for fn in parse_spec interchange_build; do
    local file="${PARSE}"
    [ "${fn}" = interchange_build ] && file="${INTERCHANGE}"
    _fn_body "${file}" "${fn}" | grep -q 'json_build' || {
      printf '%s does not call json_build — its payload is not file-bound\n' "${fn}" >&2
      return 1
    }
  done
}
