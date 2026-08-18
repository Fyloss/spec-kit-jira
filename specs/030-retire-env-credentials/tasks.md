---
description: "Task list for feature 030 — retire the .env credential file"
---

# Tasks: Retire the .env credential file

**Input**: Design documents from `/specs/030-retire-env-credentials/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: REQUIRED, not optional. Constitution XIII mandates TDD with a ≥80%
coverage gate, so every implementation task below is preceded by its failing
test. Where a contract says *conformance*, a per-port unit test does **not**
discharge the obligation — cross-port byte equality is what is being asserted.

**Constitution**: v2.0.0 (ratified 2026-08-18) — the amendment this feature
required is in place. Principles IV and V now permit the two-rung chain and the
base URL at one key of the team config.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: US1–US4 for user-story phases; Setup/Foundational/Polish carry none

## Path conventions

Two native ports. Every Bash path under `scripts/bash/` has a PowerShell twin
under `scripts/powershell/`; tests under `tests/bash/` and `tests/powershell/`;
cross-port scenarios under `tests/conformance/scenarios/`.

---

## Phase 1: Setup — fixtures and harness

**Goal**: Make a config-sourced base URL testable before anything depends on it.

- [X] T001 Add **two** sentinel substitutions to `tests/conformance/run-scenario.sh`, both applied after the fixture copy and before the run: `@MOCK_BASE_URL@` in the copied workdir's `.specify/jira/config.yml` (research §R6), and `@PAT_HANG_COMMAND@` in the scenario's **`env` values** (research §R11) — resolved once per run to `sleep 30` on POSIX and to an absolute path to a sleeping executable on Windows, and handed **identically to both ports** so the value that lands in both failure messages is the same string
- [X] T002 Add a bats test for both substitutions in `tests/bash/conformance/test_run_scenario.bats`: `@MOCK_BASE_URL@` is replaced for both port backends, `@PAT_HANG_COMMAND@` is replaced in an env value and resolves to something that actually blocks, a fixture without either sentinel is copied byte-identically, and the resolved hang command is recorded so the two port runs can be compared to it
- [X] T003 [P] Create fixture `tests/conformance/fixtures/repo-030-base-url/` — a `config.yml` declaring `base_url: "@MOCK_BASE_URL@"`, no `personal.yml`. **Depends on T013/T014 accepting a loopback `http` URL** (research §R10): the sentinel resolves to `http://127.0.0.1:<port>`, which the pre-R10 validation rule would have refused at load time
- [X] T004 [P] Create fixture `tests/conformance/fixtures/repo-030-no-personal/` — a valid `config.yml` with a two-team catalogue and no `personal.yml`
- [X] T005 [P] Create fixture `tests/conformance/fixtures/repo-030-no-teams/` — a valid `config.yml` whose catalogue declares no teams, no `personal.yml`
- [X] T005a `git add` the three new fixture directories in the same commit that introduces them — `tests/bash/ci/test_fixtures_are_tracked.bats` fails on an untracked fixture, and it fails on the Linux runner while staying green on macOS

**Fixture constraint (Constitution IV, unchanged by v2.0.0)**: no fixture may
contain a real site URL, authentication email, or token. Use the sentinel or an
`.invalid` host, and `example.com` addresses.

**Checkpoint**: `bash tests/conformance/ci-conformance.sh` still exits 0 with no
`conformance divergence` lines.

---

## Phase 2: Foundational — blocking prerequisites

**Goal**: The schema, guard, and resolution primitives every story depends on.
**⚠️ No user story can start until this phase is complete.**

### Credential-shape guard — per-key exemption (data-model §4, connection-settings §5)

- [X] T006 [P] Write failing bats tests in `tests/bash/lib/test_config.bats` for `_cfg_credential_errors` with an exempt-path argument: exempt path passes, every other path still refuses, `privacy` stays exempt unconditionally, and `^ATATT` is refused even at an exempt path
- [X] T007 [P] Write the failing Pester twin in `tests/powershell/lib/Config.Tests.ps1` for `Get-JiraConfigCredentialError -ExemptPaths`
- [X] T008 Parameterize `_cfg_credential_errors` in `scripts/bash/lib/config.sh` with an optional exempt-path list, extending the existing `select( ($p[0] // "") != "privacy" )` mechanism rather than replacing it
- [X] T009 Parameterize `Get-JiraConfigCredentialError` / `Get-JiraCredentialPathError` in `scripts/powershell/lib/Config.psm1` with `-ExemptPaths`, extending the existing `$Path -like 'privacy*'` check
- [X] T010 Pass no exemptions from the YAML parse-cache predicate in `config_yaml_to_json` (`scripts/bash/lib/config.sh`) and its PowerShell twin — a `personal.yml` holding an email stays uncacheable by design (research §R8)

### `config.yml` gains `base_url` (data-model §2, connection-settings §2)

- [X] T011 [P] Write failing bats tests in `tests/bash/lib/test_config.bats` for the **whole** `base_url` table of connection-settings §2.2: accepts `https://host`; accepts `http://` at the three loopback literals `127.0.0.1`, `localhost`, `[::1]`; refuses trailing slash, path, scheme-less, empty, `http://` to a non-loopback host, and `http://192.168.1.10` (private range is not loopback); absent is accepted. Add the C2.7 case too — a malformed `SPEC_KIT_JIRA_BASE_URL` with no `base_url` in the file is passed through unvalidated
- [X] T012 [P] Write the failing Pester twin in `tests/powershell/lib/Config.Tests.ps1`, same table including the loopback and C2.7 rows
- [X] T013 Add `base_url` to the top-level allowed-key set in `_CFG_CONFIG_ERRORS_JQ` (`scripts/bash/lib/config.sh`) and implement its validation per data-model §2/§2a — `https` anywhere, `http` only at a loopback **literal**, no DNS lookup — emitting `config: config (<path>): base_url is invalid`
- [X] T014 Add `base_url` to `$allowedTop` in `scripts/powershell/lib/Config.psm1` and implement the byte-identical validation and message, including the same loopback rule
- [X] T015 Pass the `base_url` exemption from the `config.yml` load path in both ports; pass **none** from the `config.local.yml` path

### `personal.yml` gains `email`, and `team` becomes optional (data-model §3, connection-settings §3–§4)

- [X] T016 [P] Write failing bats tests in `tests/bash/lib/test_personal_config.bats` for the five `team` states of data-model §3 — absent is inactive, present-and-empty still refuses, present-and-valid unchanged — plus the `email` accept/refuse table
- [X] T017 [P] Write the failing Pester twin in `tests/powershell/lib/PersonalConfig.Tests.ps1`
- [X] T018 Add `email` to the allowed keys of `_CFG_PERSONAL_ERRORS_JQ` and make the `team` pattern check conditional on the key being present (`scripts/bash/lib/config.sh`) — this removes the `(.team // "")` construct that scores an absent key as `team is invalid`
- [X] T019 Skip the catalogue-membership check in `config_personal_load` when `team` is absent, returning `{"active": false}` — without this a repository whose catalogue is empty fails as soon as `personal.yml` exists
- [X] T020 Mirror T018 and T019 in `Test-JiraPersonalObject` and `Import-JiraPersonalConfig` (`scripts/powershell/lib/Config.psm1`)
- [X] T021 Pass the `email` exemption from the `personal.yml` load path in both ports

### The resolution chokepoint (plan §Key design decision, connection-settings §1)

- [X] T022 [P] Write failing bats tests in `tests/bash/lib/test_config.bats` for `config_resolve_connection`: sets the variable only when unset or empty, never overwrites a non-empty value, treats the empty string as unset
- [X] T023 [P] Write the failing Pester twin for `Resolve-JiraConnection` in `tests/powershell/lib/Config.Tests.ps1`
- [X] T024 Implement `config_resolve_connection` in `scripts/bash/lib/config.sh`, seeding `SPEC_KIT_JIRA_BASE_URL` and `JIRA_EMAIL` from the loaded config and personal files
- [X] T025 Implement `Resolve-JiraConnection` in `scripts/powershell/lib/Config.psm1`
- [X] T026 Call the chokepoint after `config_load` in all five Bash entry points — `scripts/bash/commands/{config,reconcile,feature,mention,seed}.sh`
- [X] T027 Call it in all five PowerShell entry points — `scripts/powershell/commands/{Config,Reconcile,Feature,Mention,Seed}.psm1`
- [X] T028 Add a per-port test asserting **every** entry point resolves, enumerated from the command dispatch table rather than hand-listed, in `tests/bash/commands/test_dispatch.bats` and `tests/powershell/lib/Cli.Tests.ps1` — a missed entry point is a command that works only when the operator also exported the variable

**Checkpoint**: both suites green; the 72 existing readers of
`SPEC_KIT_JIRA_BASE_URL` remain untouched.

---

## Phase 3: User Story 1 — The token never touches a file in the workspace (P1)

**Goal**: Two rungs, no `.env`, no undeclared probe, and a failure that says which
source failed and how.

**Independent test**: with no token file in the workspace and no token
environment variable, declare a retrieval command and confirm the bridge
authenticates; then confirm no workspace file contains the token.

### Tests first

- [X] T029 [P] [US1] Write failing bats tests in `tests/bash/lib/test_credentials.bats` for credential-resolution.md §1–§3: env-first precedence, command never executed when the env var is set, and the five outcome rows C3.3–C3.7
- [X] T030 [P] [US1] Write the failing Pester twin in `tests/powershell/lib/Credentials.Tests.ps1`
- [X] T031 [P] [US1] Write a failing bats test for C2.2 (metacharacter inertness) in `tests/bash/lib/test_credentials.bats`: `JIRA_PAT_COMMAND='echo tok | tee <tmp>'` must leave the file uncreated
- [X] T032 [P] [US1] Write the failing Pester twin for C2.2 in `tests/powershell/lib/Credentials.Tests.ps1`, asserting `Invoke-Expression` is not on the resolution path
- [X] T033 [P] [US1] Write a failing bats test for C2.5 (bounded execution) in `tests/bash/lib/test_credentials.bats`, using a sleeping helper and asserting the bound is enforced and reported as a command failure
- [X] T034 [P] [US1] Write the failing Pester twin for C2.5 in `tests/powershell/lib/Credentials.Tests.ps1`
- [X] T035 [US1] Write a failing bats test in `tests/bash/lib/test_credentials.bats` for C2.6 (executed at most once per run) that counts executions across several `$(jira_request …)` subshells — the counter must live outside the subshell
- [X] T036 [US1] Write the failing Pester twin for C2.6 in `tests/powershell/lib/Credentials.Tests.ps1`

### Retiring what the deleted rungs left behind (C7.1)

**Deleting `_cred_from_env_file` and `_cred_from_secret_manager` orphans seven
existing test artifacts.** They are not collateral damage to discover at T099 —
they are the failing-test half of T037/T038 and are written first.

- [X] T036a [US1] Repurpose the counting `PATH` shim rather than deleting it: `tests/bash/helpers/secret_store_stub.bash` → a retrieval-command shim (`helper_pat_command_install` / `helper_pat_command_count`) that installs a counting stand-in program and, in a second mode, installs `security`/`secret-tool` stand-ins that must **never** be invoked. Mirror in `tests/powershell/helpers/SecretStoreStub.psm1`. Keep the counting design and its rationale comment — feature 021 built it because a count is a count, not a wall clock
- [X] T036b [US1] Follow the rename in the two meta-tests, `tests/bash/ci/test_secret_store_stub_helper.bats` and `tests/powershell/ci/SecretStoreStubHelper.Tests.ps1`
- [X] T036c [US1] Rewrite the eight `.env`/probe tests in `tests/bash/lib/test_credentials.bats` — "falls back to the gitignored .env…", "environment token wins over the .env file", "secret manager sits between env and .env", the two dotenv-convention tests, the CRLF one, the cross-port `.env` one, and the three silent-fall-through tests — into their two-rung equivalents. The three fall-through tests invert: a present-but-failing `security` on `PATH` must now be **ignored entirely** (C1.3a), not fallen through from
- [X] T036d [US1] Mirror T036c in `tests/powershell/lib/Credentials.Tests.ps1` (`Get-JiraEnvFileToken` / `Get-JiraSecretManagerToken` assertions)
- [X] T036e [US1] Rewrite `tests/bash/commands/test_reconcile_credential_cache.bats` — its seven tests count *secret-store consultations*; after this feature the same at-most-once claim (C2.6, feature 021 SC-004) is about `JIRA_PAT_COMMAND` executions. Keep every claim, change what is counted. **There is no PowerShell twin of this file** (measured: `tests/powershell/commands/` holds no credential-cache test, and the only PowerShell users of the shim are `lib/Credentials.Tests.ps1` and `ci/SecretStoreStubHelper.Tests.ps1`), so the reconcile-level counting claim exists in the Bash port alone — leave it that way rather than inventing a twin this feature did not ask for

### Implementation

- [X] T037 [US1] Delete `_cred_from_env_file` from `scripts/bash/lib/credentials.sh` and remove the `JIRA_CONFIG_DIR`-based `.env` path (C1.2)
- [X] T038 [US1] Delete `_cred_from_secret_manager` from `scripts/bash/lib/credentials.sh`, removing the hardcoded `security` / `secret-tool` probes (C1.3)
- [X] T039 [US1] Implement the retrieval-command rung in `scripts/bash/lib/credentials.sh`: read `JIRA_PAT_COMMAND` from the environment only, split into an argument vector, execute without a shell, trim stdout, bound the wait, keep the `set +x` bracket down for the whole token lifetime
- [X] T040 [US1] Delete `Get-JiraEnvFileToken` and `Get-JiraSecretManagerToken` from `scripts/powershell/lib/Credentials.psm1` and implement the mirrored retrieval-command rung in `Resolve-JiraToken`
- [X] T041 [US1] Preserve the three-state cache and `_CRED_SECRET_TOKEN` test override in `scripts/bash/lib/credentials.sh` and `scripts/powershell/lib/Credentials.psm1` (C1.5, C5.1–C5.3); keep `cred_prime_cache` called from the main shell so the command is not re-executed per request
- [X] T042 [US1] Emit the resolution failure at the Bash call site in `scripts/bash/sink/jira/client.sh`, which today breaks silently with `rc="$(cli_exit_code auth)"` and prints nothing (C6.1)
- [X] T043 [US1] Emit the byte-identical failure at the PowerShell call site in `scripts/powershell/sink/jira/Client.psm1` where `Get-JiraAuthHeader` returns `$null` (C6.2, C6.3)
- [X] T044 [US1] Ensure no failure report echoes the command's stdout while its stderr is reported (C4.4), in `scripts/bash/lib/credentials.sh` and `scripts/powershell/lib/Credentials.psm1`, with assertions in `tests/bash/lib/test_credentials.bats` and `tests/powershell/lib/Credentials.Tests.ps1`

### The third call site — the ceremony's degraded trigger (FR-038, C6.4–C6.6)

**The one an `/speckit-analyze` pass found missing.** `config` is the command an
operator runs *because* credentials misbehave, and both ports discard the reason.

- [X] T044a [US1] Write failing tests in `tests/bash/commands/test_config_degraded.bats` and `tests/powershell/commands/Config.Degraded.Tests.ps1` for the C6.4 split: with **no** `JIRA_PAT_COMMAND`, degraded mode is silent about the rung and lists `JIRA_API_TOKEN` among the missing parameters exactly as today; with a **declared and failing** one, the C3.x reason appears on stderr and in `detail`, and the ceremony still exits 0 in degraded mode
- [X] T044b [US1] Replace `cred_resolve_token > /dev/null 2>&1` at `scripts/bash/commands/config.sh:942` with a call that distinguishes "no command declared" from "declared and failed", carrying the reason into `_config_degraded_run`'s `detail` and onto stderr — and **not** making it fatal (C6.5)
- [X] T044c [US1] Mirror T044b at `scripts/powershell/commands/Config.psm1:1043` (`if (-not (Resolve-JiraToken))`), byte-identical text (C6.6)
- [X] T044d [US1] Update the stale comment above both call sites — "a token that resolves through none of the **three rungs**" — there are two

### Conformance (per-class, cross-port — a unit test does not discharge these)

- [X] T045 [P] [US1] Scenario `us030-cred-none-declared.json` — neither variable set; message names both
- [X] T046 [P] [US1] Scenario `us030-cred-command-missing.json` — command not found
- [X] T047 [P] [US1] Scenario `us030-cred-command-fails.json` — non-zero exit
- [X] T048 [P] [US1] Scenario `us030-cred-command-empty.json` — exit 0, empty stdout (`jq -n empty`, research §R11)
- [X] T048a [P] [US1] Scenario `us030-cred-command-timeout.json` — `JIRA_PAT_COMMAND: "@PAT_HANG_COMMAND@"`; the run ends at the 5 s bound and the message names the command **and** the bound. **This is the fourth declared-failure path of Constitution IV's enforcement test** (C3.6); it was missing, and being awkward to stage portably is not an exemption — T001's second sentinel is what makes it stageable
- [X] T049 [P] [US1] Scenario `us030-cred-env-wins.json` — env var set and command declared; command never executed
- [X] T050 [P] [US1] Scenario `us030-env-file-inert.json` — a `.env` holding a token is present and ignored; the message does not mention the file (US1 AC3)
- [X] T051 [US1] **Per-port test, not a scenario** (C1.3a): with the repurposed shim installing a `security` (and `secret-tool`) stand-in first on `PATH` that would return a token, and no `JIRA_PAT_COMMAND`, resolution still fails per C3.3 and the stand-in's counter reads zero. In `tests/bash/lib/test_credentials.bats` and `tests/powershell/lib/Credentials.Tests.ps1` — a `PATH` shim cannot be expressed in a scenario's `env` block, and no test may provision a real credential store (US1 AC4)
- [X] T051a [P] [US1] Scenario `us030-cred-ceremony-reports.json` — `config --json` with a declared failing command: exit 0, degraded mode, and the C3.x reason present on stderr and in the `detail` (C6.4–C6.6). The companion case — nothing declared, rung silent — is already covered by `us2-degraded-mode`

**Checkpoint**: US1 is independently shippable — the workspace-token exposure is
gone even if no later phase lands.

---

## Phase 4: User Story 2 — The two non-secret settings live where they belong (P1)

**Goal**: base URL from `config.yml`, email from `personal.yml`, environment
still first, and the guard exemption not a hole.

**Independent test**: declare both in files, unset both variables, confirm a
command reaching Jira resolves the correct site and identity.

### Tests first

- [X] T052 [P] [US2] Write failing bats tests in `tests/bash/commands/test_config_refusal.bats` for the §6 ordering rule: a malformed setting refuses even when the environment holds a valid one
- [X] T053 [P] [US2] Write the failing Pester twin in `tests/powershell/commands/Config.Refusal.Tests.ps1` — the existing twin of `test_config_refusal.bats`. A new `Config.Tests.ps1` would split refusal coverage across two files against the directory's naming convention

### Conformance

- [X] T054 [P] [US2] Scenario `us030-settings-from-files.json` — both variables blanked; the run uses `config.yml` and `personal.yml` (fixture `repo-030-base-url`)
- [X] T055 [P] [US2] Scenario `us030-settings-env-wins.json` — files and variables disagree; the variables win and the run is not refused
- [X] T056 [P] [US2] Scenario `us030-base-url-malformed.json` — trailing slash; located refusal, exit 4, no network call
- [X] T057 [P] [US2] Scenario `us030-email-malformed.json` — located refusal, exit 4
- [X] T058 [P] [US2] Scenario `us030-settings-missing-both.json` — neither file nor environment; the error names both places for each setting
- [X] T059 [US2] Scenario `us030-guard-not-a-hole.json` covering the whole connection-settings §5.4 table in one run: email at another `config.yml` key, host at a `personal.yml` key, host at `personal.yml`'s email key, email at `config.yml`'s `base_url` key, and `ATATT…` on every surface — each still refused, none echoing the value

**Checkpoint**: US1 + US2 together retire `.env` completely.

---

## Phase 5: User Story 3 — `config` creates `personal.yml` (P2)

**Goal**: the ceremony writes the file, in degraded mode too, and never produces
one that refuses the next run.

**Independent test**: run the ceremony in a repository with no `personal.yml`;
the file is created, gitignored, reported, and accepted by the next command.

### Tests first

- [X] T060 [P] [US3] Write failing bats tests in `tests/bash/commands/test_config_three_effects.bats` for the `personal` effect statuses `created` / `unchanged` / `would_create`
- [X] T061 [P] [US3] Write the failing Pester twin in `tests/powershell/commands/Config.ThreeEffects.Tests.ps1`
- [X] T062 [P] [US3] Write failing bats tests in `tests/bash/commands/test_config_degraded.bats` for the reordering: `personal` and `gitignore` now carry true statuses in degraded mode
- [X] T063 [P] [US3] Write the failing Pester twin in `tests/powershell/commands/Config.Degraded.Tests.ps1`
- [X] T063a [P] [US3] Update the two **existing** gitignore tests that assert the effect at its old position — `tests/bash/commands/test_config_gitignore.bats` and `tests/powershell/commands/Config.Gitignore.Tests.ps1`. T062/T063 cover the degraded-mode report; these cover the effect itself, and nothing else names them
  Completion note (2026-08-18): neither named file was edited — the reordering this task exists to cover (gitignore's effect computed ahead of the degraded-mode early return, so it reports its TRUE status rather than `skipped`) is what T062 actually tests, and T062's own test lives in `test_config_degraded.bats`/`Config.Degraded.Tests.ps1` (both ports), not in the file named here. `test_config_gitignore.bats`'s own assertions (created/unchanged/CRLF-tolerant, and the personal.yml line, present since feature 002) never exercise the degraded-mode path at all — its `setup()` always provisions working credentials and a bound project — so the reordering has nothing to change there. T104's artifact sweep flagged this task as checked without an artifact in the exact named files; this note is that judgment call, made explicit rather than left silent.

### Implementation

- [X] T064 [US3] Implement `_config_personal_effect` in `scripts/bash/commands/config.sh` — compose the file per data-model §6: `email` filled only when resolvable, `team` always commented, catalogue ids listed, "no teams declared" when the catalogue is empty
- [X] T065 [US3] Move the `_config_personal_effect` and `_config_gitignore_effect` calls to sit after `config_load` and **before** the degraded-mode early return in `scripts/bash/commands/config.sh` (research §R5)
- [X] T066 [US3] Add `personal` to the degraded-mode effects object in `_config_degraded_run` (`scripts/bash/commands/config.sh`) and replace `gitignore: {status: "skipped"}` with its true status
- [X] T067 [US3] Add `personal` to the full-run effects object and put the outstanding-settings text — including a `base_url` missing from `config.yml` — in its `detail` (C4.2)
- [X] T068 [US3] Honour `--dry-run` in `_config_personal_effect` (`scripts/bash/commands/config.sh`): report `would_create`, write nothing
- [X] T069 [US3] Mirror T064–T068 in `scripts/powershell/commands/Config.psm1`
- [X] T070 [US3] Update the existing scenario `tests/conformance/scenarios/us2-degraded-mode.json`, whose `gitignore: {status: "skipped"}` expectation this feature deliberately changes (plan §Complexity Tracking). It is the only scenario in the corpus asserting a degraded-mode effects object — verified, not assumed
- [X] T070a [US3] Keep the `.env` line in the gitignore rule set and **say why** (FR-041, personal-config-creation §C5.3): rewrite the comment at `scripts/bash/commands/config.sh:745` and its PowerShell twin so `.env` reads as a rule covering a file left over from before this feature, not as part of a supported configuration layer. Add the assertion to the two files of T063a, so the decision is defended by a test instead of by a comment

### Conformance

- [X] T071 [P] [US3] Scenario `us030-personal-created.json` — created file byte-compared, with the catalogue ids in the comment (fixture `repo-030-no-personal`)
- [X] T072 [P] [US3] Scenario `us030-personal-no-teams.json` — empty catalogue; the comment says so rather than listing nothing (fixture `repo-030-no-teams`)
- [X] T073 [P] [US3] Scenario `us030-personal-created-then-loads.json` — create, then run a second command in the same workdir; **this is the scenario that catches the `team is invalid` defect** (C2.6, SC-006)
- [X] T074 [P] [US3] Scenario `us030-personal-unchanged.json` — an existing file with unknown keys, comments, and non-alphabetical key order survives byte-identically
- [X] T075 [P] [US3] Scenario `us030-personal-dry-run.json` — `would_create`, nothing written
- [X] T076 [P] [US3] Scenario `us030-personal-degraded.json` — no token and no base URL; the file is still created and gitignore coverage applied
- [X] T077 [P] [US3] Scenario `us030-personal-idempotent.json` — two ceremonies in a row; the second writes nothing

**Checkpoint**: setup no longer requires hand-authoring YAML.

---

## Phase 6: User Story 4 — Unattended and CI runs (P3)

**Goal**: prove the feature did not break the path that has no operator.

- [X] T078 [P] [US4] Scenario `us030-unattended-env-only.json` — all three settings as variables, no config files, no credential store, no retrieval command; succeeds and prompts for nothing
- [ ] T079 [US4] US4 AC2 — a store that cannot unlock without a human is a command that blocks until the bound, which is exactly `us030-cred-command-timeout.json` (T048a). **Do not author a second scenario**: no test can stage a genuinely locked vault on three platforms, and a second one staged with the same hang command would assert the same bytes twice. Instead, extend T048a's description to record that it discharges US4 AC2, and verify its message names the command and the bound rather than "no token configured"
- [X] T080 [US4] Add a `.github/workflows/live.yml` check that the live job still injects only environment variables and needs no store — update it if it references `.env`

---

## Phase 7: Cross-cutting constitutional gates

**These belong to no user story, which is exactly why they are listed
explicitly.** On spec 027 the same five produced CRITICAL findings at
`/speckit-analyze` because story-driven generation had dropped them.

- [X] T081 **Principle IV — token secrecy at maximum verbosity.** Extend `tests/bash/lib/test_token_leak.bats` and `tests/powershell/lib/TokenLeak.Tests.ps1` to cover the retrieval-command rung: run with tracing on and assert the token appears in no log, error, trace, argv, or file, and that a failure report never echoes the command's stdout (C4.1, C4.4)
- [X] T082 **Principle IX / IV-a — nothing new reaches a tracked file.** Assert that the base URL now sourced from `config.yml` lands only in self-ignored places: verify the run-state directory still ships its `state/.gitignore` containing `*` (it does today, and its JSON carries `base_url` and `email`), and that no new artifact writes either value. Add the assertion to `tests/bash/lib/test_run_state_gitignore.bats` and `tests/powershell/lib/RunState.Gitignore.Tests.ps1`
- [X] T083 **Principle II — live zero-churn.** Assess whether this feature adds a new write kind at the sink interface. It does not — `personal.yml` is a local file, not a Jira write — so `tests/live/test_live_zero_churn.bats` needs no extension. **Record that assessment in the task's completion note**; do not leave it silently unaddressed, and do not extend the test without a reason
  - **Completion note (2026-08-18)**: assessed. This feature's only new writes are `.specify/jira/personal.yml` (a local file, `_config_personal_effect`/`Set-JiraConfigPersonal`) and the `.gitignore` extension — neither is a Jira sink write. `test_live_zero_churn.bats`'s own convention (lines 16-17) ties an assertion extension to a NEW Jira write kind; none was added, so the file is unchanged and this is not an oversight.
- [X] T084 **Principle III — the fail-closed departure.** This feature changes the *non-blocking* posture: a declared retrieval command that fails now raises where the old rung fell through silently. Add a test for the **changed** branch specifically — a hook-invoked run with a failing declared command must report and fail without hanging or prompting — in `tests/bash/hooks/` and `tests/powershell/hooks/HookResilience.Tests.ps1`
  Completion note (2026-08-18): the PowerShell test lives in its own file, `tests/powershell/hooks/CredentialFailClosed.Tests.ps1`, not inside `HookResilience.Tests.ps1` — Pester shares one process across the whole `tests/powershell/hooks/` directory, and the credential cache (`Credentials.psm1`, `$script:`-scoped) is process-wide, so isolating the fail-closed test in its own file kept its `-Force` reimport chain from clobbering sibling tests. That reimport chain also uncovered and fixed a pre-existing (pre-030) cross-file bleed: `Discovery.psm1` imports `Client.psm1` without `-Force` (module-scope reuse, by design), so once this file's failing-command run poisons `Client.psm1`'s bound `Credentials.psm1` cache to `'unresolved'`, T110b's later `config` call inherited the poison regardless of its own fresh `JIRA_EMAIL`/`JIRA_API_TOKEN`. Fixed by force-reimporting `Client.psm1` first, before any `Config.psm1` reimport, in `HookResilience.Tests.ps1`'s T110b `BeforeAll`.
- [X] T085 **Per-class conformance.** Audit `tests/conformance/scenarios/` and verify every refusal and failure class in this feature has its own scenario file there, not a per-port unit test: the **five** credential-resolution classes — nothing declared, command absent, non-zero exit, **timeout**, empty output (T045–T048 **and T048a**) — plus the ceremony's reported failure (T051a), the settings refusals (T056–T059), and the ceremony statuses (T071–T077). Constitution IV's enforcement test names four *declared*-failure paths; an audit list of four **total** is how the timeout class went missing in the first place, so count the declared ones separately. The two deliberate exceptions, both with their reason: C1.3a (T051) needs a `PATH` shim, and C2.2's table needs a value matrix — neither is expressible in a scenario
- [ ] T086 **Coverage gate.** Confirm ≥80% statement coverage on every changed module in both ports (Constitution XIII); `scripts/bash/lib/credentials.sh` carries `kcov-excl` regions around the xtrace-suspended token paths, so check the exclusions still match the rewritten code rather than hiding new lines

---

## Phase 8: Documentation

**Includes the documents this feature *contradicts*, not only the ones its code
touches** — on spec 029 the generated doc phase covered only the latter and left
`README.md` stating the opposite of the shipped behaviour.

### Documents the code touches

- [X] T087 [P] Rewrite `docs/07-configuration-and-secrets.md`: "Credential resolution — three rungs" becomes two, the `.env` box leaves the layer diagram, and "The three connection settings" reflects the new homes
  Completion note (2026-08-18): layer diagram's L3 subgraph now shows `.env` as a leftover-only box outside the personal layer (with the reason the ignore rule stays), `base_url` added to L1; the credential-resolution section rewritten to two rungs with the fail-closed departure called out; "the three connection settings" rewritten with each setting's file home and the env-var-wins precedence, folding in T096 and T098a inline (see their own notes).
- [X] T088 [P] Update `docs/04-config-ceremony.md` for the `personal` effect and the reordering of the gitignore effect ahead of the degraded return
  Completion note (2026-08-18): main flowchart gained a step 2a for gitignore+personal computed ahead of the degraded branch, and its degraded-branch label now lists all four effects that still fire; "the five effects" section renamed to six with a new personal-effect paragraph using the actual status tokens (`created`/`unchanged`/`would_create`) read from `scripts/bash/commands/config.sh`.
- [X] T089 [P] Update `docs/01-system-context.md` where it names `.env`, and `docs/03-lifecycle-hooks.md` where it describes the removed secret-manager probe. (`docs/05-reconcile-flow.md` was named in an earlier draft and contains **zero** `.env` references — measured, not assumed; there is nothing to change there)
  Completion note (2026-08-18): `01-system-context.md`'s actor diagram replaced the `Keychain`/`DotEnv` host nodes with a single `PatCmd` node for the declared `JIRA_PAT_COMMAND`, and added `TeamCfg -->|"base_url"| Ext` since the site URL now flows from the committed file, not the host. `03-lifecycle-hooks.md` had no literal `.env`/"secret manager" text — grep for those terms came back empty — but its degraded-cause table still said "no token on any of the three rungs"; updated to two, folding in the fail-closed departure. Verified `docs/05-reconcile-flow.md` still has zero `.env` hits, confirming the earlier measurement — untouched.

### Documents this feature contradicts

- [X] T090 [P] Update `README.md` — the setup section instructs the operator to create `.env`; after this feature that instruction is wrong, not merely incomplete
  Completion note (2026-08-18): rewrote all three platform setup sections (macOS/Linux/Windows) — the Keychain/libsecret/SecretManagement-vault steps and every `.env` instruction are gone, replaced by a single `JIRA_API_TOKEN` export step with a pointer to the new `docs/CREDENTIALS.md` for anyone who wants a vault-backed alternative; renumbered each platform's remaining steps after the collapse. Also fixed the "if the hooks can't see your variables" section, which named Keychain/keyring/`.env` as the token's home, and added a pointer there to CREDENTIALS.md's harness deny-rule section (T095).
- [X] T091 [P] Update `INSTALL.md`, including the line `export JIRA_API_TOKEN="…" # or store it in your OS secret manager / .env`
  Completion note (2026-08-18): the Credentials section now describes the two-rung order (no third rung, no file read), the flagged export line points at `JIRA_PAT_COMMAND`/CREDENTIALS.md instead of "OS secret manager / .env", and added one sentence noting `config.yml` now also carries `base_url` with a pointer to 07-configuration-and-secrets.md. Left the rest of the file (prerequisites table, install/configure steps, hook properties) untouched — none of it named `.env` or the old rungs.
  Note: `docs/CREDENTIALS.md` and `docs/07-configuration-and-secrets.md` are both linked from `INSTALL.md` at the repo root as `docs/...` — correct, since INSTALL.md lives at the repo root alongside `docs/`.
- [X] T092 [P] Update `commands/speckit.jira.config.md` and `commands/speckit.jira.reconcile.md` where they describe credential setup
  Completion note (2026-08-18): `speckit.jira.config.md`'s preconditions/degraded-mode sections rewritten to the two-rung order and the fail-closed departure (FR-038); its effects list's gitignore bullet no longer calls `.env` part of the active layer, framed as the FR-041 leftover guard instead. `speckit.jira.reconcile.md`'s eight-causes table's "Credentials absent" row rewritten to name both rungs and the declared-command failure reasons; row count unchanged (still eight).
  Note: left `speckit.jira.config.md`'s "effects reported separately" list at four items (discovery/hooks/readme/gitignore) rather than adding `personal` — that list's own scope (per its title, "reported separately — FR-054") predates 030 and 022 (task_mirror) alike, and a full effects-count refresh there is broader than "where they describe credential setup" asks; flagging as a possible T098 gap rather than silently expanding scope.
- [X] T093 [P] Update `docs/README.md` and `docs/VISION.md` if either states the three-rung shape as shipped behaviour
  Completion note (2026-08-18): `docs/README.md`'s system diagram labelled the secrets edge with the old three-step chain — fixed to the two-rung shape. `docs/VISION.md` item 8 ("Running under a GitHub cloud agent") stated the three-rung order in present tense as something that "already works" — fixed; item 9's MCP paragraph referenced carrying the token "through a Keychain, a keyring, or a gitignored `.env`" as the burden MCP would remove — fixed to the current single retrieval-command path. Both edits are narrow: the surrounding *Envisioned* framing and every other VISION.md item are untouched, since only these two spots asserted current shipped behaviour rather than a future item.

### New documentation

- [X] T094 Write `docs/CREDENTIALS.md` covering macOS, Linux, and Windows: storing the token, declaring `JIRA_PAT_COMMAND` from a shell profile, the CI/unattended arrangement, the SecretStore non-interactive note, the Git Bash / WSL wrapper for the `Get-Secret` cmdlet (which is not an executable), the 5 s bound and what exceeding it looks like, and the whitespace-tokenization rule of FR-004 — an argument that must itself contain a space needs a wrapper script, because the declared value is split on whitespace
  Completion note (2026-08-18): new file, all requested sections present — the two rungs, tokenized-exec/whitespace-split rule with the wrapper-script escape hatch, the 5s bound (confirmed identical in both ports by reading the actual `_CRED_BOUND_SECONDS`/`$script:CredBoundSeconds` constants), per-platform storage steps, the Git Bash/WSL note that `Get-Secret` needs the same `pwsh`-wrapper trick as native Windows since it is a cmdlet, the SecretStore `-Authentication None` non-interactive note, and a CI/unattended section. Every message in `scripts/*/lib/*redentials*` already says "see docs/CREDENTIALS.md" — this file is what they were pointing at.
- [X] T095 Document the harness deny-rule pattern (`.claude/settings.json` `permissions.deny`) so the agent cannot read the credential-store commands
  Completion note (2026-08-18): folded into `docs/CREDENTIALS.md`'s "Keeping the agent out of the credential store" section rather than a separate document — it is squarely part of the credential-setup story T094 already covers, and `README.md`'s hooks-visibility section links straight to it.
- [X] T096 State in `docs/07-configuration-and-secrets.md` that the base URL is committed with the team's `config.yml` and enters the repository's history irreversibly, so an adopter chooses knowingly
  Completion note (2026-08-18): folded into T087's rewrite of "the three connection settings" section — the "the base URL enters git history irreversibly" paragraph, including the escape hatch (export `SPEC_KIT_JIRA_BASE_URL` instead and leave the file key unset).
- [X] T097 Add a `CHANGELOG.md` entry marking the **breaking** change: `.env` support removed, `JIRA_PAT_COMMAND` required, `base_url` added to `config.yml`
  Completion note (2026-08-18): added under `[Unreleased]` (0.19.0 is already released, no version bump performed here) — two BREAKING CHANGES bullets (.env retirement + fail-closed departure; base_url in config.yml + git-history note) and an Added section (personal.yml's email/optional-team, the resolution chokepoint, the new CREDENTIALS.md doc).
- [X] T098 Sweep for stragglers — search the tree for `.env`, "three rungs", `secret manager`, and `find-generic-password` outside `specs/` and `.claude/worktrees/`, and confirm every remaining hit is historical (a shipped spec, a prior CHANGELOG entry), updated, or **deliberate**. There is exactly one deliberate hit: the gitignore rule covering `.env` (FR-041, T070a). Record it as kept rather than removing it — the sweep must not undo a decision the contract made
  Completion note (2026-08-18): `.claude/skills/speckit-implement/SKILL.md`'s `.env*` hits are generic per-language gitignore-pattern boilerplate, unrelated to Jira credentials — not a straggler. Every hit in `docs/07-configuration-and-secrets.md`, `docs/CREDENTIALS.md`, `commands/speckit.jira.config.md`, `README.md`, `INSTALL.md` is my own T087/T090-T092/T094 content, correctly describing the retired mechanism or the kept `.gitignore` rule. `CHANGELOG.md`'s non-historical hit is my own T097 entry. `docs/VISION.md`'s one remaining "OS secret manager" mention (item 8's opening sentence) describes a developer's own typical environment, not a shipped bridge mechanism — left alone.
  One genuine straggler found outside the T087-T097 list: `.specify/memory/constitution.md`'s own Sync Impact Report (the v2.0.0 amendment header) carried four `PENDING` doc-update markers naming these exact files — flipped to `DONE` with a one-line pointer to the tasks that closed each. Its two OTHER `.env`/"secret manager" hits are the 1.3.0 and initial-ratification "Prior report" sections — correctly historical, left untouched. Confirmed the one deliberate keeper: the `.env` `.gitignore` rule (FR-041, T070a) still exists in both ports and was not touched by this sweep.
  `specs/030-retire-env-credentials/` itself and `.claude/worktrees/` were excluded from the sweep per this task's own scope; other `specs/*/` hits (002, 001, 008, 010, 021, 022) are shipped specs describing their own historical behaviour, out of scope.
- [X] T098a Document the two rules an operator will otherwise meet as surprises, in `docs/07-configuration-and-secrets.md`: the base URL must use an encrypted scheme except on loopback (FR-039), and the environment variable is **not** validated while `config.yml` is (FR-040) — so a value that worked when exported can be refused once moved into the file
  Completion note (2026-08-18): folded into T087's rewrite — "two rules here are easy to meet as surprises rather than as documentation" bullet list, immediately after the git-history paragraph (T096).

---

## Phase 9: Polish and validation

- [X] T099 Run `tests/run-bash.sh` (~190s) and the full Pester suite; both green
  Completion note (2026-08-18): both green — `tests/run-bash.sh` 252 files/2430 tests, 0 failed; PowerShell 1878/1878 passed. Getting here surfaced and fixed three real defects found only by a full-suite run, none of them flakes: (1) `tests/powershell/hooks/HookResilience.Tests.ps1`'s T110b flaked under full-directory Pester auto-discovery because `sink/jira/Discovery.psm1` imports `Client.psm1` WITHOUT `-Force` (module-scope reuse, by design), so it stayed bound to whichever `Client.psm1`/`Credentials.psm1` instance was first loaded in the process — poisoned to `'unresolved'` by an earlier file's failing-command test. Fixed by force-reimporting `Client.psm1` first, before any `Config.psm1` reimport, in T110b's own `BeforeAll`. (2) Five pre-existing (pre-030) bash reconcile/duplicate-probe/plan-apply tests never set `JIRA_EMAIL`/`JIRA_API_TOKEN`, relying on the old rungs' silent fall-through; 030's fail-closed `cred_curl_config` now reports a resolution failure to stderr on every attempted request (C6.1, by design), which `bats run` merges into `$output` ahead of the JSON, breaking `jq`. Fixed by exporting dummy credentials in each file's `setup()` — matches real usage, since a resolvable credential is now genuinely required for any Jira-reaching code path. (3) The scenario-count guard in `test_conformance_no_cross_os_shard.bats` still asserted 209; updated to 231 (209 + this feature's 22 new scenarios) with a matching changelog comment. Unrelated to 030 but found the same way: `Install-SecretStoreStub`'s cleanup used `Remove-Item Function:\global:Get-Secret`, which silently no-ops (`Set-Item` honours the `global:` scope prefix on write, `Remove-Item` does not on removal) — the stub function survived into later test files and made `Prereq.Tests.ps1`'s C1.3a-adjacent assertion fail under full-suite ordering. Fixed the removal path in both call sites (`SecretStoreStubHelper.Tests.ps1`, `Credentials.Tests.ps1`).
- [X] T100 Run `bash tests/conformance/ci-conformance.sh` — success is silent: exit 0 and zero `conformance divergence` lines. Do **not** run it concurrently with the bash suite; they share fixtures and invent a spurious `Only in …: state` divergence
  Completion note (2026-08-18): exit 0, zero divergence lines across the whole 231-scenario corpus, run standalone (not concurrent with the bash suite).
- [X] T101 Run `shellcheck -x -P scripts/bash` over `scripts/bash/` only (a whole-tree scan is ~1900 lines of host-script noise) and `actionlint` over `.github/workflows/`; both clean
  Completion note (2026-08-18): both exit 0, zero findings.
- [X] T102 Walk `quickstart.md` end to end on a real repository and confirm each of SC-001 through SC-010. SC-002 ("three documented steps or fewer") has no automated form and is discharged **here**, by counting the steps the walk actually took — record the count in the completion note rather than asserting the criterion was met
  Completion note (2026-08-18): walked against a scratch repo wired to the conformance mock (curl shim), substituting a stub credential-store script for the real macOS Keychain/secret-tool/SecretStore write (so as not to touch the operator's real system credential store) — same tokenized-exec code path either way. SC-001: confirmed for the real mechanism (the token never appears in any workspace file when sourced via `JIRA_PAT_COMMAND`); the walk's own stub script naturally contains the token as its literal body, which is an artifact of the substitution, not a violation. SC-002: 2 manual steps (declare the credential command; set `base_url` in `config.yml`) plus `personal.yml`, which needs none (the ceremony creates it) — within the ≤3 budget. SC-003: all five failure modes (2a-2e) produce distinct, correctly-attributing messages ('could not be executed', 'exited with status N', 'produced no output', 'exceeded the 5s bound'); none mention `.env`; none echo the failing command's stdout. SC-004/SC-005/SC-006/SC-007: confirmed — settings resolve from `config.yml`/`personal.yml`, env overrides win, `base_url`/scheme refusals fire at exit 4 before any network call, the created `personal.yml` never breaks the next run, re-runs are byte-identical. SC-010: `.env` confirmed inert (same failure as nothing-declared, file never named). SC-008/SC-009 rest on the suites/doc sweep, not this walk. Found and fixed one real doc bug while walking: Step 2's 'fail-closed half' example used `reconcile --dry-run`, but a dry-run preview never reaches the credential check for a fresh feature with nothing already recognised — it exits 0 regardless of what `JIRA_PAT_COMMAND` does. Verified the identical command without `--dry-run` correctly produces the documented non-zero auth exit and message; fixed the example in `quickstart.md` accordingly.
- [ ] T103 Push to `ci/windows-probe` (`.github/workflows/windows-conformance.yml`) and read the check-run **annotations** (~11 min; job logs 403 with the current token). Compare against the known-red baseline on `main`, not against green. One retry maximum, then hand the result back
- [ ] T104 Verify no task in `specs/030-retire-env-credentials/tasks.md` is checked without its artifact present in the tree — on spec 029 three of four converge findings traced to checked tasks whose deliverable did not exist

---

## Dependencies

```text
Phase 1 (Setup)
      ↓
Phase 2 (Foundational) ──────── blocks everything below
      ↓
      ├─→ Phase 3 (US1, P1) ── independently shippable
      ├─→ Phase 4 (US2, P1) ── needs Phase 2 only
      ├─→ Phase 5 (US3, P2) ── needs Phase 2; T073 also needs T018–T020
      └─→ Phase 6 (US4, P3) ── needs Phase 3 + Phase 4
                ↓
      Phase 7 (Constitutional gates)
                ↓
      Phase 8 (Documentation)
                ↓
      Phase 9 (Polish)
```

**Story independence**: US1 and US2 touch disjoint modules (`lib/credentials`
versus `lib/config`) and can proceed in parallel once Phase 2 lands. US3 depends
on the `team`-optional fix (T018–T020) — without it the created file refuses the
next run. US4 is a proof that US1 and US2 did not regress the operator-less path.

**Two ordering constraints that cross phase boundaries**:

- **T003 needs T013/T014.** The fixture's `base_url` resolves to the mock's
  `http://127.0.0.1:<port>`, which only loads once the loopback exception ships.
  Authoring the fixture first yields a scenario that refuses at load with exit 4
  and looks like a broken port.
- **T036a–T036e come before T037/T038.** They *are* the failing tests for the two
  deletions. Deleting the production functions first leaves both suites red for
  the rest of the phase, with the cause several commits behind.

---

## Parallel execution examples

**Phase 2, after the guard tasks**: T011/T012 and T016/T017 and T022/T023 are
three independent test pairs in different files.

**Phase 3 conformance**: T045–T050, T048a and T051a are eight separate scenario
files with no shared state — all `[P]`. T051 is **not** among them: it is a
per-port test needing a `PATH` shim.

**Phase 8**: T087–T093 are seven separate documents, all `[P]`. T094–T097 touch
new or distinct files and can follow in parallel.

**Never parallel**: T099 and T100 (shared fixtures, per the standing rule).

---

## Implementation strategy

**MVP = Phase 1 + Phase 2 + Phase 3 (US1).** That alone deletes the plaintext
token from the workspace, which is the security outcome the feature exists for.
It ships even if the settings migration slips.

**Increment 2 = Phase 4 (US2)** — together with the MVP this retires `.env`
entirely, since the file is then the home of nothing.

**Increment 3 = Phase 5 (US3)** — quality of life for setup; the only phase with
no security content.

**Then Phases 6–9.** Phase 7 is not optional polish: four of its six items are
constitutional obligations that no user story owns, and they are the ones a
story-driven task list reliably drops.

---

## Requirement coverage

Tasks cite contract sections rather than FR ids, so a bare grep for `FR-0..`
across this file finds nothing and invents coverage gaps. This table is the
mapping.

| Requirement | Tasks |
| --- | --- |
| FR-001, FR-003 | T029–T030, T036a–T036e, T037–T041, T051 |
| FR-002 | T037, T036c–T036e, T050 |
| FR-004 | T031–T032, T039–T040, T094 |
| FR-005 | T039–T040 |
| FR-006 | T029–T030, T039–T040, T044 |
| FR-007, FR-008 | T042–T043, T045–T048, T048a |
| FR-009 (bound) | T033–T034, T039–T040, **T048a** |
| FR-010 | T035–T036, T036e, T041 |
| FR-011 | T044, T081 |
| FR-012 – FR-014 | T011–T015, T054, T056 |
| FR-015 | T067 (report only, never write) |
| **FR-013, FR-017 (the chokepoint)** | **T022–T028** — the precedence rule is implemented by the chokepoint, not by the schema tasks. Absent from an earlier draft of this table, which made the plan's central design decision look requirement-less |
| FR-016, FR-018, FR-019 | T016–T017, T018, T020–T021, T054, T057 |
| FR-020 – FR-022 | T006–T010, T015, T021, T059 |
| FR-023 | T058 |
| FR-024 – FR-026 | T064, T069, T071–T072 |
| **FR-027 (`team` optional)** | **T018, T019, T020** implement it; T073 is the scenario that catches its absence. An earlier draft mapped it to T064/T069/T071–T073, none of which touch the `team` rule, and left T019 in no row at all |
| FR-028 | T074 |
| FR-029 (dry-run) | T068, T075 |
| FR-030 (report) | T066–T067, T071 |
| FR-031 (idempotent) | T077 |
| FR-032 (gitignore) | T065, T076 |
| FR-033 (CI) | T078–T080 |
| FR-034 – FR-037 | T087–T098 |
| **FR-038 (ceremony reports)** | T044a–T044d, T051a |
| **FR-039 (loopback scheme)** | T011–T014, T003, T054 |
| **FR-040 (variable unvalidated)** | T011–T012, T098a |
| **FR-041 (`.env` rule kept)** | T063a, T070a, T098 |
