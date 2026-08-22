#!/usr/bin/env bats
# #46 category B — a payload that grows with the specification must never
# travel through a command-line argument.
#
# THE MEASUREMENT THAT PRODUCED THIS GUARD
#
# `tests/bash/sink/test_argv_size.bats` already detects oversized arguments
# portably, and it did not catch this, because its threshold was Linux's
# MAX_ARG_STRLEN (131072). Windows' cap is CreateProcess's command line and it
# is four times tighter — measured on a real Windows 11 host, 2026-08-22:
#
#     32700 bytes: OK      33000 bytes: Argument list too long
#
# The parse phase's `stories` array costs ~660 bytes per story (a 10-story spec
# yields 6607 bytes), so it crosses Windows' cap at ~50 stories and Linux's at
# ~200. Every specification between those bounds failed on windows-latest and
# passed everywhere else — precisely the four category-B scenarios of #46:
#
#     us021-prefetch-count-61   us021-prefetch-count-101
#     us021-prefetch-count-61-deleted   us023-sixty-stories-due
#
# Reproduced locally before the fix, and again one stage later after the first
# two sites were fixed — the defect was TWELVE call sites, not the one the
# handoff named. A jq shim recorded the live offending argument at 43475 bytes,
# `{"epic":{"description":{"blocks":[…` — the neutral document.
#
# HOW THIS RELATES TO THE THRESHOLD FIX
#
# The durable guard is `HELPER_ARGV_SIZE_LIMIT`, now the tightest cap across
# supported hosts, which makes the two behavioural tests in
# tests/bash/sink/test_argv_size.bats catch this class corpus-wide. This file
# is the cheap, fast complement: it names the payloads and fails in
# milliseconds with the offending line, where the behavioural test needs a mock
# and a hundred-story specification. Neither replaces the other.
#
# `AGENTS.md` states the rule as one inseparable pair — batch the loop AND keep
# the batched payload out of argv. This guard is the second half.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PORT_FILES=(
    "${ROOT}"/scripts/bash/lib/*.sh
    "${ROOT}"/scripts/bash/engine/*.sh
    "${ROOT}"/scripts/bash/commands/*.sh
    "${ROOT}"/scripts/bash/sink/jira/*.sh
  )
}

# Every variable in the port that carries a whole-document or whole-collection
# payload. Each was measured or read as growing with the size of the
# specification, tasks.md, or the seeded set. Extending this list is how a new
# aggregate gets the same protection; the behavioural threshold test is what
# catches one nobody thought to add here.
_AGGREGATES='doc|doc_for_write|parse|pre_parse|stories|recog|tasks_recog|tasks_parsed|tasks_parsed_raw|switch_back_parsed|tickets|actions|plan|tasks|provenance|delta'

@test "no jq invocation is handed a whole-spec aggregate through argv (#46 B)" {
  local bad=""
  # Continuation lines are JOINED first. The sites this exists to catch span
  # two and three lines — `jq -cn --argjson recog "…" \` then the filter — so a
  # line-at-a-time rule matches a fraction of them. That mistake is what made
  # two of #47's three guards inert on their first version.
  bad="$(awk -v agg="${_AGGREGATES}" '
    { if (buf == "") start = FNR }
    /\\$/ { sub(/\\$/, " "); buf = buf $0; next }
    { buf = buf $0; check(); buf = "" }
    END { if (buf != "") check() }
    function check(  line, pat) {
      line = buf
      sub(/#.*/, "", line)
      if (line !~ /jq /) return
      pat = "--argjson[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+\"\\$\\{(" agg ")\\}\""
      if (line ~ pat) printf "%s:%d: %s\n", FILENAME, start, substr(buf, 1, 120)
    }
  ' "${PORT_FILES[@]}")"
  [ -z "${bad}" ] || {
    printf 'a growing payload is spelled into a command line:\n%s\n' "${bad}" >&2
    printf 'Route it through json_build, or --slurpfile with json_path_arg when\n' >&2
    printf 'the call needs jq flags json_build does not set (e.g. -r).\n' >&2
    return 1
  }
}

# The positive half. Forbidding a spelling passes just as well when the call
# site is deleted outright, so the sanctioned mechanism is pinned as present.
@test "the whole-spec assemblies go through json_build or a slurped file (#46 B)" {
  local f
  for f in "${ROOT}/scripts/bash/engine/parse.sh" \
    "${ROOT}/scripts/bash/engine/interchange.sh" \
    "${ROOT}/scripts/bash/commands/reconcile.sh" \
    "${ROOT}/scripts/bash/commands/seed.sh"; do
    grep -qE 'json_build|--slurpfile' "${f}" || {
      printf '%s binds no value from a file — its payloads are in argv\n' "${f}" >&2
      return 1
    }
  done
}

# json_build is the helper the rule names; pin that it still exists and still
# reads its values from files rather than argv.
@test "json_build binds its values with --slurpfile, not --argjson" {
  local body
  body="$(awk '/^json_build\(\) *\{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' \
    "${ROOT}/scripts/bash/lib/output.sh")"
  [ -n "${body}" ]
  printf '%s\n' "${body}" | grep -q -- '--slurpfile'
  ! printf '%s\n' "${body}" | grep -q -- '--argjson'
}
