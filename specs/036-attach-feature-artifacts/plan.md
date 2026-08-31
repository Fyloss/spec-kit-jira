# Implementation Plan: Publish every feature artifact on the specification ticket

**Branch**: `036-attach-feature-artifacts` | **Date**: 2026-08-31 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/036-attach-feature-artifacts/spec.md`

## Summary

Every file in the feature directory — not just the three the mirror renders
today — is uploaded to the specification-tier ticket as an attachment, and one
comment per run announces what arrived. Re-running publishes nothing.

The approach turns on four decisions, each taken to satisfy a constraint this
repository already carries rather than to add capability:

1. **One request for the whole set.** A single multipart `POST` carrying one
   part per artifact, and a single comment `POST`. Never a call, and never a
   process, per artifact — `docs/11-process-budget.md`, in both its halves: the
   part list travels in the `curl` config on stdin, not on a command line that
   grows with the input.
2. **The record lives in Jira, not on the machine.** A `spec-kit-jira-artifacts`
   entity property on the ticket holds path → hash → attachment-id. The local
   run-state file would have made a colleague's first run republish everything —
   a zero-churn violation invisible to whoever wrote the code.
3. **The short-circuit's inputs become the artifact set.** Run state goes to
   schema 3 and hashes every publishable file. Under schema 2 a run fired after
   only `research.md` changed short-circuits and loses it silently.
4. **A refused upload withholds; it does not fail the run.** The transport maps
   `403` to the `auth` exit code for every caller; propagating that would break
   every reconcile for any team whose token lacks "Create attachments", on the
   day they upgrade. The precedent is the task tier being withheld on unmet
   mandatory fields.

Two lifecycle events are added — `after_converge` and `after_checklist` — which
touches eleven enumeration sites across both ports, the config template, the
docs and two CI guards that assert the declared set is *exactly* seven.

## Technical Context

**Language/Version**: Bash ≥ 4 (macOS's 3.2 does not qualify) and PowerShell 7+,
twin native ports proven equivalent by a shared conformance corpus.

**Primary Dependencies**: none added. Runtime prerequisites stay `curl`, `jq`,
`git` for the Bash port. Multipart is `curl`'s `form =` config directive and
PowerShell 7's built-in `Invoke-WebRequest -Form` — no library, no build step,
no download (Principle VI).

**Storage**: three documents. A Jira entity property (the publication manifest,
`contracts/artifact-manifest.schema.json`); the local run-state file, bumped to
schema 3 (`contracts/run-state-v3.md`); and the artifacts themselves, which are
files on disk read but never written by this feature.

**Testing**: `bats` (Bash), Pester (PowerShell), the cross-port conformance
corpus, plus a live dogfood run that is a gate rather than a formality — see
Risks.

**Target Platform**: macOS, Linux, Windows. The Windows-specific unknown is
whether `form =` in a `curl` config on stdin behaves as `-F` does through MSYS;
that is a `ci/windows-probe` measurement, not a deduction.

**Project Type**: Spec Kit extension — a lifecycle-hook-driven CLI bridge with a
neutral engine and a Jira sink behind a fixed interface.

**Performance Goals**: SC-009 — a first publication of 20 artifacts under 5 MB
completes inside one mirror run, under 60 s on a developer machine. The binding
constraint is not seconds but spawns: publication adds a bounded number of
processes (two in the state phase, one privacy pass, one upload) regardless of
artifact count.

**Constraints**: zero writes on an unchanged re-run, including zero property
writes (Principle II); zero writes of any kind on a BLOCK-tier privacy finding
(Principle IX); a hook never fails the host command (Principle III); byte-identical
output and identical call sequences across ports (Principle VI); no external
process per artifact and no payload through a growing command-line argument
(`docs/11-process-budget.md`).

**Scale/Scope**: a feature directory holds roughly 5–40 files. The manifest is
bounded by artifact count, not run count. Eleven call sites enumerate the
lifecycle events; two mock implementations must both learn the new endpoints.

## Constitution Check

*GATE: passed before Phase 0, re-evaluated after Phase 1 design — see below.*

Assessed against constitution **4.0.0**. The specification's own Constitution
Check covers all sixteen principles at the requirement level; this section
records what the **design** does about the ones the design can violate.

| # | Principle | Design-level proof | Verdict |
|---|-----------|--------------------|---------|
| I | Filesystem is the source of truth | `contracts/artifact-publication.md` C6 forbids `DELETE /attachment/{id}` in every mode, the guarded re-mode included. A superseded attachment is left in place, which is why the manifest holds current state rather than replacing files. | PASS |
| II | Zero-churn idempotency | C4.5 fixes the floor at zero calls of all three new kinds; the manifest write is conditional on something having landed. The manifest lives server-side (research R3) precisely so the guarantee holds on a second machine. The live suite's exhaustive write-kind list gains `attached` and `commented` in the same change. | PASS |
| III | Fail-closed on writes, non-blocking on hooks | C3 maps every outcome. The one deliberate departure is C3.2 — a `403` withholds instead of propagating — justified in Complexity Tracking below. | PASS, with a justified departure |
| IV | Credential security | The credential stays off argv: the multipart parts are added to the `curl` config that already travels on stdin (C2.1), not to a new argv-based call. No artifact content is persisted anywhere by the bridge. | PASS |
| V | Config layer separation | No configuration key is added to any layer. The manifest is Jira-side state; run state is machine-local state. Neither is configuration. | PASS |
| VI | Portability | C2.3 and `comment-body.md` B6 are the equivalence assertions. Every path handed to `curl` goes through `_jira_curl_path`. The comment body is a pinned literal, not a composed string — the measured PowerShell pipe-to-native newline is why. The Windows unknown is booked as a probe, not reasoned about. | PASS |
| VII | No hard-coded Jira assumptions | The upload limit is discovered (C1.1), never assumed; the target is the ticket playing the configured `specification` role, resolved through the existing hierarchy mapping. | PASS |
| VIII | Neutral engine / Jira sink | Enumeration, hashing, sorting and classification are engine work and name nothing Atlassian. The artifact set crosses the boundary inside the neutral document as a schema-validated optional field carrying **relative** paths only; the sink resolves the real file path at upload time (data-model §4). Attachments, comments and entity properties are entirely sink-side. | PASS |
| IX | Privacy guard | C5.1 puts the scan at the reconcile's **existing pre-write sweep**, not in the publication phase. That placement is what makes FR-016's "zero writes for the entire run" achievable at all: publication runs after the description and story writes, so a guard sitting there could only abort the upload while the reconcile's own writes had already landed. One pass, no per-artifact process, no text/binary special case. This is the principle's surface widening materially — four artifact families become payloads for the first time — so the allowlist must be exercised against artifact content, not only against descriptions. | PASS |
| X | Self-healing within its boundary | C4.3's trust rule is the self-healing clause: an interrupted run is repaired by the next one in both directions. Nothing reads or writes `.specify/extensions.yml`; the event set changes in `extension.yml`, which is ours, and the host writes the registry from it. | PASS |
| XI | Dry-run and auditability | `attach` and `comment` join the planned action set, so the dry-run report is the action set as it already is for every other kind. The summary gains `artifacts[]` with a `reason` on every withheld entry. | PASS |
| XII | Quality and catalog publication | Breaking-ish observable change: version bump, CHANGELOG naming the attachments, the comment, the two events and the run-state bump. The dogfood gate is load-bearing — see Risks and research §R15. | PASS |
| XIII | TDD, 80% coverage | Every contract row above is falsifiable and gets its test first. The short-circuit regression (`run-state-v3.md` C4) must be observed failing against schema 2 before the bump — this repository has shipped inert guards before, so "proven red first" is a task, not an intention. | PASS |
| XIV | KISS | No new abstraction: two more action kinds behind the existing sink interface, one new engine function, one transport parameter per port. No new dependency. Rejected: ADF `media` embedding (research R8), a second transport function (R6). | PASS |
| XV | YAGNI | No configuration key gates publication. Two lifecycle events are added because two requirements name them; the other two the host offers are refused with reasons. | PASS |
| XVI | Human readable | `comment-body.md` pins prose a non-engineer reads; withheld artifacts are named with their size and the limit, or with the path they collide with. Attachment names keep the exact filename in the common case. | PASS |

**Post-design re-evaluation**: no gate moved. The one departure (C3.2) was
identified during Phase 0 and is recorded in Complexity Tracking rather than
resolved away, because resolving it the other way regresses every existing
consumer.

## Project Structure

### Documentation (this feature)

```text
specs/036-attach-feature-artifacts/
├── plan.md                                  # This file
├── spec.md
├── research.md                              # Phase 0 — R1…R15
├── data-model.md                            # Phase 1 — the five objects
├── quickstart.md                            # Phase 1 — how to prove it works
├── checklists/
│   └── requirements.md
└── contracts/                               # Phase 1
    ├── artifact-publication.md              # endpoints, request shape, outcome mapping
    ├── artifact-manifest.schema.json        # the entity-property document
    ├── comment-body.md                      # the pinned comment literals
    └── run-state-v3.md                      # the schema bump
```

### Source code (repository root)

```text
extension.yml                                # + after_converge, after_checklist

scripts/bash/
├── engine/
│   └── artifact_set.sh                      # NEW — enumerate, hash, sort, flatten, classify
├── sink/jira/
│   ├── attachments.sh                       # NEW — limit discovery, upload, manifest r/w
│   ├── client.sh                            # + multipart via the stdin config (C2.1)
│   ├── privacy_guard.sh                     # + one-pass scan over the artifact set
│   └── plan_apply.sh                        # + attach / comment action kinds
├── lib/
│   ├── run_state.sh                         # schema 2 -> 3, --stdin-paths hashing
│   └── config.sh                            # + 2 events (2 sites)
└── commands/
    └── reconcile.sh                         # publication phase, summary, + 2 events

scripts/powershell/                          # the twin of every file above
├── engine/ArtifactSet.psm1
├── sink/jira/Attachments.psm1
├── sink/jira/Client.psm1                    # + -FormParts (C2.2)
├── lib/RunState.psm1
├── lib/Config.psm1
└── commands/Reconcile.psm1

templates/config.yml.template                # + 2 events in the phase_status_map comment
docs/03-lifecycle-hooks.md                   # "seven declared events" -> nine
docs/05-reconcile-flow.md                    # the publication phase
docs/VISION.md                               # §5 and the backlog item: envisioned -> shipped

tests/
├── bash/{engine,sink,lib,commands}/         # bats, per port
├── powershell/                              # Pester, per port
└── conformance/
    ├── scenarios/                           # cross-port equivalence
    └── mock-jira/
        ├── curl-shim.sh                     # NEW routes + multipart config parsing
        └── mock-server.ps1                  # NEW routes
```

**Structure Decision**: the existing four-layer split is kept exactly as it is.
Enumeration, hashing, ordering and the published/revised/unchanged decision are
pure functions of the filesystem and the manifest, so they go in `engine/` as a
new module and name nothing Atlassian. Everything that knows what an attachment,
a comment or an entity property is goes in `sink/jira/` as a second new module.
The two meet only through the neutral document, which gains one optional array.

Two mock implementations must both learn the new endpoints: the Bash suites
intercept `curl` through `tests/conformance/mock-jira/curl-shim.sh` while the
PowerShell and conformance suites drive the real loopback server
`mock-server.ps1`. Adding a route to one and not the other yields a green suite
that proves nothing — and the shim additionally has to parse the multipart
config, since it is the only place that can observe the request body the Bash
port builds.

## Complexity Tracking

| Violation | Why needed | Simpler alternative rejected because |
|-----------|-----------|--------------------------------------|
| **C3.2 — a `403` on the upload withholds instead of propagating the transport's `auth` exit code**, departing from the uniform fault mapping every other call site uses | The shared transport maps `401/403 → auth (3)`. "Create attachments" is a separate Jira permission from the ones the mirror needs today. A team whose token lacks it would see **every reconcile fail** the moment they upgrade — a total regression of a working mirror in exchange for a feature they did not ask for. Principle III's fail-closed clause governs writes attempted after an unreliable *read*; here the reads succeeded and so did the reconcile's own writes. | *Propagate the code.* Regresses every such consumer on upgrade. *Pre-flight the permission with `GET /mypermissions`.* An extra call every run to predict a failure we can simply handle, and its answer can be stale by the time we upload. *Gate publication behind a config key so affected teams opt out.* Adds the configuration key Principle XV refuses and puts the burden on the consumer to discover why their mirror broke. The precedent for withholding already exists: the task tier is withheld with a named warning on unmet mandatory fields. |
| **A Jira entity property as a second state store**, beside the run-state file that already exists | FR-012 requires the record to hold "across runs, machines and interrupted runs". The run-state file is gitignored per-machine state: a colleague's first run would find no record and republish every artifact, violating Principle II on a machine other than the author's — the class of defect that stays green in CI forever. | *Reuse the run-state file.* Fails across machines. *Encode the hash in the attachment filename.* No extra store, but every filename a human reads becomes bookkeeping noise (Principle XVI). *Compare against the ticket's attachment list alone.* Cannot distinguish unchanged from revised without a hash. The mechanism itself is not new: the ticket identity marker is already an entity property, for the same stability reason. |

---

## Phase 0 — complete

[research.md](./research.md) — R1…R15. Every unknown is resolved to a decision;
the eight that a mock cannot falsify are collected in §R15 with the gate that
does falsify them.

## Phase 1 — complete

[data-model.md](./data-model.md) · [contracts/](./contracts/) ·
[quickstart.md](./quickstart.md)

## Risks carried into `/speckit-tasks`

1. **Eight API facts are unverified** (research §R15). Mocks we write cannot
   falsify them, which is the exact condition under which Principle II records
   that three live-only bugs were found in the original extension. Seven are a
   dogfood gate; one — the `curl` `form =` directive through MSYS — is a
   `ci/windows-probe` measurement, ~2 hours, because the constitution forbids
   closing a single-OS question by emulation.
2. **The short-circuit regression must be proven red first.** The test for
   `run-state-v3.md` C4 has to be observed failing against schema 2 before the
   bump lands. This repository has shipped guards that were inert — two of three,
   once — so "run it against the pre-change file from git" is a task with an
   artifact, not an intention.
3. **Eleven enumeration sites for two new events.** Listed in research R10 with
   file and line. Missing one leaves a lifecycle event that fires but whose
   `phase_status_map` key is rejected as unknown — green suites, broken config.
4. **Two mock surfaces.** A route added to `curl-shim.sh` but not
   `mock-server.ps1` (or the reverse) produces a green suite on one port and a
   failure on the other. The shim's multipart parsing is new work, not a copy.
5. **`run-summary.schema.json` is documentation only** — no code reads it, and
   it has drifted behind both ports before. The tasks must update it *and* the
   guard, or `artifacts[]` becomes the next drift.
6. **The privacy guard's surface widens materially.** `research.md`,
   `data-model.md`, `contracts/` and `checklists/` become payloads for the first
   time. A BLOCK false positive here refuses whole runs, so the allowlist needs
   fixtures against real artifact content — not only against descriptions.
