# Tasks: Hooks Active From Installation

**Input**: Design documents from `/specs/003-install-hook-activation/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Test tasks are INCLUDED. Constitution XIII mandates TDD with ≥80%
statement coverage, and plan.md states every change is written as a failing test
first. The project's bug-fix rule additionally requires the reported defect to
have a reproducing test before the fix.

**Organization**: Tasks are grouped by user story so each story can be
implemented, tested and delivered independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US6)
- Every task names its exact file path
- Identifiers are stable and never reused. T085–T090 were added to Phase 7
  after Phase 9 already existed, so they appear grouped by subject rather than
  by number. Execution order follows the phases, not the identifiers

## Path Conventions

Spec Kit extension with twin native ports (plan.md § Project Structure):

- Manifest: `extension.yml` at repository root
- Agent commands: `commands/*.md`
- Bash port: `scripts/bash/{hooks,commands,lib,engine,sink}/`
- PowerShell port: `scripts/powershell/{hooks,commands,lib,engine,sink}/`
- Suites: `tests/bash/`, `tests/powershell/`, `tests/conformance/`, `tests/live/`
- Contracts inherited from feature 001: `specs/001-jira-reconcile-engine/contracts/`

**Twin-port rule**: every behavioural change lands on both ports
(Constitution VI), and so does every test that asserts behaviour. Bash and
PowerShell tasks touch different files and are therefore almost always
parallelisable.

**The load-bearing constraint**: the consuming repository's
`.specify/extensions.yml` is **read-only to this extension**, in every state,
from every command (FR-022). No task below may add, keep or reintroduce a write
to it. The tasks that enforce this mechanically are T055–T059 and T069–T070.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: the harness that makes "what the official install actually writes"
observable — without it, User Story 1 cannot be tested at all.

- [X] T001 Create the scratch-repo install harness in `tests/conformance/install-harness.sh`: runs `specify init --here --ai claude` then `specify extension add --dev <repo-root>` into a temporary directory, prints the resulting `.specify/extensions.yml`, exposes a checksum helper over that file, supports repeated `--force` reinstalls and a seeding hook for pre-existing registry content, and skips with a clear message when the `specify` CLI is absent (quickstart.md §1–§2)
- [X] T002 [P] Create the PowerShell twin harness in `tests/conformance/InstallHarness.ps1`, function for function, so install-time behaviour is verifiable on Windows (Constitution VI)
- [X] T003 [P] Wire the harness and the new CI check files into the three-OS matrix in `.github/workflows/ci.yml`, so the manifest↔registry, message↔command and no-registry-write checks run on every push

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the two shared records every story depends on — the canonical
eight-field hook entry as a **recognition rule** (contracts/hook-registry-entry.md)
and the operator disable record (data-model.md § Operator disable record).

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.
US1 declares entries that must match the canonical shape; US2 and US6 both read
the disable record.

- [X] T004 [P] Extend the `hook_health` object in `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json` with `held_disabled` (array of event names), `duplicated` (array of event names) and `unreadable` (boolean), all additive and optional so a consumer validating against the previous schema is unaffected, per data-model.md § Hook health
- [X] T005 [P] Add the `hooks.disabled` key (array of event names from the closed set of seven) to `specs/001-jira-reconcile-engine/contracts/config.local.schema.json`, additively
- [X] T006 [P] Write failing tests for the registry **reader** in `tests/bash/hooks/test_register_hooks.bats`: an entry is recognised as ours when `extension` is `jira`; an entry is recognised as **leftover** when `extension` is absent and `command` is one of ours; the canonical eight-field shape is asserted on read — `extension`, `command`, `enabled`, `optional`, `priority`, `prompt`, `description`, `condition` — with `prompt` being the host's **expanded** default, the exact string `Execute <command>?` with the command substituted (research.md R2, verified at `specify_cli/extensions/__init__.py:3866`); and the seven declared events are one closed set
- [X] T007 [P] Write the failing twin tests in `tests/powershell/hooks/RegisterHooks.Tests.ps1`, asserting the PowerShell port classifies the same input state identically
- [X] T008 [P] Write failing tests for the disable-record read/write in `tests/bash/lib/test_config.bats`: reading an absent record yields the empty set, an unknown event name is reported and ignored rather than failing the run, and a written record round-trips
- [X] T009 [P] Write the failing twin tests in `tests/powershell/lib/Config.Tests.ps1`
- [X] T010 Rewrite `scripts/bash/hooks/register_hooks.sh` as a **reader**: replace `_register_hooks_entry`/`_register_hooks_before_entry` with recognition and classification over the canonical eight-field shape, add leftover-entry recognition, extend `HOOK_EVENTS`/`HOOK_BEFORE_EVENT` so the seven declared events are one closed set (research.md R2, R9), and **delete `register_hooks_write` together with every helper that exists only to serve it** — the module must no longer contain any code that opens the registry for writing (FR-022, SC-011)
- [X] T011 [P] Implement the twin reader and the same deletion in `scripts/powershell/hooks/RegisterHooks.psm1`
- [X] T012 Implement `hooks.disabled` read/write against `.specify/jira/config.local.yml` in `scripts/bash/lib/config.sh`, including the new key in `_CFG_LOCAL_ERRORS_JQ` so schema validation accepts it
- [X] T013 [P] Implement the twin local-binding read/write in `scripts/powershell/lib/Config.psm1`

**Checkpoint**: the registry is read and classified on both ports, the writer is
gone, and the disable record exists. User story implementation can now begin.

---

## Phase 3: User Story 1 - The mirror is wired up by the official install (Priority: P1) 🎯 MVP

**Goal**: `specify extension add` alone registers all seven lifecycle events into
the consuming repository's `.specify/extensions.yml`, enabled and attributed to
`jira`, with no configuration ceremony run.

**Independent Test**: install into a clean scratch repository with the harness
from T001 and inspect `.specify/extensions.yml` — seven events, one `jira`-owned
entry each, `enabled: true`. Reinstall twice: still exactly one entry per event.

### Tests for User Story 1 ⚠️

> Write these FIRST and confirm they FAIL before implementing.

- [X] T014 [P] [US1] Write the failing manifest-shape CI check in `tests/bash/ci/test_manifest_hooks.bats`: `hooks:` is a **top-level** key of `extension.yml` (not nested under `provides:`), declares exactly the seven events, every entry sets `optional: false`, and no entry declares `condition` (contracts/extension-manifest-hooks.md, research.md R1/R8)
- [X] T015 [P] [US1] Write the failing twin CI check in `tests/powershell/ci/Manifest.Hooks.Tests.ps1`
- [X] T016 [P] [US1] Write the failing install-registration test in `tests/bash/conformance/test_us1_install_hooks.bats` driving T001's harness: fresh install produces one `jira` entry per event marked enabled; a pre-seeded foreign extension entry survives unchanged; two further `--force` reinstalls produce no duplicates and strip nothing (FR-005, FR-006, SC-004)
- [X] T017 [P] [US1] Write the failing twin install-registration test in `tests/powershell/conformance/Us1.InstallHooks.Tests.ps1` driving T002's harness

### Implementation for User Story 1

- [X] T018 [US1] Add the top-level `hooks:` block to `extension.yml` declaring `before_specify` → `speckit.jira.feature` and the six `after_*` events → `speckit.jira.reconcile`, each with `optional: false` and a human-readable `description`, omitting `priority`, `prompt` and `condition` (contracts/extension-manifest-hooks.md)
- [X] T019 [US1] Update the post-install section of `INSTALL.md` to state that the hooks are registered and active from install, that they are performed rather than offered, that a hook failure never fails a spec-kit command, that the extension never modifies the hook registry itself, and to name the single remaining step (`/speckit.jira.config`) before mirroring can reach Jira (FR-026, US1 scenario 4)
- [X] T020 [US1] Update `tests/conformance/scenarios/us9-hook-registration.json` so its expected registry matches the canonical eight-field entry rather than the old four-field shape

**Checkpoint**: the install registers the hooks. They still reference a command
that does not exist — User Story 3 is a hard co-requisite for a shippable MVP.

---

## Phase 4: User Story 2 - Registered hooks are performed, not merely offered (Priority: P1)

**Goal**: a registered hook is dispatched by the agent as part of the host
lifecycle command, while a hook failure still never fails that command; an
operator-disabled event stays inert and silent even after a reinstall
re-enables it in the registry.

**Independent Test**: run each covered lifecycle step in a configured repository
and confirm the bridge step ran without confirmation. Then disable one event,
run the ceremony once so the decision is recorded, reinstall, run its lifecycle
step: no bridge step, no warning, and the registry untouched by us.

### Tests for User Story 2 ⚠️

- [X] T021 [P] [US2] Extend `tests/bash/hooks/test_hook_resilience.bats` with failing cases proving non-blocking outcome propagation still holds under `optional: false` — every bridge fault leaves the host command's exit code untouched (FR-015, research.md R4)
- [X] T022 [P] [US2] Write the failing twin cases in `tests/powershell/hooks/HookResilience.Tests.ps1`
- [X] T023 [P] [US2] Add failing cases to `tests/bash/commands/test_reconcile.bats`: for an event present in the disable record the reconcile entry point exits inert — no Jira call and no warning — regardless of the registry showing `enabled: true` (FR-020, research.md R5 step 2)
- [X] T024 [P] [US2] Write the failing twin cases in `tests/powershell/commands/Reconcile.Tests.ps1`
- [X] T025 [P] [US2] Add failing cases to `tests/bash/commands/test_config_three_effects.bats` asserting the **ceremony** records an observed `enabled: false` into the disable record, that the health classification itself writes nothing anywhere, and that `--dry-run` predicts the record write without performing it (research.md R5 step 1, Constitution XI)
- [X] T026 [P] [US2] Write the failing twin cases in `tests/powershell/commands/Config.ThreeEffects.Tests.ps1`

### Implementation for User Story 2

- [X] T027 [US2] Honour the disable record at dispatch in `scripts/bash/commands/reconcile.sh`: read `hooks.disabled` via `lib/config.sh` and exit `0` silently for a recorded event before any prerequisite or network work
- [X] T028 [P] [US2] Implement the twin dispatch guard in `scripts/powershell/commands/Reconcile.psm1`
- [X] T029 [US2] Record an observed `enabled: false` into the disable record from `scripts/bash/commands/config.sh` — **not** from `register_hooks_health`, which stays a pure classification — and surface the event under `held_disabled` in the health object
- [X] T030 [P] [US2] Implement the twin recording and `held_disabled` emission in `scripts/powershell/commands/Config.psm1`

**Checkpoint**: hooks dispatch mandatorily, failures stay non-blocking, and an
operator's disable survives a reinstall at dispatch time.

---

## Phase 5: User Story 3 - Every registered hook resolves to a real command (Priority: P1)

**Goal**: `speckit.jira.reconcile` exists as an installed, agent-invocable
command, is declared in the manifest, and every hook reference resolves.

**Independent Test**: cross-check the set of `hooks[].command` values in
`extension.yml` against `provides.commands[].name` and against the files in
`commands/` — the three sets agree, with zero unresolvable references.

### Tests for User Story 3 ⚠️

- [X] T031 [P] [US3] Write the failing resolution CI check in `tests/bash/ci/test_hook_command_resolution.bats`: every `hooks[].command` matches a `provides.commands[].name` exactly, and every declared command's `file:` exists on disk (SC-002, research.md R7)
- [X] T032 [P] [US3] Write the failing twin CI check in `tests/powershell/ci/HookCommandResolution.Tests.ps1`
- [X] T033 [P] [US3] Write the failing agent-document test in `tests/bash/commands/test_agent_doc_reconcile.bats`, mirroring `test_agent_doc_config.bats`: front matter `name` is exactly `speckit.jira.reconcile`, the procedure is ordered and deterministic, and it states the never-fail-the-host rule

### Implementation for User Story 3

- [X] T034 [US3] Create `commands/speckit.jira.reconcile.md` per contracts/reconcile-command.md: front matter (`name`, `description`, `argument-hint`), the four-step ordered procedure (locate the feature via `.specify/feature.json` → invoke the bridge with the spec path and `--json` → interpret the outcome as exactly one line → never fail the host command), the message-discipline table of the six distinguished causes, and the verbatim bridge-unavailable fallback block (FR-030)
- [X] T035 [US3] Declare `speckit.jira.reconcile` under `provides.commands` in `extension.yml`, pointing at `commands/speckit.jira.reconcile.md` with a description (FR-010, FR-011)

**Checkpoint**: every registered hook names a command the agent can resolve.
Combined with Phase 3, this is the shippable MVP.

---

## Phase 6: User Story 4 - The bridge runs straight after install (Priority: P1)

**Goal**: the documented procedures invoke the bridge by repository-relative
path, selecting the port from the host, so the entry point is runnable with no
manual step and no machine-wide install.

**Independent Test**: install into a clean repository, then run
`.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help` (and the
PowerShell twin) with nothing done in between; audit that nothing outside the
repository changed.

### Tests for User Story 4 ⚠️

- [X] T036 [P] [US4] Write the failing invocation CI check in `tests/bash/ci/test_agent_doc_invocation.bats`: no file under `commands/` invokes a bare `spec-kit-jira` name, and each names both `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` and `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` with the host-selection rule (FR-014, research.md R6)
- [X] T037 [P] [US4] Write the failing twin CI check in `tests/powershell/ci/AgentDocInvocation.Tests.ps1`
- [X] T038 [P] [US4] Write the failing post-install runnability test in `tests/bash/conformance/test_us4_bridge_runnable.bats` using T001's harness: the Bash entry point runs by repository-relative path immediately after install, and an audit shows the install confined to the repository — `git status --porcelain` clean outside it, and these locations byte-identical before and after: `$PATH`, `~/.zshrc`, `~/.bashrc`, `~/.bash_profile`, `~/.profile`, `/usr/local/bin`, `/opt/homebrew/bin` (FR-008, FR-012, US4 scenario 3)
- [X] T039 [P] [US4] Write the failing twin runnability test in `tests/powershell/conformance/Us4.BridgeRunnable.Tests.ps1` using T002's harness, auditing `$env:PATH`, the PowerShell profile paths and the user-scope install locations (FR-013, SC-008)

### Implementation for User Story 4

- [X] T040 [US4] Rewrite every bridge invocation in `commands/speckit.jira.config.md` to the repository-relative per-port path, replacing the bare `spec-kit-jira config` form
- [X] T041 [US4] Rewrite every bridge invocation in `commands/speckit.jira.feature.md` to the repository-relative per-port path, replacing the bare `spec-kit-jira feature` form
- [X] T042 [US4] Verify and, if needed, correct the per-port invocation table in `commands/speckit.jira.reconcile.md` so it matches the form settled in T040/T041 (depends on T034)
- [X] T043 [P] [US4] Add the cross-port selection scenario `tests/conformance/scenarios/us4-port-selection.json` asserting both ports produce the same registered entries and the same bridge outcome for the same input state (FR-013, Constitution VI)

**Checkpoint**: the reported "spec-kit-jira CLI not installed" cause is removed
on both ports.

---

## Phase 7: User Story 5 - Degraded runs say something true and actionable (Priority: P2)

**Goal**: each degraded state produces exactly one message that names the true
cause and names only commands that can be run as spelled.

**Independent Test**: run a lifecycle step in each of the five degraded states
and confirm one message per run, correctly attributed, with every command
literal resolving to a declared command or a runnable invocation.

### Tests for User Story 5 ⚠️

- [X] T044 [P] [US5] Write the failing message↔command CI check in `tests/bash/ci/test_message_command_literals.bats`, over every emitted message string in `scripts/bash/**` and `commands/*.md`. Three classes of literal are extracted and asserted, per FR-018: (a) assistant commands (`/speckit.jira.*`, `/speckit-jira-*`, `speckit.jira.*`) must match a `provides.commands[].name`; (b) bridge invocations — any occurrence of `spec-kit-jira`, or of a bridge subcommand used imperatively such as `reconcile --repair-hooks` — must appear in the repository-relative per-port form, never as a bare name; (c) host commands such as `specify extension add` must appear in the form the operator actually runs. Class (a) is what would have caught `/speckit-jira-conifg`; class (b) is what catches the existing `repair_hint` text (FR-014, FR-018, SC-009)
- [X] T045 [P] [US5] Write the failing twin CI check in `tests/powershell/ci/MessageCommandLiterals.Tests.ps1` over `scripts/powershell/**`
- [X] T046 [P] [US5] Extend `tests/bash/commands/test_config_degraded.bats` with failing cases distinguishing all six causes — not yet configured, credentials absent, credentials rejected, prerequisite missing, Jira unreachable, and the bridge entry point absent or not executable — each with its own message text and the host command exiting successfully (FR-017, SC-006)
- [X] T047 [P] [US5] Write the failing twin cases in `tests/powershell/commands/Config.Degraded.Tests.ps1`
- [X] T048 [P] [US5] Add failing single-message-discipline cases to `tests/bash/commands/test_reconcile.bats`: at most one warning per host command run, and the not-yet-configured notice is at most three lines (FR-016, FR-019, US5 scenario 3)
- [X] T049 [P] [US5] Write the failing twin cases in `tests/powershell/commands/Reconcile.Tests.ps1`
- [X] T085 [P] [US5] Write the failing fallback-block CI check in `tests/bash/ci/test_agent_fallback_block.bats`: each of the three files under `commands/` contains the bridge-unavailable fallback block **verbatim** as fixed in contracts/reconcile-command.md; each instructs the assistant to emit it exactly as written rather than describe the state in its own words; and every literal inside the block is runnable as written — the two per-port entry-point paths exist in this repository at the paths named, and the reinstall command is the official one (FR-030). This is the check that addresses the reported message, which was assistant-composed prose and therefore invisible to T044's scan of committed literals
- [X] T086 [P] [US5] Write the failing twin CI check in `tests/powershell/ci/AgentFallbackBlock.Tests.ps1`
- [X] T087 [P] [US5] Add a failing bridge-unavailable case to `tests/bash/commands/test_reconcile.bats`: with the entry point renamed away, the host command still exits successfully and the reconcile path reports the missing entry point as its distinguished cause — never as "not configured" and never as a prerequisite failure (FR-017 sixth cause, SC-006)
- [X] T088 [P] [US5] Write the failing twin case in `tests/powershell/commands/Reconcile.Tests.ps1`

### Implementation for User Story 5

- [X] T050 [US5] Rework the degraded-path messages in `scripts/bash/commands/reconcile.sh`: classify the six causes, emit at most one message per run, remove the "CLI not installed" attribution, and name only commands runnable as spelled
- [X] T051 [P] [US5] Implement the twin message rework in `scripts/powershell/commands/Reconcile.psm1`
- [X] T052 [US5] Correct the prerequisite and notice wording emitted from `scripts/bash/lib/prereq.sh` and `scripts/bash/lib/output.sh` so every command literal is spelled as declared and every bridge invocation is repository-relative
- [X] T053 [P] [US5] Implement the twin corrections in `scripts/powershell/lib/Prereq.psm1` and `scripts/powershell/lib/Output.psm1`
- [X] T054 [US5] Rewrite the two `repair_hint` literals in `scripts/bash/hooks/register_hooks.sh` and the failure warning in `scripts/bash/commands/reconcile.sh` so they name `/speckit.jira.config` or the official install command — never the bare `reconcile --repair-hooks`, which after Phase 8 no longer exists — and implement the twin rewrite in `scripts/powershell/hooks/RegisterHooks.psm1` and `scripts/powershell/commands/Reconcile.psm1`
- [X] T089 [US5] Add the bridge-unavailable fallback block, verbatim from contracts/reconcile-command.md, to `commands/speckit.jira.config.md`, `commands/speckit.jira.feature.md` and `commands/speckit.jira.reconcile.md`, each with the instruction to emit it exactly as written and not to compose an explanation for that state (FR-030, US5 scenario 4). Depends on T040/T041/T042, which settle the per-port paths the block quotes
- [X] T090 [US5] Distinguish the bridge-unavailable cause in `scripts/bash/commands/reconcile.sh` and `scripts/bash/lib/prereq.sh` — a missing or non-executable entry point is reported as its own cause, never folded into "not configured" or the generic prerequisite gate — and implement the twin distinction in `scripts/powershell/commands/Reconcile.psm1` and `scripts/powershell/lib/Prereq.psm1` (FR-017)

**Checkpoint**: every degraded run is truthful, single and actionable.

---

## Phase 8: User Story 6 - The ceremony verifies and reports, and never writes the registry (Priority: P2)

**Goal**: the extension's hook responsibility is read-classify-report. Zero
writes to `.specify/extensions.yml` in every state, from every command, with
the operator's comments and formatting intact — and an accurate, actionable
report for each state it cannot fix itself.

**Independent Test**: checksum the registry, run every command in every
documented state, checksum again — identical every time — while each state
produces its own accurate report.

### Tests for User Story 6 ⚠️

- [X] T055 [P] [US6] Write the headline failing test in `tests/bash/commands/test_registry_never_written.bats`: seed a registry containing operator comments, an unusual key order and a foreign extension's entries; for **each** documented state — healthy, one entry missing, one entry disabled, a leftover pre-manifest entry, an unreadable file, a repository not configured — run the configuration ceremony and the reconcile entry point and assert the registry's checksum is identical before and after, and that its full text is byte-identical, comments included (FR-022, FR-023, SC-007, SC-012)
- [X] T056 [P] [US6] Write the failing twin test in `tests/powershell/commands/RegistryNeverWritten.Tests.ps1`
- [X] T057 [P] [US6] Write the failing static check in `tests/bash/ci/test_no_registry_write.bats`: grep every file under `scripts/bash/**` for any construct that could write the registry path — redirection into it, `mv`/`cp`/`rm`/`truncate`/`tee`/`sed -i` targeting it, or passing it to a writing helper — and assert zero occurrences (SC-011)
- [X] T058 [P] [US6] Write the failing twin static check in `tests/powershell/ci/NoRegistryWrite.Tests.ps1` over `scripts/powershell/**`, covering `Set-Content`, `Out-File`, `Add-Content`, `Move-Item`, `Remove-Item`, `Clear-Content` and redirection
- [X] T059 [P] [US6] Extend `tests/bash/commands/test_hook_health.bats` with failing cases covering all seven declared events and the full classification — `present`, `missing`, `disabled`, plus the `held_disabled` and `duplicated` annotations and the `unreadable` flag — and asserting `repair_hint` appears only when something is not `present`, and names the right remedy for each case (FR-021, data-model.md § Hook health)
- [X] T060 [P] [US6] Write the failing twin cases in `tests/powershell/commands/HookHealth.Tests.ps1`
- [X] T061 [P] [US6] Add failing cases to `tests/bash/commands/test_config_refusal.bats`: an unreadable registry reports `unreadable` with the file named as the cause, returns the config exit code, writes nothing, and **does not** report the seven events as missing; a registry that is valid YAML but uses a construct outside the reader's subset (a YAML anchor, a flow collection) is distinguished in prose from a genuinely broken file and names the construct (FR-024, spec.md Edge Cases)
- [X] T062 [P] [US6] Write the failing twin cases in `tests/powershell/commands/Config.Refusal.Tests.ps1`
- [X] T063 [P] [US6] Add failing leftover-entry cases to `tests/bash/hooks/test_register_hooks.bats`: an entry carrying one of our commands with no `extension` field is classified `duplicated` for its event; the report names every affected event and contains a copy-pasteable manual edit; nothing is written; a foreign extension's entry is never classified as ours (FR-006, FR-028)
- [X] T064 [P] [US6] Write the failing twin cases in `tests/powershell/hooks/RegisterHooks.Tests.ps1`
- [X] T065 [P] [US6] Write failing cases for the release flag in `tests/bash/commands/test_config_reenable.bats`: `--enable-hook <event>` clears that event from `hooks.disabled`; the registry is **not** touched by it; the flag against an unrecorded event is a no-op reported as such; an unknown event name is reported and does not fail the run; `--dry-run` predicts the clearance without performing it (FR-007, FR-029, Constitution XI, XV)
- [X] T066 [P] [US6] Write the failing twin cases in `tests/powershell/commands/Config.ReEnable.Tests.ps1`

### Implementation for User Story 6

- [X] T067 [US6] Report the hook effect in prose in `scripts/bash/commands/config.sh` using the status vocabulary of contracts/hook-registry-entry.md — `healthy`, `incomplete`, `held disabled`, `duplicated`, `unreadable` — naming for each the events concerned and the remedy: the official install command for missing entries, the release flag for held events, the manual edit for leftovers. Surface `held_disabled`, `duplicated` and `unreadable` in the run summary
- [X] T068 [P] [US6] Implement the twin reporting in `scripts/powershell/commands/Config.psm1`
- [X] T069 [US6] Remove every remaining call path into the deleted writer from `scripts/bash/commands/config.sh` and `scripts/bash/commands/reconcile.sh`, so no command can reach the registry with a pen; the ceremony's hook effect becomes read-and-report only
- [X] T070 [P] [US6] Implement the twin removal in `scripts/powershell/commands/Config.psm1` and `scripts/powershell/commands/Reconcile.psm1`
- [X] T071 [US6] Add `--enable-hook <event>` (repeatable) to `scripts/bash/commands/config.sh` and its argument parsing in `scripts/bash/lib/cli.sh`: it removes the named event from the disable record, touches nothing else, and is the literal the `held disabled` report names (plan.md § Complexity Tracking, research.md R5)
- [X] T072 [P] [US6] Implement the twin flag in `scripts/powershell/commands/Config.psm1` and `scripts/powershell/lib/Cli.psm1`, spelled `--enable-hook` on both ports for consistency with the existing shared flag names
- [X] T073 [US6] Remove the `--repair-hooks` flag from `scripts/bash/commands/reconcile.sh`, `scripts/bash/lib/cli.sh` and the help text in `scripts/bash/spec-kit-jira.sh`: it exists only to perform a registry write that FR-022 forbids, and a flag named "repair" that no longer repairs would be worse than none (Principle XV, XVI). Implement the twin removal on the PowerShell port
- [X] T074 [US6] Update `tests/conformance/scenarios/us6-zero-churn.json` so the expectation is the unconditional one: over a registry written by the host install, carrying comments and a foreign entry, every command leaves the file byte-identical

**Checkpoint**: all six user stories are independently functional, and the
consuming project's registry is provably untouched.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [X] T075 [P] Update `templates/readme-block.template` and the managed block in `README.md` to the corrected sequence: install registers and activates the hooks; the configuration ceremony binds the project and verifies the registration without ever modifying it (FR-027)
- [X] T076 [P] Add the release entry to `CHANGELOG.md` and bump `extension.version` in `extension.yml` — the version literal must remain absent from every other file (Constitution XII). The entry must call out two behaviour changes for existing users: the `--repair-hooks` flag is removed, and a registry carrying entries from a pre-manifest version needs a one-time manual cleanup, with the exact edit spelled out
- [X] T077 [P] Write the uninstall conformance test in `tests/bash/conformance/test_uninstall_hooks.bats` using T001's harness: after `specify extension remove`, zero `jira`-owned entries remain and every foreign entry is byte-identical (spec.md Edge Cases § Uninstall)
- [X] T078 [P] Write the not-a-spec-kit-project test in `tests/bash/conformance/test_install_non_speckit.bats`: installing into a directory with no spec-kit structure reports the missing structure and creates no stray registry (spec.md Edge Cases)
- [X] T079 [P] Write the mixed-sequence idempotency test in `tests/bash/conformance/test_us1_sequence.bats`: ten consecutive operations in mixed order — install, `--force` reinstall, configuration ceremony — starting from a registry with no leftover entry, asserting at most one entry per event throughout and no entry ever lost (SC-004)
- [X] T080 [P] Run `shellcheck scripts/bash/**/*.sh` and `Invoke-ScriptAnalyzer` with `PSScriptAnalyzerSettings.psd1` and clear every finding introduced by this feature
- [ ] T081 Verify statement coverage stays ≥ 80% on both mocked suites via `tests/coverage/bash-coverage.sh` and the Pester coverage run (Constitution XIII)
- [ ] T082 Run the full suites green on the three-OS matrix — `bats tests/bash`, `Invoke-Pester tests/powershell`, `bats tests/conformance` — and confirm the boundary greps in `.github/workflows/boundary.yml` still pass (Constitution VIII)
- [X] T083 Walk quickstart.md sections 1–9 end to end against a scratch repository and confirm each stated expectation
- [ ] T084 Dogfood before release per `specs/003-install-hook-activation/quickstart.md` §10: point a real repository at a real Jira project, install, configure, run a full lifecycle, and confirm a mirrored feature is reached with only the install command and the configuration command (SC-010, Constitution XII)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Setup — **BLOCKS all user stories**
- **User Stories (Phases 3–8)**: all depend on Foundational
- **Polish (Phase 9)**: depends on all desired user stories

### User Story Dependencies

- **US1 (P1, Phase 3)**: after Foundational. **Co-requisite: US3** — the manifest
  block US1 adds references `speckit.jira.reconcile`, which US3 creates. Shipping
  US1 alone would register seven hooks pointing at a command the agent cannot
  resolve, converting a silent no-op into a visible failure (spec.md US3 rationale).
- **US2 (P1, Phase 4)**: after Foundational. Depends on US1's `optional: false`
  declaration for the dispatch half; the disable-record half (T023–T030) is
  independently testable against the Foundational record alone.
- **US3 (P1, Phase 5)**: after Foundational. Independently testable — the
  resolution CI check runs against the manifest whether or not the install ran.
- **US4 (P1, Phase 6)**: after Foundational. T042 depends on US3's T034; T036–T041
  are independent of every other story.
- **US5 (P2, Phase 7)**: after Foundational. T044's literal check is strengthened
  once US3 declares the third command, but does not require it. T054 depends on
  Phase 8's T073 for the `--repair-hooks` removal to be consistent — sequence
  them together or land T073 first.
- **US6 (P2, Phase 8)**: after Foundational, where the writer is already deleted
  (T010/T011). Phase 8 removes the last call paths into it and builds the report
  on top. Its checksum assertions are only meaningful once US1 makes the install
  write entries, so run Phase 8 after Phase 3 for a genuine test.

### Within Each User Story

- Tests are written first and MUST fail before implementation
- Shared records (Phase 2) before consumers
- Bash implementation and PowerShell twin are peers, not sequential
- Manifest declaration before conformance verification
- Story complete before moving to the next priority

### Parallel Opportunities

- T004–T009 (both schemas and all four failing test suites) run together
- T010/T011, T012/T013 are two parallel port pairs
- T014–T017 run together; T021–T026 run together; T031–T033 run together;
  T036–T039 run together; T044–T049 plus T085–T088 run together;
  T055–T066 run together
- Every Bash/PowerShell twin pair marked [P] runs concurrently
- Once Phase 2 completes, US3, US4 and US5 can be staffed in parallel with
  US1/US2 by different developers

---

## Parallel Example: User Story 1

```bash
# Launch all four failing tests for User Story 1 together:
Task: "Failing manifest-shape CI check in tests/bash/ci/test_manifest_hooks.bats"
Task: "Failing twin CI check in tests/powershell/ci/Manifest.Hooks.Tests.ps1"
Task: "Failing install-registration test in tests/bash/conformance/test_us1_install_hooks.bats"
Task: "Failing twin in tests/powershell/conformance/Us1.InstallHooks.Tests.ps1"
```

## Parallel Example: Foundational port pairs

```bash
# Bash and PowerShell implementations touch different files:
Task: "Registry reader, writer deleted, in scripts/bash/hooks/register_hooks.sh"
Task: "Registry reader, writer deleted, in scripts/powershell/hooks/RegisterHooks.psm1"
```

---

## Implementation Strategy

### MVP (User Story 1 + User Story 3)

1. Phase 1: Setup — the install harness, both ports
2. Phase 2: Foundational — reader, writer deleted, disable record (CRITICAL, blocking)
3. Phase 3: User Story 1 — manifest declares the seven events
4. Phase 5: User Story 3 — the reconcile command exists and resolves
5. **STOP and VALIDATE**: install into a clean repository; seven hooks registered,
   enabled, each naming a resolvable command
6. This is the smallest increment that fixes the reported defect's first half

### Incremental Delivery

1. Setup + Foundational → reader ready, writer gone
2. + US1 + US3 → hooks registered and resolvable (**MVP**)
3. + US4 → the bridge is actually runnable after install (second half of the
   reported defect; ship together with the MVP if at all possible)
4. + US2 → hooks are performed, and an operator's disable survives a reinstall
5. + US5 → every remaining degraded run is truthful and correctly named
6. + US6 → the ceremony reports precisely, and the registry is provably untouched
7. Polish → docs, changelog, uninstall, coverage, three-OS green, dogfood

### Parallel Team Strategy

1. The team completes Setup + Foundational together
2. Then:
   - Developer A: US1 + US3 (manifest and commands layer)
   - Developer B: US4 + US5 (command procedures and messages)
   - Developer C: US2 + US6 (hooks layer, dispatch and reporting)
3. Bash and PowerShell twins can be split within any of the three tracks

---

## Notes

- [P] = different files, no dependency on an incomplete task
- Every behavioural task has a twin on the other port; a change that lands on one
  port only fails Constitution VI and the conformance suite
- The engine (`scripts/*/engine/`) and sink (`scripts/*/sink/`) directories are
  not touched by any task here — that is what keeps the two boundary CI greps
  green by construction (plan.md § Structure Decision)
- No task may add a write to `.specify/extensions.yml`. T057/T058 fail the build
  if one appears, including one added in good faith by a later feature
- Verify each test fails before implementing the task it covers
- Commit after each task or logical port pair

---

## Verification status of the three open tasks

T081, T082 and T084 are left unchecked because each needs an environment this
implementation session cannot reach. What WAS verified locally is recorded here
so the remaining work is exactly scoped.

- **T081 — statement coverage ≥ 80% on both ports.**
  PowerShell: **88.52% (3972/4487)** measured with Pester's CodeCoverage over
  `scripts/powershell/**`, 469 tests passing. **Met.**
  Bash: not measurable on macOS. `tests/coverage/bash-coverage.sh` refuses by
  design — kcov drives the traced script under `/bin/bash`, which on macOS is
  Apple's 3.2, a version this port rejects. The bats tracer ran and recorded
  1921 distinct statements, but the *denominator* (which lines kcov counts as
  statements) only exists on Linux. The CI "Bash coverage" job on ubuntu-22.04
  is where this gate is decided.

- **T082 — full suites green on the three-OS matrix.**
  Verified on macOS: `bats -r tests/bash` green, `Invoke-Pester tests/powershell`
  469 passed / 0 failed, and the full conformance corpus (31 scenarios) diffed
  byte-identically across both ports. Linux and Windows require CI.

- **T084 — dogfood against a real Jira before release.**
  Requires a real Jira Cloud project and credentials. Everything up to the Jira
  boundary was exercised: `specify extension add` into scratch repositories via
  the T001/T002 harness, the seven events registered and verified, the bridge
  invoked by repository-relative path immediately after install, and the
  unconfigured-repository path reported truthfully.
