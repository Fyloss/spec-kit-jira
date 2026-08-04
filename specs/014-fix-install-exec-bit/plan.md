# Implementation Plan: A Fresh Install Runs Immediately — No Permission Step, Ever

**Branch**: `worktree-fix+chmod-scripts` | **Date**: 2026-08-03 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/014-fix-install-exec-bit/spec.md`

## Summary

Stop depending on a file mode we do not control. Two edits carry the whole feature: every published
invocation of the Bash entry point gains a `bash ` prefix, and the `-x` clause is deleted from
`prereq_bridge_missing`. Everything else is consequence — four message literals lose the words *"or
is not executable"*, five committed assertions that pinned the old contract are superseded, and the
conformance corpus gains the reproduction nobody had: install, clear the mode, run, expect success.

The change is net subtractive in the ports and makes the two ports *more* alike, because the
PowerShell twin never had an executable-bit check to begin with — it has been silently diverging
from the Bash port on exactly this input, and saying *"or is not executable"* about a condition it
never evaluates (research R4).

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS/Linux port, `#!/usr/bin/env bash`); PowerShell 7+ (Windows port)

**Primary Dependencies**: runtime — `curl`, `jq`, `git`. Development — `bats`, `shellcheck`, Pester,
`PSScriptAnalyzer`, `actionlint`, and the `specify` CLI for the install harness (tests skip without it)

**Storage**: N/A — this feature persists nothing and reads no new file

**Testing**: `tests/run-bash.sh` (~190s full, ≤60s with `--since`), `Invoke-Pester tests/powershell`,
`tests/conformance/ci-conformance.sh` for cross-port byte equivalence

**Target Platform**: macOS, Linux, Windows — the existing three-OS CI matrix. No dedicated
`ci/windows-probe` run: the defect is POSIX-only and the Windows port is structurally immune, so the
matrix's conformance job is the right instrument (research R8)

**Project Type**: CLI extension for spec-kit — twin native ports proven equivalent by a shared corpus

**Performance Goals**: unchanged. The Bash suite must stay at ~3m10s; the new conformance case adds
one harness install, which is why it strips a mode rather than driving a network install (research R7)

**Constraints**: byte-identical output across both ports (Constitution VI); no write to the
consumer's tree and no `chmod` from inside the extension (FR-008); `bash` resolved from `PATH`,
never `/bin/bash` — on macOS that is the 3.2 build the prerequisite gate rejects (contract C1.1)

**Scale/Scope**: 13 shipped files, 9 test files, 1 dev document, plus the manifest version and the
CHANGELOG. No engine module, no sink module, no Jira call is touched.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against all sixteen principles in the spec's Constitution Check table; the gates below are
the ones this plan can actually fail, restated as checks against the design rather than the intent.

| Gate | Principle | Status after Phase 1 | Evidence |
| --- | --- | --- | --- |
| No new filesystem exception | I | **PASS** | The design writes nothing. C6 removes a read (the mode test); it adds none. |
| No churn | II | **PASS with one noted write** | `templates/readme-block.template` changes, so the first reconcile after upgrade rewrites the managed block once — a content change, not churn. The second run writes nothing; quickstart Step 8 checks it (research R9). |
| Hooks stay non-blocking | III | **PASS, improved** | The design deletes the one condition that could block a hook without a genuine failure. FR-004/C6 keep a real absence a named, non-blocking cause. |
| No credential surface change | IV | **PASS** | No credential path is touched. The `chmod 600` on the local env file survives by name (FR-005), and quickstart Step 4 asserts it is the *only* surviving permission instruction. |
| Ports stay byte-equivalent | VI | **PASS, improved** | C3 and C5 give one literal per site for both ports; C6 makes the two predicates exact mirrors. The change *removes* an existing divergence (R4). |
| Engine/sink boundary intact | VIII | **PASS** | Every edit lands in entry, prereq, output and message layers. No engine decision or sink call moves. |
| Dry-run and auditability preserved | XI | **PASS** | No command's dry-run or run summary changes; C7 requires their bytes to be unaffected by the mode. |
| Failing test first | XIII | **PASS** | Quickstart Step 0 is a manual reproduction that must fail on `main`; T-phase 1 lands the automated one before any port edit. |
| Simplest thing that works | XIV | **PASS** | Two shortcuts are ruled out in the spec rather than left to taste: repairing the mode (FR-008, R6) and raising the host floor (FR-010, R1). |
| Nothing beyond the defect | XV | **PASS** | No new command, flag, config key or capability. `docs/VISION.md` gains and loses nothing. |
| Readable | XVI | **PASS** | Net subtractive in the ports; C2 states the filename-versus-invocation rule mechanically so the next reader does not have to infer it from examples. |

**Complexity Tracking**: no violations to justify — the section is omitted deliberately.

## Project Structure

### Documentation (this feature)

```text
specs/014-fix-install-exec-bit/
├── plan.md                          # This file
├── spec.md                          # Feature specification
├── research.md                      # Phase 0 — R1..R9
├── data-model.md                    # Phase 1 — shared constants, cause set, state transitions
├── quickstart.md                    # Phase 1 — Step 0 reproduction through Step 8 dogfood
├── contracts/
│   └── bridge-invocation.md         # Phase 1 — C1..C7, supersedes 003's invocation clauses
├── checklists/
│   └── requirements.md              # Spec quality checklist (all green)
└── tasks.md                         # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

The blast radius of the exec-bit fix itself, exhaustively. Two Windows defects surfaced *during*
this feature's quickstart walk-through and were fixed on the same branch; the files they add are
listed separately under "Follow-up scope" below, so this list stays the exhaustive answer to "what
does the exec-bit fix touch?".

```text
scripts/bash/
├── spec-kit-jira.sh                 # untouched — no $0 use, BASH_SOURCE resolution is invocation-agnostic (R2)
├── lib/prereq.sh                    # DELETE the -x clause (l.56-61); message l.105 drops "or is not executable"
├── lib/output.sh                    # JIRA_BRIDGE_BASH_ENTRY gains the `bash ` prefix at the emission seam (C3)
└── commands/reconcile.sh            # l.436 message drops "or is not executable"

scripts/powershell/
├── lib/Prereq.psm1                  # l.94 message only; Get-JiraMissingBridgeEntry already matches C6 — drop its stale exec-bit doc paragraph
├── lib/Output.psm1                  # $script:JiraBridgeBashEntry gains the prefix (l.147, C3)
└── commands/Reconcile.psm1          # l.536 message drops "or is not executable"

commands/                            # all three: fenced invocations gain `bash `; fallback block loses the clause (C4)
├── speckit.jira.config.md
├── speckit.jira.feature.md
└── speckit.jira.reconcile.md

templates/readme-block.template      # l.64 invocation gains the prefix — lands in every consumer README (R9)
README.md                            # two verification commands (l.~109, l.~206)
INSTALL.md                           # one verification command (l.~154)
extension.yml                        # version bump — the single source of truth
CHANGELOG.md                         # entry + a note for consumers still working around the defect

tests/bash/
├── ci/test_agent_doc_invocation.bats        # delete the -x test; add the C2 prefix rule
├── ci/test_message_command_literals.bats    # delete the -x assertion, keep the -f ones
├── ci/test_agent_fallback_block.bats        # new verbatim block (C4)
├── lib/test_prereq.bats                     # NEW case: present-but-non-executable returns empty (C6.3)
└── conformance/test_us4_bridge_runnable.bats # THE reproduction: install, chmod a-x, run, succeed

tests/powershell/                    # the four mirrors, edited in the same commit
├── ci/AgentDocInvocation.Tests.ps1
├── ci/MessageCommandLiterals.Tests.ps1
├── ci/AgentFallbackBlock.Tests.ps1
├── lib/Prereq.Tests.ps1
└── conformance/Us4.BridgeRunnable.Tests.ps1

docs/03-lifecycle-hooks.md           # sequence-diagram label at l.91 (dev-only, excluded from the install)
specs/003-install-hook-activation/contracts/reconcile-command.md   # one-line supersession pointer (R5)
```

### Follow-up scope — two Windows defects found by this feature's own walk-through

Neither is about the executable bit. Both were uncovered while proving FR-006 (byte parity between
the ports) and are recorded here because they ship on this branch, in this release. They are tracked
as T036 and T037.

```text
scripts/bash/commands/reconcile.sh          # the resume command's leading slash, built inside the jq filter
scripts/powershell/commands/Reconcile.psm1  # the confirmation object terminated with LF, not Environment.NewLine
docs/10-windows-portability.md              # quirks 7 and 8 — the catalog entries for both (dev-only)
tests/bash/ci/test_no_msys_convertible_jq_arg.bats    # NEW — port-wide guard for quirk 7
tests/bash/ci/test_no_translating_stdout_write.bats   # NEW — port-wide guard for quirk 8
tests/bash/commands/test_reconcile_field_defaults.bats         # regression case for quirk 7
tests/powershell/commands/Reconcile.FieldDefaults.Tests.ps1    # its PowerShell mirror
```

**Structure Decision**: no new module, no new directory. The feature lives entirely in the two ports'
message and prerequisite layers plus the documents that quote them, which is why the file list above
is the design — there is no architecture to choose. `tests/`, `specs/` and `docs/` are excluded from
the install by `.extensionignore`, so the shipped surface is `scripts/`, `commands/`, `templates/`,
`README.md`, `INSTALL.md` and `extension.yml`; that is the exact set FR-005 and SC-002 are scanned
over.

## Implementation sequence

Ordering is load-bearing, and the reason is Constitution XIII rather than convenience: five committed
assertions currently demand the *opposite* of this feature (research R5). Editing the ports first
would leave the suite red for a reason unrelated to the defect, which destroys the signal the failing
test is supposed to carry.

1. **Reproduce.** Add the mode-stripped conformance case to `test_us4_bridge_runnable.bats` and the
   `prereq_bridge_missing` unit case. Both must fail on the current tree. Run quickstart Step 0 by
   hand once to confirm the failure is the real one.
2. **Supersede the old assertions.** Delete the four `-x` assertions and rewrite the fallback-block
   fixture. The suite is now red for exactly one reason: the ports have not been changed yet.
3. **Bash port.** Drop the `-x` clause; add the prefix at the invocation seam; update the two
   messages. Bash suite green.
4. **PowerShell port.** The three message sites and the invocation seam; drop the stale doc
   paragraph. Pester green, conformance green.
5. **Shipped documents.** Command documents, `README.md`, `INSTALL.md`, `readme-block.template`.
   `test_message_command_literals.bats` and `test_agent_doc_invocation.bats` are the gate here.
6. **Release surface.** Version bump in `extension.yml`, CHANGELOG entry naming the workaround
   consumers can now drop, the `docs/` diagram label, the supersession pointer in 003's contract.
7. **Prove it.** Quickstart Steps 1–8, with Step 7 on a host old enough to actually reproduce the
   defect — or an explicit note that no such host was available.

## Risks

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Prefixing a *filename* as if it were an invocation | Produces "the bridge entry point bash .specify/… was not found" — a message that is wrong in a new way | C2 states the rule mechanically and scopes it to a line-local pattern; the doc-invocation test enforces it both ways |
| `/bin/bash` creeping in during review | Turns a permission failure into a "Bash >= 4 required" failure on every Mac | C1.1; worth calling out in the PR description, not just the contract |
| Harness tests skipping silently | `specify` absent ⇒ User Story 1 is never validated, and the run still looks green | Quickstart's "Done when" requires them **run**, not merely not-failed |
| Step 7 unreproducible on a modern host | The dogfood proves nothing if the host restores the mode | Quickstart Step 7 says to record that outcome as inconclusive rather than as a pass |
| The old wording being "restored" later as a regression fix | The fallback block is pinned verbatim in 003's contract | Step 6 adds the supersession pointer there |
