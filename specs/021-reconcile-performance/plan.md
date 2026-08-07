# Implementation Plan: A Reconcile Costs Seconds, and Costs Nothing When Nothing Changed

**Branch**: `feat/improve-scripts-performances` | **Date**: 2026-08-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/021-reconcile-performance/spec.md`

## Summary

Six changes, ordered so that each one is measured by the one before it.

A timing module (`lib/timing.sh` / `Timing.psm1`) marks eight phase boundaries and reports elapsed
milliseconds and request counts on stderr when `SPEC_KIT_JIRA_TIMING` is set. It is built first, because
every other number in this plan is a claim until it prints one. Two of the eight names are pinned to the
pipeline deliberately: `state` is the short-circuit below, and `gate` is the mandatory-field gate that runs
before recognition — this codebase calls three different steps a gate, and the report may only mean one.

The credential is then resolved **once**, into a non-exported shell variable primed in the main shell
before the first request-issuing subshell. That last clause is the whole design: most `jira_request`
call sites capture the body through `$(…)`, so a cache filled inside one of them dies with the
subshell. Priming in the parent makes the cache visible to every child, and costs nothing on a run that
never reaches the network.

Recognition gains a **prefetch** in front of its existing per-key reads: one
`POST /rest/api/3/issue/bulkfetch` (up to 100 keys, direct key-addressed fetch, no search index)
populates a map, and `_recognition_read` consults that map before falling back to today's `GET`. The
prefetch can only remove individual reads; it can never change an outcome, because anything it does not
answer is answered exactly as it is today.

A **run-state document** under `.specify/jira/state/` records the content hashes of the inputs of the
last fully successful reconcile. A run whose freshly computed document equals the recorded one exits 0
having touched neither the network nor the secret store. `--force` ignores it, and every doubt fails open.

The transport reuses one connection across the requests a phase issues, and the per-story and per-task
loops stop forking a `jq` per field. Both are refactors the conformance corpus proves byte-for-byte.

Last — no longer gated, since constitution v1.3.0 landed on 2026-08-07 — the PowerShell port's
`Get-JiraSecretManagerToken` stops being a no-op and reads `spec-kit-jira` from a registered
SecretManagement vault.

## Technical Context

**Language/Version**: Bash ≥ 4 (`lib/prereq.sh` enforces it; macOS 3.2 is explicitly disqualified) and
PowerShell 7+. No language is added.

**Primary Dependencies**: unchanged and mandatory — `curl`, `jq`, `git` on the Bash port; PowerShell 7+
built-ins **plus `git`** on the Windows port, where `Prereq.psm1` already declares `git` as its single
required command. `git hash-object` becomes load-bearing for the run-state digest on **both** ports, and
because both already enforce `git` as a prerequisite, this adds no dependency anywhere — which is what
keeps FR-046 true. `Microsoft.PowerShell.SecretManagement` is an
**optional** rung, never probed by `prereq_check`.

**Storage**: one new machine-owned artefact — `.specify/jira/state/<feature-dir>.json`, canonical JSON,
gitignored by a `.gitignore` containing `*` that the bridge writes beside it. No database, no cache of
tracker responses, no credential ever.

**Testing**: `bats` (`tests/run-bash.sh`), Pester (`tests/powershell`), and the shared conformance corpus
(`tests/conformance/ci-conformance.sh`) against the mock in `tests/conformance/mock-jira/`. The corpus
captures stdout, stderr, exit code, `calls.log`, and the post-run tree, and diffs the two ports; that
`calls.log` is what proves the request-count requirements deterministically.

**Target Platform**: macOS, Linux, Windows — the standing three-OS matrix.

**Performance Goals**: unchanged re-run under 1 s with zero requests (SC-001); typical changed run under
30 s (SC-002); read phase bounded by ⌈M/100⌉ + anomalies rather than M (SC-003); secret store consulted
at most once per process (SC-004).

**Constraints**: the credential must not appear on argv, in any stream, trace, transcript, child
environment, or file (Principle IV, NFR-3/SC-007). Every exit code, warning, and classification is
frozen. The two ports must stay byte-identical on stdout and on every written file.

**Scale/Scope**: a typical specification is 1 parent + ≤10 stories + ≤50 tasks = ≤61 recorded keys, which
is one `bulkfetch` request. The corpus carries 87 conformance scenarios and the bats suite ~1507 tests;
both must stay green with no scenario edits where behaviour is unchanged.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Pre-design | Post-design |
| --- | --- | --- | --- |
| I | Filesystem is the source of truth | PASS, one cost recorded | PASS — the short-circuit takes no write decision at all, so no overwrite ever precedes drift detection. Its blindness to out-of-band tracker change is spec FR-028 and is documented, not hidden. |
| II | Zero-churn idempotency | PASS | PASS — strengthened. The prefetch cannot create a ticket the per-key read would not have created, because a key it fails to answer is re-read individually. R2 below refuses the search-index mechanism that would have reintroduced duplicate creation. |
| III | Fail-closed on writes, non-blocking on hooks | PASS | PASS — the prefetch's failure mode is "no prefetch", not "no ticket"; every fail-closed decision still comes from the same per-key code path. Run-state doubt fails open to work, never open to skipping a failure. |
| IV | Credential security | **GATED** | **PASS.** The cache design (R3) tightens rather than relaxes the discipline. The Windows rung is resolved: constitution **v1.3.0** (2026-08-07) defines the second rung by its requirement — an OS-encrypted store read at run time — and names PowerShell SecretManagement as the Windows mechanism. The same amendment declares the rung soft-optional on all three platforms, which makes FR-035/FR-036/FR-038 constitutional and adds fall-through tests for the macOS and Linux rungs to this feature's scope. |
| V | Config / binding / secrets separation | PASS | PASS — the run state is machine-owned local state beside the local binding, self-ignoring, never committed, never a secret's home. No key enters the committable config; the timing switch is an environment variable. |
| VI | Three-OS portability | PASS | PASS — R1 pins a clock strategy that degrades explicitly rather than silently on a host without a sub-second clock, and R7 pins the digest primitive to `git hash-object`, which is the only content hash guaranteed identical on all three hosts by the existing prerequisites. |
| VII | No hard-coded workflow assumptions | PASS | PASS — `bulkfetch` requests exactly the field list the per-key read requests today. No status, type, or transition assumption is added. |
| VIII | Neutral engine / Jira sink | PASS | PASS — `sink/jira/prefetch.sh` is sink; `lib/timing.sh` and `lib/run_state.sh` carry no tracker identifier and hash local files only. No engine module gains a sink import. |
| IX | Two-tier privacy guard | PASS | PASS — untouched, and its guard-then-write ordering is unchanged. A short-circuited run sends nothing and therefore reaches no guard decision. |
| X | Self-healing automatic mirror | PASS, one cost recorded | PASS with the cost restated: while the run state matches, a ticket damaged since the last run is not healed. `--force` and any local edit restore it. The expiring-digest alternative is recorded in R8 as rejected, not forgotten. |
| XI | Universal dry-run and auditability | PASS | PASS — R8 makes `--dry-run` neither write nor consume run state, so a preview still predicts the real run exactly. The short-circuit announces itself in the summary. |
| XII | Quality and catalog publication | PASS | PASS — CHANGELOG entry, three-OS matrix, and a dogfood run that is the acceptance evidence for SC-001/SC-002 rather than a formality. |
| XIII | TDD with ≥80% coverage | PASS | PASS — the load-bearing assertions are counts and byte comparisons against the mock, not wall clocks: `calls.log` line counts, a counting secret-store stub, and corpus diffs. Credential resolution stays a near-100% critical path. |
| XIV | KISS | PASS | PASS — the prefetch is a map in front of an unchanged function; the run state is a small readable document compared by equality, with no second hashing layer. Two test seams are added and justified below. |
| XV | YAGNI | PASS | PASS — every artefact traces to an FR: timing switch (FR-001), `--force` (FR-023), state file (FR-019), vault rung (FR-033). The two test seams are the YAGNI tension and are justified in Complexity Tracking. |
| XVI | Human readable | PASS | PASS — the timing report is a named phase, a duration, a count. The state file is a readable list of `input → hash` lines, so "why did it not skip?" is answered by looking at it. |

**Gate result**: PASS to proceed. Every workstream is unblocked.

The Windows vault rung was gated on a constitution amendment at the time this plan was first written;
that amendment landed as **v1.3.0 on 2026-08-07** and FR-033 through FR-040 may now be planned into
`tasks.md`. It brought one addition to this feature's scope: because the amendment declares the
secret-manager rung soft-optional on **every** platform and requires a test per unavailability path,
the macOS and Linux rungs need fall-through tests they do not have today
(`tests/bash/lib/test_credentials.bats` covers the empty-source case but not tool-absent or
tool-failing). Those tests belong to the credential workstream (FR-007…FR-014), not the Windows-rung one
(FR-033…FR-040), and must precede it.

## Project Structure

### Documentation (this feature)

```text
specs/021-reconcile-performance/
├── plan.md              # This file
├── research.md          # Phase 0 output — R1..R10
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── timing-report.md
│   ├── credential-cache.md
│   ├── recognition-prefetch.md
│   └── run-state.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── lib/
│   ├── timing.sh              # NEW — phase marks, request counter, clock strategy
│   ├── run_state.sh           # NEW — compose, compare, record the run-state document
│   ├── credentials.sh         # MODIFIED — per-run cache + cred_prime_cache
│   ├── cli.sh                 # MODIFIED — --force
│   ├── prereq.sh              # UNCHANGED — no new prerequisite (C-5)
│   └── output.sh              # UNCHANGED — json_canonical serialises the state document
├── sink/jira/
│   ├── prefetch.sh            # NEW — one bulkfetch, key → issue map
│   ├── client.sh              # MODIFIED — request counter, connection reuse
│   └── recognition.sh         # MODIFIED — consult the prefetch, then fall back unchanged
└── commands/
    └── reconcile.sh           # MODIFIED — phase marks, state phase, prefetch priming, loop de-forking

scripts/powershell/
├── lib/
│   ├── Timing.psm1            # NEW
│   ├── RunState.psm1          # NEW
│   ├── Credentials.psm1       # MODIFIED — $script: cache + SecretManagement rung
│   └── Cli.psm1               # MODIFIED — --force
├── sink/jira/
│   ├── Prefetch.psm1          # NEW
│   ├── Client.psm1            # MODIFIED — request counter
│   └── Recognition.psm1       # MODIFIED
└── commands/
    └── Reconcile.psm1         # MODIFIED

tests/
├── bash/lib/                  # timing, run_state, credential-cache suites
├── bash/sink/                 # prefetch suite, client counter suite
├── powershell/                # Pester twins of each of the above
└── conformance/
    ├── mock-jira/             # MODIFIED — serve POST /rest/api/3/issue/bulkfetch
    └── scenarios/             # NEW — us021-* scenarios listed in quickstart.md

docs/
├── 05-reconcile-flow.md       # MODIFIED — the state phase in the pipeline diagram
├── 07-configuration-and-secrets.md  # MODIFIED — replace the "no Windows rung" paragraph
├── 02-module-architecture.md  # MODIFIED — three new modules
└── ../README.md, ../INSTALL.md      # MODIFIED — Windows vault storage section
```

**Structure Decision**: the existing twin-port tree is kept exactly. Three new modules per port, five
modified per port, and no directory added to either port tree. Two directories are created outside them:
`.specify/jira/state/` at run time by the bridge (self-ignoring, see Complexity Tracking) and
`tests/powershell/helpers/` by the test work — the Pester side has no helpers directory today, where
`tests/bash/helpers/` already exists. `lib/` is the right home for `timing.sh` and `run_state.sh` under
Principle VIII: both are infrastructure over local files and carry no tracker identifier — the same test
`output.sh` and `credentials.sh` already pass. `prefetch.sh` is unambiguously sink: it speaks a Jira
endpoint.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| ~~Principle IV's Windows parenthetical says "Windows Credential Manager"; FR-033…FR-040 implement PowerShell SecretManagement~~ **RESOLVED — constitution v1.3.0, 2026-08-07** | It was the only route by which PowerShell 7 reads an OS-encrypted secret store without shipping P/Invoke code or a compiled helper, both of which Principle VI forbids at runtime. `cmdkey` lists credentials but cannot return a secret's value. | Reading the Credential Manager directly requires a compiled interop shim — a build step, which Principle VI prohibits. This was not a deviation the plan could justify away, so it was gated until the constitution was amended. Principle IV now defines the rung by its requirement rather than by a product name, so no deviation remains. |
| Two test-only seams: `_TIMING_FAKE_CLOCK` (deterministic durations) and `_RECOGNITION_NO_PREFETCH` (disable the prefetch) | The conformance corpus diffs stderr byte-for-byte across ports, so a real clock makes a timing scenario permanently red. And the only rigorous proof that the prefetch changed nothing is running the same scenario with it on and off and diffing everything. | Normalising durations inside the harness was rejected: it would teach the corpus to ignore stderr content, weakening every other scenario. Precedent for internal seams is established and load-bearing in this codebase — `_CRED_SECRET_TOKEN`, `JIRA_NO_SLEEP`, `_PREREQ_FORCE_MISSING`, `JIRA_MAX_ATTEMPTS`. Both new seams are underscore-prefixed internals, absent from the CLI contract, and exercised only by tests. |
| The run state records the extension version, requiring `extension.yml` to be read on the short-circuit path | Without it, a bridge upgrade that changes rendered output for identical inputs — exactly what feature 020's closing marker does — would be skipped until the operator happened to edit a spec. A digest that survives an upgrade is a digest that suppresses the upgrade. | A hand-maintained schema integer was rejected: it depends on a human remembering to bump it in the same PR that changes rendering, and nothing enforces that. The version read is one small YAML parse through the existing reader, well inside the 1 s budget. |
| A `.gitignore` containing `*` written inside `.specify/jira/state/` | FR-026 requires the location to be ignored **before the first state file is written**, including in repositories bound by an earlier version whose root `.gitignore` was written without this line. | Appending a fourth line to `_config_gitignore_effect` was rejected as the *guarantee*: it only runs during the config ceremony, so a repository bound before this release would write an untracked-but-not-ignored state file on its very first reconcile. The self-ignoring directory needs no ceremony and no write to the operator's own `.gitignore`. |
