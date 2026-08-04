#!/usr/bin/env bats
# Windows portability quirk 8 — the PowerShell port never writes stdout through
# a translating writer (docs/10-windows-portability.md).
#
# `[Console]::Out.WriteLine(x)` terminates with Environment.NewLine, which is
# CRLF on Windows and LF everywhere else. Every byte the ports share must be
# identical (NFR-1), and the Bash port terminates with a bare LF on every host,
# so a single WriteLine is a Windows-only divergence in the terminator alone —
# invisible on macOS and Linux, where Environment.NewLine already is LF.
#
# The port's convention is the opposite: build the text with explicit "`n" and
# push it through `[Console]::Out.Write`, which translates nothing. Cli.psm1's
# `Invoke-JiraCliParse` states it ("Callers that need real stdout wrap this in
# [Console]::Out.Write"), and Reconcile.psm1's own summary writer follows it:
#   [Console]::Out.Write($summary + "`n")
#
# Measured (us2-field-defaults-question, CI run 30854733840): with the jq
# argument defect of quirk 7 closed, the ports still differed at byte 414 —
# bash=0a against pwsh=0d, sizes 414 / 415 — a 413-byte document the Bash port
# ended with LF and the PowerShell port with CRLF. Two defects had stacked in
# one scenario; the first masked the second, because the report stops at the
# first differing byte.

bats_require_minimum_version 1.5.0

# Scoped to stdout on purpose. `[Console]::Error.WriteLine` is this port's
# settled idiom for the WARNING/error channel at some thirty sites, and stderr
# is deliberately outside the byte contract — ci-conformance.sh diffs `stdout`,
# `exit`, `calls.log` and the written tree, never stderr. Widening this guard to
# `Error` would demand a thirty-site refactor to buy nothing.

@test "the PowerShell port writes no stdout through Console::Out.WriteLine (Windows quirk 8)" {
  local root bad
  root="${BATS_TEST_DIRNAME}/../../.."
  # -E: BSD grep mishandles `\|` alternation silently.
  bad="$(grep -rnE 'Console\]::Out\.WriteLine' "${root}/scripts/powershell" || true)"
  [ -z "${bad}" ] || {
    printf 'WriteLine terminates with Environment.NewLine (CRLF on Windows); use Out.Write with an explicit `n:\n%s\n' \
      "${bad}" >&2
    return 1
  }
}
