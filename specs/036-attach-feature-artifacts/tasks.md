# Tasks: Publish every feature artifact on the specification ticket

**Feature**: `specs/036-attach-feature-artifacts`
**Plan**: [plan.md](plan.md) · **Design**: [data-model.md](data-model.md) · **Research**: [research.md](research.md) · **Validation**: [quickstart.md](quickstart.md)
**Contracts**: [artifact-publication.md](contracts/artifact-publication.md) · [comment-body.md](contracts/comment-body.md) · [run-state-v3.md](contracts/run-state-v3.md) · [artifact-manifest.schema.json](contracts/artifact-manifest.schema.json)

**Traceability**: every task cites its contract clause **and** its FR ids, so an
FR-id sweep over this file is authoritative. That is deliberate — where a
`tasks.md` in this repository cites contract clauses alone, an ID sweep reports
covered requirements as uncovered.

**Terminology**: "specification-tier" and "specification-level" name the same
thing — the ticket playing the configured `specification` role. The spec uses the
second spelling, the code and these tasks use the first, because the code already
says "task tier" and "story tier".

**Tests are not optional here.** Constitution XIII is strict Red-Green-Refactor:
no implementation task may be planned without its test task preceding it, and
the test must be **observed failing** before the implementation lands. This
repository has shipped guards that were inert — two of three, once — so "prove
it red" is a task with an artifact, not an intention.

**Ports move together.** A task naming one port has a twin naming the other.
Neither is complete alone: cross-port byte equivalence is what makes them one
product (Principle VI), and a scenario green on one port and absent on the other
proves nothing.

## Handoff — traps measured in this session

Written for whoever picks this up. Every item below cost real time to find and
none of it is inferable from the code.

**The two mocks are the Bash port's and the PowerShell port's, and they are not
interchangeable.** `curl-shim.sh` IS the Bash backend — installed first on PATH
by `mock_start` so `jira_request` reaches it instead of a socket. A route added
to one mock and not the other is a green suite that proves nothing about the
other port.

**Three mock defects made zero-churn fail for reasons outside the code:**

1. The property store recorded only for an issue the mock had itself CREATED,
   so a PUT against a RECOGNISED issue was dropped — manifest written,
   discarded, read back as absent. Fixed, **scoped to `spec-kit-jira-artifacts`
   only**. Widening it to all keys was tried and REVERTED: it made the identity
   property's PUT land where it had been dropped in favour of the config's
   `identity` map, and recognition then refused the parent on the second run.
   That difference between what the bridge writes and what the fixtures declare
   is real and belongs to whoever owns identity stamping — do not "fix" it here.
2. Neither mock served `GET /issue/{key}?fields=attachment`, so the trust rule
   read "the id the manifest claims is not on the ticket" and republished
   everything, every run.
3. Attachment ids were per-issue, so an unseeded issue got the same id twice and
   a revision was indistinguishable from its original.

**PowerShell defects that PARSE and LINT clean and die at run time.** Three in
one commit: a helper that did not exist (`Add-JiraWarning`), a variable that was
never set (`$baseUrl`; it is `$base`), and a `Mandatory [string]` rejecting the
empty lifecycle event a direct reconcile legitimately has. PSScriptAnalyzer sees
none of these. **Run the thing end to end against the mock before believing it.**

**The display layer silently drops words from file reads.** Verified while
pinning `comment-body.md`'s literals: an `awk`/`sed` read showed text with words
missing. Every assertion on those literals uses `md5`/`cmp` against the
contract's own line, never a transcription. If you are comparing strings by
eye, you are comparing something else.

**`git hash-object --stdin-paths` resolves relative paths against the REPOSITORY
ROOT**, not the process cwd. Feed absolute paths.

**BSD `tr` does not understand `\x1f`** — it substitutes a literal `x`. Use
octal `\037`. And `LC_ALL=C` must cover EVERY `tr` in a pipeline, not just the
last: one unpinned call aborts on invalid UTF-8 and turns the whole step into a
silent no-op on macOS.

**`MultipartFormDataContent` implements IEnumerable**, so `return $content`
makes PowerShell hand the caller the inner part. `return , $content`.

**Adding a lifecycle event touches THIRTEEN sites** (research R10). The table
there was wrong three times; run `tests/bash/ci` and `tests/bash/lib` and let
them tell you what else pins the set.

---

## Progress — 2026-09-01 (third session, Phase 10)

**110 of 112 tasks complete.** T111–T114 are done; only T106 (Windows probe)
and T107 (dogfood) remain, and both are outside what an agent session can
execute — T106 needs a push to `ci/windows-probe` and ~2 h, T107 needs a real
Jira project.

Measured: `tests/run-bash.sh` **286 files, 2844 tests, 0 failures, 17:37**;
Pester over the affected suites **654 tests, 0 failures**; the nine `sc036-*`
conformance scenarios byte-identical across ports on all four captures;
`shellcheck`, PSScriptAnalyzer and `actionlint` clean.

**T112's premise turned out to be wrong, and the measurement is the deliverable.**
The task said to determine first whether the hook path passes `--json`. It does
— `commands/speckit.jira-mirror.reconcile.md` instructs both ports to — so
FR-018's "surface one actionable warning" was already satisfied where FR-018 is
about. The unmet case was narrower: an operator running the bridge by hand.
That is what T112 fixes, through a `artifact_warnings` key only the publication
writes, rather than by rendering the shared `warnings` array — which every
feature since 021 writes, and which would have changed the default output of
runs 036 never touched.

**Two defects the Phase 10 work uncovered, neither of them in Phase 10's scope:**

1. **The composed manifest size was one byte too large in the Bash port.**
   `json_build` ends in `jq -cn`, which appends a newline, and `wc -c` counted
   it — so the port measured a document nobody sends. It mattered twice: the
   number reaches an operator through C4.4.1's warning (642 against the twin's
   641, which is how the conformance corpus caught it), and it is compared
   against the cap, so at exactly one boundary size the two ports disagreed
   about whether a manifest overflows at all. Fixed, with a cross-port size
   test that fails against the old form.

2. **T071's own red-proof broke the moment the work was committed.** It located
   the schema-2 module with `git log -S`, which answers "the newest commit that
   CHANGED how often this string appears" — and once the bump was committed,
   that answer was the commit that REMOVED it, whose blob says schema 3. The
   guard then compared against a file that was never the thing it meant to
   test. It now reads the blobs and takes the newest one that still says
   schema 2. A guard that passes in the working tree and fails on commit is
   worse than one that never passed.

**The T114 decision, recorded rather than left to omission** (`comment-body.md`
§B7): the run's identity is the comment itself — Jira creates exactly one per
publishing run, stamps and orders it, and the paragraph names the event. A
synthetic run identifier was rejected: it buys a reader nothing Jira does not
already give them, and it puts a machine token in the middle of a sentence
written for a person, which is what Principle XVI exists to prevent. The
evidence that the stream really does discriminate two runs of one event is
T079, in both ports, not an assertion made in the contract.

---

## Progress — 2026-09-01 (second session)

**108 of 110 tasks complete.** Only T106 (Windows probe) and T107 (dogfood)
remain, and both were excluded from this session by instruction. They are the
two gates a mock cannot satisfy, and T107 still carries the seven API facts of
research §R15 that nothing in this repository can falsify.

**Measured, not asserted**, on an unloaded machine:

- `tests/run-bash.sh` — 286 files, **2831 tests, 0 failures**, 19:02.
- Pester over the 036 suites — 86 tests, 0 failures (77 + the 9-case fault
  twin added last).
- `tests/conformance/ci-conformance.sh` — 268 scenarios, 57:16, **one**
  divergence, since fixed and re-verified byte-identical on all four captures.
- `shellcheck` (scoped to `scripts/bash`), PSScriptAnalyzer and `actionlint`
  all clean.

### The four defects this session found by running things

Each was invisible to every test that existed when the session started.

**1. The publication classified the PRE-WRITE artifact set.** The privacy sweep
must see the set before any write (C5.1), and the publication was reusing that
same set — but the apply then stamps ticket markers INTO `spec.md`. So run 1
attached bytes it had already superseded and recorded a hash matching neither
the file nor the upload; run 2 "revised" `spec.md` to correct it; and the
run-state document recorded a hash the next run could never reproduce, so
**nothing ever short-circuited**. The set is now rebuilt after the apply. Two
symptoms, one line. The steady state is now the SECOND run, not the third, and
every suite's `_settle` says so.

**2. `jq`'s `//` resolves `false` to the default.** `.enabled // true` answered
TRUE for a site that had answered `"enabled": false`, in the Bash port AND in
its shim. The PowerShell twin tests for the property's presence and always
honoured it — a silent cross-port divergence on the one setting that switches
the whole feature off. C3.9 was unexercisable until a case set it.

**3. A StrictMode read on a path a dry run reaches only sometimes.** The
PowerShell publication phase read `$applyOutcome`, which only the apply
assigns. A dry run never applies, so the read threw — but the block was
unreachable while a dry run's artifact set was empty. The moment the set became
real, the whole run died with exit 1. It parses clean, it lints clean, and the
Bash port had covered dry-run prediction from the start while this side had
not. Now `Reconcile.ArtifactsFaults.Tests.ps1` covers it.

**4. The instrument was measuring itself.** The spawn-budget guard reported
+114 processes between a 4-artifact and a 40-artifact reconcile — ~3 per
artifact, which reads as an FR-023 violation. It was the MOCK: two `sed` per
config line in the shim's parser, one `jq` per part in its attachment handler.
The port's own cost is +4 for +36 artifacts. Both shim loops are now spawn-free,
and the same guard measures the port rather than the harness.

### Two traps that cost the most time

**A `, @(…)` return in a Pester helper.** `return , @(x)` protects a
one-element array through `return`, and then piping it to `Where-Object`
unrolls a single level — so the filter sees ONE object (the inner array), and
`.filename -eq 'research.md'` on an array is truthy, so the whole list passes as
one item. Every count read 1. "After a revision the ticket carries one copy"
looked TRUE while the ticket carried two.

**`mock_start` COPIES its config.** A fault added mid-test to the file handed
to `mock_start` is read by nobody; the shim re-reads `$MOCK_CONFIG_PATH`, in
the mock's own temp directory. A 403 that never fired, on a route a direct
`curl` proved faulted.

### Decisions taken without the operator, and why

- **`inputs` keeps the three configuration files.** Contract C3.1 says the key
  set is "exactly the artifact set's paths". Taken literally that drops
  `config.yml`, `config.local.yml` and `personal.yml` from the short-circuit,
  so a re-pointed project would no longer invalidate. They stay, with v2's
  "omitted when absent" rule. C3.1 is read as governing the feature-directory
  portion.
- **An empty artifact set never matches and is never recorded.** Under schema 3
  the inputs ARE the set, so two empty sets compare equal — and a directory
  outside a git repository has an empty set. Fail open: no set, no
  short-circuit, no record. Six suites and eight scenarios were fixtures
  without a repository and now `git init`.
- **`artifacts[]` gained four withholding reasons** — `site-disabled`,
  `limit-unreadable`, `manifest-overflow`, `upload-failed` — so a run that
  withheld the whole publication reports every entry as `withheld` rather than
  `published`. Reporting `published` for a file that reached nothing is the one
  thing an audit trail cannot do.
- **`attach` and `comment` join `actions[]` from the publication phase**, not
  from `plan_apply.sh`. Publication runs after the apply, because the ticket
  may have been created by it; planning them earlier is not possible.

### What is NOT done

- **T106 / T107**, by instruction. `docs/11-process-budget.md`'s question — does
  `form =` in a curl config on stdin behave as `-F` through MSYS — is still
  unanswered, and the entity-property cap in C4.4 is still an assumption
  documented as one.
- **A stderr asymmetry in `us6-dry-run`**, unrelated to this feature: the Bash
  port's stderr carries `jq: error … Cannot index array with string "story"`
  and the PowerShell port's does not. Reproduced identically against HEAD in a
  detached worktree, so it predates this branch. Not investigated further.
- **The prose renderer never prints warning text.** `summary_render_prose`
  emits `Warnings: N` and no message; every publication warning this feature
  adds is visible only under `--json`. Pre-existing and wider than 036, but it
  blunts FR-021 in the default output and deserves its own spec.

---

## Progress — 2026-09-01 (first session)

**Phase 1, Phase 2 and Phase 9 are COMPLETE.** Phase 3/4 have their engine and
sink code on both ports; what is missing is the wiring and the Pester twins.

Done and marked:

- T003–T012, T015–T018 — the artifact set, both ports, byte-identical
- T013/T014 — the privacy sweep, both ports, at the pre-write point
- T019–T026 — the multipart transport and both mock surfaces
- T027–T033 — `after_converge` and `after_checklist`, thirteen sites
- T035/T036, T042/T043, T046/T047, T059/T060, T064 — the attachment modules on
  both ports: limit discovery, the withholding gate, the upload, the comment
  body, the manifest, the property-cap check
- T108–T110 — the convergence findings

**Done but NOT marked, and why.** `tests/bash/sink/test_attachments.bats`
covers classification, the comment body (compared byte-for-byte against
`comment-body.md`'s own lines), the manifest and the zero-churn cycle — 25
cases, proven red against the absent module. It does NOT yet cover the
network-level assertions those task numbers also demand: that
`GET /attachment/meta` is called exactly once per run, that the upload targets
the specification tier only, and that a ticket created in the same run is
published onto. Those need the command harness, not the module. **T034, T039,
T040, T041, T044, T045, T057, T058, T061, T063, T065–T069 stay unchecked**
until they have both halves, and there is no Pester twin of any of them yet.

**Next, in order:**

1. `Reconcile.ArtifactPublication.Tests.ps1` and `Attachments.Tests.ps1` — the
   Pester twins of `test_attachments.bats`. The two ports were compared
   directly and agree byte for byte on all five decision shapes, but that
   comparison lives in a shell one-liner, not in the suite.
2. **T048–T053 — the wiring.** The publication phase in `reconcile.sh` and
   `Reconcile.psm1`, `attach`/`comment` in the planned action set, and
   `artifacts[]` in the run summary plus its schema guard. This is the piece
   that makes the feature exist for a user; everything above is inert without
   it.
3. T054–T056, then Phase 4's remaining tests, then Phases 5–8.

**Unchanged**: T001/T002 need a real baseline (the first one was taken against
a moving tree). T106 (Windows probe) and T107 (dogfood) are outside what an
agent session can execute; T107 carries the seven API facts no mock we write
can falsify, and it is the gate that matters most before release.

**Do not merge yet.** The privacy sweep is live and publication is not, so an
existing consumer whose `research.md` quotes a real `*.atlassian.net` URL would
see runs refused with nothing gained in exchange. Ship Phase 3 + Phase 4
together, or hold the branch.

## Progress — 2026-08-31

**17 of 110 tasks complete** (T003–T012, T015–T018, T108–T110): Phase 1, the
engine half of Phase 2, and the whole of the Phase 9 convergence set.

Verified, not assumed: 1201 bats tests green, Pester 14/14 + 41/41, both ports
emit byte-identical artifact-set JSON AND byte-identical neutral documents for
the same fixture, `shellcheck` clean over
all of `scripts/bash`, PSScriptAnalyzer clean, and the repository's own CI
guards (boundary, jq path spelling, packaging surface) green.

**T001/T002 are recorded as NOT done rather than skipped.** The baseline run
was started before the tree was stable and its two failures turned out to be
its own interference; the two suites it flagged were re-run clean afterwards,
but that is a re-run, not a baseline. Whoever picks this up should take a real
one first.

**Stopped deliberately at T013.** The privacy guard (T013/T014) is the next
task and it is a pair: a scanning function plus its wiring into the reconcile's
existing pre-write sweep. Landing the function alone would ship code no caller
reaches — dead on arrival under Principle XV — and the wiring is a change to a
139 KB `reconcile.sh` whose correctness needs the command-level suites to
verify. It is a clean seam to resume from, not a half-finished one.

---

## Phase 1: Setup

- [X] T001 Record the pre-change baseline: run `tests/run-bash.sh`, note the measured wall time and test count, and update the runtime figure in `AGENTS.md` if it has drifted from the ~16 min / 2688 tests recorded on 2026-08-30
- [X] T002 Confirm `bash tests/conformance/ci-conformance.sh` is green before any change — success is silent, so the check is exit 0 with no `conformance divergence` line, and the temp paths it prints are harness noise
- [X] T003 [P] Build the shared test fixture `tests/bash/helpers/artifact_fixture.bash`: a feature directory holding `spec.md`, `plan.md`, `tasks.md`, `research.md`, `contracts/api.md`, `checklists/requirements.md`, a small binary (`assets/diagram.png`), and one git-ignored file — the corpus every phase below reuses
- [X] T004 [P] Build the PowerShell twin of T003 in `tests/powershell/helpers/ArtifactFixture.psm1`, producing a byte-identical directory

---

## Phase 2: Foundational — the artifact set, the guard, and the transport (blocks every user story)

**Purpose**: the engine object every story consumes, the privacy guard that must
exist before any artifact content can reach the network, the schema that carries
the set across the boundary, the transport that can send a multipart body, and
the two mock surfaces that can observe it. No story can begin until this is done.

### The artifact set (engine) — data-model §1, FR-001, FR-005, FR-007, FR-023

- [X] T005 [P] Write failing cases in `tests/bash/engine/test_artifact_set.bats`: nested files found at any depth (FR-001); a git-ignored file absent from the set (FR-007); the set sorted by `path` byte-wise (data-model §1 "Ordering"); `contracts/api.md` → `contracts__api.md` and a top-level file keeping its exact name (FR-005, research R7); a `..` path rejected; paths `/`-separated on every host
- [X] T006 [P] Write the Pester twin of T005 in `tests/powershell/engine/ArtifactSet.Tests.ps1`
- [X] T007 [P] Write a failing process-budget case in `tests/bash/engine/test_artifact_set.bats` asserting the whole set is built with a **bounded** number of external processes regardless of artifact count — one `git ls-files`, one `git hash-object`, one stat pass — using `tests/bash/helpers/spawn_count.bash`; prepend the counting shim to `PATH` and probe the instrument first, or it reports 0 forever (FR-023, research R4/R5)
- [X] T008 [P] Write a failing argv-size case in `tests/bash/engine/test_artifact_set.bats` asserting no command line grows with the artifact set — measure against the **Windows** ~32 767-byte cap, not the host's, using `tests/bash/helpers/argv_size.bash` (FR-023, `docs/11-process-budget.md`)
- [X] T009 Implement `scripts/bash/engine/artifact_set.sh`: enumerate with one `git ls-files --cached --others --exclude-standard -z -- <feature dir>`, hash with one `git hash-object --no-filters --stdin-paths` fed on **stdin**, then sort, size and flatten as pure string work (research R4/R5, data-model §1)
- [X] T010 Implement `scripts/powershell/engine/ArtifactSet.psm1`, byte-equivalent to T009, splitting the NUL-separated enumeration identically
- [X] T011 [P] Write failing collision cases in both suites: `contracts/api.md` + `checklists/api.md` flatten identically ⇒ **both** withheld, one warning naming both paths, the rest of the run unaffected (FR-005, data-model §1 "Validation", research R7)
- [X] T012 Implement the collision detection in both ports' artifact-set modules per T011

### The privacy guard over artifact content — C5, FR-016, SC-007, Principle IX

**This is foundational, not polish.** It was scheduled after the upload path in
the first draft of this file; `/speckit-analyze` found that FR-016's "zero writes
for the **entire** run" is unachievable from the publication phase, because the
description and story writes have already landed by then. The scan belongs at the
reconcile's existing pre-write sweep, and it must exist before any task uploads
artifact content anywhere.

- [X] T013 [P] Write failing cases in `tests/bash/sink/test_privacy_guard_artifacts.bats` and its Pester twin `tests/powershell/sink/PrivacyGuard.Artifacts.Tests.ps1`: a BLOCK-tier coordinate inside `research.md` leaves the ticket **untouched** — zero calls of every write kind on the mock call log, not merely zero attachments (C5.5); the same for a BLOCK-tier byte sequence inside the **binary** artifact (research R12); the message names the artifact and the shape and never the value; an allowlisted Confluence link and an allowlisted corporate domain **inside artifact content** produce neither a block nor a warn (C5.2, C5.3, FR-016, SC-007)
- [X] T014 Fold the artifact scan into the existing pre-write sweep in `scripts/bash/commands/reconcile.sh` and `scripts/powershell/commands/Reconcile.psm1`, calling `scripts/bash/sink/jira/privacy_guard.sh` / `scripts/powershell/sink/jira/PrivacyGuard.psm1` once over the whole set — one pass, no per-artifact process, no second traversal, no text/binary special case (C5.1, C5.4)

### The neutral document — Principle VIII, data-model §4

- [X] T015 [P] Write failing validation cases in `tests/bash/engine/test_interchange.bats`: a document carrying a well-formed `artifacts` array validates; one carrying an absolute path is **rejected**; one omitting `artifacts` entirely still validates (the field is optional); an entry missing a required key is rejected
- [X] T016 [P] Write the Pester twin of T015 in `tests/powershell/engine/Interchange.Tests.ps1`
- [X] T017 Add the optional `artifacts` array to `specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json` and to the validation programme in `scripts/bash/engine/interchange.sh` and `scripts/powershell/engine/Interchange.psm1` (data-model §4)
- [X] T018 [P] Extend the engine/sink boundary guard case in `tests/bash/ci/test_boundary_gate_neutral_tokens.bats` to cover `scripts/bash/engine/artifact_set.sh` — proving the new engine module names no Atlassian identifier and sources nothing under `sink/` (Principle VIII)

### The transport — contract C2, FR-023, Principle IV

- [X] T019 [P] Write failing multipart cases in `tests/bash/sink/test_client_multipart.bats`: the request carries `X-Atlassian-Token: no-check`; one `form =` line per artifact; each line spells the path through `_jira_curl_path` (`cygpath -m` under a forced `JIRA_PATH_STYLE=native`); each carries an explicit `;filename=` equal to the flattened name; the whole config still travels on **stdin** (C2.1)
- [X] T020 [P] Write the failing credential case in the same file: with maximum verbosity enabled, the credential appears in no argv, no log and no trace of the multipart path — the test Constitution IV names verbatim (Principle IV, NFR-3)
- [X] T021 [P] Write the Pester twin of T019/T020 in `tests/powershell/sink/Client.Multipart.Tests.ps1`, including that `ContentType` is **not** set when form parts are supplied and that each part's filename is the flattened name, not the `FileInfo` basename (C2.2, research R14)
- [X] T022 Extend `scripts/bash/sink/jira/client.sh` to emit `header =` and `form =` directives into the stdin config when the caller supplies form parts, changing nothing about the existing retry, backoff or exit-code mapping (C2.1)
- [X] T023 Add `-FormParts` to `Invoke-JiraRequest` in `scripts/powershell/sink/jira/Client.psm1`: suppress `ContentType`, add the token header, set each part's filename explicitly (C2.2)

### The two mock surfaces — research R13

- [X] T024 [P] Extend `tests/bash/ci/test_mock_shim_contract.bats` **first**, so the shim and the server are asserted to serve the same four new routes, and observe it RED before either mock learns them — the guard that stops one port's suite going green on a route the other port has never seen
- [X] T025 [P] Add to `tests/conformance/mock-jira/curl-shim.sh`: `GET /attachment/meta`, `POST /issue/{key}/attachments`, `POST /issue/{key}/comment`, and `GET|PUT /issue/{key}/properties/spec-kit-jira-artifacts` — **including parsing the multipart config** so the shim can record the part filenames and order, which is the only place the Bash port's request body is observable
- [X] T026 [P] Add the same four routes to `tests/conformance/mock-jira/mock-server.ps1`, keying responses the way the existing routes do — and **not** by pattern-matching an existing `fields=` route, because the mock keys some responses on the exact query string and a widened field list silently serves the wrong fixture

### The two lifecycle events — FR-019, research R10

- [X] T027 [P] Write the failing manifest case: update `tests/bash/ci/test_manifest_hooks.bats` (`EXPECTED_EVENTS` at line 33, the *exactly seven* assertion at line 69, the reconcile-fires-every-after loop at line 81) to expect **nine** hooks including `after_converge` and `after_checklist`, and observe it RED against the current `extension.yml`
- [X] T028 [P] Write the Pester twin of T027 in `tests/powershell/ci/Manifest.Hooks.Tests.ps1`
- [X] T029 [P] Write failing config cases in `tests/bash/lib/test_config.bats` and `tests/powershell/lib/Config.Tests.ps1`: a `phase_status_map` declaring `after_converge` or `after_checklist` is **accepted**, and the unknown-key message lists all eight lifecycle events (the nine hooks less `before_specify`, which is not a phase)
- [X] T030 Add `after_converge` and `after_checklist` to the `hooks:` block of `extension.yml`, both `optional: false`, both firing `speckit.jira-mirror.reconcile` (FR-019)
- [X] T031 Add both events to the four Bash/PowerShell enumeration sites: `scripts/bash/lib/config.sh:963` (message) and `:1065` (`JIRA_HOOK_EVENT_NAMES`), `scripts/powershell/lib/Config.psm1:942` and `:1858`
- [X] T032 Add both events to the two canonical-order sites: `scripts/bash/commands/reconcile.sh:309` and `scripts/powershell/commands/Reconcile.psm1:380`
- [X] T033 [P] Add both events to the `phase_status_map` comment in `templates/config.yml.template:91`, keeping the self-documenting style Principle XVI requires

**Checkpoint**: the artifact set exists and is covered on both ports; artifact content cannot reach the network unscanned; the neutral document carries the set; both transports can send a multipart body without the credential leaving stdin; both mocks serve the new routes and a guard proves they agree; nine hooks are declared and accepted everywhere.

---

## Phase 3: User Story 1 — a Jira reader can read everything Spec Kit produced (P1) 🎯

**Goal**: every artifact of the feature directory is downloadable from the
specification ticket, announced by one comment per run.

**Independent test**: run the mirror on a feature directory holding more than
the three rendered documents, then from Jira alone confirm every file is
downloadable and one comment names each.

### Limit discovery and withholding — C1.1, C3.9, FR-017

- [X] T034 [P] [US1] Write failing cases in `tests/bash/sink/test_attachments.bats`: `GET /attachment/meta` is called **once per run** and only when there is something to publish; `enabled: false` withholds the whole publication with one warning and attempts no upload (C3.9); an unreachable meta call withholds with one warning and attempts no upload (C3.7)
- [X] T035 [P] [US1] Write the Pester twin of T034 in `tests/powershell/sink/Attachments.Tests.ps1`
- [X] T036 [P] [US1] Write failing oversize cases in both suites: an artifact above the **discovered** limit is withheld, the warning names the path, its size and the limit, and every other artifact still publishes (FR-017, C4.2)
- [X] T037 [US1] Implement limit discovery and the withholding gate in `scripts/bash/sink/jira/attachments.sh`, holding the limit in-process for the run (C1.1)
- [X] T038 [US1] Implement the twin in `scripts/powershell/sink/jira/Attachments.psm1`

### Upload — C1.4, FR-001, FR-002, FR-003, FR-006

- [X] T039 [P] [US1] Write failing upload cases in both suites: **one** `POST /issue/{key}/attachments` per run whatever the artifact count (FR-023); parts in the set's sort order; a binary artifact uploaded byte-for-byte unmodified (FR-002, US1 AS3); nested artifacts distinguishable by their flattened part filenames (US1 AS5)
- [X] T040 [P] [US1] Write a failing tier case in both suites: the upload targets the **specification-tier** ticket only — zero attachment calls against any story-tier or task-tier key (FR-003)
- [X] T041 [P] [US1] Write a failing same-run case in both suites: when the specification ticket is created by this run, the artifacts are published onto it in that run, not deferred (FR-006, US1 AS4)
- [X] T042 [US1] Implement the upload in `scripts/bash/sink/jira/attachments.sh` — one request, parts in sort order, real file paths resolved from the feature directory plus the relative path (C1.4, data-model §4)
- [X] T043 [US1] Implement the twin in `scripts/powershell/sink/jira/Attachments.psm1`

### The announcing comment — comment-body.md, FR-004, FR-008

- [X] T044 [P] [US1] Write failing body cases in `tests/bash/sink/test_comment_body.bats`: exactly **one** comment per publishing run and **zero** otherwise (B6.2, FR-008, SC-004); the paragraph literal chosen by whether any artifact is a revision (B2); one bullet per artifact in sort order, each `` `<path>` — new `` or `` — revised `` (B3, B6.3); the event rendered as `code`-marked text, verbatim; withheld artifacts **absent** from the comment (B4); no trailing newline introduced by composition (B6.4)
- [X] T045 [P] [US1] Write the Pester twin of T044 in `tests/powershell/sink/CommentBody.Tests.ps1`
- [X] T046 [US1] Implement the comment body in `scripts/bash/sink/jira/attachments.sh` from the pinned literals of `contracts/comment-body.md`, built on the existing `sink/jira/adf.sh` primitives, with no `media` node (B1, research R8)
- [X] T047 [US1] Implement the twin in `scripts/powershell/sink/jira/Attachments.psm1`, copying the literals rather than composing them — the measured PowerShell pipe-to-native newline is why this is spelled out (B6.4)

### Wiring into the reconcile — FR-021, SC-001

- [X] T048 [P] [US1] Write failing command-level cases in `tests/bash/commands/test_reconcile_artifacts.bats` using the T003 fixture: a first run publishes **every** artifact of the directory — none missing — and the summary's `artifacts[]` names each with `published` (SC-001, data-model §5)
- [X] T049 [P] [US1] Write the Pester twin of T048 in `tests/powershell/commands/Reconcile.Artifacts.Tests.ps1`
- [X] T050 [US1] Add the publication phase to `scripts/bash/commands/reconcile.sh` after the existing write phases, and add `attach` and `comment` to the planned action set in `scripts/bash/sink/jira/plan_apply.sh` (data-model §5). The privacy scan is **not** here — it is at the pre-write sweep, per T014 and C5.1
- [X] T051 [US1] Implement the twins in `scripts/powershell/commands/Reconcile.psm1` and `scripts/powershell/sink/jira/PlanApply.psm1`
- [X] T052 [P] [US1] Add the `artifacts[]` array to `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json` **and** extend the reconcile schema guard that consumes `tests/bash/helpers/summary_schema.bash`, so the published contract cannot drift behind the ports again (data-model §5 note)
- [X] T053 [P] [US1] Write the conformance scenario `tests/conformance/scenarios/sc036-artifacts-first-publication.json`: both ports produce byte-identical comment bodies, an identical multipart part list, an identical call sequence and an identical `artifacts[]` array — a reconcile fixture needs `resolved_ids` and **no** `base_url`, or the run is a silent exit-0 no-op (FR-022, SC-008, quickstart §4)

### The scenarios that justify the two new events, and the two ticket-state edge cases

- [X] T054 [P] [US1] Write the failing end-to-end case in both suites for the scenario that justifies `after_checklist` at all: a feature directory whose **only** change is a new `checklists/ux.md` — `spec.md`, `plan.md` and `tasks.md` untouched — publishes that file when the mirror fires, without any further Spec Kit command (US1 AS6, SC-005, FR-019)
- [X] T055 [P] [US1] Write the failing adopted-ticket case in both suites: publication onto a specification ticket recorded as **human-origin/adopted** succeeds — it is additive, and the human-origin protection concerns deletion and overwrite, neither of which happens here (spec Edge Cases, Principle I)
- [X] T056 [P] [US1] Write the failing no-ticket case in both suites: a feature whose specification ticket does not exist and cannot be created — routing refused — publishes nothing, half-publishes nothing, writes no manifest, and the next successful run publishes the directory as it then stands (spec Edge Cases)

**Checkpoint**: US1 is independently demonstrable — a first publication puts every artifact on the ticket with one comment. It is **not shippable alone**: without Phase 4 every run republishes everything.

---

## Phase 4: User Story 2 — re-running changes nothing (P1)

**Goal**: a run over an unchanged feature directory issues zero attachment,
comment and property writes.

**Independent test**: run the mirror twice over an unchanged directory and
assert on the mock call log — not on the summary text — that the second run
made zero calls of all three kinds.

### The publication manifest — data-model §2, FR-012

- [X] T057 [P] [US2] Write failing manifest cases in both suites: a `404` on the property read means "no manifest" and every artifact is a first publication, **not** a fail-closed condition (C1.2); an unrecognised `schema` value is treated as absent and republishes, never as an error; the document validates against `contracts/artifact-manifest.schema.json`
- [X] T058 [P] [US2] Write failing classification cases in both suites, one per row of C4.1: path absent ⇒ `published`; `hash` differs ⇒ `revised`; `hash` matches and the id is on the ticket ⇒ `unchanged` with **no write**; `hash` matches and the id is absent from the ticket ⇒ `published` (the trust rule)
- [X] T059 [US2] Implement manifest read, classification and write in `scripts/bash/sink/jira/attachments.sh`: the write is issued **only** when at least one artifact landed, and carries only entries that actually landed (data-model §2 "Lifecycle")
- [X] T060 [US2] Implement the twin in `scripts/powershell/sink/jira/Attachments.psm1`
- [X] T061 [P] [US2] Write failing trust-rule cases in both suites (C4.3): `GET /issue/{key}?fields=attachment` is issued **only** when the manifest claims an id and the run is about to conclude `unchanged`; property written but upload never landed ⇒ republish; upload landed but property never written ⇒ republish, the duplicate accepted and marked a revision. This is SC-010: after a run that failed partway, the next run leaves the ticket carrying every current artifact and loses none
- [X] T062 [US2] Implement the trust rule in both ports per T061

### The manifest's bound — C4.4

- [X] T063 [P] [US2] Write failing overflow cases in both suites: a feature directory whose composed manifest would exceed the entity-property cap withholds the **whole** publication before any upload, with one warning naming the artifact count, the composed size and the cap, and issues zero writes of every kind (C4.4.1); a site-rejected manifest write despite that check warns and names size as the cause, rather than a generic save failure (C4.4.2)
- [X] T064 [US2] Implement the size check in both ports' attachment modules, with the assumed cap documented in the code **as an assumption** pending research §R15 item 4 — never as a constant that reads as measured (C4.4, Principle VII)

### The zero-churn floor — FR-009, FR-010, C4.5

- [X] T065 [P] [US2] Write the failing zero-churn case in `tests/bash/commands/test_reconcile_artifacts_idempotent.bats`: two runs over an unchanged directory, asserting on `$MOCK_CALLLOG` that the second issues **zero** `POST .../attachments`, **zero** `POST .../comment` and **zero** `PUT .../properties/spec-kit-jira-artifacts` (FR-009, US2 AS1)
- [X] T066 [P] [US2] Write the Pester twin of T065 in `tests/powershell/commands/Reconcile.ArtifactsIdempotent.Tests.ps1`
- [X] T067 [P] [US2] Write the failing call-budget case in both suites, one row per C1 "Call budget": short-circuit ⇒ **0** calls; run proceeds with every artifact unchanged ⇒ exactly **1** call, the manifest read, and zero writes; run proceeds with a publication ⇒ the bounded set. The middle row is the one a loose reading gets wrong (C1)
- [X] T068 [P] [US2] Write the failing third-and-fourth-run case in both suites: attachment and comment counts identical to after the first run (US2 AS2)
- [X] T069 [P] [US2] Write the failing single-change case in both suites: exactly one artifact changed ⇒ exactly that one published, exactly the comment announcing it, and no write for any unchanged artifact (FR-010, US2 AS3, SC-003)

### Run state v3 — FR-011, run-state-v3.md

- [X] T070 [P] [US2] Write the failing short-circuit regression in `tests/bash/lib/test_run_state_artifacts.bats`: publish, modify **only** `research.md`, re-run, assert the run does **not** short-circuit and that `research.md` is published (run-state-v3.md C4, FR-011, US2 AS4)
- [X] T071 [US2] **Prove T070 red against schema 2** by running it against the pre-change `lib/run_state.sh` retrieved from git, and record the failure output in the task's completion note — a guard that was never observed failing is not a guard
- [X] T072 [P] [US2] Write the Pester twin of T070 in `tests/powershell/lib/RunState.Artifacts.Tests.ps1`
- [X] T073 [US2] Bump `_RUN_STATE_SCHEMA` 2 → 3 in `scripts/bash/lib/run_state.sh`, replace the three fixed inputs with the artifact set's path→hash map, and replace the per-input `git hash-object` with one `--stdin-paths` call (C2, C3.1–C3.6)
- [X] T074 [US2] Implement the twin in `scripts/powershell/lib/RunState.psm1`
- [X] T075 [P] [US2] Write the failing state-phase budget case in `tests/bash/lib/test_run_state_artifacts.bats`: the state phase spawns a **bounded** number of processes regardless of artifact count (run-state-v3.md C5), using `spawn_count.bash` with the PATH shim
- [X] T076 [P] [US2] Write the conformance scenario `tests/conformance/scenarios/sc036-artifacts-zero-churn.json`: both ports issue an identical (empty) call sequence on the second run

**Checkpoint**: US1 + US2 together are the shippable increment. Publication happens, and re-running is free.

---

## Phase 5: User Story 3 — a revised artifact is republished, and the earlier one survives (P2)

**Goal**: the record follows the folder across the feature's life.

**Independent test**: publish, modify one artifact, re-run, and assert the
ticket carries both copies with a comment for each, the later one marked a
revision.

- [X] T077 [P] [US3] Write failing revision cases in both suites: a changed `spec.md` is published again and announced by a new comment whose line reads `— revised` (FR-013, US3 AS1, B3)
- [X] T078 [P] [US3] Write the failing preservation case in both suites: after a revision the earlier attachment is still present and still downloadable, and **no** `DELETE` was issued against any attachment (FR-014, US3 AS2, C6)
- [X] T079 [P] [US3] Write the failing ordering case in both suites: with several published versions of one artifact, the comment stream makes the publication order unambiguous and the most recent version identifiable without opening the files (US3 AS3)
- [X] T080 [P] [US3] Write the failing deletion case in both suites: an artifact deleted from the feature directory leaves its published copies on the ticket, produces **zero** Jira writes, and its manifest entry is left in place (FR-015, US3 AS4, data-model §2)
- [X] T081 [US3] Implement the revision path in both ports' attachment modules — the same attachment name is reused, so the ticket lists several copies by design (research R7)
- [X] T082 [P] [US3] Write a CI guard in `tests/bash/ci/test_no_attachment_delete.bats` proving no code path in either port issues `DELETE /attachment/` in any mode, the guarded re-mode included, and observe it red against a deliberately planted call before removing it (C6, Principle I)
- [X] T083 [P] [US3] Write the conformance scenario `tests/conformance/scenarios/sc036-artifacts-revision.json`: both ports produce identical revision comments and identical call sequences

**Checkpoint**: the ticket is a faithful, append-only record of the feature's artifacts.

---

## Phase 6: User Story 4 — the operator can predict and audit the publication (P2)

**Goal**: dry-run predicts exactly, the summary explains every withholding, and
a publication failure never fails the host command.

**Independent test**: dry-run then the real run against the same state, and
assert the predicted artifact and comment sets equal the actual ones.

- [X] T084 [P] [US4] Write failing dry-run cases in both suites: dry-run names every artifact it would publish and every comment it would post, and issues **zero** writes; the summary renders `would-publish` / `would-revise` in place of the two write actions (FR-020, US4 AS1, data-model §5)
- [X] T085 [P] [US4] Write the failing prediction-equality case in both suites: the dry-run's predicted publication set equals the following real run's actual set, exactly (US4 AS2, SC-006)
- [X] T086 [P] [US4] Write failing summary cases in both suites: every `withheld` entry carries a `reason` and the facts to act on — size and limit for `oversized`, the colliding path for `name-collision` (FR-021, US4 AS3, Principle XVI)
- [X] T087 [US4] Implement the dry-run rendering and the summary entries in both ports
- [X] T088 [P] [US4] Write the failing **fail-closed departure** case in both suites — the changed branch, not the unchanged one: a `403` on `POST .../attachments` withholds with one warning naming the ticket and the missing capability with its remedy, the reconcile's earlier writes stand, and **the run's exit code is unchanged** (C3.2, FR-018, plan Complexity Tracking)
- [X] T089 [US4] Implement the C3.2 translation at the publication call site in both ports — inspecting the transport result rather than letting the `auth` code propagate, which would otherwise fail every reconcile for a token lacking "Create attachments"
- [X] T090 [P] [US4] Write failing cases for the remaining rows of C3 in both suites: comment write fails after a successful upload ⇒ manifest **is** written and one warning says the announcement did not post (C3.5); manifest write fails after a successful upload ⇒ one warning, and the next run does not duplicate (C3.6); 5xx / network / 429-exhausted ⇒ withheld, manifest **not** written, next run retries (C3.4)
- [X] T091 [US4] Implement the C3.4–C3.6 outcome mapping in both ports
- [X] T092 [P] [US4] Write the failing hook case in both suites: a publication failure fired from a lifecycle hook leaves the host command's exit code unaffected and surfaces exactly one actionable warning (FR-018, US4 AS4, SC-011, Principle III)

**Checkpoint**: every write the feature performs is predictable, auditable, and incapable of failing the host command.

---

## Phase 7: Cross-cutting constitutional obligations

**These belong to no user story, which is exactly why they get dropped.** Each
one below has produced a CRITICAL finding at `/speckit-analyze` on a previous
feature of this repository. Do not fold them into a story phase.

The privacy-guard obligation used to live here and has moved to Phase 2
(T013/T014) — `/speckit-analyze` showed it was not polish but a prerequisite.

- [X] T093 [P] **Principle II — the live zero-churn suite.** Extend `tests/live/test_live_zero_churn.bats` with `attached` and `commented` assertions, in the same change that adds those write kinds to the sink. The principle's enforcement test requires this list to stay exhaustive. This is also SC-002's "verified against a real Jira instance" clause. Bash only — there is no PowerShell live twin, and that asymmetry is expected
- [X] T094 [P] **Principle IV — credentials at maximum verbosity.** Covered for the new multipart path by T020/T021; confirm here that the assertion is present in **both** ports and runs at maximum verbosity, and record the confirmation rather than assuming T020 covered the PowerShell side
- [X] T095 [P] **Per-class conformance scenarios.** Each withholding class gets its own conformance scenario, not merely a per-port unit test: `sc036-artifacts-oversized.json`, `sc036-artifacts-name-collision.json`, `sc036-artifacts-site-disabled.json`, `sc036-artifacts-privacy-blocked.json`, `sc036-artifacts-403-withheld.json`, `sc036-artifacts-manifest-overflow.json` — per-class unit tests do not satisfy a per-class conformance obligation
- [X] T096 [P] **The process budget, end to end.** Write a failing case asserting a whole reconcile over a 40-artifact directory spawns no process per artifact and passes no payload through a growing command-line argument, measured against the **Windows** cap — extend `tests/bash/ci/test_argv_whole_spec_aggregate.bats` rather than starting a new guard (FR-023)
- [X] T097 [P] **SC-009's wall clock.** Measure a first publication of a 20-artifact directory totalling under 5 MB against the mock and assert it completes inside one run in under 60 s, recording the measured figure. The spawn invariant (T096) is the durable constraint; this is the user-facing number the specification actually promises, and nothing else measures it (SC-009)

---

## Phase 8: Documentation, release, and the gates a mock cannot satisfy

- [X] T098 [P] Update `docs/03-lifecycle-hooks.md`: "The seven declared events" becomes nine, in the prose **and** in the Mermaid diagram, with `after_converge` and `after_checklist` shown firing reconcile
- [X] T099 [P] Update `docs/05-reconcile-flow.md` with the publication phase — where it sits, what it calls, the zero-churn floor, and the fact that the privacy scan is at the pre-write sweep rather than beside the upload
- [X] T100 [P] Update `docs/VISION.md`: §5 "Automatic comments for the complementary artefacts" moves from *envisioned* to *shipped*, its open question about comment granularity is recorded as decided, and "Attachment and screenshot upload" leaves the Part 3 backlog. The vision authorises nothing, so leaving a shipped item marked envisioned invites re-proposing it
- [X] T101 [P] Update `README.md` where it describes what reaches Jira — the doc sweep that a previous feature skipped, leaving `README.md` stating the opposite of the shipped behaviour with no task touching it
- [X] T102 Bump `extension.version` in `extension.yml` — the single source of truth; the literal appears nowhere else but `CHANGELOG.md`, and CI greps to prove it
- [X] T103 Add the `CHANGELOG.md` entry naming every observable change: attachments, the announcing comment, the two new lifecycle events, the run-state schema bump, the new summary array, and the two new `phase_status_map` keys teams gain for free
- [X] T104 Run `find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +` and `actionlint`; both must be clean. The scoping is deliberate — a whole-tree scan is ~1 900 lines of host-script noise
- [X] T105 Run the full `tests/run-bash.sh`, the Pester suite and `bash tests/conformance/ci-conformance.sh` — **never the bash suite and conformance concurrently**, they share fixtures and the collision invents an unrelated `Only in …: state` divergence. Run in chunks: a single run over ~10 minutes gets killed and reports exit 0 with no summary line
- [ ] T106 **Windows probe** — push to `ci/windows-probe` to measure whether the `form =` directive in a `curl` config on stdin behaves as `-F` does through MSYS (research R6, §R15 item 5). Budget ~2 hours, not 11 minutes; results arrive as check-run annotations, not job logs. Freeze the branch while it runs — pushing mid-CI restarts everything. One retry maximum on a flake, then hand the result back
- [ ] T107 **Dogfood against a real Jira site** — the seven remaining items of research §R15, following `quickstart.md` §5. Confirm each and record the result: multiple `file` parts in one request; the `X-Atlassian-Token` header alongside `Authorization`; the `attachment/meta` response shape; the entity-property size cap (which C4.4 currently assumes); two attachments sharing a filename; the status returned when the token lacks "Create attachments"; the PowerShell `-Form` part-filename override. **This is a gate, not a formality** — every test above passes against mocks we wrote ourselves, which is the exact condition under which Principle II records three live-only bugs in the original extension

---

## Dependencies

```text
Phase 1 (setup, fixtures)
   └─> Phase 2 (artifact set · PRIVACY GUARD · neutral doc · transport · mocks · events)   ← blocks everything
          ├─> Phase 3  US1  publication            (P1)
          │      └─> Phase 4  US2  zero-churn      (P1)   ← US2 needs US1's writes to suppress
          │             ├─> Phase 5  US3  revisions (P2)  ← needs the manifest from US2
          │             └─> Phase 6  US4  dry-run + faults (P2)
          └─> Phase 7 (cross-cutting)
                 └─> Phase 8 (docs, release, probe, dogfood)
```

**Why the guard is in Phase 2 and not Phase 7.** FR-016 requires a BLOCK-tier
finding to leave the ticket entirely untouched. Publication runs after the
description and story writes, so a guard placed beside the upload can only abort
the upload — the reconcile's own writes have already landed. The scan therefore
sits at the pre-write sweep, and it must exist before any task in Phase 3 sends
artifact content anywhere.

**Story independence, honestly stated**: US1 is independently *demonstrable* but
**not independently shippable**. Shipped alone it republishes every artifact on
every run — a Principle II violation, which is why the specification made US2
P1 alongside it rather than P2 below it. US3 and US4 are genuinely optional
increments on top.

## Parallel opportunities

- **Phase 1**: T003 ‖ T004.
- **Phase 2**: six workstreams — artifact set (T005–T012), privacy guard (T013–T014), neutral document (T015–T018), transport (T019–T023), mocks (T024–T026), events (T027–T033). Within each, the test tasks are `[P]`; the implementations are not, since each port's twin must match the other.
- **Phase 3**: T034–T036, T039–T041, T044/T045, T048/T049, T052, T053, T054–T056 are `[P]`.
- **Phase 4**: T057, T058, T061, T063, T065–T070, T072, T075, T076 are `[P]`.
- **Phase 5**: T077–T080, T082, T083 are `[P]`.
- **Phase 6**: T084–T086, T088, T090, T092 are `[P]`.
- **Phase 7**: all five are `[P]` — different files, different concerns.
- **Phase 8**: T098–T101 are `[P]` (docs); T102–T107 are strictly sequential.

**Never parallel**: `tests/run-bash.sh` and `tests/conformance/ci-conformance.sh`
(shared fixtures — see T105).

## Implementation strategy

1. **Phase 1 + 2 first, in full.** Nothing below works without the artifact set,
   the guard must exist before any artifact content moves, and the two mock
   surfaces are where a half-done job goes green and proves nothing.
2. **Phase 3 + Phase 4 as one shippable increment.** This is the MVP. Not
   Phase 3 alone.
3. **Phases 5 and 6 as separate increments** once the MVP is green.
4. **Phase 8's last two tasks are the real gates.** T106 and T107 answer the
   eight questions in research §R15 that nothing else can. Budget them: ~2 hours
   for the probe, a real Jira project for the dogfood.

---

## Phase 9: Convergence

Appended by `/speckit-converge` on 2026-08-31, after the engine half of Phase 2
landed. Each item is work the artifacts require that no earlier task covers —
not a restatement of an unchecked task above.

- [X] T108 Thread the artifact set into the neutral document: extend `interchange_build` in `scripts/bash/engine/interchange.sh` and `Build-JiraNeutralDocument` in `scripts/powershell/engine/Interchange.psm1` to accept the set and emit it as the `artifacts` key, omitting the key entirely when the set is empty; write the failing cross-port case first, asserting both ports emit the identical document for one fixture. Without this the set never crosses the engine/sink boundary and the validation rules landed in T015–T017 guard a field nothing writes — per data-model §4, Principle VIII, FR-001 (missing)
- [X] T109 Cover `helper_spawn_count_setup`'s extra-tool parameter in `tests/bash/ci/test_spawn_count_helper.bats`: a caller naming `git` gets a shim that counts and delegates it, the default four are still shimmed when no extra is named, and an unresolvable extra tool still refuses rather than writing a shim that silently counts nothing. The parameter was added by this feature and every budget assertion that names a non-default tool rides on it — a shim that never fires reports 0 spawns, and a budget test against a dead instrument passes for the wrong reason — per Constitution XIII (missing)
- [X] T110 Guard the three statements of the `artifacts` rules against each other — `specs/001-jira-reconcile-engine/contracts/neutral-interchange.schema.json`, the jq programme in `scripts/bash/engine/interchange.sh`, and the PowerShell validator — so a rule added to one and not the others fails CI. Scope it to the `artifacts` key rather than the whole document: the wider drift is pre-existing and belongs to its own spec. The precedent is `run-summary.schema.json`, which sat 7 items behind both ports across three features because nothing compared them — per plan: schema-validated boundary (partial)

---

## Phase 10: Convergence

Appended by `/speckit-converge` on 2026-09-01, after the implementation phases
completed. Each item is work the artifacts require that no earlier task covers —
not a restatement of an unchecked task above. Nothing here is `missing` or
`contradicts`: every requirement has code, and all four findings are shortfalls
in the reporting surface or in test coverage.

- [X] T111 Render `artifacts[]` in the DEFAULT prose summary, in both ports — `summary_render_prose` (`scripts/bash/lib/output.sh`) and `ConvertTo-JiraSummaryProse` (`scripts/powershell/lib/Output.psm1`) know no such key, so a run reports per-artifact outcomes only under `--json`. Measured: a run withholding three oversized artifacts prints `Warnings: 3, Errors: 0` and nothing else, where FR-021 requires the summary to say, per artifact, whether it was published, unchanged or skipped and — for a skip — the reason. Write the failing case first in `tests/bash/commands/test_reconcile_artifacts.bats` and its Pester twin, asserting the withheld artifact's path, size and limit appear in the prose output; then render, in a fixed order both ports share, so Constitution VI's byte-identity holds for prose as it already does for `--json`. Note the blast radius before writing: every run that publishes now gains prose lines, so the reconcile suites asserting on that output have to be read, not assumed — per FR-021, Principle XVI (`partial`)
- [X] T112 Surface the publication WARNINGS in the prose summary, in both ports — the same two renderers print a warning count and never the text, so FR-017's warning naming the artifact, its size and the site limit, and C3.2's naming the ticket and the "Create attachments" remedy, reach no operator who did not pass `--json`. FR-018 requires a hook-context failure to "surface one actionable warning", and a count is not actionable. Determine FIRST whether the hook path passes `--json` (that decides whether this is a defect in practice or only in the direct-invocation path), and record the answer in the task's completion note. Scope the change to the publication warnings rather than rendering the whole `warnings` array: that array is written by every feature since 021, and rendering it wholesale changes the default output of runs this feature never touched — a wider change than 036 authorises (Principle XV). Failing test first, both ports — per FR-017, FR-018, Principle XVI (`partial`)
- [X] T113 Cover contract row C3.3 — a `413` on the upload — on BOTH ports, failing test first. Both ports already translate it (`reconcile.sh`, `Reconcile.psm1`: the warning names the offered file count and the site's per-file limit) and NO test on either port exercises it: T090 enumerated C3.4, C3.5 and C3.6 and omitted this row, so the branch shipped without the test Constitution XIII requires to precede it. Inject the fault the way `test_reconcile_artifacts_faults.bats` does — the mock's `faults` map keyed on the attachments path — and assert the warning names both numbers and that the run's exit code is unchanged. This is the branch class that produced this feature's two run-time-only defects (an unset `$baseUrl`, a StrictMode read of `$applyOutcome`): a message-composing path that parses and lints clean and dies when reached — per Constitution XIII, contract C3.3 (`partial`)
- [X] T114 Close FR-004's "and the run that published it". The comment identifies the lifecycle EVENT (`contracts/comment-body.md` B2 pins that literal and never addresses the run), and the manifest's `run` field records the event too — so two `after_plan` runs that both publish are indistinguishable in the record, and a reader asking "which run put this version here?" is answered only by Jira's own comment timestamp. Decide it deliberately rather than leaving it decided by omission: either carry a discriminator the record and the comment can both name, or amend `contracts/comment-body.md` to state that the comment's position and timestamp in Jira's stream ARE the run's identity and that FR-004 is met by them. Do not edit `spec.md` — per FR-004 (`partial`)
