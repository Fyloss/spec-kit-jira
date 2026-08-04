---
description: "Task list for A Fresh Install Runs Immediately — No Permission Step, Ever"
---

# Tasks: A Fresh Install Runs Immediately — No Permission Step, Ever

**Input**: Design documents from `/specs/014-fix-install-exec-bit/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/bridge-invocation.md, quickstart.md

**Tests**: Requested. Constitution Principle XIII (TDD) and the plan's Implementation sequence
require the new/superseded tests to land, and fail, before any port edit.

**Organization**: Tasks are grouped by user story (US1–US4) so each is independently completable
and testable. The predicate shared by every story (`prereq_bridge_missing` /
`Get-JiraMissingBridgeEntry`) sits in Foundational because all four stories depend on it directly.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: which user story the task belongs to (US1, US2, US3, US4)
- File paths are exact; line numbers are current-tree references, not guarantees the edit lands there

---

## Phase 1: Setup

- [X] T001 Reproduce the defect by hand per `quickstart.md` Step 0 (install `--dev`, `chmod a-x` the
      Bash entry point, run `bash .../spec-kit-jira.sh --help`) and confirm it fails on the current
      tree with "not found or is not executable", exit code 5. This is the gate: if it passes now,
      every test below is reproducing the wrong thing.

**Checkpoint**: Defect confirmed reproducible. Proceed to Foundational.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Land the failing tests that supersede the old contract, then fix the one predicate all
four user stories depend on. Ordering matters (Constitution XIII): the suite must go red for exactly
one reason — the ports not yet changed — before any port edit.

- [X] T002 [P] In `tests/bash/conformance/test_us4_bridge_runnable.bats`, delete the assertion at
      lines 51-59 that `./${BASH_ENTRY} --help` works with "no `bash` prefix", and delete the
      "arrives EXECUTABLE" assertion at lines 61-67 (research R5). Replace both with: (a) the
      mode-stripped reproduction — `harness_install`, `chmod a-x` on the installed Bash entry point,
      run `bash "${REPO}/${BASH_ENTRY}" --help`, require exit 0 — and (b) an equivalence assertion
      covering **every declared subcommand**, not `--help` alone: for each of `--help`,
      `config --dry-run`, `feature --dry-run`, `reconcile --dry-run` and `mention --dry-run` (the set
      `spec-kit-jira.sh:38` declares and C2's rule enumerates), the same command run against a `0644`
      entry point and against a `0755` one must produce byte-identical stdout, byte-identical stderr
      and the same exit code (FR-009, SC-003, C7, research R7). On an unconfigured scratch repository
      most of these exit on a degraded cause — that is fine and is the point: a degraded-cause path is
      exactly as mode-independent as a successful one, and asserting on it needs neither credentials
      nor network. Confirm both new cases fail on the current tree.
- [X] T003 [P] In `tests/bash/lib/test_prereq.bats`, add a new case: with both entry points present
      but the Bash one `chmod a-x`'d, `prereq_bridge_missing` returns empty (C6.3). Confirm it fails
      on the current tree.
- [X] T004 [P] In `tests/bash/ci/test_agent_doc_invocation.bats`, delete the `-x` assertion at line 75
      ("the Bash entry point executable"). Add the C2 rule instead: wherever
      `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` is followed on the same line by
      whitespace and one of `config|reconcile|mention|feature|--help`, it must be immediately preceded
      by `bash `; any other occurrence must not be prefixed. **Scope: `commands/*.md` only** — this
      suite's `DOCS` array (lines 19-20) walks nothing else, so `README.md`, `INSTALL.md` and
      `templates/readme-block.template` are T005's job, not this one. Confirm the new assertion fails
      today (the fenced examples do not yet carry the prefix).
- [X] T005 [P] In `tests/bash/ci/test_message_command_literals.bats`, delete the `-x` assertion at
      line 106, keeping the `-f` existence assertions at lines 102-103. Then add the C2 rule as a new
      test over the file set this suite already walks (`scripts/bash/**`, `templates/*.template`,
      `commands/*.md`, `README.md`, `INSTALL.md` — lines 38-41): wherever
      `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` is followed on the same line by
      whitespace and one of `config|reconcile|mention|feature|--help`, it MUST be immediately preceded
      by `bash `; any other occurrence MUST NOT be. This is the **only** automated enforcement covering
      T014-T016 (`README.md`, `INSTALL.md`, `readme-block.template`), which is why it lands here and
      not in `test_agent_doc_invocation.bats`. Confirm it fails today.
- [X] T005A [P] In `tests/bash/ci/test_message_command_literals.bats`, add the FR-005/SC-002 sweep as
      an automated test over the shipped surface this suite already walks: no file under
      `scripts/bash/**`, `templates/*.template`, `commands/*.md`, `README.md` or `INSTALL.md` may
      match `chmod|not executable|executable bit`, with exactly one named exemption — `README.md`'s
      `chmod 600 .specify/jira/.env`, the credential-secrecy control FR-005 exempts by name. In the
      same test, assert neither port ever changes a file mode (`chmod` in Bash, `Set-ItemProperty` /
      `UnixFileMode` in PowerShell) — FR-008, which otherwise ships with no test at all. The
      PowerShell mirror (T007) carries the same sweep over `scripts/powershell/**`. Confirm it fails
      today: `prereq.sh:28,33,100,105`, `reconcile.sh:436`, the three command documents,
      `Prereq.psm1:39,94`, `Reconcile.psm1:536`.
- [X] T006 [P] In `tests/bash/ci/test_agent_fallback_block.bats`, rewrite the verbatim `BLOCK` fixture
      (line ~37) to drop "or is not executable" per C4. Then replace the assertion at line 74 — which
      currently *requires* that clause — with a whole-document assertion: no command document may
      contain `is not executable` or `executable bit` anywhere, block, lead-in prose or table row
      alike (FR-005). Confirm it fails against the current command documents.
- [X] T007 [P] Mirror T002–T006 in PowerShell: `tests/powershell/conformance/Us4.BridgeRunnable.Tests.ps1`,
      `tests/powershell/lib/Prereq.Tests.ps1` (C6.3 case — PowerShell never had the clause, so this
      pins the already-correct behaviour), `tests/powershell/ci/AgentDocInvocation.Tests.ps1`,
      `tests/powershell/ci/MessageCommandLiterals.Tests.ps1` (delete the `-x`-equivalent assertion if
      present; add the C2 rule over the same file set **plus** `scripts/powershell/**`, and the T005A
      sweep), `tests/powershell/ci/AgentFallbackBlock.Tests.ps1`.
- [X] T008 In `scripts/bash/lib/prereq.sh`, delete the `-x` clause from `prereq_bridge_missing`
      (lines ~56-61) so it only ever checks `-f` on both entry points, per C6.1-C6.4, **and correct
      the three comments that still describe the deleted check** — lines 28 ("or not executable"),
      33 ("lost its executable bit") and 100 ("a lost file or a lost executable bit"). T005A is red
      until they go; Principle XVI wants them corrected deliberately rather than swept up in Phase 6.
      Bash suite is now red for exactly one remaining reason per test file.
- [X] T009 [P] In `scripts/powershell/lib/Prereq.psm1`, `Get-JiraMissingBridgeEntry` already matches
      C6 (no `-x`-equivalent clause exists in PowerShell); delete the stale exec-bit doc paragraph
      near line 39 that describes a check this function never performs (research R4).

**Checkpoint**: The core detection predicate is an exact mirror on both ports and the new/updated
tests are red for the right reason (message text and invocation prefix, not the predicate). User
stories can now proceed.

---

## Phase 3: User Story 1 - Install, then run — nothing in between (Priority: P1) 🎯 MVP

**Goal**: A fresh install, by the route that strips file modes, runs the documented verification
command successfully with no permission step, on the oldest supported host.

**Independent Test**: Install onto a clean repository, strip the Bash entry point's mode, run the
documented verification command — it succeeds (quickstart Step 0, post-fix expectation).

### Implementation for User Story 1

- [X] T010 [US1] In `scripts/bash/lib/output.sh`, add the `bash ` prefix at the invocation seam in
      `output_bridge_invocation` (line ~103/112) so it emits
      `bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh <args> (on Windows: …)` per C3.
- [X] T011 [US1] In `scripts/bash/lib/prereq.sh` (line ~105), drop "or is not executable" from the
      degraded-cause message so it reads: `spec-kit-jira: the bridge entry point <path> was not
      found — the extension install is incomplete. Restore it with: …` (C5, site 1).
- [X] T012 [P] [US1] In `scripts/powershell/lib/Output.psm1`, add the `bash ` prefix to the string
      `Get-JiraBridgeInvocation` (line ~160) returns for the Bash entry, mirroring T010 byte for byte.
- [X] T013 [P] [US1] In `scripts/powershell/lib/Prereq.psm1` (line ~94), drop "or is not executable"
      from the `Write-Warning` message, mirroring T011.
- [X] T014 [US1] Update the two verification commands in `README.md` (lines ~109, ~206) to gain the
      `bash ` prefix.
- [X] T015 [US1] Update the verification command in `INSTALL.md` (line ~154) to gain the `bash `
      prefix.
- [X] T016 [US1] Update the invocation in `templates/readme-block.template` (line ~64) to gain the
      `bash ` prefix, since it lands verbatim in every consumer's managed README block (research R9).
- [X] T017 [US1] Run `tests/run-bash.sh --since main` and `bats -r tests/bash/conformance/test_us4_bridge_runnable.bats`;
      confirm green. Run quickstart Step 2 (`chmod 755` vs `chmod 644`, diff the two captures) and
      confirm they are byte-identical.

**Checkpoint**: User Story 1 fully functional and independently testable — a mode-stripped install
runs on the first documented command.

---

## Phase 4: User Story 2 - The lifecycle hooks mirror on a permission-stripped tree (Priority: P1)

**Goal**: The automated hook-driven mirror (`reconcile`) is never blocked by a stripped file mode,
and the bridge-unavailable fallback the assistant reads stops mentioning permissions.

**Independent Test**: On a permission-stripped install with hooks registered, a lifecycle event fires
and the mirror completes with its normal run summary; a second, unchanged run writes nothing.

### Implementation for User Story 2

- [X] T018 [US2] In `scripts/bash/commands/reconcile.sh` (line ~436), drop "or is not executable"
      from the degraded-cause notice: `Jira mirror skipped: the bridge entry point <path> was not
      found; the extension install is incomplete. This spec-kit command completed normally and
      nothing was mirrored to Jira. Restore it with: …` (C5, site 2).
- [X] T019 [P] [US2] In `scripts/powershell/commands/Reconcile.psm1` (line ~536), mirror T018 in the
      `Write-JiraReconcileNotice` call.
- [X] T020 [US2] Remove "or is not executable" from **every** occurrence in the three command
      documents, not only the C4 verbatim block. Five sites, measured on the current tree: the
      "When the entry point is not found or is not executable" lead-in at
      `commands/speckit.jira.config.md:49`, `commands/speckit.jira.feature.md:40` and
      `commands/speckit.jira.reconcile.md:91`; the degraded-cause table row at
      `commands/speckit.jira.reconcile.md:83` ("or exists but is not executable"); and the block
      itself in all three (`config.md:57`, `feature.md:48`, `reconcile.md:99`), rewritten per C4.
      Depends on T006 being red first.
- [X] T021 [P] [US2] In the same three command documents, add the `bash ` prefix to every fenced
      *invocation* example while leaving the host-selection table rows and the fallback block bare
      (C2): `speckit.jira.config.md` lines ~40 and ~113, `speckit.jira.feature.md` line ~67,
      `speckit.jira.reconcile.md` line ~45.
- [X] T022 [US2] Run `bats -r tests/bash/ci/test_agent_fallback_block.bats tests/bash/ci/test_agent_doc_invocation.bats`
      and the PowerShell mirrors; confirm green. Manually fire a lifecycle hook on a mode-stripped
      install twice and confirm the second run writes nothing (quickstart-equivalent to Step 8, US2
      scenario 2).

**Checkpoint**: The hook-driven mirror path is unaffected by file mode, and the fallback prose
matches C4 in both ports.

---

## Phase 5: User Story 3 - An already-broken install heals by upgrading, and nothing else (Priority: P2)

**Goal**: A tree already stuck in the broken state becomes fully functional through the ordinary
extension upgrade alone — no manual command before or after it, on this upgrade or any future one.

**Independent Test**: Take a tree in the broken state, upgrade through the host's normal update
path, and run every documented command with no permission step before or after (quickstart Step 7).

### Implementation for User Story 3

- [X] T022A [US3] In `tests/bash/ci/test_manifest_hooks.bats` and
      `tests/powershell/ci/Manifest.Hooks.Tests.ps1`, add an assertion pinning
      `requires.speckit_version` in `extension.yml` (line ~30) to `>=0.13.0` — FR-010 forbids
      satisfying this feature by raising the floor, and T023 edits that very file. Unlike T002-T007
      this test is **green on the day it is written**: it is a regression pin, not a red-first test,
      and Constitution XIII's failing-test-first rule does not reach behaviour the feature leaves
      unchanged. It must land before T023.
- [X] T023 [US3] Bump the version in `extension.yml` (line ~17) — the single source of truth for the
      release that carries this fix. Do not touch `requires.speckit_version`; T022A now fails if it
      moves (FR-010).
- [X] T024 [US3] Add a `CHANGELOG.md` entry describing the fix and explicitly naming the manual
      `chmod` workaround consumers can now drop.
- [X] T025 [US3] Run quickstart Step 7 by hand: `specify extension add jira --from
      https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip` on a host below the
      version that restores file modes; confirm the entry point lands `0644` and the verification
      command still succeeds. If no such host is available, record that explicitly rather than as a
      pass (risk noted in plan.md).

**Checkpoint**: A tree in the pre-fix broken state is proven to heal via upgrade alone, and the
release surface names the fix for consumers already working around it.

---

## Phase 6: User Story 4 - Diagnostics stay honest (Priority: P2)

**Goal**: A genuinely absent entry point is still reported as its own named cause with a working
remedy, and no shipped message, command document or installation document mentions permissions to
make the bridge runnable.

**Independent Test**: Delete one port's entry point, run the bridge, and confirm the reported cause
names that file and offers a remedy that works (quickstart Step 3); confirm no surviving permission
wording anywhere except the credentials-file secrecy control (quickstart Step 4, SC-002).

### Implementation for User Story 4

- [X] T026 [US4] Add a one-line supersession pointer in
      `specs/003-install-hook-activation/contracts/reconcile-command.md` pointing at this feature's
      `contracts/bridge-invocation.md`, so the old "was not found or is not executable" wording is
      never "restored" later as a mistaken regression fix (research R5).
- [X] T027 [US4] Confirm T005A is green in both ports, then run the sweep once by hand exactly as
      quickstart Step 4 spells it: `grep -rniE 'chmod|not executable|executable bit' commands/
      scripts/ templates/ README.md INSTALL.md`. The only hit must be `README.md`'s
      `chmod 600 .specify/jira/.env` (the credentials-secrecy control FR-005 exempts by name). A hand
      run that disagrees with the automated test means the test's file set is wrong, not the tree.
- [X] T028 [US4] Manually verify FR-004/US4 acceptance scenario 1: `mv
      .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1{,.bak}`, run the Bash entry
      point, confirm the PowerShell path is named as its own degraded cause, the message says "was
      not found" with no permission clause, and the spec-kit command still completes normally.
      Restore the file afterwards.

**Checkpoint**: Diagnostics remain honest for a genuinely broken install, and zero permission
instructions survive anywhere in the shipped tree.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T029 [P] Update the sequence-diagram label in `docs/03-lifecycle-hooks.md` (line ~91) to match
      the new invocation spelling (dev-only document, excluded from the install).
- [X] T030 Run `shellcheck $(git ls-files '*.sh')` and `actionlint`; both must stay clean.
- [X] T031 Run `tests/run-bash.sh` (full suite, ~3m10s) and `pwsh -c 'Invoke-Pester tests/powershell'`;
      both green with the install-harness tests **run**, not skipped.
- [X] T032 Run `bash tests/conformance/ci-conformance.sh`; confirm exit 0 and zero lines containing
      "conformance divergence".
- [X] T033 Run quickstart Step 8 on a configured consumer repository: `/speckit.jira.config` twice
      after upgrade — first run rewrites the managed README block, second run writes nothing.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS all user stories — T008/T009 (the predicate
  fix) must land after T002–T007 including T005A (the failing tests) are confirmed red, per
  Constitution XIII.
- **User Stories (Phase 3-6)**: All depend on Foundational completion. US1 and US2 are both P1 and
  touch disjoint files (`output.sh`/`prereq.sh` vs `reconcile.sh`/command docs' fallback block) so
  they can proceed in parallel. US3 and US4 are P2 and have no code dependency on US1/US2 beyond the
  Foundational predicate, but are ordered after for narrative priority.
- **Polish (Phase 7)**: Depends on all four user stories being complete.

### User Story Dependencies

- **US1 (P1)**: Depends only on Foundational. No dependency on other stories.
- **US2 (P1)**: Depends only on Foundational. Shares the command documents with US1's fenced
  examples (T021 touches the same three files as T020) but different lines — sequence T020 before
  T021 within US2 to keep each commit's diff legible.
- **US3 (P2)**: Depends only on Foundational; independently testable via the upgrade path alone.
  Within the story, T022A (the FR-010 manifest pin) precedes T023 (the version bump) — they edit the
  same file and the pin exists to guard that edit.
- **US4 (P2)**: Depends only on Foundational; T027's sweep is more informative after US1/US2's
  message edits land, but does not require them to complete first.

### Within Each User Story

- Tests (Foundational T002-T007, T005A included) precede all implementation, and must fail before the
  corresponding fix lands. T022A is the one exception and says so in its own text: it pins behaviour
  this feature does not change, so it is green from the moment it is written.
- Bash port edit precedes its PowerShell mirror in each pair (T010→T012, T011→T013, T018→T019),
  matching the plan's Implementation sequence step 3 before step 4.
- Each story's validation run is its last task.

### Parallel Opportunities

- All of T002-T007 run in parallel (different files, all additive test edits). T005 and T005A share
  `test_message_command_literals.bats`: they add two independent tests to one file, so run them
  together as a single edit rather than as two concurrent ones.
- T009 runs in parallel with T008 (different ports, no shared file).
- T012/T013 run in parallel with each other and with T014-T016 (different files).
- T019 runs in parallel with T018.
- T021 runs in parallel with T020 only if applied as a separate commit hunk on the same files — treat
  as sequential in practice to avoid merge noise within US2.
- T029 runs in parallel with T030-T033.

---

## Parallel Example: Foundational Phase

```bash
# Launch the five failing-test tasks together (different files):
Task: "Rewrite test_us4_bridge_runnable.bats mode-stripped reproduction + per-subcommand equivalence"
Task: "Add C6.3 present-but-non-executable case to test_prereq.bats"
Task: "Replace -x assertion with C2 prefix rule in test_agent_doc_invocation.bats (commands/ only)"
Task: "Delete -x assertion, add C2 rule + SC-002/FR-008 sweep in test_message_command_literals.bats"
Task: "Rewrite verbatim fixture + whole-document clause check in test_agent_fallback_block.bats"
```

## Parallel Example: User Story 1

```bash
# Launch the PowerShell mirror and the shipped-document updates together (different files):
Task: "Add bash prefix in Output.psm1's Get-JiraBridgeInvocation"
Task: "Drop 'or is not executable' in Prereq.psm1's Write-Warning"
Task: "Add bash prefix to README.md's two verification commands"
Task: "Add bash prefix to INSTALL.md's verification command"
Task: "Add bash prefix to templates/readme-block.template"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (confirm the defect reproduces).
2. Complete Phase 2: Foundational (failing tests, then the shared predicate fix — CRITICAL, blocks
   every story).
3. Complete Phase 3: User Story 1.
4. **STOP AND VALIDATE**: quickstart Steps 0-2 pass; a mode-stripped install runs the documented
   verification command successfully.
5. Ship if ready — this alone closes the reported defect for the direct-invocation path.

### Incremental Delivery

1. Setup + Foundational → predicate fixed on both ports, old contract superseded.
2. Add US1 → verify independently → the direct-invocation path is fixed (MVP).
3. Add US2 → verify independently → the hook-driven mirror path is fixed and the fallback prose is
   honest.
4. Add US3 → verify independently → an already-broken tree heals by upgrade alone.
5. Add US4 → verify independently → diagnostics stay honest and zero permission wording survives.
6. Polish → lint, full suites, cross-port conformance, README-block idempotency.

### Parallel Team Strategy

With two people: one takes US1 (core Bash/PowerShell fix + shipped verification docs), the other
takes US2 (reconcile message + fallback block + command-doc fenced examples) — both depend only on
Foundational and touch disjoint lines. US3 and US4 are small enough for either person to pick up
after US1/US2 land.

---

## Notes

- [P] tasks touch different files with no unresolved dependency between them.
- [Story] labels map every Phase 3-6 task to spec.md's US1-US4 for traceability.
- Verify each new/rewritten test fails before implementing the corresponding fix (Constitution XIII).
- No task in this feature adds a file, a command, or a config key — every implementation task edits
  an existing line (plan.md's Project Structure is the exhaustive blast radius).
- Commit per phase where practical; Foundational should land as one commit per plan.md's
  Implementation sequence step 2 (supersede) followed by step 2's predicate fix, so the suite is red
  for exactly one reason at every intermediate point.

---

## Phase 8: Convergence

- [X] T034 Create `specs/014-fix-install-exec-bit/quickstart-results.md` recording the outcome of
      every quickstart step, following the convention set by
      `specs/003-install-hook-activation/quickstart-results.md` (header naming the host and tool
      versions, then one section per step with an assertion/result table) per SC-001 (missing).
      SC-001 requires a result for each cell of `{--dev copytree, --from zip} × {declared floor,
      current}`; nothing in the tree records any of them today, so T025 and T033 are ticked with no
      artifact behind them. The `--dev × current` cell is carried by the install-harness tests
      (`tests/bash/conformance/test_us4_bridge_runnable.bats`, `Us4.BridgeRunnable.Tests.ps1`), which
      were confirmed **run, not skipped**. The zip × floor cell — the one that produced the defect —
      is **not reproducible on the available host**: `specify` here is `0.14.4.dev0`, and the host
      restores file modes from `0.14.3`, so an archive install lands `0755` and proves nothing.
      Record that cell as not reproducible, naming the host version that makes it so, rather than as
      a pass (SC-001's own wording, and the risk plan.md flags). Also record Steps 0, 2, 3, 4, 7
      and 8 with the result actually observed.
- [X] T035 In `specs/014-fix-install-exec-bit/quickstart.md` Step 4 (line ~76), correct the stated
      expectation from "exactly one hit — `README.md`'s `chmod 600 .specify/jira/.env`" to the two
      hits the shipped tree actually carries — `README.md:184` and
      `templates/readme-block.template:88` — both being the same credentials-secrecy control FR-005
      exempts by name (partial). The automated sweep at
      `tests/bash/ci/test_message_command_literals.bats:145` already exempts `chmod 600` generally
      and is green; only the hand-run expectation is stale, and as written it turns a compliant tree
      into a reported leftover. Do not change either `chmod 600` occurrence — neither is an
      instruction to make the bridge runnable, so FR-005 and SC-002 are already satisfied.
