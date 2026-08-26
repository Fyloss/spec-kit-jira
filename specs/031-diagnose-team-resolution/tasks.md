# Tasks: A pass-through says which state produced it

**Feature**: `specs/031-diagnose-team-resolution/` | **Branch**: `fix/diagnose-inactive-team-selection`
**Input**: [spec.md](./spec.md) · [plan.md](./plan.md) · [research.md](./research.md) · [data-model.md](./data-model.md) · [contracts/pass-through-diagnosis.md](./contracts/pass-through-diagnosis.md) · [quickstart.md](./quickstart.md)

## Format: `[ID] [P?] [Story] Description`

- **[P]** — parallelisable: different file, no dependency on an incomplete task.
- **[US1] / [US2] / [US3]** — the user story the task serves. Setup,
  Foundational and Polish tasks carry no story label.

**Tests are NOT optional here.** Constitution XIII requires a failing test
first, and the specification's acceptance scenarios are written to be exactly
that. Every phase below leads with its tests.

## Path Conventions

| Concern | Bash port | PowerShell port |
| --- | --- | --- |
| Feature command | `scripts/bash/commands/feature.sh` | `scripts/powershell/commands/Feature.psm1` |
| Configuration library | `scripts/bash/lib/config.sh` | `scripts/powershell/lib/Config.psm1` |
| Unit tests | `tests/bash/{commands,lib}/` | `tests/powershell/{commands,lib}/` |
| Cross-port equivalence | `tests/conformance/scenarios/*.json` + `tests/conformance/fixtures/` | same corpus, both ports |

---

## Phase 1: Setup (shared fixtures)

Four repository shapes the whole feature is tested against. None exists today.

- [X] T001 [P] Add fixture `tests/conformance/fixtures/repo-031-config-unloadable/` — a valid `teams:` catalogue whose `config.yml` carries a deliberate YAML syntax error, and no `personal.yml`
- [X] T002 [P] Add fixture `tests/conformance/fixtures/repo-031-personal-unloadable/` — a valid `config.yml` plus a `personal.yml` that parses but violates the schema
- [X] T003 [P] Add fixture `tests/conformance/fixtures/repo-031-nested/` — a valid catalogue and a `team: ijt` selection at the fixture root, plus an empty `sub/module/` directory to invoke from
- [X] T004 [P] Add fixture `tests/conformance/fixtures/repo-031-no-project/` — a directory carrying no `.specify/` at any level

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: give every pass-through branch a name, without changing one byte
of output. This is what US1 and US3 both build on, and it is provable on its
own: the whole existing corpus must stay green.

⚠️ **No user story can start until this phase completes.**

- [X] T005 Add a unit test in `tests/bash/commands/test_feature.bats` asserting the resolution-state identifiers of [data-model.md §1](./data-model.md) are exhaustive and mutually exclusive for the states this feature defines — two of them (`personal-unloadable` as a distinct outcome, and `no-repository`) are not reachable before it lands
- [X] T006 [P] Mirror T005 in `tests/powershell/commands/Feature.ResolutionState.Tests.ps1`
- [X] T007 Introduce the resolution-state identifier at each existing pass-through branch in `scripts/bash/commands/feature.sh` (the `[[ ! -f config.yml ]]` branch ~L758, the `config_load` failure ~L767, the zero-team branch ~L785) and in `config_personal_load`'s two branches in `scripts/bash/lib/config.sh` — carried internally only, no output change
- [X] T008 Mirror T007 in `scripts/powershell/commands/Feature.psm1` and `scripts/powershell/lib/Config.psm1`
- [X] T009 Run the full existing corpus and confirm byte-identical output on every path — `tests/run-bash.sh` and `bash tests/conformance/ci-conformance.sh` — proving the vocabulary is inert before anything speaks

**Checkpoint**: states are named internally; behaviour is unchanged.

---

## Phase 3: User Story 1 — a broken configuration announces itself (P1) 🎯 MVP

**Goal**: a file that exists and fails to load is reported with its located
reason; a file that does not exist stays silent.

**Independent test**: place a `config.yml` with a known malformed line in a
repository with no personal selection, run `feature` naming no ticket, and see
the located error and the pass-through. Delivers value with nothing else built.

### Tests for User Story 1

- [X] T010 [P] [US1] Failing test in `tests/bash/commands/test_feature.bats` — a malformed `config.yml` is reported with file and located reason, exit 0, zero Jira calls (contract C2.1, C3.1, C3.2; spec AS1)
- [X] T011 [P] [US1] Failing test in `tests/bash/commands/test_feature.bats` — a schema-violating `config.yml` names the offending key, never the bare word "invalid" (C2.1; AS2)
- [X] T012 [P] [US1] Failing test in `tests/bash/commands/test_feature.bats` — an unloadable `personal.yml` is reported and does NOT fail the run, replacing today's exit 4 (C3.3, FR-013; AS5)
- [X] T013 [P] [US1] Regression test in `tests/bash/commands/test_feature.bats` — an EMPTY `config.yml` and an EMPTY `personal.yml` stay silent, never reported as load failures (C2.5; edge case)
- [X] T014 [P] [US1] Mirror T010–T013 in `tests/powershell/commands/Feature.Diagnosis.Tests.ps1`
- [X] T015 [US1] Add conformance scenario `tests/conformance/scenarios/us031-config-unloadable.json` over fixture T001, and `us031-personal-unloadable.json` over T002 — the report is byte-identical across ports (C5.1)

### Implementation for User Story 1

- [X] T016 [US1] Stop discarding the loader's stderr at `scripts/bash/commands/feature.sh` ~L767 (`config_load "${dir}" 2> /dev/null`) — capture it and emit it as the report; leave the absent-file branch at ~L758 untouched
- [X] T017 [US1] Make an unloadable `personal.yml` report-and-continue rather than fail, at the EARLIER call site — `config_resolve_connection` in `scripts/bash/lib/config.sh` ~L1488, which runs before the explicit personal load and is where the run actually dies today (research D3)
- [X] T018 [US1] Mirror T016 in `scripts/powershell/commands/Feature.psm1`
- [X] T019 [US1] Mirror T017 in `scripts/powershell/lib/Config.psm1`
- [X] T020 [US1] Confirm `us3-feature-no-team.json` and `us29-feature-us6-no-config-no-mention.json` pass **unmodified** — the silence this feature must not break (C5.3, FR-004, FR-005)
- [X] T021 [US1] Add conformance scenario `tests/conformance/scenarios/us031-zero-team-catalogue.json` over the EXISTING fixture `tests/conformance/fixtures/repo-030-no-teams/` — a valid `config.yml` declaring no teams, invoking `feature` with no ticket mentioned, asserting silence (C2.3, FR-017). The clarification session decided this state is a supported single-project setup; nothing tests it today, and `us030-personal-no-teams.json` only looks like it does — it drives the `config` command and asserts a comment's wording
- [X] T022 [US1] Failing test in `tests/bash/commands/test_feature.bats` and the PowerShell twin — `--dry-run` output and exit code are unchanged on the two branches this story alters, so the exit-code change of FR-013 does not silently move the predicted run (Principle XI)

**Checkpoint**: US1 is independently shippable. US2 and US3 need nothing from it.

---

## Phase 4: User Story 2 — the configuration is found from the repository (P2)

**Goal**: the same repository state yields the same result from any starting
directory.

**Independent test**: valid configuration and selection at the repository root,
invoke from a subdirectory, get the same naming as from the root.

### Tests for User Story 2

- [X] T023 [P] [US2] Failing test in `tests/bash/lib/test_config.bats` — resolution order is `JIRA_CONFIG_DIR`, then `SPECIFY_INIT_DIR`, then the nearest ancestor carrying `.specify/` (C1.1, FR-014, FR-015)
- [X] T024 [P] [US2] Failing test in `tests/bash/lib/test_config.bats` — the walk goes upward only and stops at the filesystem root (C1.2)
- [X] T025 [P] [US2] Failing test in `tests/bash/commands/test_feature.bats` — no ancestor carries `.specify/` ⇒ a report naming the directory walked from, exit 0, no fallback to a relative path (C1.4, FR-008; AS3)
- [X] T026 [P] [US2] Mirror T023–T025 in `tests/powershell/lib/Config.Resolution.Tests.ps1`
- [X] T027 [US2] Add conformance scenario `tests/conformance/scenarios/us031-nested-invocation.json` over fixture T003 and `us031-no-project.json` over T004 — path resolution and absolute-path spelling are the two hosts' divergence surface, so these belong here and not in per-port tests (C5.2)
- [X] T028 [P] [US2] Failing test asserting run-state relocation is not a recognition failure and creates no duplicate (C1.5, FR-016)

### Implementation for User Story 2

- [X] T029 [US2] Implement the upward `.specify/` walk in `scripts/bash/lib/config.sh`, honouring an explicit `JIRA_CONFIG_DIR` first and `SPECIFY_INIT_DIR` second — reimplemented natively, never sourcing the host's `common.sh` (research D1)
- [X] T030 [US2] Mirror T029 in `scripts/powershell/lib/Config.psm1`
- [X] T031 [US2] Ensure every message introduced by this feature names the RESOLVED absolute path, never the relative form it is written as (FR-009, C1.3's spelling obligation)
- [X] T032 [US2] Assert by grep that neither port gained a `git` invocation — `grep -rE "\bgit (checkout|switch|branch|init|add|commit|rev-parse)\b" scripts/bash scripts/powershell` must still return zero (C1.3)

**Checkpoint**: the last unobservable state is gone.

---

## Phase 5: User Story 3 — an operator can ask which state produced it (P3)

**Goal**: `--verbose` names the state and the consulted path; default output
does not move.

**Independent test**: run with the verbose diagnostic in a repository in each
state and confirm each is named distinctly.

### Tests for User Story 3

- [X] T033 [P] [US3] Failing test in `tests/bash/commands/test_feature.bats` — `--verbose` names the resolution state, the absolute path consulted, and what would change it, for each of the seven states (C4.1, FR-010)
- [X] T034 [P] [US3] Failing test — WITHOUT `--verbose`, default and `--json` output carry no new line and no new key (C4.2, FR-011)
- [X] T035 [P] [US3] Mirror T033–T034 in `tests/powershell/commands/Feature.Verbose.Tests.ps1`

### Implementation for User Story 3

- [X] T036 [US3] Consume the `verbose` flag `lib/cli.sh` already parses (`:98`, `:350`) inside `cmd_feature` in `scripts/bash/commands/feature.sh` — it is currently never read
- [X] T037 [US3] Mirror T036 in `scripts/powershell/commands/Feature.psm1`
- [X] T038 [US3] Confirm no new flag, no manifest change, no new argument surface was introduced (C4.3, Principle XV)

**Checkpoint**: every state is diagnosable on request; nothing is unavoidable.

---

## Phase 6: Polish & cross-cutting concerns

These belong to no user story, which is exactly why they are enumerated. Four
of the five are constitutional obligations a story-driven task list drops.

- [X] T039 **Principle IV — credentials never echoed.** Test that a
      credential-shaped value in either file is reported by its located reason
      WITHOUT the value appearing, at maximum verbosity (`--verbose`),
      in `tests/bash/commands/test_feature.bats` and the PowerShell twin (C2.6)
- [X] T040 **The fail-closed departure needs its own test.** FR-013 narrows
      Principle III's posture on one branch; contract **C3.4** requires proof
      that the refusal C6.2 still governs survives — a run that WOULD reach the
      network with an unloadable `personal.yml` must still fail closed. Without
      this the C6.2a amendment is a hole, not an exception
- [X] T041 **Principle II — live suite.** This feature adds no write kind and
      touches no sink interface, so `tests/live/test_live_zero_churn.bats`
      needs no extension. Record that judgement in the task list rather than
      leaving it unexamined
- [X] T042 **Principle IX — privacy guard.** This feature writes nothing to any
      tracked file and issues no Jira request, so the guard's surface is
      unchanged. Confirm by asserting zero writes on every path it introduces
- [X] T043 [P] Update `docs/07-configuration-and-secrets.md` with the resolution
      order — it is the document that explains where each setting lives, and it
      currently describes a relative path
- [X] T044 [P] Update `docs/06-feature-naming.md` — its flow ends at
      `{active:false}` as a single outcome; it now has seven named states
- [X] T045 [P] Add the `CHANGELOG.md` entry under `## [Unreleased]`, written
      from the operator's side: what they will now be told that they were not
- [X] T046 Run `shellcheck` over `scripts/bash` and `actionlint`, and the full
      `tests/run-bash.sh` plus `bash tests/conformance/ci-conformance.sh`,
      never concurrently — shared fixtures invent divergences when overlapped

---

## Dependencies

```
Phase 1 (fixtures)  ──┐
                      ├──> Phase 2 (state vocabulary, output unchanged)
                      │         │
                      │         ├──> Phase 3 US1 (P1)  ← MVP, shippable alone
                      │         ├──> Phase 4 US2 (P2)  ← independent of US1
                      │         └──> Phase 5 US3 (P3)  ← reads the vocabulary
                      │
                      └──> Phase 6 (polish, after the stories it audits)
```

- **US1, US2 and US3 are mutually independent** once Phase 2 lands. They may be
  built in any order, or in parallel by different people.
- **T040 depends on T017/T019** — it tests the branch they change.
- **T020 and T032 are guards, not features**: they assert something did NOT
  change, and must run at the end of their phase.

## Parallel execution

- **Phase 1**: T001–T004 are four separate fixture directories — all four at once.
- **Phase 2**: T005 ∥ T006 (different ports), then T007 ∥ T008.
- **Phase 3**: T010–T014, T021 and T022 are all test or scenario authoring in
  distinct files — parallel. T016 ∥ T018 and T017 ∥ T019 pair the two ports.
- **Phase 6**: T043, T044, T045 touch three different documents.

## Implementation strategy

**MVP is Phase 1 + Phase 2 + Phase 3.** That ships the change with the largest
share of the reported pain — an operator whose configuration is broken is told
so instead of being told nothing — and it is provable without either other
story. Phase 3 carries three guards that assert the *opposite* of its own
change (T013, T020, T021) plus one that asserts the predicted run did not move
(T022): this story makes two states speak, and the whole risk is that it makes
a third speak by accident.

**Phase 4 second**, because it removes the one state an operator cannot observe
by any means, and because until it lands the "absent file stays silent" rule of
US1 rests on a path that may simply have been the wrong one.

**Phase 5 last.** It is the cheapest of the three and the only one whose value
depends on the other two being distinguishable in the first place.
