# Implementation Plan: Survive Jira Labels Containing Quotes and Backslashes

**Branch**: `013-fix-yaml-string-escaping` | **Date**: 2026-08-03 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/013-fix-yaml-string-escaping/spec.md`

## Summary

A Jira label may contain `"` or `\`. The configuration serialiser cannot represent one, so the
ceremony refuses the whole document with `EXIT_CONFIG` (4) and the project cannot be configured.

The fix is one agreed spelling on disk, applied at both ends of the same file format:

- **Writer** escapes exactly two characters inside the double quotes it already emits — `\` becomes
  `\\`, then `"` becomes `\"`. Every other byte, including tabs and non-ASCII, is emitted exactly as
  today, so output for a document containing neither character is byte-identical (FR-017).
- **Reader** undoes exactly those two. A backslash forming no recognised escape is kept literally
  (FR-012), so every hand-maintained file that loads today keeps loading.
- **Refusal** changes from "contains `"` or `\`" to "contains a line break" (FR-020). This is not
  purely a narrowing: measurement showed a line-break value is written **raw, with exit 0**, leaving
  a file that cannot be parsed and surfaces later as a misleading error advising a re-run that would
  regenerate it. The refusal reaches a case it never previously caught (research R8).

Three call sites upstream of the scalar decoder also need escape-awareness, or the value is mangled
before the decoder ever sees it: the inline-comment stripper, the quoted-key scan, and — in
PowerShell only — the refusal walker's single-error return.

Nothing above the serialiser changes. FR-002 to FR-005 — display, allowed-value checks, identifier
matching across runs — are satisfied *by construction* once the in-memory value is correct, because
every consumer already compares decoded values. They are carried as verification tasks, not code
tasks; see [research.md](./research.md) R6.

## Technical Context

**Language/Version**: Bash ≥ 4 (`prereq.sh:79` gates it; macOS 3.2 is refused) and PowerShell 7+

**Primary Dependencies**: `jq` for the bash port's JSON/YAML transforms; no new dependency added

**Storage**: Plain-text YAML files — `.specify/jira/config.local.yml` (machine-owned, gitignored)
and `.specify/jira/config.yml` (committable, hand-maintained)

**Testing**: `bats` (`tests/bash/lib/test_config.bats`), Pester
(`tests/powershell/lib/Config.Tests.ps1`), and the cross-port conformance corpus
(`tests/conformance/`)

**Target Platform**: macOS, Linux, Windows (PowerShell port + MSYS bash)

**Project Type**: CLI tool — two native ports proven equivalent by a shared conformance corpus

**Performance Goals**: No regression in reader throughput. The decode adds no subprocess and is
skipped entirely for scalars containing no backslash (research R3), which is nearly all of them.

**Constraints**: Byte-identical output between ports (Constitution VI); writer must stay
deterministic and a fixed point of the reader; the bash port must not call `jq` outside the
`lib/output.sh` CRLF guard (`output.sh:50`); no `$'\r\n'` inside any glob pattern.

**Scale/Scope**: Two library modules, ~6 functions per port, one contract document, one doc page.
No new files in `scripts/`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Gate | Verdict |
| --- | --- | --- | --- |
| I | Filesystem Is the Source of Truth | No new file ownership, no new ticket read/write/delete | **PASS** — only the spelling inside two existing files changes |
| II | Zero-Churn Idempotency | Writer deterministic; re-run byte-identical | **PASS** — escaping is a pure function of the value; a byte-identical second run is asserted |
| III | Fail-Closed on Writes | Refusal keeps exit code, zero partial output, named path | **PASS** — and strengthened. Two silent-corruption paths are converted to fail-closed: the reader's undecoded value (R1) and the line-break value written raw at exit 0 (R8). |
| IV | Credential Security | Refusal names path, never value | **PASS** — the refusal wording keeps the path-only rule; no value is interpolated |
| V | Config / Binding / Secrets separation | No value changes layer | **PASS** — unaffected |
| VI | macOS / Linux / Windows Portability | Both ports byte-identical on 3 runners | **PASS with a required action** — the ports currently diverge on refusal *listing* (bash prints every path, PowerShell returns only the first). Pre-existing and previously untested; the new refusal scenario would expose it, so the plan aligns PowerShell to bash. See research R5. |
| VII | No Hard-Coded Workflow Assumptions | No label charset compiled in | **PASS** — this is the principle the defect violates; FR-006 forbids fixing it by normalisation |
| VIII | Neutral Engine / Jira Sink | No Atlassian vocabulary crosses the interface | **PASS** — the serialiser is shared infrastructure below both sides |
| IX | Two-Tier Privacy Guard | Guard still applies to these values | **PASS with a required test** — `_cfg_redact_line` and its PowerShell mirror `Protect-CfgLine` run on raw line text before formatting, so decoding cannot bypass them. But the escape-aware stripper changes *what text a diagnostic retains*: a token previously truncated at a `#` now reaches the redactor. T052/T053 guard that path. |
| X | Self-Healing Mirror | Hook registration/health untouched | **PASS** — unaffected |
| XI | Dry-Run and Auditability | Preview predicts real bytes | **PASS** — the preview shares the writer; no new destructive operation |
| XII | Quality and Catalog Publication | PATCH bump, CHANGELOG, green matrix, clean lint | **PASS** — the CHANGELOG must call out FR-022, the one intended behaviour change |
| XIII | TDD ≥ 80% coverage | Failing test before fix | **PASS** — Phase 2 orders every test before its fix; the reported label shape is the lead regression test |
| XIV | KISS | Simplest solution satisfying the spec | **PASS** — two characters, one escape rule, no new dependency, no migration step, no normalisation layer |
| XV | YAGNI | Nothing built beyond the spec | **PASS** — `\n` / `\t` / `\uXXXX` escapes explicitly rejected in research R2; line breaks are refused rather than encoded |
| XVI | Human Readable | Conventional spelling, operator sees Jira's text | **PASS** — the on-disk form is the one any standard YAML tool parses; escape notation never reaches a prompt |

**Result: PASS.** No violations to justify; Complexity Tracking is therefore empty.

**Post-Phase-1 re-check: PASS.** The design added no component, no dependency, and no configuration
key. The one gate carrying an action (VI) is discharged by an explicit task aligning the PowerShell
refusal walker with the bash listing, plus a conformance scenario that fails if the two drift again.

## Project Structure

### Documentation (this feature)

```text
specs/013-fix-yaml-string-escaping/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output — R1..R8
├── data-model.md        # Phase 1 output — the scalar's states along its path
├── quickstart.md        # Phase 1 output — runnable validation
├── baseline.txt         # Phase 2 output — pre-fix behaviour recorded by T001
├── contracts/
│   └── yaml-string-escaping.md   # Supersedes yaml-key-grammar.md §2.3
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/
├── bash/lib/config.sh                 # 5 sites change
│   ├── _cfg_strip_inline_comment      # escape-aware inside a double-quoted region
│   ├── _cfg_map_entry_key             # escape-aware closing-quote scan (double-quote branch only)
│   ├── _cfg_scalar_json               # NEW decode step after stripping double quotes
│   ├── _CFG_WRITE_REFUSAL_JQ          # badchars `["\\]` -> line breaks only
│   └── _CFG_YAML_EMIT_JQ              # NEW `yesc` def, applied in `yscalar` and `qkey`
└── powershell/lib/Config.psm1         # 6 sites change (mirrors of the above)
    ├── Remove-CfgInlineComment
    ├── Get-CfgMapEntryKey
    ├── Convert-CfgScalar
    ├── Test-CfgUnrepresentable        # -> line breaks only
    ├── Get-CfgWriteRefusalError       # -> list every path, aligning with bash (research R5)
    └── Write-CfgYamlScalar + Write-CfgYamlNode's key quoting

scripts/powershell/commands/Config.psm1 # no code change — FR-003/004/005 verification sites,
                                       # the mirrors of scripts/bash/commands/config.sh
    ├── :459                           # outside_allowed check, mirror of config.sh:278
    └── :661-663                       # allowed-values prompt, mirror of config.sh:510

tests/
├── bash/lib/test_config.bats          # reader / writer / round-trip units
├── powershell/lib/Config.Tests.ps1    # Pester mirrors
├── bash/commands/test_config_incremental.bats        # FR-005 identifier reuse
├── powershell/commands/Config.Incremental.Tests.ps1  # its mirror
├── powershell/commands/Config.FieldDefaults.Tests.ps1 # FR-003 prompt, FR-004 acceptance
└── conformance/
    ├── fixtures/                      # introspection payload carrying a quoted label
    └── scenarios/                     # us1-label-quoted, us1-label-backslash,
                                       # us3-escaped-form-on-disk, us4-linebreak-refused

docs/
└── 07-configuration-and-secrets.md    # refusal description narrows to line breaks

specs/007-fix-unicode-config-keys/contracts/yaml-key-grammar.md
                                       # §2.3 marked superseded, pointing at this feature's contract
```

**Structure Decision**: No new source file. The change is confined to the two existing serialiser
modules — `scripts/bash/lib/config.sh` and its mirror `scripts/powershell/lib/Config.psm1` — because
every affected behaviour is a property of the shared YAML subset, not of any one command. Tests
follow the established three-tier split: per-port units, then cross-port conformance scenarios for
the byte-equivalence claims that units cannot make.

The contract lives in this feature's `contracts/` directory, matching the convention 011 used for
`field-defaults.md`. Because `scripts/bash/lib/config.sh:451` and `Config.psm1` cite
`yaml-key-grammar.md` §2.3 by name, that section is amended in place with a supersession pointer
rather than silently contradicted.

## Phase Summary

- **Phase 0 — Research** (`research.md`): eight decisions, each checked by running the real code
  rather than reasoning about it. Highlights: the escape algorithm and why `@json` was rejected
  (R2), the decode rule and its fast path (R3), the three escape-blind call sites upstream of the
  decoder (R4), the pre-existing port divergence in refusal listing (R5), and the live line-break
  corruption the old refusal never covered (R8).
- **Phase 1 — Design** (`data-model.md`, `contracts/yaml-string-escaping.md`, `quickstart.md`): the
  scalar's four representations and the transitions between them; the normative contract both ports
  implement; and a runnable end-to-end validation built on the reported label shape.
- **Phase 2 — Tasks** (`/speckit-tasks`): not created by this command.

## Complexity Tracking

No Constitution Check violations. Section intentionally empty.
