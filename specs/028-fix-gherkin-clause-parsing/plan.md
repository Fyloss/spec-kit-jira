# Implementation Plan: A Scenario Written the Template's Way Reaches the Ticket Intact

**Branch**: `fix/duplicate-acceptance-criteria-2` | **Date**: 2026-08-16 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/028-fix-gherkin-clause-parsing/spec.md`

## Summary

The specification template ships every acceptance scenario as one line with emphasised keywords —
`1. **Given** …, **When** …, **Then** …`. The clause recogniser accepts an emphasis wrapper *after* a
keyword but not *before* one, and only on the single-line three-clause path; the one-clause-per-line path
already handles both sides. So the template's own default line fails to split, and each port then fails in
its own way: the bash port's glob fallback silently assigns the **whole line** to the Given, the When and the
Then buckets alike (the reported threefold repetition, each clause stuttered because the renderer prefixes
its plain keyword to a body that still opens with the bold one), while the PowerShell port's fallback regex
matches nothing and the panel comes out **empty**.

The fix is one change of shape, applied identically to both ports: make the wrapper optional on **both**
sides of every keyword in the single-line recogniser, and make the recogniser **fail closed** — a line it
cannot split into three distinct clauses yields no scenario, instead of yielding one whose clauses are all
the same unsplit line. The renderer is not touched: it is already correct, and the stutter disappears the
moment the parser stops handing it a body that begins with the keyword.

User Story 4 adds a bounded pre-pass that joins an indented continuation line into the scenario line above
it, so a wrapped scenario — the form every specification in this repository actually uses, and today worth
an empty panel on both ports — is read whole.

Both regex designs and the join rule were **prototyped and measured on both ports before this plan was
written** (research §R1–§R3); nine inputs, including the two existing regression fixtures, produce identical
output from bash and PowerShell.

## Technical Context

**Language/Version**: Bash 3.2+ (macOS system bash, MSYS bash on Windows) and PowerShell 7+ — two native
ports proven equivalent by a shared conformance corpus.

**Primary Dependencies**: `jq` (bash port: only ever through `scripts/bash/lib/output.sh`), `curl`. **None
added, and none newly invoked** — the whole change is bash ERE / .NET regex matching and string
concatenation.

**Storage**: N/A. Nothing is persisted, read from, or written to any store by this feature. No Jira entity
property, no run state, no config key.

**Testing**: `bats` via `tests/run-bash.sh`; Pester; cross-port byte equivalence via
`tests/conformance/ci-conformance.sh`; `shellcheck -x -P scripts/bash` and PSScriptAnalyzer.

**Target Platform**: macOS, Linux, Windows (windows-latest runner + `ci/windows-probe` for the conformance
corpus).

**Project Type**: CLI tool — neutral engine + Jira sink, two native ports.

**Performance Goals**: No regression. The spawn budget (024, `contracts/spawn-budget.md` C1.2/C1.3) is the
binding constraint, and this feature is free of it by construction: every added operation is a regex match
or a string append inside the existing per-line loop, and `markdown_tokenize_inline` — the only function the
clause bodies reach — is pure bash with no external process. `tests/bash/engine/test_parse_spawn_budget.bats`
holds the count constant as clause and scenario counts double; both assertions must still pass **unmodified**.

**Constraints**: Byte-identical output from both ports (Constitution VI). No `$'\r\n'` inside a glob
pattern; no direct `jq` in the bash port. No new command, flag, configuration key, or output surface
(FR-018).

**Scale/Scope**: Two source files — `scripts/bash/engine/parse.sh` and
`scripts/powershell/engine/Parse.psm1` — one function in each. No sink file, no engine file besides these
two, no caller changes shape.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Initial evaluation (pre-Phase 0)**: PASS — no violation, no justification required.

**Post-design re-evaluation (post-Phase 1)**: PASS. The design strengthened VI, III and XVI and weakened
none. Complexity Tracking stays empty.

| # | Principle | Gate status after design |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | PASS. The ticket is made to say what `spec.md` says. No new exception; no ticket, region, or field is written that is not written today. |
| II | Zero-Churn Idempotency | PASS. Parsing is pure and deterministic; a settled ticket re-renders to the same bytes. FR-017's cross-platform form is what §R1's two-port prototype exists to guarantee. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | PASS, strengthened. The delimiter-free fallback stops guessing: contract §2 rule T3 emits nothing where today's glob fallback emits a scenario made of three copies of one line. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | PASS. Unaffected — no credential is read, written, recorded, or reported. |
| V | Separation of Team Config / Local Binding / Secrets | PASS. Unaffected, and FR-018 forbids a configuration key: how a scenario is read is behaviour, not an option. |
| VI | macOS / Linux / Windows Portability | PASS, repaired. This is the principle the feature restores. §R1/§R3 prototyped both ports on the same nine inputs before design was fixed; §R6 puts the emphasised forms into the conformance corpus, whose absence is why the divergence shipped. No `$'\r\n'` enters a glob pattern; no new `jq` call. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | PASS. Unaffected — no status, transition, screen, or field configuration is read or assumed. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | PASS, strengthened by omission. The whole fix lands in `engine/`; `sink/jira/adf.sh` and `Adf.psm1` are **not touched**. Recognising a scenario is engine work on plain markdown; naming the keyword in the panel stays in the sink, already correct. |
| IX | Two-Tier Privacy Guard, With an Allowlist | PASS. Unaffected — no new text is composed and no scanned surface changes; guard-then-write ordering is untouched. |
| X | Self-Healing Automatic Mirror | PASS. Nothing here stops the mirror healing its own region. Per the reporter's 2026-08-16 clarification, no requirement depends on that healing and no scenario tests it. |
| XI | Universal Dry-Run and Auditability | PASS. `--dry-run` predicts the payloads this feature can produce because the payload is computed by the same parse path; no destructive operation is added. |
| XII | Quality and Catalog Publication | PASS. A defect fix on shipped behaviour, carrying a CHANGELOG entry, gated by the full suite, the conformance corpus, and the linters on all three operating systems. |
| XIII | TDD With a Minimum 80% Coverage | PASS. §R5 names the failing tests, in both ports, that go in **before** the fix — the reporter's own line asserted to produce three disjoint unstuttered clauses. Required by the project's bug-fix policy as well as by this principle. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | PASS. Nothing is invented: the wrapper token, the keyword vocabulary, the clause buckets and the boundary preference all exist. One asymmetry is removed and one fallback is made to fail rather than guess. §R2 records the two more elaborate designs rejected. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | PASS. No markdown parser, no Gherkin dialect, no configurable or localised keywords, no repair/migration path, no new flag. The one piece of scope beyond the report (User Story 4) is named, justified and ranked P2 in the spec. |
| XVI | Human Readable — Readable by a Human Above All | PASS, directly served. The panel reads "Given a user arrives on the Homepage" instead of the same sentence three times with a stuttered keyword. |

## Project Structure

### Documentation (this feature)

```text
specs/028-fix-gherkin-clause-parsing/
├── plan.md                          # This file
├── spec.md                          # Feature specification
├── research.md                      # Phase 0 output — measured decisions R1..R7
├── data-model.md                    # Phase 1 output — the scenario/clause shape
├── quickstart.md                    # Phase 1 output — how to reproduce and verify
├── contracts/
│   └── clause-recognition.md        # Phase 1 output — the normative grammar, both ports
├── checklists/
│   └── requirements.md              # Spec quality checklist
└── tasks.md                         # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/
├── bash/engine/parse.sh             # parse_acceptance_criteria — the whole bash-side fix
└── powershell/engine/Parse.psm1     # Get-JiraParsedAcceptance — the whole pwsh-side fix

tests/
├── bash/engine/
│   ├── test_parse_title_desc.bats   # extend: emphasised triple, wrapped, fail-closed, cross-port
│   └── test_parse_spawn_budget.bats # unchanged — must still pass (FR-021)
├── powershell/engine/
│   └── Parse.TitleDesc.Tests.ps1    # the same cases, Pester
└── conformance/
    ├── fixtures/repo-with-template-form-ac/   # NEW fixture: emphasised + wrapped scenarios
    └── scenarios/us028-template-form-ac.json  # NEW scenario pinning both ports byte-for-byte
```

**Structure Decision**: The existing two-port engine layout, unchanged. The feature touches exactly one
function per port plus tests. `sink/jira/adf.sh` and `Adf.psm1` are deliberately untouched — see
Constitution VIII above and research §R4.

## Complexity Tracking

> Empty — the Constitution Check records no violation, so nothing requires justification.
