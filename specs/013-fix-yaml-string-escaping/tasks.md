---

description: "Task list for 013 — Survive Jira Labels Containing Quotes and Backslashes"
---

# Tasks: Survive Jira Labels Containing Quotes and Backslashes

**Input**: Design documents from `/specs/013-fix-yaml-string-escaping/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/yaml-string-escaping.md](./contracts/yaml-string-escaping.md)

**Tests**: **MANDATORY.** Constitution XIII requires a failing test before every fix, and the
project's bug-fix policy requires the regression test to be written first. Every implementation
task below is preceded by the test that must fail without it.

**Organization**: Tasks are grouped by user story. Phase 2 is foundational because the reader's
decode is a **safety prerequisite** for the writer's encode — see the sequencing constraint below.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

Two native ports, mirrored function-for-function:

- Bash: `scripts/bash/lib/config.sh` — tests in `tests/bash/lib/test_config.bats`
- PowerShell: `scripts/powershell/lib/Config.psm1` — tests in `tests/powershell/lib/Config.Tests.ps1`
- Cross-port: `tests/conformance/scenarios/*.json` + `tests/conformance/fixtures/`

**The parallel axis in this repo is the port boundary.** `config.sh` and `Config.psm1` are each a
single file, so tasks touching the same one serialise; a bash task and its PowerShell mirror are
always `[P]` with each other.

---

## ⚠️ Sequencing constraint (read before starting)

The reader's decode and the writer's encode are **one atomic change to the file format**.

- Shipping the **decode alone** is safe: the reader learns to undo an escape the writer never emits.
- Shipping the **encode alone** is **data-corrupting**: the writer emits `\"`, the reader returns it
  with literal backslashes, and the value round-trips to something else — the exact defect this
  feature exists to fix, merely relocated.

Therefore Phase 2 (decode) MUST be merged before or in the same commit as Phase 3 (encode). Do not
land Phase 3 on its own.

---

## Phase 1: Setup (Baseline)

**Purpose**: Record the pre-fix behaviour so every regression claim is provable rather than asserted.

- [X] T001 Record pre-fix baseline for [quickstart.md](./quickstart.md) Scenarios 1, 3 and 4 into `specs/013-fix-yaml-string-escaping/baseline.txt`, confirming: Scenario 1 decodes to literal backslashes at exit 0 then refuses at exit 4; Scenario 3 truncates `tricky` to `a \`; Scenario 4 writes a corrupt file at **exit 0**
- [X] T002 [P] Confirm the suites are green before any edit — `tests/run-bash.sh`, `pwsh -c 'Invoke-Pester tests/powershell'`, `bash tests/conformance/ci-conformance.sh`, `shellcheck scripts/bash/lib/config.sh`. The **full** Pester suite, not just `lib/Config.Tests.ps1`: `lib/Config.psm1` is a shared serialiser that the 31 command suites plus the engine, sink and hook suites all load, so a single-file run cannot establish this baseline

**Checkpoint**: The three defects are documented as observed facts, not predictions.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The reader half — decode plus the two escape-blind scans upstream of it. Blocks every
user story, and MUST land before Phase 3 (see the sequencing constraint).

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Contract

- [X] T003 Amend `specs/007-fix-unicode-config-keys/contracts/yaml-key-grammar.md` §2.3 to mark it superseded, pointing at `specs/013-fix-yaml-string-escaping/contracts/yaml-string-escaping.md`; leave §1, §2.1, §2.2 and §3 in force

### Tests (write first — these MUST fail)

- [X] T004 [P] Add failing reader tests to `tests/bash/lib/test_config.bats`: (a) `- "Platform \"legacy\""` decodes to `Platform "legacy"`; (b) `"Delivery\\Platform"` decodes to one backslash; (c) `"trailing\\"` does not swallow the delimiter; (d) `"\\\""` decodes to the two characters `\"`; (e) the escaped form decodes identically as a sequence item and as a mapping value (contract §2.4)
- [X] T005 [P] Add the same failing reader cases to `tests/powershell/lib/Config.Tests.ps1` against `Convert-CfgScalar` / `ConvertFrom-JiraConfigYaml`
- [X] T006 [P] Add failing comment-stripper test to `tests/bash/lib/test_config.bats`: `tricky: "a \" # b"` must decode to `a " # b`, not the truncated `a \` recorded in T001 — the fixture MUST use an **odd** number of escaped quotes, because an even count hides the defect (FR-011)
- [X] T007 [P] Add the same failing comment-stripper case to `tests/powershell/lib/Config.Tests.ps1` against `Remove-CfgInlineComment`
- [X] T008 [P] Add failing quoted-key test to `tests/bash/lib/test_config.bats`: `"say \"x\"": v` yields key `say "x"` and value `v` (FR-010, contract §2.3)
- [X] T009 [P] Add the same failing quoted-key case to `tests/powershell/lib/Config.Tests.ps1` against `Get-CfgMapEntryKey`
- [X] T010 [P] Add **compatibility guard** tests to `tests/bash/lib/test_config.bats` that must stay green throughout: `path: "C:\Users\shared"` keeps both backslashes (FR-012); `single: 'a\"b'` is not decoded (FR-013); `Won't Do: "10004"` still parses (007 research R1); a value containing a literal TAB round-trips unchanged (research R2)
- [X] T011 [P] Add the same compatibility guards to `tests/powershell/lib/Config.Tests.ps1`
- [X] T052 [P] Add a **privacy guard** test to `tests/bash/lib/test_config.bats` that must stay green throughout (FR-024, Constitution IX): a line that fails the mapping-entry test, carrying a double-quoted region with an **odd** escaped quote followed by ` # ` and a credential-shaped substring — e.g. `bad "a \" # ATATT<token>` — must emit `[redacted]` in the parse-failure diagnostic. T014 is what makes this reachable: today the stripper's quote state inverts on the escaped quote and truncates the line before the token, so the token is never printed; afterwards the region stays open and the token reaches `_cfg_redact_line` for the first time. Like T010/T011 this is a guard, not a red-first test — FR-024 is a must-not-regress requirement
- [X] T053 [P] Add the same privacy guard to `tests/powershell/lib/Config.Tests.ps1` against `Protect-CfgLine` / `New-CfgParseFailure` (`Config.psm1:172`, `:190`)

### Implementation

- [X] T012 [P] In `scripts/bash/lib/config.sh`, add `_cfg_decode_escapes` implementing the contract §2.1 walk (`\"`→`"`, `\\`→`\`, any other `\x` verbatim), with the fast path `[[ "${s}" != *\\* ]]` returning immediately; call it from `_cfg_scalar_json` on the double-quoted branch only
- [X] T013 [P] In `scripts/powershell/lib/Config.psm1`, add the mirror decode and call it from `Convert-CfgScalar` on the double-quoted branch only
- [X] T014 In `scripts/bash/lib/config.sh`, make `_cfg_strip_inline_comment` skip the character following a `\` **only while `in_d` is set**; leave the single-quoted and unquoted states unchanged (data-model §4)
- [X] T015 [P] In `scripts/powershell/lib/Config.psm1`, apply the same change to `Remove-CfgInlineComment`
- [X] T016 In `scripts/bash/lib/config.sh`, make `_cfg_map_entry_key`'s closing-quote scan skip an escaped quote **only when the opening quote is `"`**; leave the single-quote branch and the bare-key scan at line 265 untouched — 007 research R1 requires `Won't Do: "10004"` to keep parsing
- [X] T017 [P] In `scripts/powershell/lib/Config.psm1`, apply the same change to `Get-CfgMapEntryKey`

**Checkpoint**: T004–T011 all green. The reader now decodes; the writer still refuses. Safe to land
on its own, and required before Phase 3.

---

## Phase 3: User Story 1 — Configure a project whose introspection returns a quoted label (Priority: P1) 🎯 MVP

**Goal**: The ceremony completes and writes its allowed-value lists and resolved-id table when
introspection returns a label containing `"` or `\`.

**Independent Test**: Run the ceremony against introspection metadata carrying a label with an
embedded double quote and one with an embedded backslash; the command exits 0 and the local
configuration file holds an entry for each.

### Tests (write first — these MUST fail)

- [X] T018 [US1] **Invert the two tests that encode the old behaviour** in `tests/bash/lib/test_config.bats:196` and `:203` ("a key containing a double quote is refused on write…", "a string value containing a double quote is refused on write…"): they must now assert the document is **written** and round-trips, keeping the assertion that the value never appears in any error. Do not delete them — they are the regression's two ends
- [X] T019 [P] [US1] Add failing writer tests to `tests/bash/lib/test_config.bats` asserting the exact bytes of contract §1.3: `Platform "legacy"` → `"Platform \"legacy\""`, `Delivery\Platform` → `"Delivery\\Platform"`, `Group "A\B"` → `"Group \"A\\B\""`, `\"` → `"\\\""`, and `clean` → `"clean"` byte-identical to today (FR-017)
- [X] T020 [P] [US1] Add the same failing writer byte-assertions to `tests/powershell/lib/Config.Tests.ps1`
- [X] T021 [P] [US1] Add a failing test to `tests/bash/lib/test_config.bats` that a mapping **key** containing `"` is emitted escaped and read back identical (FR-010 + FR-014, the resolved-id table's shape)
- [X] T039 [P] [US4] Add a failing test to `tests/bash/lib/test_config.bats`: a string value containing a line break is refused with exit 4, nothing is written to stdout, and the error contains the path but zero characters of the value — contrast with the T001 baseline where this wrote a corrupt file at **exit 0** (FR-020). Cover a bare **CR (U+000D)** as well as **LF (U+000A)**, per contract §1.4 and §4. **Placed in Phase 3, not Phase 6**: T024 is one edit that both stops refusing `"`/`\` and starts refusing line breaks (research R8), so this is that edit's red test and Constitution XIII requires it here
- [X] T040 [P] [US4] Add the same line-break refusal test, including the bare-CR case, to `tests/powershell/lib/Config.Tests.ps1` — note this file currently has **no** refusal coverage at all, so this is a new class of test there

### Implementation

- [X] T022 [US1] In `scripts/bash/lib/config.sh`, add a `yesc` definition to `_CFG_YAML_EMIT_JQ` — `(. / "\\" | join("\\\\")) | (. / "\"" | join("\\\""))` — and apply it in both `yscalar`'s string branch and `qkey`. Backslash first, then quote; reversing the order double-escapes (research R2). Do **not** substitute `@json`, which also escapes TAB
- [X] T023 [P] [US1] In `scripts/powershell/lib/Config.psm1`, apply `.Replace('\','\\').Replace('"','\"')` in `Write-CfgYamlScalar` and in `Write-CfgYamlNode`'s key quoting, in that order
- [X] T024 [US1] In `scripts/bash/lib/config.sh`, change `_CFG_WRITE_REFUSAL_JQ`'s `badchars` from `test("[\"\\\\]")` to a test for **LF (U+000A) or CR (U+000D)** — contract §1.4 names both, and §4 puts a non-terminating `\r` under the same rule — so `"` and `\` stop being refused; reword both message strings to name the line break rather than the two characters, keeping the path-only rule (Constitution IV). Red test: T039
- [X] T025 [P] [US1] In `scripts/powershell/lib/Config.psm1`, change `Test-CfgUnrepresentable` to test for **LF or CR** only, and reword `Get-CfgWriteRefusalError`'s two messages to match the bash wording byte-for-byte. Red test: T040

### End-to-end

- [X] T026 [US1] Add a conformance fixture repository under `tests/conformance/fixtures/repo-with-quoted-label/` plus the mock introspection payload whose `allowedValues` carry a label containing `"` and another containing `\`
- [X] T027 [US1] Add conformance scenario `tests/conformance/scenarios/us1-label-quoted.json` running `config` against that fixture and asserting exit 0 and byte-identical written files across both ports
- [X] T028 [P] [US1] Add conformance scenario `tests/conformance/scenarios/us1-label-backslash.json` for the backslash label
- [X] T029 [US1] Add a test asserting the operator-facing allowed-values question renders the label as the text a human sees in Jira, with no escape notation and no stray backslash (FR-003) — the prompt is built at `scripts/bash/commands/config.sh:510` via `join(", ")`
- [X] T054 [P] [US1] Add the FR-003 mirror for PowerShell: assert the allowed-values question renders the label as the text a human sees in Jira, with no escape notation and no stray backslash — the prompt is built at `scripts/powershell/commands/Config.psm1:661-663` via `-join ', '`, tested in `tests/powershell/commands/Config.FieldDefaults.Tests.ps1`

**Checkpoint**: The reported defect is fixed end to end. Quickstart Scenarios 1, 2, 4 and 5 pass —
Scenario 4's silent corruption is now a fail-closed refusal. This is the MVP.

---

## Phase 4: User Story 2 — The label survives the round trip and matches on later runs (Priority: P1)

**Goal**: A recorded label reads back identical, is still matched against introspection on the next
run, is accepted when recorded as a field default, and a re-run rewrites the file byte-for-byte.

**Independent Test**: Record a configuration containing quoted and backslashed labels, read it back
and compare with what introspection supplied; re-run against unchanged introspection and compare the
two files byte-for-byte.

**Note**: research R6 established that no production code above the serialiser needs changing —
every consumer already compares decoded values. These are therefore **verification** tasks. They are
not taken on trust: T032 covers the exact-match site where a half-decoded value would silently
reject a value Jira accepts.

### Tests

- [X] T030 [P] [US2] Add a round-trip corpus test to `tests/bash/lib/test_config.bats` covering every Edge Case in spec.md **expressible as a logical-value round trip**. The three it uniquely adds are: a run of consecutive backslashes preserved in count, a quote adjacent to the delimiter, and `Platform "legacy"` vs `Platform legacy` remaining **distinct** values (FR-006, invariant I5). The remaining Edge Cases are not round trips of a logical value and are covered elsewhere — trailing comment marker by T006/T007, key-with-delimiter-colon by T008/T009, `C:\Users\shared` / single-quoted / `"10004"` by T010/T011, privacy redaction by T052/T053
- [X] T031 [P] [US2] Add the same round-trip corpus to `tests/powershell/lib/Config.Tests.ps1`
- [X] T032 [US2] Add a test proving a recorded field default whose value contains `"` is **accepted** by the allowed-values check at `scripts/bash/commands/config.sh:278` (`index($v)`), not rejected as `outside_allowed` (FR-004). Extend it to round-trip that default through the committable `config.yml` — written escaped, read back identical — so FR-021's "same decoding, same widened representation, same narrowed refusal" is exercised on the team-config layer and not only inferred from the shared serialiser
- [X] T055 [P] [US2] Add the FR-004 mirror: a recorded field default whose value contains `"` is **accepted** by the allowed-values check at `scripts/powershell/commands/Config.psm1:459`, not classified `outside_allowed` — in `tests/powershell/commands/Config.FieldDefaults.Tests.ps1`, with the same `config.yml` round trip as T032
- [X] T033 [US2] Add a test to `tests/bash/commands/test_config_incremental.bats` proving a label recorded in one run is matched to its introspected counterpart on the next, so the resolved identifier is reused rather than re-resolved (FR-005)
- [X] T056 [P] [US2] Add the FR-005 mirror to `tests/powershell/commands/Config.Incremental.Tests.ps1`: a label recorded in one run is matched to its introspected counterpart on the next, so the resolved identifier is reused rather than re-resolved
- [X] T034 [P] [US2] Add a determinism test to `tests/bash/lib/test_config.bats`: write → read → write yields byte-identical files for a document holding a quoted label (FR-017, quickstart Scenario 5)
- [X] T035 [US2] Add conformance scenario `tests/conformance/scenarios/us2-quoted-label-idempotent.json` — a second `config` run over unchanged introspection reports no change and rewrites the file byte-for-byte (FR-019, Constitution II)

**Checkpoint**: The fix is durable, not a one-shot write.

---

## Phase 5: User Story 3 — Read a file that already holds a value in escaped form (Priority: P2)

**Goal**: A configuration file already on disk in the escaped form loads as the text that form
denotes, and can be rewritten.

**Independent Test**: Place a file containing `- "Platform \"legacy\""` on disk, load it, assert the
value is `Platform "legacy"`, write it back, assert success and byte-identical content.

**Note**: the decode landed in Phase 2 and can be verified there on its own; the **rewrite** half of
this story needs the Phase 3 encode, since the writer still refuses `"` until T024 lands. This story
verifies the on-disk recovery path end to end and the FR-022 compatibility boundary.

### Tests

- [X] T036 [P] [US3] Add a test to `tests/bash/lib/test_config.bats` that a pre-seeded file holding `- "Platform \"legacy\""` loads as `Platform "legacy"` and rewrites byte-identically — this is quickstart Scenario 1, the wedged-configuration recovery
- [X] T037 [P] [US3] Add the same pre-seeded-file test to `tests/powershell/lib/Config.Tests.ps1`
- [X] T038 [US3] Add conformance fixture `tests/conformance/fixtures/repo-with-escaped-config/` whose `config.local.yml` already contains the escaped form, plus scenario `tests/conformance/scenarios/us3-escaped-form-on-disk.json` asserting both ports recover it identically

**Checkpoint**: An already-wedged configuration recovers on the next ordinary load, with no migration
step.

---

## Phase 6: User Story 4 — A genuinely unrepresentable value still refuses (Priority: P3)

**Goal**: The two ports refuse identically. The refusal predicate itself moved to Phase 3 with the
single edit that changes it (T024/T025, red-tested by T039/T040); what remains here is the
pre-existing port divergence in refusal **listing** that the new refusal scenario would otherwise
expose (research R5).

**Independent Test**: Submit a document with two unrepresentable values; assert both ports print
every offending path, deduplicated and in the same order, at exit 4 with zero bytes written.

**Note**: research R8 measured the line-break case as a **live** defect, not a hypothetical: today
the write succeeds at exit 0 and produces an unparseable file whose later load blames a line the
operator never wrote and advises a re-run that would regenerate it. That is why its tests sit with
the predicate edit in Phase 3 rather than here.

### Tests

- [X] T041 [P] [US4] Add a test to `tests/bash/lib/test_config.bats` asserting a document with **two** unrepresentable paths reports **both**, deduplicated and in the same order (research R5)
- [X] T041b [P] [US4] Add the same two-path listing test to `tests/powershell/lib/Config.Tests.ps1` — it fails until T042

### Implementation

- [X] T042 [US4] In `scripts/powershell/lib/Config.psm1`, change `Get-CfgWriteRefusalError` to accumulate **every** offending path rather than returning the first, and `ConvertTo-JiraConfigYaml` to emit them all — aligning with bash's `unique | .[]` and discharging the Constitution VI action recorded in plan.md (research R5)
- [X] T043 [US4] Add conformance scenario `tests/conformance/scenarios/us4-linebreak-refused.json` asserting both ports produce identical stderr and identical exit codes for a refused document

**Checkpoint**: The two ports refuse identically, listing every offending path. The silent
line-break corruption itself was closed in Phase 3 by T024/T025.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T044 [P] Update `docs/07-configuration-and-secrets.md` — the refusal description at the fail-closed flow narrows from "contains `"` or `\`" to "contains a line break"
- [X] T045 [P] Update the code comments that cite the superseded rule: `scripts/bash/lib/config.sh:462-464` ("A key or a string value containing `"` or `\` cannot be represented…") and the mirroring block in `scripts/powershell/lib/Config.psm1`, pointing at the new contract
- [X] T046 [P] Add a `CHANGELOG.md` entry as a PATCH release, explicitly recording the FR-022 behaviour change: a double-quoted scalar containing a recognised escape now decodes to the text it denotes, so a value some deployments read with literal backslashes will start reading without them (Constitution XII)
- [X] T047 Run `shellcheck scripts/bash/lib/config.sh` and `actionlint` — both must be clean
- [X] T048 Run the full suites: `tests/run-bash.sh` (~190s), `pwsh -c 'Invoke-Pester tests/powershell'` (the whole tree, per T002), `bash tests/conformance/ci-conformance.sh`. Conformance success is **silent** — exit 0 with zero "conformance divergence" lines; temp paths in the output are harness noise
- [X] T049 Push to `ci/windows-probe` (~11 min, results arrive as annotations) and confirm zero divergences. Required, not optional: this change adds two new backslash glob patterns and modifies the port's largest multi-line `jq` read, both classes with a history of behaving differently under MSYS (research R7)
- [X] T050 Execute every scenario in [quickstart.md](./quickstart.md) and confirm each matches its documented "after" output, including that Scenario 1 failed against the T001 baseline
- [ ] T051 Dogfood against the real Jira instance whose quoted option label produced the defect: run the configuration ceremony end to end, confirm it completes, and confirm the resolved-id table and allowed-value lists hold the label intact. Record the outcome in the PR — exit code, entry count, and a byte-identical second run — but **not** the consumer's field or option names, per the anonymisation rule the spec follows throughout. Constitution XII makes this a release gate, and spec.md's Constitution Check row XII commits to it by name

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — must run before any edit, or the baseline is unrecoverable
- **Phase 2 (Foundational)**: Depends on Phase 1. **BLOCKS all user stories**, and MUST land before Phase 3
- **Phase 3 (US1, P1)**: Depends on Phase 2 — see the sequencing constraint
- **Phase 4 (US2, P1)**: Depends on Phase 3 (round-trip needs both halves)
- **Phase 5 (US3, P2)**: Depends on Phase 3. Its decode half is verifiable after Phase 2, but T036's byte-identical rewrite requires the encode — the writer still refuses `"` until T024 lands
- **Phase 6 (US4, P3)**: Depends on Phase 3. The refusal predicate and its red tests (T024/T025, T039/T040) land there; Phase 6 aligns the two ports' refusal **listing** on top of it
- **Phase 7 (Polish)**: Depends on all preceding phases

### User Story Dependencies

- **US1 (P1)**: Requires Foundational. The MVP
- **US2 (P1)**: Requires US1 — verifies the composition of both halves
- **US3 (P2)**: Requires Foundational for the decode and US1 for the rewrite
- **US4 (P3)**: Its predicate tests run in Phase 3 alongside the edit they cover; Phase 6 carries the port-alignment remainder

### Within Each User Story

- Tests are written first and MUST fail before the implementation task that satisfies them
- Reader before writer, always (the sequencing constraint)
- Both ports before the conformance scenario that compares them

### Parallel Opportunities

The **port boundary is the parallel axis**. `scripts/bash/lib/config.sh` and
`scripts/powershell/lib/Config.psm1` are each a single file, so tasks touching the same one
serialise; the same holds for `tests/bash/lib/test_config.bats` and
`tests/powershell/lib/Config.Tests.ps1`.

- T004/T005, T006/T007, T008/T009, T010/T011, T052/T053 — bash test vs PowerShell test
- T012/T013, T014+T016 vs T015+T017 — bash implementation vs PowerShell implementation
- T019/T020, T022 vs T023, T024 vs T025, T039/T040, T029/T054 — same axis in Phase 3
- T030/T031, T032/T055, T033/T056, T036/T037, T041/T041b — same axis in Phases 4–6
- T044/T045/T046 — three different documents

---

## Parallel Example: Phase 2 Foundational

```bash
# The two ports' failing tests, together:
Task: "T004 Add failing reader tests to tests/bash/lib/test_config.bats"
Task: "T005 Add failing reader tests to tests/powershell/lib/Config.Tests.ps1"

# Then the two ports' implementations, together:
Task: "T012 Add _cfg_decode_escapes to scripts/bash/lib/config.sh"
Task: "T013 Add the mirror decode to scripts/powershell/lib/Config.psm1"
```

---

## Implementation Strategy

### MVP (Phases 1–3)

1. Phase 1 — capture the baseline. Without it the regression cannot be proven
2. Phase 2 — the reader half. Safe to land alone
3. Phase 3 — the writer half. **Must not land without Phase 2**
4. **STOP and VALIDATE**: quickstart Scenarios 1, 2, 4 and 5; the consumer project configures (recorded by T051)

At this point the reported defect is fixed and shippable.

### Incremental Delivery

1. Phases 1–3 → MVP: the reported defect closed **and** the line-break corruption closed, since T024/T025 do both
2. Phase 4 (US2) → durability: round trip, matching, zero churn
3. Phase 5 (US3) → recovery of already-wedged configurations
4. Phase 6 (US4) → the two ports aligned on refusal listing
5. Phase 7 → docs, CHANGELOG, Windows probe, dogfood

### Risk Notes

- **Do not land Phase 3 alone.** It converts a blocked run into silent data corruption
- **Do not adopt `@json`** for the encode. It also escapes TAB, and a tab round-trips correctly today (research R2)
- **Do not make the bare-key scan escape-aware.** `Won't Do: "10004"` must keep parsing (007 research R1); T010/T011 guard this
- **Do not satisfy any requirement by normalising a label.** FR-006 forbids stripping or folding these characters; T030 asserts distinctness
- **A green macOS run is not evidence for Windows.** T049 is required (research R7)

---

## Notes

- `[P]` tasks = different files, no dependencies
- `[Story]` label maps a task to a user story for traceability, **independently of phase placement** — T039/T040 are `[US4]` but execute in Phase 3, next to the edit they red-test
- **Task IDs are stable, not sequential.** T039–T042 and T051–T056 were placed by dependency rather than by number during a post-generation review; read the phases in document order, not by ID
- Verify every test fails before implementing
- Commit after each task or logical group; Phases 2 and 3 may be separate commits but must land together
- `bats -r tests/bash` works directly if raw output is needed, but the `-r` is load-bearing — without it bats silently runs nothing

---

## Phase 8: Convergence

- [X] T057 **CRITICAL** Rename `Get-CfgWriteRefusalErrors` (`scripts/powershell/lib/Config.psm1:571`) to a singular noun and update its four call sites (`:565`, `:584`, `:591`, and its own recursion) per Constitution XII, plan.md Constitution Check row XII (contradicts) — `Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse -Settings PSScriptAnalyzerSettings.psd1` returns one `PSUseSingularNouns` Warning there; the settings file enforces `Severity = @('Error','Warning')` without excluding that rule and `ci.yml:130` exits 1 on any result, so the CI **Lint (shellcheck, PSScriptAnalyzer)** job fails on this branch. The pre-013 baseline `64bff1b` had zero. T047 verified `shellcheck` only
- [X] T058 **CRITICAL, SCOPED OUT** Windows conformance divergence `us2-field-defaults-question` (`stdout: first difference at byte 311 — bash=43 pwsh=2f`, sizes 434 / 415) re-confirmed on probe run `30877556011` (HEAD `2d9d0dd`, which carries every T057–T063 fix): byte offset, byte values and both sizes are **identical** to probe run `30855631505` on the pre-013 `4f11ac4`, and to the annotation already present on the pre-013 baseline `64bff1b`. The divergence sits in `reconcile`'s field-defaults question rendering, a code path none of 013's escape-handling changes (T012–T063) touch — it is a pre-existing, unrelated Windows-only defect, not a regression this feature introduced or can close under FR-023/SC-006/Constitution VI. Scoped out of 013; needs its own investigation and probe run under a separate fix
- [X] T059 Make `Get-CfgWriteRefusalError`'s dedupe and ordering ordinal in `scripts/powershell/lib/Config.psm1:567` — replace `Sort-Object -Unique` with an ordinal sort plus case-sensitive dedupe, matching the `[System.StringComparer]::Ordinal` already used at `:620` — per FR-023 and contract §4 "both ports print the same lines, in the same order" (partial). `Sort-Object -Unique` is culture-sensitive and case-insensitive while bash's `_CFG_WRITE_REFUSAL_JQ:539` uses jq `unique` (ordinal): for the label-shaped paths `Won't Do` and `Won-t Do` the two ports emit the refusal lines in opposite order
- [X] T060 Extend the two-path refusal listing tests — `tests/bash/lib/test_config.bats:465` and `tests/powershell/lib/Config.Tests.ps1:346` — to a path pair whose ordering distinguishes an ordinal from a culture-sensitive comparer (e.g. keys `Won't Do` and `Won-t Do`) per FR-023, contract §4 (missing). Both tests currently use `a` and `b`, which sort identically under either comparer, which is why T059's divergence went undetected
- [X] T061 Update the stale `config_to_yaml` doc comment at `scripts/bash/lib/config.sh:577` — it still states the superseded rule "Refuses (EXIT_CONFIG) a key or string value containing `"` or `\`" directly above code that refuses line breaks only — per FR-025, Constitution XVI (contradicts). T045 corrected the `:514-518` block but missed this second site
- [X] T062 Restore the doc-comment adjacency in `scripts/bash/lib/config.sh`: `_cfg_map_entry_key`'s doc block at `:232-240` is separated from its function at `:267` by `_cfg_decode_escapes` (`:241-263`), so a nine-line comment describing one function now sits directly above another — move the helper above the doc block, or the doc block down to its function, per Constitution XVI (partial)
- [X] T063 Fix the five `actionlint` findings (`.github/workflows/ci.yml:120` SC2046; `.github/workflows/gates.yml:228` SC2018/SC2019 ×4), or record why T047's actionlint clause is out of this feature's scope (contradicts). All five are pre-existing, sit in files 013 did not touch, and no CI job runs actionlint — but T047 names it as a gate and AGENTS.md requires it to stay clean
