#!/usr/bin/env bats
# Windows portability quirk 7 — no jq argument value may be spelled with a
# leading `/` (docs/10-windows-portability.md).
#
# On Windows the `jq` the bash port calls is jq.exe, a NATIVE binary, and the
# MSYS runtime rewrites every argument that looks like a POSIX absolute path on
# its way into a native child. A `--arg rw "/speckit.jira.reconcile …"` reaches
# the filter as `C:/Program Files/Git/speckit.jira.reconcile …` — the MSYS root
# spliced in front — so the value the port serialises is not the value it wrote.
# The PowerShell twin builds the same string in-language, where no argument
# vector exists to rewrite, which makes every such site a byte divergence
# (NFR-1) that only windows-latest can see.
#
# Following the test_no_style_branch.bats convention: the rule is enforced on
# the source, because the host that breaks it is not the host that runs this
# suite. Only LITERAL values are decidable here; a `--arg x "${var}"` whose
# runtime value begins with `/` carries the same hazard and is guarded by the
# conformance corpus on the Windows probe.
#
# The remedy at a flagged site is never to escape the slash: prepend it INSIDE
# the filter — `--arg rw "speckit…"` with `resume_with: ("/" + $rw)` — where
# nothing between bash and jq can touch it.

bats_require_minimum_version 1.5.0

@test "no jq --arg/--argjson value in the bash port starts with a slash (Windows quirk 7)" {
  local root bad
  root="${BATS_TEST_DIRNAME}/../../.."
  # `--arg <name> "/…"` and `--arg <name> '/…'`, plus their --argjson/--rawfile
  # spellings. -E throughout: BSD grep mishandles `\|` alternation silently.
  bad="$(grep -rnE -- "--(arg|argjson|rawfile|slurpfile) +[A-Za-z_][A-Za-z0-9_]* +[\"']/" \
    "${root}/scripts/bash" || true)"
  [ -z "${bad}" ] || {
    printf 'jq argument value spelled with a leading slash (MSYS rewrites it):\n%s\n' "${bad}" >&2
    return 1
  }
}
