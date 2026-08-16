# Quickstart: Reproducing and Verifying 028

**Feature**: 028-fix-gherkin-clause-parsing | **Date**: 2026-08-16

Every command below is runnable from the repository root. The reproduction steps are the failing tests
Constitution XIII and the project's bug-fix policy require **before** the fix.

## Prerequisites

- `bash` 3.2+, `jq`, `bats` — for the bash port and its suite
- `pwsh` 7+ and Pester — for the PowerShell port
- No Jira credentials, no network: everything here runs against the engine directly or the mock tracker

---

## 1. Reproduce the defect (both ports, ~5 seconds)

**bash** — the reporter's own line:

```bash
bash -c '
for f in scripts/bash/lib/output.sh scripts/bash/engine/markdown.sh scripts/bash/engine/parse.sh; do source "$f"; done
printf "%s\n" "1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears." \
  | parse_acceptance_criteria | jq .
'
```

*Before the fix*: one scenario whose `given`, `when` **and** `then` each hold the entire line, each opening
with a bold `Given` span. That is both reported symptoms in one payload — the threefold repetition, and the
`Given **Given** …` stutter the renderer produces from it.

*After the fix*: three disjoint clauses, none beginning with a keyword.

**PowerShell** — the same input:

```bash
pwsh -NoProfile -Command '
Get-ChildItem scripts/powershell/lib/*.psm1,scripts/powershell/engine/*.psm1 | ForEach-Object { Import-Module $_.FullName -ErrorAction SilentlyContinue }
Get-JiraParsedAcceptance -Text "1. **Given** a user arrives on the Homepage, **When** they click Login, **Then** the login form appears."
'
```

*Before the fix*: `[]` — the panel comes out **empty**, a different failure from the bash port's. This is
the Constitution VI divergence the feature repairs; confirm both before starting.

**The wrapped form** (User Story 4) — replace the input above with a scenario split across three lines with
the continuations indented. Both ports return `[]` before the fix.

**T007 record, 2026-08-16**: `tests/bash/engine/test_parse_title_desc.bats` rows 1/5/6/9 and the T3 case
fail pre-fix with the whole-line-in-every-bucket symptom (row 2, the plain delimited form, already passes —
consistent with R1). `tests/powershell/engine/Parse.TitleDesc.Tests.ps1` rows 1/5/6/9 fail pre-fix with
`Count | Should -Be 1` returning 0 or a null-array index error — the empty-panel symptom; row 2 and the T3
case already pass on this port for the same reason R1 records (a regex that fails is silent, and the T3
input never matched to begin with).

---

## 2. Verify the grammar against the normative table

[`contracts/clause-recognition.md`](./contracts/clause-recognition.md) §4 lists nine inputs and their
required clause values. Run all nine through both ports and compare — including rows 7 and 8, which must
emit **nothing**, and row 9, which pins the greedy split that makes the two ports agree.

Rows 3 and 4 are existing unit tests: if they change value, the fix is wrong.

---

## 3. Run the unit suites

```bash
tests/run-bash.sh --since main          # change-scoped, ≤60s on this diff
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/engine -Output Detailed"
```

The Gherkin cases live in `tests/bash/engine/test_parse_title_desc.bats` and
`tests/powershell/engine/Parse.TitleDesc.Tests.ps1`. New cases go beside the existing ones; the existing
four in each port must pass **unmodified**.

Full bash suite when the change is complete: `tests/run-bash.sh` (~190s locally; far longer on CI runners).

---

## 4. Confirm the spawn budget did not move (FR-021)

```bash
bats -r tests/bash/engine/test_parse_spawn_budget.bats
```

Both `parse_acceptance_criteria` assertions must pass **unmodified**: the count stays constant as clause
count doubles and as scenario count doubles. This feature adds no external process — if the count moves, a
command substitution has crept into a per-line position.

---

## 5. Prove the two ports byte-identical

```bash
bash tests/conformance/ci-conformance.sh
```

Success is **silent**: exit 0 and zero lines containing "conformance divergence". Temp-path noise in the
output is the harness, not a failure.

Do **not** run this concurrently with `tests/run-bash.sh` — they share fixtures and a concurrent run
invents a spurious divergence in an unrelated scenario.

The new fixture and scenario this feature adds:

```text
tests/conformance/fixtures/repo-with-template-form-ac/   # emphasised single-line + wrapped scenarios
tests/conformance/scenarios/us028-template-form-ac.json
```

This matters more than it looks: **every** acceptance-criteria line in every existing fixture uses the
one-clause-per-line form, so the corpus currently has no opinion about the spec-kit template's own default
output. That gap is why the divergence shipped (research §R6).

---

## 6. Windows

The bash port's Windows behaviour is proven on the real runner, never by emulation: push to
`ci/windows-probe` (~11 min) and read the results as check-run annotations rather than job logs. Note that
the probe's baseline on `main` is itself red, so compare against that baseline rather than expecting green.

---

## 7. Linters

```bash
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse"
actionlint
```

---

## Done when

- [X] Step 1 reproduces both failures **before** any source edit, and both are gone after
- [X] All nine rows of contract §4 agree across both ports
- [X] Existing Gherkin unit tests and both spawn-budget assertions pass **unmodified**
- [X] `ci-conformance.sh` exits 0 with the new fixture in place
- [X] A second reconcile over the unchanged fixture reports 0 created / 0 updated (FR-017, SC-007)
- [X] The `--dry-run` sibling scenario predicts the corrected panel and writes nothing (FR-019)
- [X] The diff adds no command, flag, config key or output surface, touches no sink file, and leaves the `engine-sink-boundary` gate green (FR-018, FR-020)
- [X] `shellcheck`, PSScriptAnalyzer and `actionlint` clean
- [X] CHANGELOG entry added (Constitution XII)
- [ ] Windows port proven on the real runner (`ci/windows-probe`) — **not run: requires pushing to a remote branch, held for explicit operator go-ahead (T033)**
