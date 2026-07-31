# Implementation Plan: The Local Binding Survives Names the Jira Instance Actually Uses

**Branch**: `fix/config-issues` | **Date**: 2026-07-31 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-fix-unicode-config-keys/spec.md`

## Summary

The configuration reader accepts a mapping key only if every character of it belongs to a short
enumerated set, and stops parsing — silently, with exit 0 — at the first line that fails. A
single accented status name therefore discards the rest of the local binding file.

The fix inverts the rule and closes the silence, in both ports and in one commit:

1. **Recognise a key by structure, not by character class.** A line is a mapping entry when a
   delimiter colon can be located in it — a colon followed by whitespace or end of line, after
   an optional quoted key. Nothing is said about which characters a key may contain, so `Élevée`,
   `完了`, `Done (QA)` and `high/low` all pass, while `https://x` still does not.
2. **Quote every key on write.** Four key forms cannot round-trip bare — an embedded `: `, a
   ` #`, a leading `- `, and padding whitespace. Quoting unconditionally neutralises all four
   with one rule instead of a "does this need quoting?" predicate maintained in two languages.
   The reader keeps accepting bare keys, because the committable `config.yml` and the host's
   PyYAML-written `extensions.yml` use them.
3. **Fail closed on a line that cannot be interpreted.** The parser records source line numbers,
   raises instead of breaking, and reports file, line, content and remediation with
   `EXIT_CONFIG` (4). The printed line is redacted of credential shapes first, because the
   pre-write scan runs on a parsed document and there is none at that point. A key repeated at
   the same mapping level takes the same path rather than silently winning (FR-016). The four
   call sites that swallow the failure today stop swallowing it.
4. **Give the conformance suite eyes for a shared defect.** A fixture carrying the bug report's
   own reproduction, asserted per port against expected content — not only port against port.

Full reasoning in [research.md](./research.md); the normative rules are in
[contracts/yaml-key-grammar.md](./contracts/yaml-key-grammar.md) and
[contracts/parse-failure.md](./contracts/parse-failure.md).

## Technical Context

**Language/Version**: Bash (declared minimum, above macOS's system 3.2) and PowerShell 7+ — the
two native ports required by Constitution VI. No third language is introduced.

**Primary Dependencies**: unchanged — `jq`, `curl`, `git` at runtime. No YAML library is added;
the deliberately restricted subset parser stays hand-written, which is why this defect was
possible and why the fix is a parser change rather than a dependency swap.

**Storage**: files only. `.specify/jira/config.local.yml` (gitignored, machine-owned),
`.specify/jira/config.yml` (committable), `.specify/jira/personal.yml`, and the host's
`.specify/extensions.yml` — all read by the parser being fixed.

**Testing**: bats for Bash, Pester for PowerShell, plus the shared conformance harness
(`tests/conformance/run-scenario.sh`) driving both ports against the mock Jira.

**Target Platform**: macOS, Linux, Windows — the three-OS GitHub Actions matrix.

**Project Type**: CLI extension for Spec Kit, script-native, two mirrored implementations.

**Performance Goals**: not a factor. Configuration files are tens of lines; the key scan is
linear in line length and replaces a regex match of the same order.

**Constraints**: byte-identical output between ports (Constitution VI); no new runtime
dependency (XIV); no new exit code — `EXIT_CONFIG` (4) already covers configuration faults, so
the monotonic escalation of the existing table is untouched (III).

**Scale/Scope**: two library modules and their four calling sites per port, one new conformance
fixture and scenario, and the regression tests. Roughly 250 lines of source change across both
ports — the estimate grew with the redaction helper and the duplicate-key set — and the test
suites that must precede them.

## Constitution Check

*GATE: passed before Phase 0, re-checked after Phase 1 (below).*

| # | Principle | Gate verdict |
| --- | --- | --- |
| I | Filesystem Is the Source of Truth | **Pass — unaffected.** No Jira read, write, delete or adoption path is added or altered. |
| II | Zero-Churn Idempotency | **Pass.** No new write kind. The writer stays deterministic: same input JSON, same bytes. The *content* of `config.local.yml` changes once (keys become quoted); a re-run after that writes byte-identical bytes, which the existing determinism tests assert. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | **Pass — directly implemented.** Parse failure returns `EXIT_CONFIG` (4), no partial document reaches a caller, and reconcile performs zero Jira writes. The existing hook downgrade (reconcile.sh:632-648) keeps the host command's exit code at 0 with one `WARNING:`. No new exit code, so escalation stays monotonic. |
| IV | Credential Security | **Pass.** Fixtures carry issue-type, priority and status names only. The parse-failure message formats path, line number and the offending line **redacted** of credential shapes (`parse-failure.md` §2.1) — the pre-write scan cannot cover this path, since it runs on a parsed document and the failure precedes one; the writer's refusal (research R3) names the path, never the value. |
| V | Team Config / Local Binding / Secrets | **Pass.** Layer boundaries untouched; nothing moves into the extension folder. The same parser serves layers 1 and 2, so both are fixed by one change. |
| VI | macOS / Linux / Windows Portability | **Pass.** Both ports change in one commit with mirrored control flow — a shared error flag rather than a `throw` on one side and a global on the other. The grammar is proven byte-safe in UTF-8 (contract §3). FR-014 closes the hole that let a shared defect through the parity-only suite. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | **Pass — this is the principle being restored.** An enumerated key charset was a hard-coded assumption about how a company names its statuses. |
| VIII | Neutral Engine / Jira Sink | **Pass.** `lib/config.sh` and `lib/Config.psm1` are port infrastructure with no Jira knowledge, and none is added. Fixture names are data. |
| IX | Two-Tier Privacy Guard | **Pass — unaffected.** The pre-write scan and its tiers are untouched. |
| X | Self-Healing Automatic Mirror | **Pass.** The hook registry is read by this parser, so it gains the same guarantees. `config_hooks_disabled_read` propagates rather than defaulting to "nothing disabled" — an unreadable binding must never be able to re-enable a hook the operator disabled. |
| XI | Universal Dry-Run and Auditability | **Pass.** Dry-run is unaffected. Auditability improves: a silent loss becomes a located, reported one. |
| XII | Quality and Catalog Publication | **Pass.** CHANGELOG entry, three-OS matrix, and dogfooding against the real Jira instance whose names exposed the defect. |
| XIII | TDD With ≥80% Coverage | **Pass.** Fourteen regression cases enumerated in research R7, written first and observed failing (quickstart Check 1) — including the conformance case, which is authored before either fix so its red is observable at all. New tests use paths they create themselves — no machine-wide scan — so the suites stay green under `bats --jobs`. |
| XIV | KISS | **Pass.** The structural rule is *simpler* than the enumeration it replaces: it removes a special case. Unconditional key quoting removes a predicate rather than adding one. No new dependency, no new abstraction, no new exit code. |
| XV | YAGNI | **Pass.** No escaping is implemented — the writer refuses what it cannot represent (research R3). No compatibility shim, no migration, no strictness option. |
| XVI | Human Readable | **Pass.** The written file stays reviewable and becomes more internally consistent, since values were already quoted. The failure message names file, line, content and a copy-pasteable remediation instead of vanishing. |

**Result: no violations. Complexity Tracking is empty.**

### Post-Phase-1 re-check

Re-evaluated after the contracts and data model were written. No verdict changed. Two points
were sharpened by the design work and are recorded here because they are the places where a
careless implementation would breach a principle:

- **VI** — the temptation to use PowerShell's `throw` and Bash's `return` is a real divergence
  risk: the two would unwind differently and produce different stderr ordering. The contract
  pins a mirrored flag mechanism instead.
- **XIII / VII** — making `_cfg_is_map_entry` fatal *everywhere* would break `- jira`, a legal
  sequence of strings, and would be caught only by an existing test. The contract distinguishes
  the mapping-level test (fatal) from the sequence-level dispatch (not fatal).

## Project Structure

### Documentation (this feature)

```text
specs/007-fix-unicode-config-keys/
├── plan.md                       # This file
├── spec.md                       # Feature specification
├── research.md                   # Phase 0 — R1..R7, all decisions
├── data-model.md                 # Phase 1 — key, binding document, parse failure, parser state
├── quickstart.md                 # Phase 1 — 10 runnable validation checks
├── contracts/
│   ├── yaml-key-grammar.md       # Reader recognition + writer emission, normative
│   └── parse-failure.md          # Message, exit code, propagation, invariants
├── checklists/
│   └── requirements.md           # Spec quality checklist (complete)
└── tasks.md                      # Phase 2 — created by /speckit-tasks, NOT by this command
```

### Source Code (repository root)

```text
scripts/
├── bash/
│   ├── lib/
│   │   └── config.sh                     # _cfg_prep (+_cfg_linenos, _cfg_seen), _cfg_is_map_entry,
│   │                                     #   _cfg_parse_mapping, _cfg_local_json,
│   │                                     #   config_hooks_disabled_read, config_personal_load,
│   │                                     #   _CFG_YAML_EMIT_JQ (key quoting + refusal)
│   ├── commands/
│   │   └── reconcile.sh                  # _reconcile_local_binding_for — propagate, zero writes
│   └── hooks/
│       └── register_hooks.sh             # register_hooks_health — surface the located message
└── powershell/
    ├── lib/
    │   └── Config.psm1                   # Read-CfgPrep (+CfgLineNos, CfgSeen), Test-CfgMapEntry,
    │                                     #   Read-CfgMapping, ConvertFrom-JiraConfigYaml,
    │                                     #   ConvertTo-JiraConfigYaml — mirrors of the above
    ├── commands/
    │   └── Reconcile.psm1                # twin of _reconcile_local_binding_for
    └── hooks/
        └── RegisterHooks.psm1            # twin of register_hooks_health

tests/
├── bash/
│   ├── lib/test_config.bats                          # R7 cases 1-8, 11
│   ├── commands/test_reconcile*.bats                 # R7 case 9
│   ├── hooks/                                        # R7 case 10
│   └── conformance/test_us1_unicode_binding.bats     # R7 case 12 (new file)
├── powershell/
│   ├── lib/Config.Tests.ps1                          # mirrors of R7 1-8, 11
│   ├── commands/, hooks/                             # mirrors of 9, 10
│   └── conformance/Us1.UnicodeBinding.Tests.ps1      # mirror of 12 (new file)
└── conformance/
    ├── fixtures/repo-with-unicode-binding/           # new — the bug report's reproduction
    └── scenarios/us1-unicode-binding.json            # new
```

**Structure Decision**: the repository's existing two-port layout is used unchanged. Every source
edit has an exact twin at the mirrored path in the other port, and the two are made in the same
commit (FR-013). No file is created outside the directories above.

## Implementation Sequence

Ordering is set by Constitution XIII: every test precedes the code it exercises.

| Step | Work | Gate |
| --- | --- | --- |
| 1 | Write R7 cases 1-8 and 11 in `test_config.bats` and `Config.Tests.ps1`; write cases 9, 10; add the conformance fixture, scenario and case 12 | **Observe red.** Record the reproduction's `{"resolved_ids":{"JET":{"issue_types":{}}}}` as the evidence Principle XIII requires. |
| 2 | Reader: implement the grammar (contract §1) in `_cfg_is_map_entry`, extract the key per §1.1/§1.2 in `_cfg_parse_mapping` — both ports | cases 1-5 green |
| 3 | Writer: quote every key, refuse `"`/`\` — both ports | cases 6, 11 green; writer parity holds (quickstart Check 2) |
| 4 | Fail-closed: add `_cfg_linenos` and the per-frame `_cfg_seen` set, raise instead of break, redact the printed line (`parse-failure.md` §2.1), propagate through the four call sites (research R5) — both ports. The line-number array lands here, behind the only test that observes it, not in an earlier foundational step | cases 7, 8, 13, 14 green |
| 5 | Propagation to reconcile and hooks | cases 9, 10 green |
| 6 | Update tests that assert written bytes; CHANGELOG; verify coverage and parallel-safety | full suites green on three OSes, coverage ≥80% |

Step 3 must not be split across commits from step 2: a reader that unquotes without a writer
that quotes, or the reverse, leaves the round trip open — the failure mode the bug report
explicitly warns about (FR-005).

## Complexity Tracking

No Constitution Check violation. The table is intentionally empty.

The one judgement worth recording is a *reduction* in complexity rather than an addition:
unconditional key quoting was chosen over conditional quoting precisely to avoid a
"would this key survive bare?" predicate duplicated in two languages (research R2). The cost is
that `config.local.yml` changes shape once; backward compatibility is out of scope by the
specification, so no shim is written to absorb it.

This is also the reading of FR-006's "not decoratively" clause that the plan adopts: the clause
prohibits escaping and per-key decoration, not a uniform rule. FR-006 was reworded to say so
explicitly rather than left to be interpreted at review.
