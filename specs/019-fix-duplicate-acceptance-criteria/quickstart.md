# Quickstart: Validating the Ownership Decision

**Feature**: 019-fix-duplicate-acceptance-criteria | **Date**: 2026-08-06

Prerequisites: `bats`, `jq`, and (for the cross-port checks) `pwsh` 7+. No Jira credentials and no network
access are needed for anything on this page.

---

## 1. The failing test, first

Per the project's bug-fix policy this reproduction is written and seen to **fail** before any source change.
It is the measurement that produced the spec, reduced to one assertion.

```bash
bash /dev/stdin <<'EOF'
cd "$(git rev-parse --show-toplevel)"
source scripts/bash/lib/output.sh
source scripts/bash/engine/managed_section.sh
source scripts/bash/sink/jira/adf.sh

ac1='[{"given":[[{"text":"the page is open"}]],"when":[[{"text":"the button is clicked"}]],"then":[[{"text":"Hello World is shown"}]]}]'
ac2='[{"given":[[{"text":"the page is open"}]],"when":[[{"text":"the button is clicked"}]],"then":[[{"text":"Hello Universe is shown"}]]}]'
mk() { jq -cn --argjson a "$1" '{description:{blocks:[{type:"paragraph",spans:[{text:"Greeting button"}]}]},acceptance_criteria:$a}'; }

# A description written by a release predating the boundary: no marker.
created="$(jq -c '.doc' <<< "$(adf_render_managed_description "$(mk "${ac1}")")")"
legacy="$(jq -c '{type:"doc",version:1,content:[.content[] | select((.content[0].marks[0].type? // "") != "strong")]}' <<< "${created}")"

# The developer edits spec.md and re-runs reconcile. Origin is "bridge".
after="$(adf_render_managed_description "$(mk "${ac2}")" "${legacy}" bridge)"
n="$(jq '[.doc | .. | objects | select(.type?=="heading") | .content[0].text] | map(select(.=="Acceptance Criteria")) | length' <<< "${after}")"

echo "Acceptance Criteria sections: ${n}  (expected 1)"
echo "status: $(jq -r '.status' <<< "${after}")  (expected ok)"
[ "${n}" -eq 1 ] || { echo "FAIL — the defect is present"; exit 1; }
EOF
```

**Before the change**: `Acceptance Criteria sections: 2`, `status: migrated-warned`, exit 1. (The third
argument is ignored because it does not exist yet — which is the point.)

**After the change**: `1` / `ok`, exit 0.

---

## 2. The decision table, row by row

`tests/bash/engine/test_managed_ownership.bats` covers all six rows of `contracts/ownership-decision.md` §1.
Run it alone during the inner loop:

```bash
bats -r tests/bash/engine/test_managed_ownership.bats
```

The `-r` is load-bearing — without it `bats` silently runs nothing.

---

## 3. The regression guard: everything else must be untouched

Invariant §5.3 of the contract says output is byte-identical to the pre-feature implementation for every
ownership other than `self`. The way to see that is that the existing suites pass **unmodified**:

```bash
tests/run-bash.sh --since main     # change-scoped, ≤60s on a single-module diff
tests/run-bash.sh                  # full suite, ~190s
```

Four artefacts are expected to change, and only these four (`research.md` §R7):

- `tests/conformance/scenarios/us4-migration-ambiguous.json` — rewritten; its fixture is `origin:"bridge"`,
  so its expectation flips from "duplicated + warned" to "replaced + silent"
- `tests/bash/sink/test_boundary_migration.bats` and its Pester twin — each case gains an origin
- `tests/bash/sink/test_adf.bats` and `tests/powershell/sink/Adf.Tests.ps1` — the pre-existing contract §3
  regression case now passes `origin` explicitly (`human`); omitting it changed meaning under the new
  optional parameter (it now defaults to `unknown`, not `other`)
- `tests/bash/ci/test_conformance_no_cross_os_shard.bats` — the hard-coded scenario count, 106 → 107, for
  the new `us4-migration-ambiguous-human.json` below
- `tests/conformance/mock-jira/configs/preserve-pre-release.json` — PRE-2 and PRE-3 flip from
  `origin:"bridge"` to `origin:"human"`, so their pre-existing suffix-split expectations stay green under
  the new decision (§7 names what this trades away)

If any **other** existing test needs editing to pass, that is a signal the change reached further than the
decision, not a licence to edit the test.

---

## 4. Cross-port equivalence

```bash
bash tests/conformance/ci-conformance.sh
```

Success is silent: exit 0 and zero lines containing `conformance divergence`. There is no pass banner, and
the temp paths it prints are harness noise.

New scenarios to expect green:

| Scenario | Asserts |
| --- | --- |
| `us4-migration-clean.json` | unchanged — a clean transition still duplicates nothing |
| `us4-migration-ambiguous.json` (rewritten) | `origin:"bridge"` → replaced, no warning |
| `us4-migration-ambiguous-human.json` (new) | `origin:"human"` → preserved, one warning |
| `sc008-deleted-managed-region-restored.json` | unchanged — Principle X still holds |

---

## 5. Linters

```bash
shellcheck $(git ls-files '*.sh')
actionlint
```

Both must be clean. PSScriptAnalyzer runs in CI against `PSScriptAnalyzerSettings.psd1`.

---

## 6. Windows

The change touches the managed-section splice, which is where this project's Windows divergences have
historically appeared. Two rules apply while writing it:

- Never put `$'\r\n'` inside a glob pattern — the MSYS matcher lets it match a bare LF. Count CRLF pairs
  with `_ms_count_crlf`'s CR-by-CR walk.
- Never call `jq` directly in the bash port; go through `scripts/bash/lib/output.sh`.

A Windows-only divergence is diagnosed by measurement on the real runner (push to `ci/windows-probe`,
~11 min, results arrive as check-run annotations), never by emulation. Note that `main` is **not** green on
`windows-latest`: diff this branch's annotations against `main`'s before attributing a failure to it.

---

## 7. What this does *not* validate

Tickets already carrying a duplicate are **not** repaired — out of scope by the reporter's decision. After
this ships, such a ticket still shows two acceptance-criteria sections until a human trims it or the ticket
is recreated. That is expected, and no test asserts otherwise.
