---
description: "Task list for 034 — retire the hook registry report"
---

# Tasks: Retire the hook registry report

**Input**: Design documents from `/specs/034-retire-hook-report/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED. Constitution XIII mandates TDD, and FR-010 additionally
requires the widened guard to be **demonstrated red against the pre-change code**
before it is accepted. Test tasks are therefore not optional here.

**Organization**: grouped by user story. Two cross-cutting phases (6 and 8) exist
because FR-001, FR-009 and FR-012 are properties of the whole feature and belong to
no single story — deleting the shared reader is only possible once every caller is
gone.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelisable — different files, no dependency on an incomplete task
- **[Story]**: US1 / US2 / US3; setup, foundational, cross-cutting and polish tasks carry none

## Path Conventions

Two native ports at the repository root: `scripts/bash/` and `scripts/powershell/`.
Tests in `tests/bash/` (bats), `tests/powershell/` (Pester) and
`tests/conformance/` (cross-port byte equivalence). Line numbers below are from
`2be2889` and are navigation aids, not assertions.

**Standing rule for every task in this file**: the two ports move in lockstep. A
port left half-deleted diverges on every conformance scenario at once and hides
which change caused it.

---

## Phase 1: Setup

**Purpose**: capture the pre-change baseline the whole feature is measured against.

- [X] T001 Record the pre-change baseline in `specs/034-retire-hook-report/baseline.md`: the output of `git grep -cn 'extensions\.yml\|SPEC_KIT_JIRA_EXTENSIONS_YML' -- scripts/`, the current `bats` and Pester test counts, and the conformance scenario count (254). Counts in this repository grow fast enough that a stale number misleads.
- [X] T002 [P] Stage the pre-change port for the guard-red proof: `PRE=$(mktemp -d) && git archive HEAD scripts | tar -x -C "$PRE"`, and record `$PRE` in `specs/034-retire-hook-report/baseline.md`. Verify `grep -rc 'extensions\.yml' "$PRE/scripts"` prints a non-zero count — a guard whose search root reads nothing passes vacuously, and that is indistinguishable from a guard that works.
- [X] T003 [P] Trace every caller of `Get-CfgUnsupportedConstruct`, which is defined **inside** `scripts/powershell/hooks/RegisterHooks.psm1:182` under a `Get-Cfg*` name that reads as belonging to the config library. Record in `specs/034-retire-hook-report/baseline.md` whether it moves to `scripts/powershell/lib/Config.psm1` or dies with its module (data-model §10).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: FR-010's enforcement guard, written and **proven red** before a single
line is deleted.

**⚠️ CRITICAL**: No user story work begins until T007 has been observed failing.
This project has shipped guards that were inert — two of three in a previous
feature — and an inert guard is silent about it.

- [X] T004 Add a `SPEC_KIT_JIRA_GUARD_ROOT` override to the `setup()` of `tests/bash/ci/test_no_registry_write.bats` so `SCRIPTS` can be pointed at the staged pre-change tree from T002, defaulting to `${ROOT}/scripts/bash` as today.
- [X] T005 Widen `tests/bash/ci/test_no_registry_write.bats` per research R6: replace the seven write-verb tests with (1) **total absence** of `extensions\.yml` and `SPEC_KIT_JIRA_EXTENSIONS_YML` from `scripts/bash`, outside an explicit allowlist of the prohibition's own explanatory comment; (2) **the deleted module has not returned** — no `hooks/register_hooks.sh`, no `register_hooks_*` symbol; (3) **no read verb reaches a registry-shaped path**. Use `grep -rnE 'a|b'` throughout — BSD `grep` silently mishandles `\|` alternation on macOS.
- [X] T006 [P] Mirror T004+T005 in `tests/powershell/ci/NoRegistryWrite.Tests.ps1` against `scripts/powershell`, adding the equivalent absence tests for `RegisterHooks.psm1` and the `Get-JiraHook*` / `Test-JiraHookEntry*` / `New-JiraHookUnreadable` symbols.
- [X] T007 **Prove both guards red.** Run `SPEC_KIT_JIRA_GUARD_ROOT="$PRE" bats tests/bash/ci/test_no_registry_write.bats` and the Pester equivalent against the staged pre-change tree. All three new tests MUST fail in each port. Paste the failing output into `specs/034-retire-hook-report/baseline.md`. A task marked done here without that recorded output has no artifact behind it.

**Checkpoint**: the guards are known to detect the thing they exist to detect. User story work can begin.

---

## Phase 3: User Story 1 — The configuration ceremony stops reporting on the registry (Priority: P1) 🎯 MVP

**Goal**: the ceremony's run summary reports discovery, the managed README block,
the ignore rule and the per-operator file, and says nothing about lifecycle hooks.

**Independent Test**: run the ceremony against a repository whose registry is
correct, one whose registry is absent, and one whose registry is malformed; the
three summaries are identical in hook-related content — all three contain none, and
the exit codes do not differ (quickstart §1).

### Tests for US1

- [X] T008 [P] [US1] Rewrite `tests/bash/commands/test_config_three_effects.bats` for the new membership. Its "three" was discovery/hooks/readme, written before the gitignore effect existed; it becomes discovery/readme/gitignore. Assert `.effects | has("hooks") | not` and that `additionalProperties: false` is honoured.
- [X] T009 [P] [US1] Mirror T008 in `tests/powershell/commands/Config.ThreeEffects.Tests.ps1`.
- [X] T010 [P] [US1] Add the three-registry-states test to `tests/bash/commands/test_config_degraded.bats` (correct / absent / malformed → identical hook-related content, identical exit code), covering US1 AC1–AC3. The malformed case is the load-bearing one: a file the extension never opens cannot affect it, so there must be no parse warning and no exit-code difference.
- [X] T011 [P] [US1] Mirror T010 in `tests/powershell/commands/Config.Degraded.Tests.ps1`.
- [X] T012 [P] [US1] Delete `tests/bash/commands/test_hook_health.bats` and `tests/powershell/commands/HookHealth.Tests.ps1` — their entire subject is removed, so there is no residual assertion to re-point.
- [X] T013 [US1] Add to `tests/bash/lib/test_output.bats` (config-effects render, ~64–116) and `tests/powershell/lib/Output.Tests.ps1` (~241–271): a config summary whose `effects` object carries no `hooks` key renders an `Effects:` block naming discovery, readme, gitignore and personal, and never the word `hooks`. Assert the RENDERED block, not the JSON — this is the human path, and it is the consumer FR-008 reaches that T008/T009 do not. **Not [P]**: it shares `test_output.bats` / `Output.Tests.ps1` with T022 in US2.

### Implementation for US1

- [X] T014 [US1] Delete `_config_hooks_effect` and the three `_CONFIG_HOOKS_*` globals from `scripts/bash/commands/config.sh` (lines ~892–987), and the call site plus `ext_path` derivation in `cmd_config` (lines ~1021–1031).
- [X] T015 [US1] Remove `hooks_status` / `hooks_detail` / `hooks_health` from the ceremony's summary assembly in `scripts/bash/commands/config.sh`: the main summary (`--arg hs` / `--arg hd` at ~1465, `--argjson hooks` at ~1487) and the **degraded** summary helper (signature at ~127–144, `effects` assembly at ~167). Both paths emit the effects object; missing the degraded one leaves the field alive exactly where the false verdict was first seen.
- [X] T016 [US1] Mirror T014+T015 in `scripts/powershell/commands/Config.psm1` (hooks-effect body ~1012–1080, `$RegistryPath` derivation ~1126–1130, summary assembly ~1190 and ~1669/1687).
- [X] T017 [US1] Remove `hooks` from the fixed effect render order in `scripts/bash/lib/output.sh` (~265, ~270) and `scripts/powershell/lib/Output.psm1` (~230, ~234). Both ports must move in the same change — the fixed order is what makes the two render byte-identically. Nothing breaks if this is skipped: `output.sh:272` skips an absent status, which is precisely why it would survive untouched all the way to T074 and fail the SC-006 grep with no owner.
- [X] T018 [US1] Amend `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json` per `contracts/summary-fields-removed.md` §1 and §3: remove the `effects.hooks` property, and remove `healthy`, `incomplete`, `held_disabled`, `duplicated`, `unreadable` from `$defs/effect.status`, rewriting the description's partition sentence — every remaining value is a write outcome. **Leave `effects.personal`, `effects.field_defaults`, `effects.task_mirror`, the `would_create` status, the `inert` status, and the top-level `provisional` and `rerun_guidance` alone**: all seven have live producers in both ports, all seven were undeclared until the M2 repair that preceded this task, and all are documented as surviving in the contract's notes. Removing any would re-open the drift this feature just closed. `tests/bash/commands/test_run_summary_schema.bats` will fail if one goes.

**Checkpoint**: US1 is independently deliverable. The reader still exists and reconcile still calls it; the ceremony no longer does.

---

## Phase 4: User Story 2 — Reconcile stops carrying a hook verdict (Priority: P1)

**Goal**: reconcile's run summary reports the mirror's own work and carries no hook
health object.

**Independent Test**: reconcile against the same three registry states as US1; the
summaries are identical in hook-related content (quickstart §2).

### Tests for US2

- [X] T019 [P] [US2] Add to `tests/bash/commands/test_reconcile.bats`: the run summary has no `hook_health` key, under all three registry states (US2 AC1).
- [X] T020 [P] [US2] Mirror T019 in `tests/powershell/commands/Reconcile.Tests.ps1`.
- [X] T021 [P] [US2] Confirm `tests/bash/hooks/test_hook_resilience.bats` and `tests/powershell/hooks/HookResilience.Tests.ps1` pass **unmodified** — one actionable warning, exit downgraded to 0, host command unaffected (US2 AC2, FR-007, SC-003). If either needs editing, the deletion has reached further than the spec allows; stop and report rather than adjusting the test.
- [X] T022 [US2] Strip `"hook_health":{}` from the seven hard-coded reconcile-summary literals in `tests/bash/lib/test_output.bats` (lines 145, 161, 177, 184, 192) and `tests/powershell/lib/Output.Tests.ps1` (lines 282, 287). These are fixtures for the human-rendering path, not assertions about hook health, so they will **not** go red when the field is removed — the renderer renders whatever it is handed. The only check that catches them is T074's grep, and without this task that check has no remediation behind it. **Not [P]**: shares both files with T013 in US1.

### Implementation for US2

- [X] T023 [US2] Delete the hook-health block from `scripts/bash/commands/reconcile.sh` (lines ~2126–2132), **including the hard-coded empty fallback** `'{"disabled":[],…,"unreadable":false}'`. An empty object asserting nothing is the same defect quieter (spec Assumptions).
- [X] T024 [US2] Remove `hook_health` from reconcile's summary emission in `scripts/bash/commands/reconcile.sh` (~2298, ~2313).
- [X] T025 [US2] Mirror T023+T024 in `scripts/powershell/commands/Reconcile.psm1` (~2385, ~2542).
- [X] T026 [US2] Amend `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json` per `contracts/summary-fields-removed.md` §2: delete the top-level `hook_health` object and all seven of its properties. Run `tests/bash/commands/test_reconcile_summary_schema.bats` immediately after: it fails if the contract loses `hook_health` while T023/T024 have not yet removed it from the code, which is the half-applied state this pair can leave behind. It will **not** catch the reverse — a field declared but no longer emitted is not a violation — so the deletion here is still a manual step, not one the guard performs for you.

**Checkpoint**: neither run summary carries a registry claim. The reader is now called from nowhere.

---

## Phase 5: User Story 3 — The release flag and its record are withdrawn (Priority: P2)

**Goal**: `--enable-hook` and the `hooks.disabled` local-binding key are both gone,
each refused through a path that already exists.

**Independent Test**: invoke the configuration command with the withdrawn flag and
assert the documented refusal; validate a local binding carrying the withdrawn key
and assert the located exit-4 refusal (quickstart §4, §5).

**⚠️ Scope note**: this phase also removes reconcile's **silent dispatch hold**
(research R3). The record has a third consumer the specification names only
obliquely as "a withheld lifecycle event"; it cannot survive the key's retirement.
Constitution 4.0.0 authorises the removal in as many words.

### Tests for US3

- [X] T027 [P] [US3] Add to `tests/bash/commands/test_config_refusal.bats`: `config --enable-hook after_specify` is refused through the existing unknown-flag path, naming the flag, with that path's exit code (US3 AC1).
- [X] T028 [P] [US3] Mirror T027 in the Pester config refusal suite.
- [X] T029 [P] [US3] Add to `tests/bash/lib/test_config.bats`: a `config.local.yml` declaring `hooks: {disabled: [after_specify]}` is refused with exit 4 and a message containing **both** `hooks` and the file's full path (US3 AC2, SC-004). Assert the **message text**, not only the exit code — a refactor dropping the path would keep the code green and lose the only part an operator can act on.
- [X] T030 [P] [US3] Add the negative case to the same file: a `config.local.yml` declaring none of the withdrawn keys validates exactly as before (US3 AC3).
- [X] T031 [P] [US3] Mirror T029+T030 in `tests/powershell/lib/Config.Tests.ps1`.
- [X] T032 [P] [US3] Add the **changed-branch** test for the removed dispatch hold, in `tests/bash/commands/test_reconcile_target.bats` and its Pester twin: with `SPEC_KIT_JIRA_HOOK_EVENT=after_specify` set, reconcile now proceeds to the normal target and prerequisite guards instead of returning 0 silently. Principle III's posture is being narrowed here, and the *changed* branch is the one that needs its own test — the unchanged branch already has T021.
- [X] T033 [P] [US3] Delete `tests/bash/commands/test_config_reenable.bats` and `tests/powershell/commands/Config.ReEnable.Tests.ps1`.

### Implementation for US3

- [X] T034 [US3] Remove `--enable-hook` from the option table in `scripts/bash/lib/cli.sh` (~253–264) and its `enable_hooks` emission (~91, ~321–333, ~382), so the flag falls to the existing unknown-flag path.
- [X] T035 [US3] Mirror T034 in `scripts/powershell/lib/Cli.psm1`.
- [X] T036 [US3] Remove `enable_hooks` from `cmd_config`'s flag parsing in `scripts/bash/commands/config.sh` (~994, ~1005), and its PowerShell mirror.
- [X] T037 [US3] Retire the key in `scripts/bash/lib/config.sh`: delete `"hooks"` from the accepted-key `IN(...)` list in `_CFG_LOCAL_ERRORS_JQ` (line ~1023) and delete the `has("hooks")` validation block (~1027–1034). No retired-key rule and no bespoke message — SC-004 requires zero added lines, and `_cfg_report_errors` at ~1561 is already handed the file path.
- [X] T038 [US3] Mirror T037 in `scripts/powershell/lib/Config.psm1`: remove `hooks` from the `$allowed` list (~1020) and delete the `hooks` validation block below it.
- [X] T039 [US3] Delete `config_hooks_disabled_read` / `_add` / `_remove` from `scripts/bash/lib/config.sh` (~3518–3630).
- [X] T040 [US3] Delete `Get-JiraHooksDisabled` / `Add-JiraHooksDisabled` / `Remove-JiraHooksDisabled` from `scripts/powershell/lib/Config.psm1` (~2013–2122) and their entries in `Export-ModuleMember` (~2128).
- [X] T041 [US3] Delete the dispatch hold: `_reconcile_is_held` (`scripts/bash/commands/reconcile.sh` ~67–85) and its call site with the `EXIT_CONFIG` branch (~621–634). The `timing_phase_begin "prereq"` call immediately above must survive.
- [X] T042 [US3] Mirror T041 in `scripts/powershell/commands/Reconcile.psm1`: `Test-JiraReconcileHeld` (~62–83) and its call site (~732).
- [X] T043 [US3] Amend `specs/001-jira-reconcile-engine/contracts/config.local.schema.json` and `specs/002-config-discovery-team-prefix/contracts/config-cli-contract.md` per `contracts/retired-cli-and-config.md` §1 and §2.

**Checkpoint**: nothing in either port reads or writes the disable record, and no command accepts the flag.

---

## Phase 6: Cross-cutting — complete FR-001 and turn the guards green

**Purpose**: the shared reader can only be deleted once US1, US2 and US3 have
removed every caller. FR-001, FR-009 and SC-002 are properties of the whole feature
and belong to no story.

**Depends on**: Phases 3, 4 and 5 complete.

- [X] T044 Delete `scripts/bash/hooks/register_hooks.sh` and every `source` of it. The `hooks/` directory stays — `readme_block.sh` is untouched.
- [X] T045 Delete `scripts/powershell/hooks/RegisterHooks.psm1` and every import of it, applying T003's decision about `Get-CfgUnsupportedConstruct`. `ReadmeBlock.psm1` is untouched. Import the config library **without** `-Force` if a new dependency is introduced — `Import-Module -Force` in a sink module clobbers the caller's scope, and one Pester file will not reproduce it.
- [X] T046 Remove `SPEC_KIT_JIRA_EXTENSIONS_YML` from both ports, from `tests/conformance/install-harness.sh` and `tests/conformance/InstallHarness.ps1`, and from documentation (research R5). An override naming a path nothing opens is a claim about a capability that no longer exists.
- [X] T047 Re-point the manifest check (FR-009): in `tests/bash/ci/test_manifest_hooks.bats` the last test sources `scripts/bash/lib/config.sh` and compares the manifest's event set against `JIRA_HOOK_EVENT_NAMES` instead of sourcing the deleted module and reading `HOOK_EVENTS`. Retiring it is **not** an option — the set's other consumer, `_cfg_after_event_names_json`, feeds 023's `phase_status_map` enum (research R1).
- [X] T048 [P] Mirror T047 in `tests/powershell/ci/Manifest.Hooks.Tests.ps1` against `$script:JiraHookEventNames`.
- [X] T049 **FR-006 — prove the manifest is otherwise untouched.** T047/T048 assert only that the manifest's event set equals the port's, which a change to `optional:`, a new `condition:`, or an altered `command:` would survive intact — and any of those alters what the host registers, which FR-006 forbids outright. Two assertions: (a) the remaining tests in `test_manifest_hooks.bats` and `Manifest.Hooks.Tests.ps1` — top-level placement, not nested under `provides:`, `optional: false` on every entry, no `condition`, a description per entry, no `priority`/`prompt` — pass **unmodified**; (b) the top-level `hooks:` block of `extension.yml` is byte-identical to `git show HEAD:extension.yml`'s, extracted with the same awk the test uses. Scope (b) to the block, not the file: T078 bumps `version:` and a whole-file comparison would fail on that alone.
- [X] T050 Rewrite the comment block at `scripts/bash/lib/config.sh` ~1058–1084 and its PowerShell mirror at ~1876. It currently justifies `JIRA_HOOK_EVENT_NAMES` as "the `hooks.disabled` enum of config.local.schema.json" and tells the reader that `hooks/register_hooks.sh` consumes it. Both halves become false; the surviving reason is 023's lifecycle enum.
- [X] T051 Delete `tests/bash/hooks/test_register_hooks.bats` and `tests/powershell/hooks/RegisterHooks.Tests.ps1`.
- [X] T052 Reassess `tests/bash/commands/test_registry_never_written.bats` and `tests/powershell/commands/RegistryNeverWritten.Tests.ps1`. Their behavioural claim (the registry is byte-identical after every documented state) is now trivially true and is subsumed by the absence guard. Either delete them with the behaviour or narrow them to the one thing they still prove that the guard cannot — keep the decision explicit; do not leave them passing vacuously (Constitution XIII).
- [X] T053 **Run both widened guards against the working tree and confirm GREEN**, then re-run them against `$PRE` from T002 and confirm they are still RED. A guard that has gone green without ever being red proves nothing, and one that is green against both trees has stopped reading.

**Checkpoint**: `git grep -n 'extensions\.yml' -- scripts/` returns nothing but the guard's own explanatory comment. FR-001 and SC-002 are satisfied.

---

## Phase 7: Cross-cutting — conformance (FR-012, SC-005)

**Depends on**: Phase 6.

**Never run these concurrently with `tests/run-bash.sh`** — they share fixtures and
will invent an `Only in …: state` divergence in an unrelated scenario.

- [X] T054 Retire `tests/conformance/scenarios/us9-hook-registration.json`. Its subject — the ceremony's hooks effect and its status vocabulary — is deleted, so there is no residual assertion to keep.
- [X] T055 Re-point `tests/conformance/scenarios/us021b-disabled-event.json`: keep the `repo-with-disabled-event` fixture and the argv, change the expectation to the exit-4 located refusal of `unknown config.local key: hooks`. This is what makes SC-004 a **cross-port** claim; per-port unit tests do not satisfy a conformance obligation, and this project has shipped that substitution before. Update the scenario's `description` to say what it now proves.
- [X] T056 [P] Reword the `description` of `tests/conformance/scenarios/us4-port-selection.json`, which currently pins "the same registered entries in the same `hook_health` object". No behavioural change.
- [X] T057 [P] Sweep `tests/conformance/scenarios/us6-zero-churn.json` and `us1-style-ambiguous-refusal.json` for descriptions naming the registry guarantee. `us6-zero-churn`'s registry clause is now trivially true; keep the fixture registries in `repo-with-config`, `repo-with-spec` and `repo-032-accept-site-replay` — a guard proving "we never open it" is only meaningful where the file exists.
- [X] T058 Run `bash tests/conformance/ci-conformance.sh` and confirm exit 0 with **zero** `conformance divergence` lines. Success is silent — there is no pass banner, and the temp paths in the output are harness noise.

---

## Phase 8: Cross-cutting — constitutional obligations belonging to no story

**Purpose**: obligations that are properties of the whole feature. Story-driven task
generation systematically drops these; they are enumerated here rather than left to
a per-story reading.

- [X] T059 **Principle II (zero-churn)**: extend `tests/live/test_live_zero_churn.bats` in this same change. The feature **removes** a write kind — the ceremony's conditional write of the disable record on encountering an `enabled: false` entry. The suite must stop expecting it. Bash only; there is no PowerShell live twin.
- [X] T060 **Principle IX / Constitution IV (tracked-file content)**: the rewritten `templates/readme-block.template` is content newly written into a tracked file in every consumer repository. Confirm the rewrite introduces no real site URL and no operator-identifying string, and that it passes the two-tier privacy guard.
- [X] T061 **Principle XI (dry-run)**: confirm `config --dry-run` still predicts every remaining effect and performs none, now that one effect and its two conditional writes are gone.
- [X] T062 **Principle XVI (readable)**: confirm both retirement refusals say who wrote the thing and what to do — the unknown-flag refusal names `--enable-hook`; the schema refusal names `hooks` and the file. Neither may need a comment to be understood.
- [X] T063 **Principle X (the two re-run clauses)**: confirm the other two clauses of the amended enforcement test still hold and that neither needed editing — reconcile re-run after an interrupted run re-establishes the binding with no duplicate ticket (`tests/bash/commands/test_reconcile_idempotent.bats`, `tests/conformance/scenarios/us023-idempotent-rerun.json`), and a ceremony re-run reports zero churn (`tests/conformance/scenarios/us1-config-idempotent.json`, `us6-zero-churn.json`). Observe them green **after** the dispatch hold is removed (T041/T042) — that is the early-exit path they traverse. If either needs editing, stop and report rather than adjusting it: the deletion has reached past the spec, the same way T021 bounds FR-007.

---

## Phase 9: Documentation sweep (FR-011, SC-006)

**Purpose**: SC-006 is "zero occurrences … anywhere in shipped code or
documentation". That is only checkable against an enumerated list, which is why
research R10 enumerates it — a previous feature here shipped with `README.md`
stating the opposite of the feature because the tasks covered only the code's own
docs.

**`specs/**` and `CHANGELOG.md` are excluded on purpose**: they are the historical
record, and earlier specifications correctly describe the world they were written in.

- [X] T064 **Write the FR-011 presence test FIRST, and observe it red.** Every other check in this phase tests for ABSENCE — T074's grep proves the retired claims are gone, which a phase that deleted the paragraphs and wrote nothing in their place would also satisfy. Nothing yet asserts the three statements FR-011 requires to be PRESENT. Add to `tests/bash/ci/test_consumer_docs_naming_surface.bats` (or a sibling in `tests/bash/ci/`): `INSTALL.md` and `templates/readme-block.template` each state that hook registration and its survival across reinstalls belong to the host, that a repository whose hooks are absent will simply see nothing happen, and that a hand-disabled hook may be re-enabled by a reinstall without warning. Run it before T065–T072 and record it failing; it is the only test in this phase that can go red for the right reason.
- [X] T065 Rewrite `INSTALL.md` (14 hook mentions): delete the `held_disabled` / `duplicated` / `unreadable` status table, the "how to disable a hook" section, and the leftover-entry upgrade section. Add FR-011's three statements: registration and its survival belong to the host; a repository whose hooks are absent will simply see nothing happen; a hand-disabled hook may be re-enabled by a reinstall without warning.
- [X] T066 [P] Rewrite `commands/speckit.jira-mirror.config.md`: delete the normative "hooks effect" section (~302–353), the status table and the `--enable-hook` entry, and rewrite the front-matter `description:` which currently promises to "verify the lifecycle hooks the install registered".
- [X] T067 [P] Remove `--enable-hook` from the tolerated-flag list in `commands/speckit.jira-mirror.reconcile.md` (~400). A flag no command accepts cannot be tolerated by another.
- [X] T068 Rewrite `templates/readme-block.template` (~8–35): drop "it also verifies the hook registration" and the `--enable-hook` release instruction; state the two withdrawn protections. Every consumer takes exactly one `written` outcome on its next ceremony and `unchanged` thereafter — that is a versioned managed block working, not churn.
- [X] T069 Re-run `tests/bash/ci/test_consumer_docs_invocation.bats` and `tests/bash/ci/test_consumer_docs_naming_surface.bats` after **T065, T068 and T072** — not after T068 alone. These two scans do not test anything this feature changes: they pin how `README.md`, `INSTALL.md` and `templates/readme-block.template` spell the bridge invocation (`bash <path>`, never a bare path), and those are exactly the three files T065, T068 and T072 rewrite. They are regression guards on the doc sweep's blast radius, so they run once the sweep is complete. `test_readme_idempotent.bats` / `test_readme_edgecases.bats` and their Pester twins assert **mechanism** and must pass unmodified; if one needs editing, check the edit is to a literal and not to the splice — 018 guards the top edge of the managed region only, and human text below it has been destroyed before.
- [X] T070 [P] Rewrite `docs/03-lifecycle-hooks.md` around what remains: the manifest declares, the host registers, the bridge runs, one warning on failure.
- [X] T071 [P] Remove the reader from the module map in `docs/02-module-architecture.md` and the health step from the flow in `docs/05-reconcile-flow.md`.
- [X] T072 [P] Sweep `README.md` (~170, ~183, ~599, ~610), `docs/01-system-context.md`, `docs/04-config-ceremony.md` and `docs/README.md`. The restricted-YAML-reader note in `README.md` keeps its point but must stop citing a file we no longer read.
- [X] T073 [P] Mark `specs/003-install-hook-activation/contracts/hook-registry-entry.md` as superseded by this feature, in place — do not delete it. It is the historical record of a contract that existed.
- [X] T074 Run the SC-006 check: `git grep -nE 'enable-hook|hook_health|held_disabled|SPEC_KIT_JIRA_EXTENSIONS_YML|hooks\.disabled' -- scripts/ tests/ docs/ commands/ templates/ README.md INSTALL.md` returns nothing.

---

## Phase 10: Polish & Release

- [X] T075 Run `tests/run-bash.sh` (~190 s locally) and `pwsh -c 'Invoke-Pester tests/powershell'`. Confirm the deleted tests are **gone**, not skipped, and that the counts moved by the expected amount against T001's baseline. Constitution XIII also requires the suites stay green under parallel execution — run the bash suite with `bats --jobs` at least once, but never concurrently with the conformance corpus.
- [X] T076 [P] Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`. Keep the scan scoped to `scripts/bash`; a whole-tree scan is ~1900 lines of host-script noise.
- [X] T077 Confirm the 80% statement-coverage gate (Constitution XIII) still passes. This feature deletes a well-tested module **and its tests**, so the net direction of the percentage is not self-evident and could fall. Record the before/after figures in `specs/034-retire-hook-report/baseline.md` alongside T001's counts.
- [X] T078 Bump `extension.yml` `version:` from `0.23.0` to `0.24.0` (research R8), and confirm the CI check that the version literal appears in exactly two files — `extension.yml` and `CHANGELOG.md` — still passes.
- [X] T079 Add the `CHANGELOG.md` entry, marked BREAKING, naming individually: the removed `--enable-hook` flag, the removed `hooks.disabled` local-binding key, the removed `effects.hooks` and `hook_health` summary fields, the five removed effect-status values, and the removed silent dispatch hold for a hand-disabled event.
- [ ] T080 Run the live integration suite against a real Jira instance on the release commit and record the result in `specs/034-retire-hook-report/baseline.md` (Constitution XII: "a green live-integration run on the release commit"). It needs real credentials, so it is never a fork-PR gate — but it is a shipping gate, and this feature removes reconcile's dispatch hold (T041/T042), an early-exit path no mocked test observes under a real host dispatch.
- [ ] T081 Dogfood this feature against a real Jira instance before release and record the observed output in `specs/034-retire-hook-report/baseline.md` (Constitution XII: "Every shipped feature MUST be dogfooded against a real Jira instance before release"). Exercise the three states the feature actually changes: a ceremony run (no hooks effect in the summary), a hook-fired reconcile (no `hook_health`, and the mirror still runs), and a `config.local.yml` still declaring `hooks:` (exit 4 naming both the key and the file). The false verdict this feature removes was found by dogfooding, not by the suite.
- [X] T082 Walk `quickstart.md` §1–§9 end to end against a real checkout and record the results. This is the acceptance evidence for SC-001 through SC-006.

---

## Dependencies

```text
Phase 1 (Setup)
   └─> Phase 2 (Guards, proven RED)         ← BLOCKING
          ├─> Phase 3 (US1, P1)  ─┐
          ├─> Phase 4 (US2, P1)  ─┤  independent of each other
          └─> Phase 5 (US3, P2)  ─┘
                 └─> Phase 6 (delete the reader, guards GREEN)
                        └─> Phase 7 (conformance)
                               ├─> Phase 8 (constitutional gates)
                               ├─> Phase 9 (documentation)
                               └─> Phase 10 (polish & release)
```

**Story independence**: US1, US2 and US3 touch disjoint call sites and can be
implemented in any order, or concurrently, once Phase 2 is done. They converge only
at Phase 6, which cannot start until all three have removed their callers — the
reader is shared, and deleting it earlier breaks whichever story has not yet moved.

**The one file two stories share**: T013 (US1) and T022 (US2) both edit
`tests/bash/lib/test_output.bats` and `tests/powershell/lib/Output.Tests.ps1`.
Neither is marked [P], and if the two stories are run concurrently these two tasks
must be serialised against each other.

**The one ordering that is not negotiable**: T007 (guards red) precedes every
deletion. Written afterwards, the guard proves only that the code you just wrote
matches the guard you just wrote.

## Parallel opportunities

- **Phase 1**: T002 and T003 together.
- **Phase 2**: T006 alongside T005 (different ports, different files).
- **Phase 3**: T008–T012 together (five distinct test files), then T013, then T014–T018.
- **Phase 4**: T019–T021 together, then T022.
- **Phase 5**: T027–T033 together (seven distinct test files).
- **Phase 9**: T064 first and alone (the FR-011 presence test, observed red), then T066, T067, T070, T071, T072, T073 together — six distinct documents. T069 waits for the whole sweep, since T072 is inside that parallel group.
- **Across stories**: one agent per story through Phases 3–5, provided each stays inside its own call sites, none touches `hooks/register_hooks.sh` (Phase 6's), and T013/T022 are serialised.

## Independent test criteria

| Story | Criterion |
| --- | --- |
| **US1** | Ceremony summaries for a correct, an absent and a malformed registry are identical in hook-related content — all three contain none — with no exit-code difference and the other three effects unchanged in shape, in both the JSON and the human-rendered output. |
| **US2** | Reconcile's summary has no `hook_health` under all three registry states, while a hook-context bridge failure still yields exactly one warning and exit 0. |
| **US3** | `--enable-hook` is refused as an unknown flag naming the flag; a `config.local.yml` declaring `hooks:` is refused with exit 4 naming both the key and the file; one declaring neither validates as before. |

## Implementation strategy

**MVP = Phase 1 + Phase 2 + Phase 3 (US1)**. That removes the false verdict from
the place it was actually observed and where an operator is most likely to act on
it. It is shippable on its own: the reader still exists and reconcile still calls
it, but the ceremony is silent.

**Full value = MVP + US2.** The spec rates the two P1 and calls them inseparable in
value, for a reason worth respecting — reconcile runs far more often than the
ceremony, so shipping US1 alone leaves the same wrong verdict in the busier path.

**US3 and Phase 6 are the remainder**, and they are what make FR-001 true. Until
the reader is deleted the extension still opens a file Constitution X forbids it to
open; the summaries are merely quiet about it.

---

## Phase 11: Convergence

- [X] T083 Mark `specs/003-install-hook-activation/contracts/hook-registry-entry.md` as superseded by 034, in place, per tasks.md T073 (missing). T073 is checked `[X]` but produced no artifact: the file carries no supersession marker. Add a short header saying the contract described the registry-entry shape the extension classified, that 034 removed the classifier, and that the file is kept as the historical record of a contract that existed — do NOT delete it.
- [X] T084 Reconcile SC-003's wording with what shipped, per SC-003 (partial). SC-003 claims the end-to-end hook scenarios pass "unmodified"; `tests/bash/hooks/test_hook_resilience.bats` and `tests/powershell/hooks/HookResilience.Tests.ps1` both needed edits — their `setup()`/`BeforeAll` sourced the deleted module so every test died before running, and three tests had retired behaviour as their subject. The FR-007 behaviour itself is untouched and green. Either amend SC-003 to claim what is true (the hook-context behaviour is unchanged; the suites needed harness repair) or record the deviation against it explicitly. The evidence is already written up in `specs/034-retire-hook-report/baseline.md`.
