---

description: "Task list for 026 — An Installable Artifact, Built From the One List That Already Says What Ships"
---

# Tasks: An Installable Artifact, Built From the One List That Already Says What Ships

**Input**: Design documents from `/specs/026-release-asset-install/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: REQUIRED, not optional. Constitution XIII makes development strictly Red-Green-Refactor and states
that *no implementation task may be planned without its test task preceding it in `tasks.md`*. Every
implementation task below names the test task it turns green, and every test task says what failure proves.

**Organization**: grouped by user story so each is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on an incomplete task
- **[Story]**: US1–US4, on user-story phases only
- Every task names its exact file path

## Phase ordering note

The specification gives US2 (publication) and US3 (gates) the same priority, P2. They are sequenced here as
**US3 before US2**, because `contracts/publication.md` C2.3 forbids publishing without the gates: publication
built first would be publication that cannot be wired to its blocking condition. US1 remains first, US4 last.

---

## Phase 1: Setup

**Purpose**: make the new development-only directory a first-class citizen of the existing checks, before
anything is written into it. Doing this first means the lint and suite gates cover `packaging/` from its very
first line rather than after someone notices.

- [X] T001 Create the directories `packaging/` and `tests/bash/packaging/` at the repository root, so the paths
  the later tasks reference exist (git tracks files, not directories, so they materialise with T012 and T006 —
  this task is the decision to place them there, recorded in `specs/026-release-asset-install/plan.md`)
- [X] T002 [P] Extend the shellcheck step in `.github/workflows/ci.yml` (job `lint`, step *shellcheck
  scripts/bash*) to also scan `packaging/`. The current command is `find scripts/bash -name '*.sh' -exec
  shellcheck -x -P scripts/bash {} +`, so a script under `packaging/` is unlinted today — verified by reading
  the job. Rename the step to match its widened scope
- [X] T003 [P] Extend the `--since` change-scoping map in `tests/run-bash.sh` (around line 133, the
  `scripts/bash/<module>` → `tests/bash/<module>` mirror) so a change under `packaging/` selects
  `tests/bash/packaging/`. Without this the inner loop silently runs zero tests for this feature's own code
- [X] T004 [P] Add `packaging/` and `tests/bash/packaging/` to any path filter in `.github/workflows/gates.yml`
  job `changes` that decides whether the bash-relevant jobs run

**Checkpoint**: the new directories exist and are covered by lint and suite discovery.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the exclusion-list correction, the surface derivation, the version reader, and the archive
builder. Every user story needs an artifact to exist; US3 needs one to gate, US2 needs one to publish, US1
needs one to install.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete.

### Tests (write first, observe them FAIL)

- [X] T005 [P] Write `tests/bash/helpers/consumer_fixture.bash` — a helper that creates a throwaway spec-kit
  consumer repository (`specify init --here`), starts a loopback HTTP server on a port **the operating system
  assigns** (bind 0), and returns both the recorded port and the recorded server PID. Constitution XIII forbids
  a fixed well-known port or any machine-wide scan for teardown; the helper publishes what it started so tests
  assert against a recorded identifier. Includes its own self-test asserting that two concurrent instances get
  different ports
- [X] T006 [P] Write `tests/bash/packaging/test_extensionignore_entries.bats` — asserts `.extensionignore`
  excludes `.git/` and `packaging/`. **Fails now**: the file lists `.github/`, `.gitignore` and `.gitattributes`
  but not `.git/`, which is why `--dev` copies 6 165 files and 38 MB of history into a consumer tree
  (research R5)
- [X] T007 [P] Write `tests/bash/packaging/test_surface_derivation.bats` — asserts the derivation of
  `contracts/surface-derivation.md` §2 yields exactly 87 files, contains `extension.yml`, both ports' entry
  points and all three command documents, and contains nothing under `tests/`, `specs/`, `docs/`, `.specify/`,
  `.github/`, `packaging/`, nor `.extensionignore` itself. **Fails now**: no derivation exists
- [X] T008 [P] Write `tests/bash/packaging/test_surface_matches_dev_install.bats` — performs a real
  `specify extension add --dev` into a fixture from T005 and asserts the installed tree equals the derived
  surface, member for member, both directions. **Fails now**: fails on the `.git` leak until T011 lands, which
  is exactly the failure that justifies T011
- [X] T009 [P] Write `tests/bash/packaging/test_version_resolution.bats` — asserts the resolver returns the
  `extension.version` value, never `schema_version` and never `requires.speckit_version`; fails loudly on an
  absent or empty field; and that `packaging/` contains no version literal anywhere. **Fails now**: no resolver
- [X] T010 [P] Write `tests/bash/packaging/test_build_artifact.bats` — asserts the builder writes an archive
  whose members all sit under a single `spec-kit-jira/` root, whose stripped contents equal the derived surface,
  and that **building twice produces byte-identical archives** (`contracts/artifact-shape.md` §4). **Fails
  now**: no builder

### Implementation

- [X] T011 Add `.git/` and `packaging/` to `.extensionignore`, each with the explanatory comment that file's
  existing style requires — `.git/` naming the measured 6 165-file / 38 MB leak, `packaging/` naming it as the
  release tooling a consumer cannot use. Turns T006 green and unblocks T008
- [X] T012 [P] Implement `packaging/resolve-version.sh` — reads `extension.version` from `extension.yml` using
  the same `sed` expression the existing *Version literal single-sourced* job uses, so there is one parsing
  behaviour rather than two; fails on absent or empty. Turns T009 green
- [X] T013 Implement the surface derivation in `packaging/build-artifact.sh` — `git ls-files` piped through
  `git -c core.excludesFile=.extensionignore check-ignore --no-index --stdin`, keeping the unreported
  candidates and subtracting `.extensionignore`. **No inclusion list, no `find -prune`, no reimplementation of
  gitignore syntax** (`contracts/surface-derivation.md` C2.2). Turns T007 green
- [X] T014 Implement archive writing in `packaging/build-artifact.sh` — every member under `spec-kit-jira/`,
  members emitted in sorted order, timestamps and permission bits normalised to fixed values (modes are
  discarded on extraction anyway, research R3), deflate with stored fallback, `set -euo pipefail`, partial
  output removed on failure, refusal to run on an empty derived surface. Turns T010 green
- [X] T015 Make `packaging/build-artifact.sh` print a machine-readable manifest of what it built — member
  count, uncompressed total, largest member and its path — to be consumed by the gates of Phase 4 rather than
  re-derived there

**Checkpoint**: `packaging/build-artifact.sh` produces a deterministic archive equal to the surface, and the
two install routes now agree. User story work can begin.

---

## Phase 3: User Story 1 — A consumer installs from the documented URL, and it works (Priority: P1) 🎯 MVP

**Goal**: installing from the artifact yields a *working* extension on macOS, Linux and Windows — including on
the lowest spec-kit host this extension declares it supports.

**Independent Test**: from a pristine consumer repository, install from a locally built artifact served over
loopback, then invoke the bridge's `--help` and read the hook registry. No publication needed.

**Why the fix below is in scope**: measured in research R3, a zip install on the declared floor host leaves the
bridge at `0644`; the documented bare-path invocation then exits 126, and our own prerequisite gate rejects the
`bash <script>` workaround with exit 5 while advising `--dev`, a route a URL consumer does not have. The user's
acceptance condition — *the bridge answers `--help`* — is unreachable without it.

### Tests for User Story 1 (write first, observe them FAIL)

> These seven files pin the current behaviour. They change **before** the implementation, and their failure is
> the proof the defect exists (Constitution XIII, and the project's rule that a regression test precedes a fix).

- [X] T016 [P] [US1] Write the regression test in `tests/bash/packaging/test_bridge_runs_without_exec_bit.bats`
  — installs a built artifact into a fixture, `chmod 644` the entry point to simulate the floor host
  deterministically, and asserts that the prerequisite gate does **not** report the bridge as missing and that
  `bash <path> --help` exits 0. **Fails now** with exit 5 from `scripts/bash/lib/prereq.sh:58`
- [X] T017 [P] [US1] Update `tests/bash/ci/test_agent_doc_invocation.bats` to require the `bash <path>` form in
  all three command documents (2 bridge-path references, 2 exec-bit references today)
- [X] T018 [P] [US1] Update `tests/bash/ci/test_agent_fallback_block.bats` for the new literals (3 and 2)
- [X] T019 [P] [US1] Update `tests/bash/ci/test_message_command_literals.bats` for the new literals (2 and 3)
- [X] T020 [P] [US1] Update `tests/bash/conformance/test_us4_bridge_runnable.bats` to drop its executable-bit
  premise and assert runnability through the interpreter instead (1 and 3)
- [X] T020a [P] [US1] Write `tests/bash/ci/test_consumer_docs_invocation.bats` — asserts that `README.md`,
  `INSTALL.md` and `templates/readme-block.template` instruct the bridge **through the interpreter**
  (`bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh …`) and contain no bare-path form.
  **Fails now**: four occurrences — README lines 109 and 213, INSTALL line 183, the template line 69. Nothing
  in the tree pins these three files today, which is how the instance was missed
  (`contracts/bridge-invocation.md` C4.3). The template is the one that matters most: it is **shipped**, and it
  writes this text into every consuming repository's own README
- [X] T021 [P] [US1] Mirror T017–T019 in `tests/powershell/ci/AgentDocInvocation.Tests.ps1`,
  `tests/powershell/ci/AgentFallbackBlock.Tests.ps1` and `tests/powershell/ci/MessageCommandLiterals.Tests.ps1`,
  keeping the literals byte-identical between ports as those tests already require. T020a gets **no** Pester
  mirror: it scans port-agnostic Markdown, and a second implementation of that scan would be exactly the
  duplicated-statement drift this feature exists to prevent — recorded here so review does not reflexively
  demand one (`contracts/bridge-invocation.md` §4 lists twenty files, not twenty-one)
- [X] T022 [US1] Run `bats tests/bash/packaging/test_bridge_runs_without_exec_bit.bats tests/bash/ci/test_agent_doc_invocation.bats tests/bash/ci/test_agent_fallback_block.bats tests/bash/ci/test_message_command_literals.bats tests/bash/ci/test_consumer_docs_invocation.bats tests/bash/conformance/test_us4_bridge_runnable.bats`
  and the three Pester files under `tests/powershell/ci/`, and **record the failures** in the task list — this
  is the Red step the constitution requires an operator to validate. Note `bats` needs `-r` for a directory
  argument or it silently runs nothing

### Implementation for User Story 1

- [X] T023 [US1] Remove the `-x` clause from `prereq_bridge_missing()` in `scripts/bash/lib/prereq.sh`
  (lines 56–61), keeping **both** `-f` clauses so a genuinely absent entry point is still reported with its own
  cause. Turns T016 green
- [X] T024 [P] [US1] Rewrite the bridge-missing remediation literal in `scripts/bash/lib/prereq.sh` and
  `scripts/powershell/lib/Prereq.psm1` (line 94) to name a route a URL-installing consumer actually has.
  `Prereq.psm1` needs **no logic change** — it never checked the bit, and its doc-comment at line 39 says why;
  removing the Bash check increases parity rather than threatening it
- [X] T025 [P] [US1] Update the matching remediation literals in `scripts/bash/commands/reconcile.sh`
  (line 599), `scripts/powershell/commands/Reconcile.psm1` (line 738), `scripts/bash/hooks/register_hooks.sh`
  (`HOOK_INSTALL_COMMAND`, line 62) and `scripts/powershell/hooks/RegisterHooks.psm1`
  (`$script:HookInstallCommand`, line 45). The two hook constants carry the same `--dev` literal C2.4 forbids
  and are pinned by `test_message_command_literals.bats` and its Pester mirror as *runnable exactly as spelled*
  (003 FR-018), so they change in the same task as the tests that pin them
- [X] T026 [P] [US1] Change the instructed invocation to `bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh …`
  in `commands/speckit.jira.config.md` (lines 36, 40, 55, 113), **and** rewrite the `--dev` remedy in the
  `incomplete` row of the hook-state table (line 255) to name the route a URL-installing reader has
  (`contracts/bridge-invocation.md` C2.4)
- [X] T027 [P] [US1] Same instructed-invocation change in `commands/speckit.jira.feature.md`
- [X] T028 [P] [US1] Same in `commands/speckit.jira.reconcile.md`
- [X] T028a [P] [US1] Change the instructed invocation to the `bash <path>` form in the three consumer
  documents: `README.md` (lines 109, 213), `INSTALL.md` (line 183) and `templates/readme-block.template`
  (line 69). The template is **shipped** — it writes this text into the consuming repository's own README, so
  leaving it is the one instance that keeps propagating after the fix. Turns T020a green.
  **Sequencing note**: README line 213 sits one line below an install URL that T048 rewrites in Phase 6; the
  two edits are independent but land in the same hunk, so whichever runs second must not revert the first
- [X] T029 [US1] Write `.github/workflows/install-e2e.yml` — a matrix of {`ubuntu-latest`, `macos-latest`,
  `windows-latest`} × {floor host, current host}. The floor is read from `requires.speckit_version` in
  `extension.yml` at job time, never written into the workflow, so the tested floor cannot drift from the
  declared one (`contracts/publication.md` C4.2). Each job: build the artifact, serve it over loopback on an
  OS-assigned port, `specify init` a fixture, install with `y` on stdin, then assert install exit 0, tree equals
  the surface, `--help` exit 0 as the command documents spell it, and all seven lifecycle events registered and
  enabled. Triggered on pushes touching `packaging/`, `.extensionignore`, `extension.yml`, the shipped surface
  or the release workflow, plus `workflow_dispatch`
- [X] T030 [US1] Confirm `.github/workflows/install-e2e.yml` asserts only its own outcomes and shares no state
  with the existing suites, so its signal stays readable against a `windows-latest` baseline that is
  independently red (`contracts/publication.md` C4.7)

**Checkpoint**: a locally built artifact installs and runs on all three operating systems, on both host
versions. This is the MVP — everything the user asked for is demonstrably true, just not yet published.

---

## Phase 4: User Story 3 — A wrong artifact never reaches a user (Priority: P2)

**Goal**: no artifact is publishable unless it is provably the installable surface, provably small enough, and
provably free of development material.

**Independent Test**: build three deliberately wrong artifacts and confirm each is rejected with a message
naming the offending entries.

### Tests for User Story 3 (write first, observe them FAIL)

- [X] T031 [P] [US3] Write `tests/bash/packaging/test_gate_entry_bounds.bats` — an archive padded past 256
  entries is rejected, and the message reports the measured count **and** the ceiling; archives breaching the
  uncompressed-total, largest-member, path-length and component-length bounds are each rejected with the
  measured value. **Fails now**: no gate exists
- [X] T032 [P] [US3] Write `tests/bash/packaging/test_gate_completeness.bats` — an archive with a surface file
  removed is rejected, and **every** missing path is listed, not just the first
- [X] T033 [P] [US3] Write `tests/bash/packaging/test_gate_purity.bats` — an archive with a development file
  injected (a `tests/` file, and separately a `.git/` entry) is rejected, and every extra path is listed
- [X] T034 [P] [US3] Write `tests/bash/packaging/test_gate_fail_closed.bats` — an absent archive, an unreadable
  `.extensionignore`, a `git` failure, and an empty derived surface each fail the gate. Asserts in particular
  that an empty surface is never read as "nothing is missing" (`contracts/surface-derivation.md` C4.4)
- [X] T035 [P] [US3] Write `tests/bash/packaging/test_gate_windows_hostile_names.bats` — a member path
  containing any of `<>:"|?*` or a reserved device name is rejected. Without this, such a name is discovered
  only by a Windows consumer, after publication

### Implementation for User Story 3

- [X] T036 [US3] Implement `packaging/verify-artifact.sh` — the bounds gate, consuming the manifest T015 emits
  rather than re-deriving it. States each ceiling in **exactly one place** with its rationale beside it
  (`contracts/artifact-shape.md` C3.2). Turns T031 and T035 green
- [X] T037 [US3] Implement the completeness and purity gates in `packaging/verify-artifact.sh` — the expected
  set obtained by performing a `--dev` install into a fixture from T005 and diffing, **never** from a committed
  inventory (FR-014, `contracts/surface-derivation.md` C3.3). Turns T032 and T033 green
- [X] T038 [US3] Make every gate fail-closed under `set -euo pipefail`, with each failure naming the offending
  paths rather than a count or a first offender. Turns T034 green
- [X] T039 [US3] Wire the cheap gates into `.github/workflows/gates.yml` as a new job that runs on **every**
  pull request: build, bounds, completeness, purity, determinism, version resolution. No network, seconds of
  wall clock

**Checkpoint**: a wrong artifact cannot pass CI. US1 and US3 both hold independently.

---

## Phase 5: User Story 2 — The maintainer cuts a version and the artifact publishes itself (Priority: P2)

**Goal**: every released version carries the artifact, named from the manifest, with zero manual steps.

**Independent Test**: run the publication path for a version and confirm both assets are attached, that the
embedded manifest version matches, and that a tag/manifest mismatch refuses to publish.

**Depends on**: Phase 4 — `contracts/publication.md` C2.3 requires the gates to run before any upload.

### Tests for User Story 2 (write first, observe them FAIL)

> The three rules below are *decisions*, not YAML plumbing, so they live in `packaging/publish-artifact.sh`
> and the workflow only calls it (`contracts/publication.md` C2.7, plan design decision 4). Written into
> `release.yml` they would be exercisable only by cutting a tag, and the Red step the constitution requires
> could never run.

- [X] T040 [P] [US2] Write `tests/bash/packaging/test_release_version_crosscheck.bats` — drives
  `packaging/publish-artifact.sh` with a tag naming a version that disagrees with `extension.yml` and asserts
  it exits non-zero naming **both** values (`contracts/publication.md` C2.2). Accepts `v1.2.3` and `1.2.3`
  spellings of the tag. **Fails now**: no such script
- [X] T041 [P] [US2] Write `tests/bash/packaging/test_release_asset_names.bats` — asserts
  `publish-artifact.sh` derives `spec-kit-jira.zip` and `spec-kit-jira-<version>.zip` from one archive, that
  the two carry identical bytes, and that the version comes only from the manifest (C2.4, A4)
- [X] T042 [P] [US2] Write `tests/bash/packaging/test_release_no_silent_overwrite.bats` — with a `gh` stub on
  `PATH` reporting an asset of that name already attached, asserts the script refuses and names the asset, and
  that a `gh` failure of any kind fails the run rather than passing it (FR-012, FR-019, Principle II)
- [X] T042a [P] [US2] Write `tests/bash/ci/test_workflow_release.bats` — asserts
  `.github/workflows/release.yml` invokes `packaging/verify-artifact.sh` before any upload step, and carries
  no version literal and no inline publication logic of its own (C2.3, C2.7, V1). The project already tests
  workflows this way — see `tests/bash/ci/test_workflow_bash_runner.bats` and `test_workflow_kcov_runner.bats`

### Implementation for User Story 2

- [X] T043 [US2] Implement `packaging/publish-artifact.sh` — resolves the version via
  `packaging/resolve-version.sh`, cross-checks it against the supplied tag and fails naming both on mismatch,
  derives the two asset names, and refuses to overwrite an asset already attached to the release. Every `gh`
  call goes through a single indirection so tests can stub it. **Settle first** the open question recorded at
  `contracts/publication.md` C2.7: whether this script creates the release when the tag has none, or requires
  one to exist — `…/releases/latest/download/…` (FR-010) resolves against a Release object, not a tag, and
  SC-008's "zero manual steps" depends on the answer. Turns T040, T041 and T042 green
- [X] T044 [US2] Write `.github/workflows/release.yml` — triggered by a version tag; builds the archive; runs
  `packaging/verify-artifact.sh` and blocks on failure with no override path; then calls
  `packaging/publish-artifact.sh` with the tag, the archive path and the ambient release credential. The
  workflow holds no logic of its own. Turns T042a green
- [X] T045 [US2] Make the whole path fail-closed — an unreadable manifest, a failed build, a failed gate, a
  failed cross-check or a failed upload leaves the release without a partially correct asset (C2.5, C2.6)

**Checkpoint**: cutting a tag publishes a gated artifact under both addresses, with no manual step.

---

## Phase 6: User Story 4 — The documentation stops lying (Priority: P3)

**Goal**: every install command points at the release artifact; the source-archive URL is gone and cannot come
back unnoticed; `--dev` stays documented as the development route.

**Independent Test**: search the consumer-facing documents for a source-archive address and find none;
reintroduce one and watch the check fail.

### Tests for User Story 4 (write first, observe them FAIL)

- [X] T046 [P] [US4] Write `tests/bash/packaging/test_docs_no_source_archive.bats` — fails if `archive/refs/`
  appears anywhere in `README.md` or `INSTALL.md`, naming file and line. **Fails now**: five occurrences across
  the two files (README lines 17, 102, 212, 309; INSTALL line 42)
- [X] T047 [P] [US4] Write `tests/bash/packaging/test_docs_no_version_literal.bats` — fails if the resolved
  version literal appears in `README.md`, `INSTALL.md` or anywhere under `packaging/`. This is what makes the
  version-free documented address a checked property rather than an intention

### Implementation for User Story 4

- [X] T048 [US4] Replace every install command in `README.md` (lines 17, 102, 212, 309) with
  `specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip`.
  Turns T046 partly green
- [X] T049 [US4] Same in `INSTALL.md` (line 42), and add the pinned form with a `<X.Y.Z>` **placeholder**, never
  a literal (`contracts/publication.md` C3.3). Completes T046 and T047
- [X] T050 [P] [US4] Document the untrusted-source confirmation in `INSTALL.md` (FR-024) — installing from a
  URL outside a configured catalog raises an `⚠ Untrusted Source` panel and blocks on
  `Continue with installation? [y/N]:`; with no stdin it prints `Aborted.` and installs nothing, which in a
  script reads as success. Measured in research R8
- [X] T051 [P] [US4] Keep `--dev` documented in both files, explicitly labelled as the route for **developing
  the extension**, not for consuming it (FR-022)
- [X] T052 [US4] Add the two documentation checks to `.github/workflows/gates.yml` so they run on every pull
  request alongside the existing version-literal gate (FR-023)

**Checkpoint**: all four user stories hold independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T053 [P] Update `CHANGELOG.md` with the entry for this feature — the broken install path, the artifact,
  the `--dev` `.git` leak, and the bridge-runnability fix. Constitution XII makes a maintained changelog
  mandatory, and `CHANGELOG.md` is one of only two files permitted to carry the version literal
- [X] T054 [P] Verify `shellcheck -x -P scripts/bash` is clean across `scripts/bash` **and** `packaging/`, and
  that `actionlint` is clean across the two new workflows and the two modified ones
- [X] T055 Run `tests/run-bash.sh` in full and confirm green (~190 s locally; the runner is roughly an order of
  magnitude slower, so size any new `timeout-minutes` from real step timings, not from local ones)
- [X] T056 Run `bash tests/conformance/ci-conformance.sh` and confirm cross-port byte equivalence. Success is
  silent: exit 0 with zero "conformance divergence" lines
- [ ] T057 Run the Pester suite and confirm the three modified files pass on both a macOS and a Linux host —
  Pester discovery order differs by host, so a green macOS run is not by itself evidence
- [X] T058 Walk `quickstart.md` end to end on a real machine, including the floor-host steps, and correct any
  step whose observed output differs from what it claims
- [X] T059 Confirm the existing *Version literal single-sourced* job in `.github/workflows/gates.yml` is still
  green — `packaging/` is deliberately inside its scan, so a version accidentally hard-coded in the builder is
  caught here
- [ ] T060 Dogfood: install the built artifact into a real consuming repository and run one reconcile.
  Constitution XII requires every shipped feature to be dogfooded against a real Jira instance before release

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no dependencies — start immediately
- **Phase 2 (Foundational)**: depends on Phase 1 — **blocks all user stories**
- **Phase 3 (US1, P1)**: depends on Phase 2
- **Phase 4 (US3, P2)**: depends on Phase 2; independent of US1
- **Phase 5 (US2, P2)**: depends on Phase 2 **and Phase 4** — publication cannot be wired to gates that do not
  exist (`contracts/publication.md` C2.3). This is the one genuine cross-story dependency in the feature
- **Phase 6 (US4, P3)**: depends on Phase 2 only — the documented URL can be written and checked before
  anything is published, and the check is what stops the address regressing
- **Phase 7 (Polish)**: depends on every story that is being shipped

### Within Phase 2

`T005` (fixture helper) precedes `T008`, which uses it. `T011` (`.extensionignore`) precedes `T008` passing —
that is the point of T008. `T013` (derivation) precedes `T014` (archive writing). `T015` precedes T036, which
consumes its output.

### Within each user story

Tests are written and observed to FAIL before implementation. In US1 specifically, T022 is the explicit Red
checkpoint the constitution requires an operator to validate.

### Parallel opportunities

- T002, T003, T004 — three different files
- T005–T010 — six independent test files
- T012 is independent of T013/T014 once T011 lands
- T016–T021 plus T020a — seven independent test files
- T024–T028 plus T028a — seven files, all literals and documents, once T023 lands
- T031–T035 — five independent test files
- T040–T042 plus T042a — four independent test files
- T046, T047 — two independent test files
- **US1, US3 and US4 can proceed in parallel** once Phase 2 is complete; US2 waits on US3

---

## Parallel Example: Phase 2 tests

```bash
# Six test files, no shared state, all expected to fail:
Task: "Write tests/bash/helpers/consumer_fixture.bash"
Task: "Write tests/bash/packaging/test_extensionignore_entries.bats"
Task: "Write tests/bash/packaging/test_surface_derivation.bats"
Task: "Write tests/bash/packaging/test_surface_matches_dev_install.bats"
Task: "Write tests/bash/packaging/test_version_resolution.bats"
Task: "Write tests/bash/packaging/test_build_artifact.bats"
```

## Parallel Example: User Story 1 literals

```bash
# Once T023 has landed, these change independently:
Task: "Rewrite the remediation literal in scripts/bash/lib/prereq.sh and scripts/powershell/lib/Prereq.psm1"
Task: "Update literals in reconcile.sh, Reconcile.psm1, register_hooks.sh and RegisterHooks.psm1"
Task: "Change the instructed invocation in commands/speckit.jira.config.md"
Task: "Change the instructed invocation in commands/speckit.jira.feature.md"
Task: "Change the instructed invocation in commands/speckit.jira.reconcile.md"
Task: "Change the instructed invocation in README.md, INSTALL.md and templates/readme-block.template"
```

---

## Implementation Strategy

### MVP first (Phases 1–3)

1. Phase 1 — Setup
2. Phase 2 — Foundational (blocks everything)
3. Phase 3 — US1
4. **STOP and VALIDATE**: a locally built artifact installs and runs on all three operating systems and both
   host versions. At this point the reported defect is fixed in substance; only publication and the guard rails
   remain.

### Incremental delivery

1. Setup + Foundational → an artifact exists and the two install routes agree
2. **US1** → it installs and runs everywhere (MVP)
3. **US3** → a wrong one cannot be published
4. **US2** → it publishes itself on every version
5. **US4** → the documentation points at it and cannot regress

### Note on CI cost

The cheap gates (Phase 4, wired in T039) run on every pull request. The three-OS × two-host end-to-end install
(T029) is the expensive one and is triggered narrowly. This project's runners are roughly an order of magnitude
slower than local, and a `windows-latest` retry costs about an hour and rarely teaches anything — one retry,
then read the result rather than re-running.

---

## Notes

- **Tests are not optional here.** Every implementation task above names the test task it turns green; a task
  list that reversed that order would fail the constitution's own review gate.
- The single most important invariant to protect during implementation: **no file other than
  `.extensionignore` may enumerate what ships.** If a task tempts you toward a path list in the builder or in a
  gate, that is the drift this whole feature exists to prevent.
- [P] tasks touch different files with no dependency on an incomplete task.
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
