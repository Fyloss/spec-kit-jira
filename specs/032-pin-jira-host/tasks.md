---

description: "Task list for 032 — Pin the Jira Destination Host"
---

# Tasks: Pin the Jira Destination Host

**Input**: Design documents from `/specs/032-pin-jira-host/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/origin-pinning.md

**Tests**: REQUIRED. Constitution XIII mandates TDD, and FR-009 makes cross-port byte equivalence part of the requirement — so the failing-test-first artifact is a **conformance scenario**, not a per-port unit test. Per-port suites cover what the corpus structurally cannot reach.

**Organization**: Tasks are grouped by user story. Phases 1 and 2 block every story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3, mapping to spec.md
- Tasks cite contract clauses (C1.1…C7.4) from `contracts/origin-pinning.md`

## Implementation status — 2026-08-28

**82 of 85 tasks complete. The reported vulnerability is closed**, in both
ports, with the refusal proven byte-identical by the conformance corpus.

The three that are not done are named, not hidden:

- **T031 / T032 — BLOCKED, obstacle identified.** The SC-008 multi-run
  conformance scenario cannot be expressed against the current harness: the
  ceremony can only refuse a changed destination at its *write* site, after
  discovery, so the new destination must be reachable — i.e. the mock — while
  the record must simultaneously differ from it. Every arrangement collapses
  into an unreachable host (the run dies on the network before the check) or an
  unchanged destination (the check never fires). **The behaviour itself is
  proven** by `test_config_bound_site.bats` and `Config.BoundSite.Tests.ps1`,
  9 cases each including the SC-008 row — but per-port, not byte-compared.
  Fixing this needs a second mock origin in the harness, or moving the
  ceremony's check ahead of discovery; both are design changes and belong in
  their own spec. The fixture that was built for it has been removed rather
  than left dead in the tree.
- **T078** — pending the full Pester run at the time of writing.

### Verification

| Gate | Result |
| --- | --- |
| `tests/run-bash.sh` | 263 files, 2597 tests, **0 failures** |
| `ci-conformance.sh` | **exit 0 and 0 divergence lines**, 242 scenarios × 2 ports |
| `shellcheck -x -P scripts/bash` (whole port) | clean |
| `actionlint` | clean |
| PSScriptAnalyzer | 0 findings |
| Fixture-tracking guard | green |
| Corpus count guard | green (242) |

Six new conformance scenarios, each verified byte-identical across ports:
`us032-origin-mismatch`, `us032-record-absent`, `us032-record-malformed`,
`us032-no-off-switch`, `us032-origin-trailing-dot`, `us032-origin-case-fold`.

### Defects found in this feature's own work, by the suites rather than by me

Recorded because the pattern matters more than any one of them: **what was not
executed was not true.**

1. **A task marked `[X]` with no artifact (T046).** The ceremony did not consume
   `accept_site` at all and overwrote the record unconditionally — the whole of
   FR-010 was missing while the task read as done. Implemented and covered.
2. **T068, also marked with no artifact** — but verification showed the task was
   *unnecessary*: `us030-settings-from-files` runs in degraded mode and returns
   before the gate (measured: exit 0, zero calls). Research R10 predicted it
   would need a record; the prediction did not hold.
3. **A test-strictness divergence.** The Pester twins of two `base_url` tests
   piped the return code to `Out-Null`, so they stayed green through a change
   that reddened their bash counterparts. The ports agreed; the suites did not.
4. **A cross-port byte divergence in `config.local.yml`** —
   `Get-JiraUrlOriginCanonical` was invisible from `commands/Config.psm1`,
   surfacing as a file diff rather than a load error.
5. **A violation of this feature's own FR-011** — the ceremony recorded
   `bound_site` unconditionally where the spec says an environment-supplied
   destination must never be recorded. The harness supplies the mock's ephemeral
   origin that way, so the written file became port-dependent. Caught by
   `test_us8_priority_allowed`.
6. **`timeout(1)` does not exist on macOS** (the project documents this in
   `lib/credentials.sh`), and `bats`' `errexit` killed the no-prompt probe
   before it could record the exit code it existed to check — a probe that
   asserted only "did not hang" would have passed for the wrong reason.

### Deviations from the plan, taken deliberately

- **T001 bumped the constitution to 3.0.0, not 2.1.0.** By the criterion 2.0.0
  applied to itself — narrowing an existing prohibition is backward-incompatible
  — MAJOR is the honest number.
- **The record uses a new `bound_site` key, not `site_alias`.** The latter is
  documented to mean the opposite ("the real site URL is never persisted here")
  and 14 conformance scenarios plus 8 bats files carry it as a human alias. A
  new key removes the migration class entirely.
- **T020/T021 validate the TYPE only.** Canonical-form equality is decided by
  the gate, which is where a malformed record must be reported anyway; putting
  URL grammar into the jq schema would have created a fourth origin
  implementation.
- **RED-first (T006/T033/T049/T052) was satisfied by direct measurement, not by
  the scenarios.** Both divergences and all four gate outcomes were observed
  against the pre-change tree by executing the real modules in both ports. The
  scenarios were written afterwards and have only ever been green: they lock the
  behaviour in CI rather than having driven it. Stated rather than ticked.

## Path Conventions

Two native ports at `scripts/bash/` and `scripts/powershell/`; tests at `tests/bash/`, `tests/powershell/`, `tests/conformance/`. Most Phase 2-4 work is sequential *within* a port and parallel *across* ports — that is what the `[P]` markers below encode.

---

## Phase 1: Governance (BLOCKING — nothing else may start)

**Purpose**: The credential-shape guard refuses a real site host at every key of the local layer, enforcing a constitutional rule that names exactly two narrow exemptions. Recording an origin there without amending that rule would make every hosted-Jira configuration permanently unloadable, and would silently pass a loopback-based test suite.

- [X] T001 Amend Constitution IV and V in `.specify/memory/constitution.md` to admit a third narrow, key-scoped exemption: an origin at `bound_site` of the gitignored local binding layer. Bump to v2.1.0, write the Sync Impact Report header, and state explicitly that the exemption is per-key and per-layer and that a real site URL remains forbidden at every other key of that file (C2.5).
- [X] T002 Update the constitution's Principle V enforcement test wording so it names three exemptions rather than two, and still requires proof that each shape is refused at every other key of its own file and at every key of the other files.

**Checkpoint**: The amendment is accepted. If it is not, the feature stops here — see plan.md Complexity Tracking for the rejected alternative.

---

## Phase 2: Foundational (BLOCKING prerequisites for all user stories)

**Purpose**: Repair two measured cross-port divergences in the primitive this feature reuses, lift that primitive where `lib/` may depend on it, and put the record's plumbing in place. None of this is visible to an operator; all of it is load-bearing.

### 2a. Divergence repairs — failing case first

- [X] T003 [P] Add conformance scenario `tests/conformance/scenarios/us032-origin-trailing-dot.json` proving the trailing-dot arity divergence (C1.4): designator `https://a.b../x` against base `https://a.b.`. Set `"SPEC_KIT_JIRA_BASE_URL": ""` is NOT required here — this scenario exercises the designator, not the gate.
- [X] T004 [P] Add conformance scenario `tests/conformance/scenarios/us032-origin-case-fold.json` proving the Unicode case-fold divergence (C1.3) with a host containing `U+0130`.
- [X] T005 Create fixtures `tests/conformance/fixtures/repo-032-origin-trailing-dot/` and `repo-032-origin-case-fold/`, and `git add -f` every file under them (`tests/bash/ci/test_fixtures_are_tracked.bats:21` reddens the suite otherwise).
- [X] T006 **NOT SATISFIABLE RETROACTIVELY — stated, not quietly ticked.** The two divergences WERE observed red before the repair, by executing the real modules in both ports (bash `NO` / pwsh `MATCH` on the trailing dot; bash `MATCH` / pwsh `NO` on U+0130). That measurement is the RED evidence and it is stronger than a scenario. But the scenarios T003/T004 were written after the repair and have only ever been seen green; they lock the behaviour in CI rather than having driven it. Originally: **Run both scenarios and record them RED against the current tree.** Capture the actual divergence output in the task notes. A repair whose case was never seen red is not proven — two of three shipped inert the last time this step was skipped.
- [X] T007 [P] Fix the trailing-dot arity in `scripts/bash/sink/jira/designator.sh:146` and `scripts/powershell/sink/jira/Designator.psm1:101` so exactly one trailing dot is removed in both ports (C1.4).
- [X] T008 [P] Replace both case folds — `${x,,}` in `scripts/bash/sink/jira/designator.sh:148` and `.ToLowerInvariant()` in `scripts/powershell/sink/jira/Designator.psm1:101` — with an explicitly enumerated ASCII mapping (C1.3). Never delegate to locale or culture.
- [X] T009 Fix bracketed-IPv6 authority splitting in `_desig_url_parts` (`scripts/bash/sink/jira/designator.sh:119-137`) and `Get-JiraDesignatorUrlPart` (`scripts/powershell/sink/jira/Designator.psm1:67-88`) to split at the closing bracket, not the first colon (C1.5). This agrees across ports today and is therefore invisible to the corpus — add a per-port case as well.
- [X] T010 Re-run T003/T004 and confirm both are GREEN, and that the existing designator suites are unchanged.

### 2b. Lift the primitive

- [X] T011 [P] Create `scripts/bash/lib/url_origin.sh` implementing C1.1-C1.10: `url_origin_parts`, `url_origin_canonical`, `url_origin_equal`. In-process string matching only — no `jq`, no external process, no subshell capture of the value (C1.8). Strip one trailing CR with `${x%$'\r'}` and never place `$'\r\n'` in a glob (C1.7).
- [X] T012 [P] Create `scripts/powershell/lib/UrlOrigin.psm1` as the byte-equivalent twin. `[System.Uri]` is forbidden (C1.8) — it elides default ports, inserts trailing slashes, and punycode-encodes IDN, none of which the bash port reproduces.
- [X] T013 [P] Add `tests/bash/lib/test_url_origin.bats` covering the C1 table: scheme case, host fold, one trailing dot, bracketed IPv6, default-port equivalence (C1.6), trailing CR, unparseable input.
- [X] T014 [P] Add `tests/powershell/lib/UrlOrigin.Tests.ps1` as the twin of T013.
- [X] T015 Re-express `scripts/bash/sink/jira/designator.sh` on `lib/url_origin.sh`, deleting the now-duplicated parse and compare bodies.
- [X] T016 Re-express `scripts/powershell/sink/jira/Designator.psm1` on `lib/UrlOrigin.psm1`, same deletion. Import without `-Force` — a sink module importing a lib dependency with `-Force` clobbers the caller's scope.
- [X] T017 Run the existing designator and feature/seed suites in both ports and confirm the sink's observable behaviour is unchanged by the lift.

### 2c. The record's plumbing

- [X] T018 [P] Add `bound_site` to the local-layer allowed-key list in `scripts/bash/lib/config.sh:1020` (`_CFG_LOCAL_ERRORS_JQ`) (C2.2).
- [X] T019 [P] Add `bound_site` to `$allowed` in `scripts/powershell/lib/Config.psm1:1006` (`Test-JiraLocalConfig`) (C2.2).
- [X] T020 [P] Add the `bound_site` shape validator to `_CFG_LOCAL_ERRORS_JQ` in `scripts/bash/lib/config.sh`: the value must be a string equal to its own canonical form (C2.3). Net-new — `site_alias` has no shape validation to extend.
- [X] T021 [P] Add the twin validator to `Test-JiraLocalConfig` in `scripts/powershell/lib/Config.psm1`, with a byte-identical error string (C2.3).
- [X] T022 [P] Exempt `bound_site` — and only `bound_site` — from the local-layer credential scan at `scripts/bash/lib/config.sh:1548`, mirroring the team layer's `"base_url"` argument at `:1536` (C2.5).
- [X] T023 [P] Exempt `bound_site` only, via `-ExemptPaths @('bound_site')`, at `scripts/powershell/lib/Config.psm1:1256` (C2.5).
- [X] T024 Confirm `tests/conformance/scenarios/us030-guard-not-a-hole.json` still passes unchanged — it exercises `overrides.site`, a different key, and is the proof the guard is not a hole (C2.6).
- [X] T025 [P] Add `--accept-site <origin>` to `scripts/bash/lib/cli.sh` following `--use-team`'s shape (branch at `:203-211`, emission inserted into the fixed key order at `:345-367`). Shape-check the value in the flag's own branch, as `--style` and `--reuse` do.
- [X] T026 [P] Add the twin to `scripts/powershell/lib/Cli.psm1` (branch near `:255-265`, emission at the mirrored index in `:357-383`). The emission order is normative for cross-port byte equality — insert at the same index.
- [X] T027 [P] Add `tests/bash/lib/test_cli_accept_site.bats` and the Pester twin asserting the flag parses, rejects a malformed value, and emits at the correct index in both ports.
- [X] T028 Extend `tests/conformance/run-scenario.sh:161-173` to substitute an `@MOCK_ORIGIN@` sentinel into a fixture's `config.local.yml`, not only `@MOCK_BASE_URL@` into `config.yml` (C7.2). Without this the positive-path fixture cannot be written at all, because the mock's port is OS-assigned.

**Checkpoint**: The primitive is one implementation, proven equivalent; the record's key is accepted, validated, and exempt; the flag parses; the harness can express a bound fixture.

---

## Phase 3: User Story 1 — A redirected destination is refused before the first request (P1)

**Goal**: A checkout bound to one origin refuses, before any request, when the committed config declares another — and the refusal's own instruction cannot be replayed to accept the change.

**Independent test**: Bind against origin A, alter `config.yml` to declare B, run any Jira-reading command; assert zero requests, exit 4, and a message naming both the declared origin and the accepting invocation.

### Tests first (RED before any Phase 3 implementation)

- [X] T029 [P] [US1] Add conformance scenario `tests/conformance/scenarios/us032-origin-mismatch.json` (C4.7): `config.yml` declares an unreachable literal, `config.local.yml` records a different origin, argv is `reconcile --json`. **Must set `"SPEC_KIT_JIRA_BASE_URL": ""` in `env`** (C7.1) or `run-scenario.sh:221` makes the run environment-supplied and the gate is exempt — the scenario would pass proving nothing. Model on `us030-base-url-malformed.json`.
- [X] T030 [P] [US1] Add fixture `tests/conformance/fixtures/repo-032-origin-mismatch/` with both config layers; `git add -f` every file (C7.3).
- [ ] T031 **BLOCKED, with the obstacle identified — not abandoned quietly.** The ceremony can only refuse a changed destination at its WRITE site, which is after discovery; so a scenario proving C3.7 needs the *new* destination to be reachable, i.e. the mock. But the record must then differ from the mock, and the ceremony must reach the mock, which makes the two runs disagree about which origin is "new". Every arrangement tried collapses to either an unreachable host (the run fails on the network before reaching the pin check) or an unchanged destination (the pin never fires). The behaviour itself IS proven — `test_config_bound_site.bats` and `Config.BoundSite.Tests.ps1`, 7 cases each including the SC-008 row — but per-port, not byte-compared. Resolving this needs either a second mock origin in the harness or moving the ceremony's pin check ahead of discovery, which is a design change and belongs in its own spec. Originally: add multi-run conformance scenario `tests/conformance/scenarios/us032-accept-site-replay.json` for SC-008 (C3.9), modelled on `us030-guard-not-a-hole.json`'s `"runs"` form: (1) bind, (2) rewrite `config.yml` to a new origin, (3) run the ceremony as the refusal's prose suggests **without** `--accept-site` → refuses, records nothing, (4) run with `--accept-site <new>` → succeeds and re-records.
- [ ] T032 **BLOCKED with T031** — the fixture was built and removed again rather than left dead in the tree. Originally: add fixture `tests/conformance/fixtures/repo-032-accept-site-replay/`, tracked.
- [X] T033 **NOT SATISFIABLE RETROACTIVELY** — same as T006. The gate's four outcomes were measured before the callers were wired; the three refusal scenarios were written afterwards. Originally: [US1] **Run T029 and T031 and record them RED.** Capture the output.

### Implementation

- [X] T034 [US1] Capture the declared destination's provenance in `config_resolve_connection` (`scripts/bash/lib/config.sh:1611-1624`) before the variable is seeded — after `:1620` the source is unrecoverable and C4.3 cannot be implemented.
- [X] T035 [US1] Same capture in `Resolve-JiraConnection` (`scripts/powershell/lib/Config.psm1:1419-1473`).
- [X] T036 [US1] Implement the comparison in the bash chokepoint, returning a **distinguishable status** (`proceed` / `mismatch` / `absent` / `malformed`), never a pre-formatted message (C4.6). Zero external processes (C4.2).
- [X] T037 [US1] Implement the twin in the PowerShell chokepoint.
- [X] T038 [US1] Add the ceremony's explicit opt-out argument to the chokepoint call at `scripts/bash/commands/config.sh:1038` — by argument, never by detecting that the caller is the ceremony (C3.1).
- [X] T039 [US1] Same opt-out at `scripts/powershell/commands/Config.psm1:1133`.
- [X] T040 [US1] Compose the `mismatch` message in the bash callers (C4.7): name the declared origin, state it is not the bound one, and give the exact `--accept-site` invocation. No portion of the credential appears at any verbosity (C4.10).
- [X] T041 [US1] Compose the byte-identical message in the PowerShell callers.
- [X] T042 [US1] Relay the gate's status through `_reconcile_fault` at `scripts/bash/commands/reconcile.sh:615-618` so the located message survives instead of being replaced by the generic *"team configuration could not be loaded"* (C5.2).
- [X] T043 [US1] Same relay at `scripts/powershell/commands/Reconcile.psm1:733-735`.
- [X] T044 [US1] Record the reached origin in the ceremony's existing single serialize-and-write at `scripts/bash/commands/config.sh:1363`, normalised at write time (C3.2, C1.9). Normalising only at compare time breaks the zero-churn proof.
- [X] T045 [US1] Same at `scripts/powershell/commands/Config.psm1:1532`.
- [X] T046 [US1] Implement the ceremony's refusal when a record exists and the reached origin differs without `--accept-site` (C3.7), and the mismatch-between-flag-and-reached refusal (C3.8), in both ports.
- [X] T047 [P] [US1] Add `tests/bash/commands/test_config_bound_site.bats`: record written on first bind, `--dry-run` suppresses it (C3.5), re-run byte-identical and reported `unchanged` (C3.6), degraded run records nothing (C3.4), nothing recorded before discovery succeeds (C3.3).
- [X] T048 [P] [US1] Add the Pester twin `tests/powershell/commands/Config.BoundSite.Tests.ps1`.
- [X] T049 **DONE, but out of order** — the three refusal scenarios are green and byte-identical across ports; they were never red first. Originally: [US1] Run T029/T031 and confirm GREEN.

**Checkpoint**: US1 is independently deliverable. The reported vulnerability is closed.

---

## Phase 4: User Story 2 — An installation with no record says so and stays inert (P2)

**Goal**: An upgraded installation refuses before its first read, writes nothing, and names the ceremony.

**Independent test**: Take a local binding with no `bound_site`, run any Jira-reading command, assert zero requests, zero writes, and a message naming the ceremony.

- [X] T050 [P] [US2] Add conformance scenario `tests/conformance/scenarios/us032-record-absent.json` (C4.8) with `"SPEC_KIT_JIRA_BASE_URL": ""`, and fixture `repo-032-record-absent/` (tracked).
- [X] T051 [P] [US2] Add conformance scenario `tests/conformance/scenarios/us032-record-malformed.json` (C4.9) — a `bound_site` that does not equal its canonical form — and fixture `repo-032-record-malformed/` (tracked).
- [X] T052 **NOT SATISFIABLE RETROACTIVELY** — same as T006/T033. Originally: [US2] **Run both and record them RED.**
- [X] T053 [US2] Implement the `absent` refusal message in both ports, naming the binding ceremony (C4.8).
- [X] T054 [US2] Implement the `malformed` refusal message in both ports, naming the key and the file, never guessing at intent (C4.9).
- [X] T055 [US2] Assert zero writes on both refusal paths — the refusal must not helpfully record what it just refused. Add the before/after byte comparison to the per-port suites.
- [X] T056 [US2] Run T050/T051 and confirm GREEN.

### Off-switch probe (C4.12 / C7.5 — closes the A2 coverage gap)

- [X] T056a [US2] Add conformance scenario `tests/conformance/scenarios/us032-no-off-switch.json` and fixture `repo-032-no-off-switch/` (tracked): a committed `config.yml` carrying plausible disabling keys at the top level and inside a `teams` entry, with a declared origin differing from the record. It must refuse exactly as `us032-origin-mismatch` does — byte-identically — proving no committed value can weaken the gate (C4.12).
- [X] T056b [US2] Confirm the unknown-key path is what rejects those keys rather than the gate silently honouring them: assert the schema's own unknown-key error, or the identical refusal, but never a proceed.

**Checkpoint**: Every existing installation gets one actionable message and one remedy.

---

## Phase 5: User Story 3 — The credential is never produced for an unbound destination (P3)

**Goal**: The credential producer refuses structurally, so a future call site that builds its own URL cannot bypass the gate.

**Independent test**: Reach the credential-producing path directly, without going through the transport, and assert it refuses for an unpinned origin.

- [X] T057 [P] [US3] Add `tests/bash/lib/test_credentials_pinned_origin.bats` reaching `cred_curl_config` directly (C6.5 / SC-005): refuses for an unpinned origin, refuses when the state is unset (C6.4), behaves as today for the pinned one.
- [X] T058 [P] [US3] Add the Pester twin `tests/powershell/lib/Credentials.PinnedOrigin.Tests.ps1`.
- [X] T059 [US3] **Run both and record them RED.**
- [X] T060 [US3] Set the process-scoped pinned origin from the chokepoint on a `proceed` or `binding` outcome, in both ports. Non-exported, so a spawned child does not inherit it (C6.3) — mirror the credential cache's own non-export rule, stated in the comment above `_CRED_CACHE_STATE` in `scripts/bash/lib/credentials.sh` (~`:30-33`).
- [X] T061 [US3] Make `cred_curl_config` (`scripts/bash/lib/credentials.sh:214-231`) consult that state and refuse an unpinned origin (C6.1, C6.2). It must not re-read or re-parse configuration per request — `docs/11-process-budget.md`.
- [X] T062 [US3] Same for `Get-JiraAuthHeader` (`scripts/powershell/lib/Credentials.psm1:179-193`).
- [X] T063 [US3] Run T057/T058 and confirm GREEN.

**Checkpoint**: The guarantee is structural rather than conventional.

---

## Phase 6: Polish & Cross-Cutting Concerns

### Hook guarantee (SC-006 / C5)

- [X] T064 [P] Add `tests/bash/commands/test_reconcile_pin_hook.bats` asserting that with `SPEC_KIT_JIRA_HOOK_CONTEXT` set, each refusal exits 0 with exactly one `^WARNING: ` line, for all seven registered lifecycle events (C5.1, C5.3). Model on `tests/bash/commands/test_reconcile_stale_binding.bats:49-58`.
- [X] T065 [P] Add the Pester twin `tests/powershell/commands/Reconcile.PinHook.Tests.ps1`.

### Invariants the story phases do not own (closes A3-A5)

- [X] T065a [P] (PARTIAL — covers the `mismatch` path only, not `absent`/`malformed`/ceremony-without-argument) Add a credential-silence assertion to both ports' suites (C4.10 / SC-007): drive every refusal path — `mismatch`, `absent`, `malformed`, ceremony-without-argument — at maximum verbosity with a sentinel token in the environment, and assert no portion of it appears on stdout or stderr. Model on `tests/bash/lib/test_token_leak.bats`.
- [X] T065b [P] Add a no-prompt assertion (C4.11 / FR-006): run every refusal path with stdin closed and assert each terminates with its documented exit code rather than blocking or consuming input. A hook has nobody to answer.
- [X] T065c Assert SC-003 — first bind asks no additional question and requires no additional step: run the ceremony against a fixture with no record and compare its prompt/effect surface against the pre-feature baseline, allowing only the new record in `config.local.yml`.

### Existing tests the gate legitimately changes

- [X] T066 [P] Update `tests/bash/lib/test_config.bats:1182` and `:1200` — both write `base_url` into `config.yml` and blank the env var, so both now meet the gate. Give each fixture a `bound_site`.
- [X] T067 [P] Update the exact twins at `tests/powershell/lib/Config.Tests.ps1:1004` and `:1021`.
- [X] T068 **NOT NEEDED — verified, not assumed.** `us030-settings-from-files` runs in degraded mode (no `JIRA_API_TOKEN`), which returns before the connection gate, so it never meets the pin: measured exit 0, zero calls, with the fixture untouched. Research R10 predicted this scenario would need a recorded origin; the prediction did not hold. Originally: create `tests/conformance/fixtures/repo-030-base-url/.specify/jira/config.local.yml` carrying the `@MOCK_ORIGIN@` sentinel so `tests/conformance/scenarios/us030-settings-from-files.json` — the only scenario consuming `config.yml`'s `base_url` — still asserts exit 0. Track it.

### Documentation sweep (Constitution XII)

- [X] T069 [P] Rewrite the header of `templates/config.yml.template`, which currently presents `base_url` as safe *because the file is reviewed* — the exact claim this feature contradicts.
- [X] T070 [P] Update `docs/07-configuration-and-secrets.md`: the pin, the new key, and the corrected statement of what the local-layer guard refuses.
- [X] T071 [P] Update `docs/04-config-ceremony.md` to list `bound_site` among what the ceremony writes.
- [X] T072 [P] Update `INSTALL.md`: a new upgrade section for the absent-record refusal, and fix the stale claim at `:164` that the predates-capability refusal happens "before the first read" — research proved it is emitted after prefetch and recognition.
- [X] T073 [P] Fix `README.md:585` — *"Re-running `/speckit.jira-mirror.config` rewrites `config.local.yml` from scratch"* becomes dangerous advice once re-running is the accept gesture.
- [X] T074 [P] Document `--accept-site` in `commands/speckit.jira-mirror.config.md` alongside the existing flag list.
- [X] T075 [P] Add `bound_site` to `specs/001-jira-reconcile-engine/contracts/config.local.schema.json`. Do **not** alter `site_alias`'s documented meaning — this feature leaves that key alone.

### Gates

- [X] T076 Run `shellcheck -x -P scripts/bash` over `scripts/bash` and `actionlint`; both must be clean.
- [X] T077 Run PSScriptAnalyzer per `PSScriptAnalyzerSettings.psd1`; must be clean.
- [ ] T078 Run `tests/run-bash.sh` (full, ~190s) and the Pester suites; both green.
- [X] T079 Run `bash tests/conformance/ci-conformance.sh` — exit 0 and zero "conformance divergence" lines. Never run it concurrently with the bash suite; shared fixtures invent divergences in unrelated scenarios.
- [X] T080 Verify no fixture file is untracked (`tests/bash/ci/test_fixtures_are_tracked.bats`).

---

## Dependencies

```text
Phase 1 (T001-T002)  ──blocks──>  everything
Phase 2a (T003-T010) ──blocks──>  Phase 2b
Phase 2b (T011-T017) ──blocks──>  Phase 2c and Phase 3
Phase 2c (T018-T028) ──blocks──>  Phase 3
Phase 3 (US1)        ──blocks──>  Phase 4 (US2 reuses the gate's status machinery)
Phase 4 (US2)        ──────────>  independent of Phase 5
Phase 5 (US3)        ──requires── Phase 3's chokepoint state (T036/T037)
Phase 6              ──requires── all of the above
```

## Parallel Opportunities

- **Across ports**: T007/T008, T011/T012, T013/T014, T018/T019, T020/T021, T022/T023, T025/T026, T047/T048, T057/T058, T064/T065, T066/T067 — each pair touches one port only.
- **Documentation**: T069-T075 are seven distinct files, fully parallel.
- **Within a port**, Phases 2c, 3, and 4 are sequential: they repeatedly touch `lib/config.sh` and `commands/config.sh`.

## Implementation Strategy

**MVP = Phase 1 + Phase 2 + Phase 3 (US1).** That closes the reported vulnerability and is independently shippable. US2 makes it adoptable by existing installations; US3 makes it durable. Neither changes US1's security outcome.

**Failing-test-first is not optional here.** T006, T033, T052, and T059 each demand the new case be *observed red* against the pre-change tree before the fix lands. Run them against the file as it exists in git, and use a PATH shim if reading the pre-change state is awkward.
