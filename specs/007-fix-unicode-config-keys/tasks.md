---

description: "Task list for 007 — The Local Binding Survives Names the Jira Instance Actually Uses"
---

# Tasks: The Local Binding Survives Names the Jira Instance Actually Uses

**Input**: Design documents from `/specs/007-fix-unicode-config-keys/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: REQUIRED and written first. Constitution XIII mandates strict Red-Green-Refactor,
FR-015 requires the regression tests to be observed failing before any fix, and the repository's
bug-fix policy says the same. No implementation task may be started before its test task is
complete and red.

**Organization**: Tasks are grouped by user story. Two constraints override naive independence
and are repeated at every point where they bite:

> **Both ports, one commit.** FR-013 and Constitution VI require the Bash and PowerShell changes
> to land in the *same commit*, byte-identical in behaviour. A `[P]` twin may be *worked* in
> parallel; it may never be *committed* alone.

> **Reader and writer, one change.** FR-005: key quoting on write and key unquoting on read must
> move together, or the round trip stays open — the exact trap the bug report warns about.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different file from its sibling, no dependency on an incomplete task — safe to work concurrently
- **[Story]**: US1, US2, US3 — maps to the user stories in spec.md
- Every task names an exact file path

## Path Conventions

Two mirrored native ports, per plan.md:

- Bash: `scripts/bash/lib/`, `scripts/bash/commands/`, `scripts/bash/hooks/`
- PowerShell: `scripts/powershell/lib/`, `scripts/powershell/commands/`, `scripts/powershell/hooks/`
- Tests: `tests/bash/`, `tests/powershell/`, shared fixtures in `tests/conformance/`

---

## Phase 1: Setup

**Purpose**: establish that today's red is caused by the new tests and nothing else, and that the
suites can carry non-ASCII fixtures without mangling them.

There is no separate "foundational" phase. The one piece of shared parser state this feature adds
— the source line number — is observable only through US2's message, so it is built there, behind
its test (Constitution XIII).

- [X] T001 Capture the green baseline on the unmodified tree: run `bats tests/bash/` and `pwsh -c "Invoke-Pester tests/powershell/"`, and record the summary in the pull request description. Any pre-existing failure must be identified now, so that every red observed in T010 and T024 is attributable to the new tests.
- [X] T002 [P] Confirm the PowerShell test helpers write UTF-8 **without a BOM** when creating fixture files in `tests/powershell/lib/Config.Tests.ps1` (`Set-Content`/`Out-File` calls). A byte-order mark would prefix the first key with U+FEFF and break byte-parity against the Bash port before the parser is ever reached.

**Checkpoint**: baseline recorded; non-ASCII fixtures are safe to introduce.

---

## Phase 2: User Story 1 — A binding written in the instance's own language reads back whole (Priority: P1) 🎯 MVP

**Goal**: a binding whose issue types, priorities and statuses carry the names a real Jira
instance uses — in any script, with ordinary punctuation — survives being written and read back
in full.

**Independent Test**: write the bug report's own binding through `config_to_yaml`, read it back
through `config_yaml_to_json`, and assert the parsed result is identical to the input JSON — every
project, issue type, priority, status and scalar. Today it returns
`{"resolved_ids":{"JET":{"issue_types":{}}}}`.

### Tests for User Story 1 ⚠️ WRITE FIRST, OBSERVE RED

- [X] T006 [US1] Add the reader regression cases (research R7 cases 1-5) to `tests/bash/lib/test_config.bats`: the bug report's full document round-trips; keys in four scripts (`Récit`, `Größe`, `Приоритет`, `完了`) read back; `Done (QA)` and `high/low` read back; a **bare** `Won't Do: "7"` still parses (guards the non-quote-aware bare scan, contract §1.2); `site: https://example.atlassian.net` is still a scalar, not a key (FR-003).
- [X] T007 [P] [US1] Mirror T006 in `tests/powershell/lib/Config.Tests.ps1`, asserting the identical parsed content.
- [X] T008 [US1] Add the writer regression cases (research R7 cases 6 and 11) to `tests/bash/lib/test_config.bats`: keys `Blocked: waiting on QA`, `Sprint # 2`, `- pending` and a whitespace-padded key survive the write→read round trip; a key or string value containing `"` or `\` is refused with a named error and `EXIT_CONFIG` (4), and the offending value is never printed. Depends on T006 (same file).
- [X] T009 [P] [US1] Mirror T008 in `tests/powershell/lib/Config.Tests.ps1`. Depends on T007 (same file).

### Shared conformance fixture ⚠️ AUTHORED NOW, OBSERVES THE SAME RED

The US3 fixture asserts a *valid* unicode binding read end to end. It fails today for the same
reason T006 does, and it goes green with US1 — so it is authored here, before any source change,
as Constitution XIII and plan.md's Implementation Sequence step 1 both require. US3's own phase
keeps only the proof that the suite can now see a defect both ports share (T037).

- [X] T033 [US3] Create the fixture repository `tests/conformance/fixtures/repo-with-unicode-binding/` with `.specify/jira/config.yml` and a `.specify/jira/config.local.yml` carrying the bug report's reproduction — `Récit` beside `Story`, `Élevée`, `À faire`, `Terminé`, `完了`, `Won't Do`, plus `Done (QA)` and `high/low`, and the `style` scalar that the truncation ate. Follow the layout of `tests/conformance/fixtures/repo-with-reconcile-binding/`.
- [X] T034 [US3] Create the scenario `tests/conformance/scenarios/us1-unicode-binding.json` pointing at the T033 fixture, following the schema in `tests/conformance/scenarios/README.md`.
- [X] T035 [US3] Create `tests/bash/conformance/test_us1_unicode_binding.bats`, following the pattern of `tests/bash/conformance/test_us1_style.bats`: drive the scenario through `tests/conformance/run-scenario.sh` for **each** port and assert the capture against the fixture's **expected content** — every key with every expected id — then `diff` the two captures for byte-parity. The content assertion is what makes a shared defect visible; the parity diff alone cannot see one.
- [X] T036 [P] [US3] Create the Pester mirror `tests/powershell/conformance/Us1.UnicodeBinding.Tests.ps1`.

### Red observation for User Story 1

- [X] T010 [US1] **Observe RED**: run `bats tests/bash/lib/test_config.bats`, `bats tests/bash/conformance/test_us1_unicode_binding.bats` and both Pester mirrors; record the failures in the pull request description, including the truncated `{"resolved_ids":{"JET":{"issue_types":{}}}}` from the reproduction case and the conformance capture showing the same truncation on both ports. This is the evidence Constitution XIII requires for US1 **and** for research R7 case 12; no US1 implementation task may start before it exists.

### Implementation for User Story 1

- [X] T011 [US1] Implement the mapping-key grammar of `contracts/yaml-key-grammar.md` §1 in `scripts/bash/lib/config.sh`: rewrite `_cfg_is_map_entry` to locate a delimiter colon by structure (quoted-key path chosen by the line's first character; otherwise a **non**-quote-aware scan for the first `:` followed by whitespace or end of line), and rewrite key extraction in `_cfg_parse_mapping` — which today does `key="${content%%:*}"` and never unquotes — to take the key from that same scan and strip the surrounding quotes when present. **Do not** make the `_cfg_is_map_entry` call inside `_cfg_parse_sequence` fatal or quote-stripping: it is a dispatch deciding whether `- x` opens a mapping, and `- jira` must stay a plain scalar item (contract §1.4).
- [X] T012 [P] [US1] Mirror T011 in `Test-CfgMapEntry` and `Read-CfgMapping` in `scripts/powershell/lib/Config.psm1`, with the same guard on the `Read-CfgSequence` dispatch site.
- [X] T013 [US1] Quote every key on write in `scripts/bash/lib/config.sh`: emit `"<key>": <value>` from `_CFG_YAML_EMIT_JQ`/`config_to_yaml` unconditionally (contract §2.1), preserving ordinal key sorting and byte-determinism, and refuse a key or string value containing `"` or `\` with a named error naming the path (never the value) and `EXIT_CONFIG` (contract §2.3). Must land with T011 — FR-005.
- [X] T014 [P] [US1] Mirror T013 in `Write-CfgYamlNode`/`ConvertTo-JiraConfigYaml` in `scripts/powershell/lib/Config.psm1`.
- [X] T015 [US1] Update the stale documentation in `scripts/bash/lib/config.sh`: the module header (lines 1-19) describing the accepted subset, and the writer's comment block (lines ~298-308) which states that keys are "emitted plain (the reader does not accept quoted keys)" and that the subset "carries no `"`/`\` in keys or values" as an unchecked assumption. Both are now false.
- [X] T016 [P] [US1] Mirror T015 in the header and writer comments of `scripts/powershell/lib/Config.psm1`.
- [X] T017 [US1] Verify writer byte-parity across ports per `quickstart.md` Check 2: `config_to_yaml` and `ConvertTo-JiraConfigYaml` must emit identical bytes for the reproduction document. Confirm the existing determinism tests in `tests/bash/commands/test_config_determinism.bats` are still green — they assert run-to-run and port-to-port identity, not literal bytes, so quoted keys must not disturb them.

**Checkpoint**: US1 complete. The reported data loss is gone, but a malformed line is still discarded silently — US2 closes that.

---

## Phase 3: User Story 2 — A line the reader cannot interpret is reported, never discarded (Priority: P1)

**Goal**: an uninterpretable line fails closed with a located, actionable message, and no caller
ever receives a partial configuration.

**Independent Test**: feed the reader a file with an uninterpretable line at a mapping level;
assert exit 4, nothing on stdout, and three stderr lines naming the file, the line number, the
content and the remediation. Today this exits 0 with a silently truncated document.

**Depends on**: US1 — it shares `_cfg_parse_mapping` / `Read-CfgMapping` and the same test files;
see Dependencies below. The line-number array this story's message needs (T003/T004) is built
inside this phase, after T024, because T018 is the only test that observes it.

### Tests for User Story 2 ⚠️ WRITE FIRST, OBSERVE RED

- [X] T018 [US2] Add the fail-closed cases (research R7 cases 7, 8, 13 and 14) to `tests/bash/lib/test_config.bats`: a malformed line yields `EXIT_CONFIG` (4), empty stdout, and the exact three-line message of `contracts/parse-failure.md` §2; the reported line number counts blank and comment lines discarded by `_cfg_prep`; a `- jira` sequence item is **not** a failure; a malformed line whose text carries an Atlassian token prefix, an `*.atlassian.net` host and an email address is reported with each of the three replaced by `[redacted]` and the file path and line number intact (`parse-failure.md` §2.1, FR-009, Constitution IV); and a key repeated at the same mapping level fails with the duplicate-key message naming both line numbers, while the same key at two different levels stays legal (`yaml-key-grammar.md` §1.5, FR-016). Depends on T008 (same file).
- [X] T019 [P] [US2] Mirror T018 in `tests/powershell/lib/Config.Tests.ps1`, asserting byte-identical message text — both the redacted form and the duplicate-key form — and the same exit code. Depends on T009 (same file).
- [X] T020 [US2] Add the zero-writes case (research R7 case 9) to `tests/bash/commands/test_reconcile_diagnostics.bats`: reconcile against a repository whose `config.local.yml` is unreadable performs **zero** Jira writes and exits 4 — and does **not** report the project as unbound, which is the downstream symptom in the bug report.
- [X] T021 [P] [US2] Mirror T020 in `tests/powershell/commands/Reconcile.Diagnostics.Tests.ps1`.
- [X] T022 [US2] Add the non-blocking case (research R7 case 10) to `tests/bash/hooks/test_hook_resilience.bats`: with an unreadable binding, an `after_*` hook leaves the host spec-kit command's exit code at 0 and emits exactly one `WARNING:` line preceded by the three failure lines (FR-011, Constitution III).
- [X] T023 [P] [US2] Mirror T022 in `tests/powershell/hooks/HookResilience.Tests.ps1`.
- [X] T024 [US2] **Observe RED**: run all four suites and record the failures in the pull request description. No US2 implementation task may start before it exists.

### Implementation for User Story 2

- [X] T003 [US2] Add the `_cfg_linenos` parallel array to `_cfg_prep` in `scripts/bash/lib/config.sh`, recording each retained line's 1-based number **in the source file** (blank lines and comment lines are dropped from the retained arrays but still count). Reset it alongside `_cfg_indents` and `_cfg_lines`. This is what makes T018's line-number assertion satisfiable; it lands **after** that test is red, not before (Constitution XIII).
- [X] T004 [P] [US2] Mirror T003 as `$script:CfgLineNos` in `Read-CfgPrep` in `scripts/powershell/lib/Config.psm1`.
- [X] T005 [US2] Re-run `bats tests/bash/lib/test_config.bats` and `pwsh -c "Invoke-Pester tests/powershell/lib/Config.Tests.ps1"`: T003/T004 must change no behaviour. The T001 baseline cases and every US1 case stay green, and the T024 red cases stay red — a case that flips either way means the line-number array is being read somewhere it should not be yet.
- [X] T025 [US2] Replace `_cfg_is_map_entry "${content}" || break` in `_cfg_parse_mapping` (`scripts/bash/lib/config.sh`) with a raise: set `_CFG_ERR` to the formatted three-line message using `_cfg_linenos`, and have every parser loop (`_cfg_parse_mapping`, `_cfg_parse_sequence`, `_cfg_parse_value`) return immediately when it is set. `config_yaml_to_json` prints it to stderr, prints nothing to stdout, and returns `EXIT_CONFIG`. The two legitimate mapping boundaries — a change of indent and a sequence marker — are already tested before this point and must keep breaking normally (FR-012). Two rules travel with the raise: redact `<content>` per `contracts/parse-failure.md` §2.1 before formatting the message (the pre-write credential scan cannot cover this path — it runs on a parsed document, and there is none), and keep a per-frame `_cfg_seen` set of keys so a repeat at the same mapping level raises the duplicate-key message naming both lines (`yaml-key-grammar.md` §1.5, FR-016). The set is scoped to the frame — `"statuses"` under two different project keys is legal and common. Bash ≥ 4 is already a hard prerequisite (`scripts/bash/lib/prereq.sh:76`), so an associative array is available.
- [X] T026 [P] [US2] Mirror T025 — raise, redaction and `$script:CfgSeen` — in `Read-CfgMapping`/`ConvertFrom-JiraConfigYaml` in `scripts/powershell/lib/Config.psm1` using a `$script:CfgErr` flag — **not** `throw`. A `throw` on one port and a flag on the other unwind differently and reorder stderr, which is precisely the divergence Constitution VI forbids.
- [X] T027 [US2] Stop swallowing the failure in `scripts/bash/lib/config.sh` (research R5): in `_cfg_local_json` drop the `2>/dev/null || printf '{}'` so that only an **absent** file yields `{}` while a present-but-unreadable file propagates, and rewrite the comment that promises "Never fails: a broken local binding must not break mirroring" — that promise is the defect; propagate in `config_hooks_disabled_read` (an unreadable binding is not evidence that no hook is disabled — Constitution X); and let the located message through in `config_personal_load` in place of its generic "not valid personal YAML".
- [X] T028 [P] [US2] Mirror T027 at the twin sites in `scripts/powershell/lib/Config.psm1`.
- [X] T029 [US2] Propagate in `_reconcile_local_binding_for` in `scripts/bash/commands/reconcile.sh`: an unreadable binding must fail closed with zero Jira writes, distinct from return code 2 (never bound) and 3 (bound, no entry for this project).
- [X] T030 [P] [US2] Mirror T029 in `scripts/powershell/commands/Reconcile.psm1`.
- [X] T031 [US2] Surface the located message in `register_hooks_health` in `scripts/bash/hooks/register_hooks.sh`, replacing the generic "not valid YAML in this reader's subset". The existing `EXIT_CONFIG` return is already fail-closed and does not change.
- [X] T032 [P] [US2] Mirror T031 in `scripts/powershell/hooks/RegisterHooks.psm1`.

**Checkpoint**: US1 + US2 complete — this is the shippable increment. The data loss is fixed and no future parser gap can hide.

---

## Phase 4: User Story 3 — The conformance suite can catch a defect both ports share (Priority: P2)

**Goal**: prove the property, now that the fixture authored in Phase 2 is green.

**Independent Test**: apply the fix to one port only and run the shared suite; it must fail. Apply
to both; it must pass.

**Depends on**: US1 and US2 complete. The fixture, the scenario and the two test files were
authored in Phase 2 (T033-T036) and observed red in T010 — this phase is verification only.

- [X] T037 [US3] **Verify SC-005**: revert T011/T013 in the Bash port only — `git stash push -- scripts/bash/lib/config.sh` — run `bats tests/bash/conformance/test_us1_unicode_binding.bats` and confirm it fails on both the content assertion and the parity diff; then `git stash pop` and re-run the suite green before continuing, so a failed restore cannot pass unnoticed. This proves the suite can now see a defect the two ports share — the property whose absence let this bug ship.

**Checkpoint**: all three stories complete.

---

## Phase 5: Polish & Cross-Cutting Concerns

- [X] T038 Add an "If a configuration file cannot be read" section to `README.md`, beside the existing "If the lifecycle hooks do not see your variables" section: the three-line message, exit code 4, and the remediation. No exit-code documentation exists in the repository today, and FR-008 requires the code to be documented.
- [X] T039 [P] Add the fix to the `[Unreleased]` section of `CHANGELOG.md` under `Fixed`, naming the data-loss symptom and the silent-truncation behaviour as two distinct entries (Constitution XII).
- [X] T040 Sweep `tests/` for any assertion on the writer's literal output bytes that the key quoting of T013/T014 would invalidate. The known consumers — `tests/bash/commands/test_config_determinism.bats`, `tests/bash/hooks/test_register_hooks.bats`, `tests/bash/commands/test_config_incremental.bats` — assert round-trip or port-parity rather than literal bytes and are expected to stay green; confirm rather than assume. Test files that write **bare-key** YAML as parser *input* must be left alone: they are the regression guard for contract §1.2.
- [X] T041 Run every check in `quickstart.md` (Checks 1-11) and record the results in the pull request description.
- [X] T042 [P] Verify statement coverage stays at or above 80% for both ports (kcov for Bash, Pester CodeCoverage for PowerShell) — the blocking gate of Constitution XIII.
- [X] T043 [P] Verify both suites stay green under parallel execution (`bats --jobs 4 tests/bash/`), and that no test added by this feature locates a file or process by name pattern rather than by a path it created itself (Constitution XIII, test isolation).
- [ ] T044 Dogfood against the real Jira instance whose names exposed the defect: run `/speckit.jira.config` and confirm the written `config.local.yml` reads back complete (Constitution XII).
- [ ] T045 [P] Confirm FR-006 on the real artefact: after T044, open the written `.specify/jira/config.local.yml` and confirm a reviewer can state its key rule without opening the source — every key double-quoted, every string value double-quoted, one entry per line. Paste the file into the pull request description with ids only: no site URL, no account identifier (Constitution IV).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies.
- **Phase 2 (US1)**: after Setup. It also carries the US3 fixture and conformance tests
  (T033-T036): they fail today for the US1 reason and go green with US1, so authoring them here
  is what lets them be observed red at all (Constitution XIII, FR-015). Deferring them until
  after the fix would make R7 case 12's red unobservable.
- **Phase 3 (US2)**: after US1 — same files, see the honest caveat below. `_cfg_linenos`
  (T003/T004) is built inside this phase, after the T024 red, because T018 is the only test that
  observes it; building it earlier would place implementation before its test.
- **Phase 4 (US3)**: after US1 and US2. Verification only (T037).
- **Phase 5 (Polish)**: after all three stories.

### The caveat: US1 and US2 are not file-independent

The template's usual promise — stories developed in parallel by different people — **does not hold
here**, and pretending otherwise would produce merge conflicts:

- T011 (US1) and T025 (US2) both rewrite the same lines of `_cfg_parse_mapping` in
  `scripts/bash/lib/config.sh`; T012 and T026 do the same to `Read-CfgMapping`.
- T006/T008 (US1) and T018 (US2) all edit `tests/bash/lib/test_config.bats`; likewise
  T007/T009/T019 in `Config.Tests.ps1`.

The specification says as much: the two stories are "inseparable", both P1. **Work them
sequentially, in one worktree, US1 then US2.** US1 remains independently *testable* and
independently *valuable* — it fixes the reported data loss — which is what the MVP framing needs.
It is not independently *stageable* alongside US2.

### Within each story

1. Tests written → observed RED (T010, T024) → implementation.
2. Reader and writer land together (T011+T013, T012+T014) — FR-005.
3. Bash and PowerShell land in the same commit (every `[P]` twin) — FR-013.

### Parallel Opportunities

Genuine, and confined to Bash/PowerShell twins on different files:

- T006 ‖ T007, then T008 ‖ T009 (US1 tests)
- T035 ‖ T036 (conformance tests, authored inside US1)
- T011 ‖ T012, T013 ‖ T014, T015 ‖ T016 (US1 implementation)
- T018 ‖ T019, T020 ‖ T021, T022 ‖ T023 (US2 tests)
- T003 ‖ T004 (parser state, inside US2 implementation)
- T025 ‖ T026, T027 ‖ T028, T029 ‖ T030, T031 ‖ T032 (US2 implementation)
- T039, T042, T043, T045 (independent polish)

Not parallel, despite appearances: T006 and T008 (same bats file); T011 and T013 (same
`config.sh`, and FR-005 requires them in one change); anything in US1 against anything in US2.

---

## Parallel Example: User Story 1 implementation

```bash
# The two ports of the reader grammar — different files, one commit:
Task: "T011 Implement the key grammar in scripts/bash/lib/config.sh"
Task: "T012 Mirror the key grammar in scripts/powershell/lib/Config.psm1"

# Then the two ports of the writer — again different files, again one commit,
# and in the SAME commit as T011/T012 (FR-005: reader and writer move together):
Task: "T013 Quote every key in scripts/bash/lib/config.sh"
Task: "T014 Mirror key quoting in scripts/powershell/lib/Config.psm1"
```

---

## Implementation Strategy

### MVP

**Phase 1 → Phase 2 (US1)**, then stop and validate: the bug report's document round-trips whole
on both ports, in the unit suites and through the conformance scenario.

US1 alone is a genuine increment — it removes the reported data loss. But it is not what should
ship: with US1 only, the next parser gap disappears just as silently as this one did. The
specification's own framing is that fixing the character set without fixing the silence "leaves
the failure mode in place".

### Shippable increment

**US1 + US2.** Both are P1. This is the recommended scope for the pull request.

### Full delivery

Add **US3**, which converts the fix into a guarantee: without it, the next defect that both ports
share passes the conformance suite exactly as this one did.

---

## Notes

- `[P]` = different file, no incomplete dependency. It never authorises a separate commit for one port.
- Constitution XIII is a gate, not a style: T010 and T024 produce the red evidence, and no implementation task in their phase may start before that evidence exists.
- No new exit code is introduced. `EXIT_CONFIG` (4) already covers configuration faults, so the monotonic escalation of the existing table (Constitution III) stays intact.
- Backward compatibility and migration are out of scope. The reader keeps accepting bare keys because the committable `config.yml` and the host's PyYAML-written `extensions.yml` use them — not to read files this extension wrote before the change.
