# Feature Specification: A Reconcile Costs Seconds, and Costs Nothing When Nothing Changed

**Feature Branch**: `feat/improve-scripts-performances`

**Created**: 2026-08-07

**Status**: Draft

**Input**: User description: "Reconcile performance: bring a typical reconcile run from minutes to seconds" — with
goals SC-1..SC-6, functional requirements FR-A..FR-G, constraints C-1..C-6, an out-of-scope list, research notes
measured on the current `main`, and a list of edge cases the spec must cover.

The letters above are the **request's** grouping and are preserved here only to make this specification
traceable back to it. This specification numbers its own requirements FR-001…FR-046, grouped under the bold
headings of the Requirements section, and those numbers are the ones every downstream document cites.

## Why this is a defect and not a wish

The bridge succeeds. It just takes three to seven minutes to do it, on an Apple Silicon laptop, for a
specification with one parent, a handful of stories, and their tasks. Six lifecycle events fire the same
reconcile, so a working session pays that latency again and again, and the operator learns to dread a command
that never actually failed.

The worst case is the commonest one. A re-run over a specification nobody touched still reads every recorded
ticket back, still resolves the credential once per HTTP request and once per retry, still opens a fresh
connection per request, and then writes nothing at all. The bridge pays full price for the answer "nothing to
do" — the answer it gives most often.

Three costs compound, and none of them is the network being slow:

- **The credential is re-resolved per request.** Every request rebuilds its authorisation document, and that
  goes back to the operating system's secret store each time. On macOS, `security find-generic-password` is
  tens to hundreds of milliseconds; under an endpoint-security agent that inspects every process spawn, far
  more. A run issuing 30–80 requests pays that toll 30–80 times, plus once per retry.
- **The read phase scales with the estate.** Recognition reads one ticket per recorded ticket. A specification
  with N mirrored artefacts costs N sequential round trips before a single decision is made, each one a fresh
  connection with its own DNS, TCP, and TLS handshake.
- **The hot loops fork.** The per-story and per-task loops spawn a helper process per item per field. Thousands
  of process creations per run, again multiplied by whatever inspects each one.

None of that is visible today. There is no way to ask a run where its time went, which is why this
specification puts the measurement first: every optimisation that follows has to be justified by a number the
tool itself produced, and a future regression has to be diagnosable from a single run rather than a bisect.

## Two places where this feature meets a recorded decision

Both are named here so that planning starts from them rather than rediscovering them.

**The batched read must not go through the tracker's search index.** Feature 005 established, as its decisive
constraint, that recognition locates a ticket by its recorded key and never by search: the tracker's search
index is eventually consistent, the reported defect happened between two lifecycle commands seconds apart, and
a search-based recognition returns nothing for a ticket created moments earlier — so the bridge re-creates it.
That research explicitly rejected "bulk `key IN (…)` search to collapse N reads into one" for exactly this
reason. This specification keeps the speed goal and drops the mechanism: FR-016 requires the batched read to be
**immediately consistent for a ticket created seconds earlier**, which admits a key-addressed bulk fetch and
forbids the search index. If no immediately-consistent batch mechanism exists on the target tracker, recognition
stays per-key and takes its speed from FR-029's connection reuse instead. Duplicated tickets are the defect
this project has now fixed twice; they are not available as a performance budget.

**Principle IV named Windows Credential Manager — amended, and the amendment reaches further than the
Windows rung (FR-033…FR-040).**
The constitution's credential rung used to read "OS secret manager (macOS Keychain, Linux libsecret, Windows
Credential Manager)", which named a door PowerShell 7 cannot open without a compiled interop shim that
Principle VI forbids at runtime. **Constitution v1.3.0 (2026-08-07) resolves this**: the second rung is now
defined by its requirement — a store the operating system encrypts at rest, read at run time — with
SecretManagement named as the Windows mechanism. FR-033 is no longer blocked.

The amendment also added a soft-optional rule that applies to **all three** platforms, not only Windows: an
absent tool or module, an unregistered or locked store, and a missing entry must each fall through silently;
the rung is never a prerequisite check, never errors, and never prompts or blocks. FR-035, FR-036, and FR-038
are therefore constitutional requirements rather than choices this feature made — and the enforcement test it
carries applies to the macOS and Linux rungs too, which is scope this feature inherits. See Assumption A-6.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A run explains where its time went (Priority: P1)

A maintainer suspects a reconcile has become slow. They set one documented switch, run the command once, and
read a per-phase breakdown on the error stream: how long prerequisites, the short-circuit check, configuration,
parsing, the mandatory-field gate, recognition, planning, and applying each took, and how many tracker requests
each phase issued. They now know which phase to look at, from one run, without a profiler and without editing
the scripts.

**Why this priority**: It is the instrument every other story is measured with. Without it, "recognition now
issues a bounded number of requests" is an assertion; with it, that is a number the tool prints and a test can
read. It is also the only story that leaves behind a permanent defence against the next regression.

**Independent Test**: Run reconcile twice over the same fixture, once with the switch off and once with it on.
Assert the standard output stream, the exit code, and every written file are byte-identical between the two,
and that the second run additionally emitted a per-phase breakdown on the error stream. Delivers value alone:
the current slowness becomes diagnosable even if nothing else in this specification ships.

**Acceptance Scenarios**:

1. **Given** the timing switch is unset, **When** reconcile runs, **Then** no timing line appears on any
   channel and the run's bytes are identical to today's.
2. **Given** the timing switch is set, **When** reconcile runs, **Then** the error stream carries one line per
   phase naming the phase, its elapsed wall time, and the number of tracker requests it issued, plus a total.
3. **Given** the timing switch is set, **When** the run's standard output, exit code, and written files are
   compared with the same run performed with the switch unset, **Then** all three are byte-identical.
4. **Given** the timing switch is set and command tracing is also enabled, **When** reconcile runs, **Then** no
   credential and no derived authorisation value appears on any channel.
5. **Given** the timing switch is set on either port, **When** the same fixture is reconciled, **Then** the
   phase names and their order are identical between the two ports.

---

### User Story 2 - A specification nobody touched costs nothing (Priority: P1)

A developer runs `/speckit.plan` moments after `/speckit.specify`, having changed nothing the mirror cares
about. The bridge recognises that the inputs it mirrored last time are byte-for-byte the inputs it has now,
reports that there is nothing to do, and exits — in well under a second, without contacting the tracker at all.

**Why this priority**: This is the case that fires most often and feels most broken. It is also the only change
in this specification whose ceiling is not "faster" but "free": zero requests cannot be improved on.

**Independent Test**: Reconcile a fixture to completion, then reconcile it again with no local change. Assert
the second run issues zero tracker requests, performs zero writes, exits successfully, and states in its
summary that it short-circuited. Then touch the specification and assert the next run reconciles in full.

**Acceptance Scenarios**:

1. **Given** a specification reconciled successfully with nothing left pending, **When** reconcile runs again
   with no local change, **Then** zero tracker requests are issued, zero writes occur, the exit code is 0, and
   the summary names the short-circuit.
2. **Given** the same state, **When** any byte of the specification, of the tasks document, of the effective
   configuration, or of the local binding has changed, **Then** the run reconciles in full.
3. **Given** the recorded fingerprint is missing, unreadable, malformed, or was written by a different version
   of the bridge, **Then** the run reconciles in full — the doubt always resolves toward doing the work.
4. **Given** the previous run ended in a failure, a warning, a pending confirmation, or a preview, **Then** no
   fingerprint was recorded and the next run reconciles in full.
5. **Given** the `--force` flag, **When** reconcile runs over an unchanged specification, **Then** the
   fingerprint is ignored and the run reconciles in full.
6. **Given** two reconciles racing on the same repository, **When** both complete, **Then** neither can observe
   a partially written fingerprint, and no run is ever skipped on the strength of one.

---

### User Story 3 - The operating system's secret store is asked once, not once per request (Priority: P1)

The operator keeps their token in the Keychain, the keyring, or a vault. A reconcile that issues forty requests
asks the store exactly once. The token is still resolved at run time, still never written anywhere, still
invisible to every trace and every child process — it is simply not fetched forty times.

**Why this priority**: It is the largest constant-factor cost in the current run, it applies to every request
on every path, and it is measurable directly with the instrument from User Story 1. It is also the story with
the most to lose: a cache is exactly the shape of change that leaks a secret if it is done casually.

**Independent Test**: With an instrumented stand-in for the secret store that counts its invocations, run a
reconcile that issues many requests, including at least one retried request. Assert the store was invoked
exactly once. Assert, separately, that the token appears in no process argument list, no environment of any
child process, no trace output, no transcript, no file, and no timing line.

**Acceptance Scenarios**:

1. **Given** the token comes from the operating system's secret store, **When** a reconcile issues N requests
   with R retries among them, **Then** the store is invoked exactly once regardless of N and R.
2. **Given** the token cannot be resolved from any rung, **When** the run proceeds, **Then** the store is still
   consulted only once and the run fails with exactly today's exit code and message.
3. **Given** a run in progress, **When** the token is inspected from outside, **Then** it is absent from the
   environment of every child process the run spawns.
4. **Given** command tracing is enabled at maximum verbosity, **When** the run completes, **Then** neither the
   token nor its derived authorisation value appears anywhere in the output.
5. **Given** the token is rotated in the secret store between two runs, **When** the second run executes,
   **Then** it uses the new token — the cache never outlives the run that filled it.
6. **Given** any port, **Then** the guarantees above hold identically; the mechanism may differ, the outcome
   may not.

---

### User Story 4 - Recognition reads the whole estate in a bounded exchange (Priority: P2)

A specification with a parent, ten stories, and fifty tasks is reconciled. Before this change, the read phase
alone costs sixty-one sequential round trips. After it, the same phase costs a small, fixed number of
exchanges, and every classification it produces — bound, new, blocked, gone, refused — is the one it produced
before.

**Why this priority**: It converts the read phase from linear in the estate to effectively constant, which is
what makes the changed run fit in seconds. It ranks below the first three because it only helps runs that have
work to do, and because it is the story most constrained by the recorded decision named above.

**Independent Test**: Against a mocked tracker, reconcile a fixture with many recorded tickets and assert the
number of read requests is bounded by a constant plus one per chunk, not by the number of tickets. Replay the
recognition suite's existing fixtures — a missing ticket, an invisible ticket, a marker mismatch, a transport
failure — and assert every classification, warning, and exit code is unchanged.

**Acceptance Scenarios**:

1. **Given** M recorded tickets, **When** recognition runs, **Then** the number of read requests is bounded by
   a constant plus one per fixed-size chunk of M, and never grows with M one-for-one.
2. **Given** a ticket created seconds earlier by the previous lifecycle command, **When** recognition runs,
   **Then** that ticket is recognised — the read path is immediately consistent and never depends on an index
   catching up.
3. **Given** a recorded key whose ticket no longer exists, **When** recognition runs, **Then** it is classified
   exactly as today's per-ticket "gone" outcome, with the same warning.
4. **Given** a recorded key the caller is not permitted to see, **When** recognition runs, **Then** it produces
   exactly today's per-ticket permission outcome — and if the batched mechanism cannot distinguish "absent"
   from "not permitted", the ambiguous keys alone are re-read individually rather than guessed at.
5. **Given** a transport failure of the batched read, **When** recognition runs, **Then** the whole
   specification fails closed with today's exit code and zero writes — an inconclusive read is never downgraded
   to "no ticket exists".
6. **Given** a key list longer than the mechanism's limit, **When** recognition runs, **Then** the outcome is
   identical to the unchunked outcome, whatever the chunk boundaries fall between.

---

### User Story 5 - The changed path stops paying for connections and processes it does not need (Priority: P3)

A run that has real work to do reuses one connection across the requests it sends in sequence, and its
per-story and per-task loops stop spawning a helper process per item per field. The tracker sees the same
requests, in the same order where order matters, and the run writes exactly the same bytes.

**Why this priority**: Real, compounding savings, but a refactor of mechanism rather than a change of shape.
It ranks last among the performance stories because it is the one whose benefit is hardest to observe without
User Story 1's instrument, and because it carries the highest risk of changing observable behaviour by
accident.

**Independent Test**: Run the existing conformance corpus before and after and assert byte equality of every
output and every recorded call sequence. Separately, with the timing instrument on, assert the measured
process-spawn count and connection count in the hot phases fall.

**Acceptance Scenarios**:

1. **Given** a sequence of requests to the same host, **When** the run issues them, **Then** the transport
   reuses the connection where it can.
2. **Given** writes with an ordering constraint — a parent before its children, each child carrying the parent
   key — **When** the apply phase runs, **Then** that order is preserved absolutely; no concurrency is applied
   across an ordering edge.
3. **Given** any phase of the run, **When** it issues its requests, **Then** it issues them in one
   deterministic order with no concurrency of any kind, and the run's output, summary, and observed call
   sequence are identical between the two ports and identical between repeated runs over the same fixture.
4. **Given** a per-story or per-task loop on the reconcile path, **When** it processes an item, **Then** it does
   not spawn one helper process per field of that item.
5. **Given** the full conformance corpus, **When** it is run after this change, **Then** every output is
   byte-identical to before it.

---

### User Story 6 - Windows keeps its token in an encrypted vault, like every other operating system (Priority: P3)

An operator on Windows stores the token in a registered secret vault. The bridge finds it there, between the
environment variable and the gitignored file — the same three-rung shape macOS and Linux already have. An
operator who never installs the vault module sees no change, no error, and no prompt.

**Why this priority**: It closes a real asymmetry — Windows operators are told today, in the documentation,
that no OS secret-manager rung exists for them — and it is the one story that is purely additive. It ranks
last because it changes no timing and blocks nothing else.

**Independent Test**: On the PowerShell port, with a stand-in for the vault, assert the token resolves from the
vault when the environment variable is absent. Then assert each of the four fall-through conditions — module
absent, no vault registered, no secret of that name, vault locked — resolves silently to the gitignored file
rung with no error, no prompt, and no hang.

**Acceptance Scenarios**:

1. **Given** no environment variable and a vault holding a secret named `spec-kit-jira`, **When** the token is
   resolved on Windows, **Then** it comes from the vault.
2. **Given** the vault module is not installed, **When** the token is resolved, **Then** the rung falls through
   silently to the gitignored file — no error, no warning, no prompt.
3. **Given** no vault is registered, or no secret of that name exists, **When** the token is resolved, **Then**
   the same silent fall-through occurs.
4. **Given** a vault that requires an interactive unlock, **When** the token is resolved inside a lifecycle
   hook, **Then** the rung falls through within a bounded time and never waits on a prompt.
5. **Given** an existing Windows setup using the environment variable or the gitignored file, **When** it runs
   after this change, **Then** its behaviour is unchanged.
6. **Given** the prerequisite check, **When** it runs on a host without the vault module, **Then** it passes —
   the module is never a prerequisite.

---

### Edge Cases

- **The fingerprint matches but the tracker changed underneath.** Someone deleted or edited a mirrored ticket
  out of band. The fingerprint attests to local inputs only, so the short-circuit does not notice. The
  behaviour is documented, not hidden: any local change, or `--force`, restores full reconciliation and the
  self-healing that goes with it.
- **A key the caller cannot see.** A batched read returns fewer results rather than an error. Recognition must
  detect the absence and reach today's outcome for that key, distinguishing "gone" from "not permitted" —
  falling back to an individual read for the ambiguous keys rather than choosing one.
- **Two lifecycle hooks racing.** Both may write a fingerprint. The write is atomic, so no run can ever read a
  half-written one, and a torn write can never cause a wrongful skip.
- **The timing switch and command tracing on at once.** Timing lines must not make the credential traceable,
  and the phase whose duration is being measured must keep its trace suspension.
- **A vault that demands an interactive unlock.** Inside a hook there is nobody to answer. The rung falls
  through; the installation documentation states the configuration trade-off for hook-driven use.
- **Windows PowerShell 5.1.** The prerequisite check already refuses it before any credential code runs. No new
  path.
- **The first run of all.** No fingerprint exists, nothing is recorded, and every phase runs. The
  short-circuit's absence must cost nothing measurable.
- **A run that ends in a pending confirmation.** Required-field confirmation stops the run before any write.
  That is not a completed reconcile: no fingerprint is recorded, and the re-invocation does the full work.
- **A `--dry-run`.** It writes nothing, including no fingerprint, and it never consumes one — a preview must
  still predict the real run's action set.
- **The token resolves from the environment.** The secret store is not consulted at all, once or otherwise, and
  the cache still holds for the run.
- **The token is missing entirely.** The failure is remembered for the run too, so the store is not re-consulted
  per request; the exit code, the message, and the degraded-run behaviour are today's.
- **A repository whose ignore rules predate this feature.** The fingerprint's location must be ignored before
  the first one is written; an operator who upgrades must never find it staged.

## Requirements *(mandatory)*

### Functional Requirements

**Instrumentation — measured, never assumed**

- **FR-001**: The bridge MUST provide an opt-in timing mode, activated by a single documented environment
  switch, disabled by default.
- **FR-002**: When enabled, the timing mode MUST report, for each of the phases prerequisite, state, configuration,
  parse, gate, recognition, plan, and apply, the elapsed wall time and the number of tracker requests issued in
  that phase, plus a run total for both. Two of those names are worth spelling out, because the pipeline has more
  than one thing a reader might call a gate: **state** is the short-circuit of FR-021, which runs before the
  configuration is read; **gate** is the mandatory-field gate, which runs after parsing and before recognition.
- **FR-003**: Timing output MUST go to the error stream only. With the mode on and off, the standard output
  bytes, the exit code, and every file the run writes MUST be identical — and the conformance corpus MUST be
  able to prove it.
- **FR-004**: Timing output MUST NOT contain the token, the derived authorisation value, or any credential
  material, and MUST NOT cause either to become traceable when command tracing is also enabled.
- **FR-005**: With the mode disabled, the run MUST emit no additional output on any channel.
- **FR-006**: The phase names, their order, and the shape of the timing lines MUST be identical between the two
  ports.

**The credential is resolved once per run**

- **FR-007**: The resolved token MUST be consulted from its source at most once per reconcile process,
  regardless of how many requests the run issues or how many of them are retried.
- **FR-008**: The cached value MUST live in a non-exported shell variable on the Bash port and a script-scoped
  variable on the PowerShell port. It MUST NEVER enter the environment of any child process, the PowerShell
  environment scope, or a PowerShell transcript.
- **FR-009**: Every function that reads or writes the cache MUST preserve the existing trace-suspension
  discipline of its port. The cached token and the derived authorisation value are both secrets and MUST be
  treated identically.
- **FR-010**: The cached value MUST NEVER be written to any file, temporary file, the fingerprint of FR-019, or
  the timing output of FR-002.
- **FR-011**: The resolution order MUST keep its shape on every operating system — environment, then the
  operating system's secret store, then the gitignored file. Only the frequency of consultation changes.
- **FR-012**: The cache MUST be per-run and MUST NEVER be persisted. A token rotated or revoked in the secret
  store MUST take effect on the very next reconcile; no cache may serve a token beyond the run that resolved it.
- **FR-013**: A failed resolution MUST also be remembered for the run, so that a run without a resolvable token
  consults its sources once and then fails with exactly today's exit code, message, and degraded behaviour.
- **FR-014**: The bridge MUST NOT introduce any new persistent store for credential material on any operating
  system.

**Recognition reads the estate in a bounded exchange**

- **FR-015**: Recognition MUST read the state of all recorded tickets in a number of requests bounded by a
  small constant plus one per fixed-size chunk of the key list — never one request per recorded ticket.
- **FR-016**: The mechanism used MUST be immediately consistent for a ticket created seconds earlier. A
  mechanism that depends on the tracker's search index MUST NOT be used, whatever its speed.
- **FR-017**: Every classification, warning, and fail-closed decision recognition produces MUST be identical to
  the one today's per-ticket read produces, for every case: bound, new, blocked, absent, not permitted, marker
  mismatch, duplicate marker, malformed marker, and inconclusive read. Where the batched mechanism cannot
  distinguish two outcomes, the ambiguous keys alone MUST be re-read individually rather than classified by
  assumption.
- **FR-018**: A key list exceeding the mechanism's limit MUST be chunked, and the outcome MUST be identical
  whatever the chunk boundaries fall between.

**The unchanged run does no work**

- **FR-019**: After a reconcile that completed fully successfully with nothing left pending, the bridge MUST
  record a fingerprint of the mirrored inputs in a gitignored, machine-owned location under `.specify/jira/`.
- **FR-020**: The fingerprint MUST cover the specification document, the tasks document when present, the
  effective configuration, the resolved routing decision, the recorded ticket keys, and every invocation option
  that changes which actions the run would take — everything whose change would alter what the run would do.
  The drift-handling mode is one such option: two runs over identical files, one told to abort on drift and one
  told to proceed, do not do the same work and MUST NOT share a fingerprint.
- **FR-021**: A subsequent run whose fingerprint matches MUST exit successfully having issued zero tracker
  requests and performed zero writes, and MUST say so in its run summary.
- **FR-022**: The comparison MUST fail open to a full reconcile on any doubt whatsoever: no fingerprint, an
  unreadable or malformed one, one written by a different version of the bridge, a previous run that was not
  fully successful, or any change to the inputs of FR-020.
- **FR-023**: A `--force` flag MUST bypass the fingerprint and reconcile in full.
- **FR-024**: The fingerprint MUST be written atomically, so that a concurrent run can never observe a partial
  one and can never skip work on the strength of one.
- **FR-025**: No fingerprint may be recorded by a preview run, a run that ended with a warning, a run that
  stopped at a pending confirmation, or any run that did not complete every planned action.
- **FR-026**: The fingerprint MUST NOT contain any credential, and the location it occupies MUST be covered by
  the repository's ignore rules before the first one is written.
- **FR-027**: The short-circuit MUST be evaluated after the dispatch guard and the target guard, so a disabled
  event and a rejected target behave exactly as they do today.
- **FR-028**: The documentation MUST state plainly that the fingerprint attests to local inputs only, that
  out-of-band tracker changes are therefore not detected while it matches, and that any local change or
  `--force` restores full reconciliation.

**Fewer connections, fewer processes**

- **FR-029**: Requests issued in sequence to the same host MUST reuse the transport connection where the
  transport permits it.
- **FR-030**: Writes with an ordering constraint MUST stay ordered. No concurrency may be applied across an
  ordering edge; correctness ordering always wins over parallelism.
- **FR-031**: No concurrency may be introduced anywhere on the reconcile path. Requests MUST be issued in a
  single deterministic order, so the run's output, its summary, and its observed call sequence remain identical
  between the two ports and between runs. Connection reuse is permitted precisely because it changes how
  requests travel, not the order in which they are issued or completed. Should a future change ever want
  concurrency, the determinism requirement above is the bar it has to clear first, and it needs its own spec.
- **FR-032**: Per-story and per-task loops on the reconcile path MUST NOT spawn one helper process per item per
  field. The observable behaviour of this consolidation MUST be byte-identical, provable by the existing
  conformance corpus.

**Windows gains the rung it lacks**

- **FR-033**: On Windows, the credential resolution order MUST become environment, then a registered secret
  vault, then the gitignored file — the same three-rung shape as macOS and Linux.
- **FR-034**: The secret MUST be named `spec-kit-jira`, matching the Keychain service name and the libsecret
  attribute, so the three operating-system sections of the documentation are symmetric.
- **FR-035**: The vault rung MUST be soft-optional. An absent module, an unregistered vault, a missing secret,
  and a locked vault MUST each fall through silently to the next rung — never an error, never a warning, never
  a prompt.
- **FR-036**: The vault rung MUST NOT block on an interactive prompt. Inside a lifecycle hook it MUST fall
  through within a bounded time rather than wait.
- **FR-037**: A value retrieved from the vault MUST follow the same secrecy discipline as FR-008 through
  FR-010, without exception.
- **FR-038**: The prerequisite check MUST NOT test for the vault module; its absence is never a prerequisite
  failure.
- **FR-039**: Existing Windows setups using the environment variable or the gitignored file MUST keep working
  unchanged. The new rung only adds an option between them.
- **FR-040**: The installation and configuration documentation MUST gain a Windows storage section covering
  module installation, vault registration, and storing the secret, and the existing statement that no OS
  secret-manager rung exists on Windows MUST be replaced.

**What may not change**

- **FR-041**: Every behavioural change MUST land in both ports, proven by the shared conformance corpus. A
  change with no observable difference may differ in mechanism between ports, never in outcome.
- **FR-042**: Every existing exit code, warning line, and degraded-run behaviour MUST be preserved exactly.
- **FR-043**: Every idempotency guarantee MUST be preserved exactly: markers, durable identifiers, duplicate
  blocking on a slug change, and label restoration behave as specified today.
- **FR-044**: `--dry-run` MUST continue to predict exactly the actions of the real run, including under the
  short-circuit.
- **FR-045**: A mirroring failure MUST still never fail the host command.
- **FR-046**: No new mandatory runtime dependency may be introduced. Concurrency, where used, MUST rely only on
  what is already guaranteed present.

### Key Entities

- **Run fingerprint**: the recorded evidence that a specific set of local inputs was mirrored to completion.
  Machine-owned, gitignored, atomic to write, versioned so a bridge upgrade invalidates it, and carrying no
  credential. It answers exactly one question — "are the inputs identical to the last fully successful run?" —
  and any answer other than a confident yes means doing the work. The design documents call this same artefact
  the **run-state document**, and the phase that evaluates it the **state phase**; "fingerprint", "run state",
  and "run-state document" all denote this entity and nothing else.
- **Phase timing record**: the elapsed time and request count of one named phase of one run. Lives only for the
  duration of the run, is emitted on the error stream when the mode is on, and is never persisted, never
  compared, and never allowed to carry credential material.
- **Per-run resolved credential**: the token held in memory for the lifetime of one process. It has no file, no
  environment entry, no transcript, and no successor: when the process ends it is gone, and the operating
  system's secret store remains the only place the bridge ever reads a persistent secret from.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Served, with one honest cost named. Nothing here deletes a ticket or adds an exception, and no overwrite decision is ever taken without drift detection preceding it — the short-circuit takes no decision at all, it declines to run. The cost is that while the fingerprint matches, a divergence introduced on the tracker side goes unnoticed. FR-028 documents it, FR-023 gives the operator the override, and any local edit ends it. This trade is stated in the feature request itself and is accepted deliberately, not by omission. |
| II | Zero-Churn Idempotency | Strengthened. The unchanged re-run already had to write nothing; FR-021 makes it also read nothing, which is the same guarantee held more cheaply. FR-043 keeps every identity mechanism untouched — nothing here keys on a summary, a title, or any operator-editable field. FR-016 refuses the one mechanism that would have reintroduced duplicate creation. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-042 preserves every exit code and warning verbatim; FR-017 and the recognition scenarios require an inconclusive batched read to fail the whole specification closed exactly as an inconclusive per-ticket read does today. FR-022 makes every fingerprint doubt resolve toward doing the work rather than skipping it. FR-045 keeps hooks non-blocking. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | The centre of gravity of this feature, and the one place where speed is explicitly refused as a justification. FR-008 through FR-014 spell out the cache's discipline: non-exported, never in a child environment, never transcribed, never traced, never written to any file including the fingerprint, never persisted, dead at process exit. FR-026 keeps the fingerprint credential-free. FR-033 through FR-037 extend the rung shape to Windows without loosening any of it. The principle's Windows wording was amended for exactly this — constitution v1.3.0, 2026-08-07 — and the amendment tightened rather than relaxed: it makes the rung's silent, non-prompting fall-through a requirement on all three platforms, which FR-035, FR-036, and FR-038 now restate rather than invent. |
| V | Separation of Team Config / Local Binding / Secrets | Respected. The fingerprint is machine-owned local state living beside the local binding, gitignored (FR-026), never committed, and never a place a secret goes. No new key enters the committable team config; the timing switch is an environment switch, not a configuration option. Nothing is placed inside the extension folder. |
| VI | macOS / Linux / Windows Portability | FR-041 requires both ports and conformance proof for every behavioural change. FR-006 and FR-031 exist because this feature touches the two areas that have diverged on Windows before — stream output and non-deterministic ordering. FR-033 through FR-040 close the standing Windows asymmetry rather than widening it. Any Windows-only divergence found here is diagnosed on the real runner, per the measurement-over-emulation rule. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. No status, transition, issue type, field, or hierarchy assumption is added or changed. The batched read requests the same fields the per-ticket read requests today. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Respected and load-bearing here. The batched read and the connection reuse are sink concerns and stay in the sink; the fingerprint and the timing phases are command-layer concerns and carry no tracker knowledge — the fingerprint covers local inputs, never tracker state. No engine module gains a sink import, and no engine module gains a tracker identifier. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected in kind, and its ordering is preserved: the guard still runs over every payload before any write. A short-circuited run performs no write and therefore reaches no guard decision, which is the correct behaviour for a run that sends nothing. |
| X | Self-Healing Automatic Mirror | Preserved in mechanism, bounded in reach, and this is the second cost stated plainly. Hook health checking, idempotent registration, and respect for a disabled hook are untouched. But a mirror that skips a run cannot heal a ticket damaged since the last one; healing resumes on the next local change or on `--force`. A time-bounded fingerprint was considered as a way to keep healing on a longer horizon and is recorded as a rejected alternative rather than silently dropped. |
| XI | Universal Dry-Run and Auditability | FR-044 keeps the preview exact, including its interaction with the short-circuit: a preview neither writes a fingerprint nor consumes one. FR-021 requires the short-circuit to appear in the run summary rather than resembling a run that did nothing for unclear reasons. FR-002's timing report is auditability of a second kind. No destructive operation is added. |
| XII | Quality and Catalog Publication | A performance change to shipped behaviour, carrying a CHANGELOG entry, gated by the full suite, the conformance corpus, and the linters on all three operating systems, and dogfooded against the real instance whose measurements motivated it — the dogfood is the acceptance evidence for the timing goals, not a formality. |
| XIII | TDD With a Minimum 80% Coverage | Every user story states an independent test, and the ones that matter most are counting tests rather than timing tests: the secret store is invoked once, the read phase issues a bounded number of requests, the unchanged run issues zero. These are deterministic against a mocked tracker and are written before the change. Credential resolution is a named near-100% critical path and stays one. The instrumentation of User Story 1 is built first so the later stories have something to assert against. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Each change is the smallest one that removes its cost: one variable for the credential, one file for the fingerprint, one existing transport mechanism for connection reuse, fewer helper processes rather than a new helper. No abstraction layer, no framework, no dependency. Where the simple mechanism the request named would have cost correctness — the search-index read — the simpler-still answer is chosen: do not batch that way. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every artefact is demanded by a requirement above and exercised by a test: the timing switch by FR-001, the `--force` flag by FR-023, the fingerprint by FR-019, the Windows rung by FR-033. A generic retrieval-command rung, a cross-run response cache, a fingerprint expiry, and a configurable concurrency degree are all named out of scope and none is built as a dead branch. |
| XVI | Human Readable — Readable by a Human Above All | The timing report is prose a human reads in a terminal — a named phase, a duration, a count — not a machine format the operator must decode. The short-circuit says in the summary that it short-circuited and why, rather than presenting a suspiciously empty run. The Windows documentation section is written so an operator can follow it once and never return to it. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reconcile with nothing changed since the last successful run completes in under 1 second and
  issues zero requests to the tracker. Measured on the Bash port, macOS, warm run.
- **SC-002**: A reconcile of a typical specification — one parent, up to 10 stories, up to 50 tasks — with
  changes to mirror completes in under 30 seconds, against the 3-to-7 minutes measured today. Measured under
  SC-001's conditions — Bash port, macOS, warm run — against the same live instance the 3-to-7-minute figure
  came from, so the before and after numbers are comparable.
- **SC-003**: For a run with changes, the number of tracker requests is bounded by the number of writes plus a
  small constant for reads, and never grows one-for-one with the number of recorded tickets.
- **SC-004**: The operating system's secret store is consulted at most once per reconcile process, whatever the
  number of requests and retries — asserted by a counting stand-in, not by timing.
- **SC-005**: A maintainer can attribute a slow run to a single phase from one command invocation, using only
  the timing mode and no other tool. Concretely: the reported phase durations account for at least 90% of the
  run's total wall time, so no meaningful cost hides between the phases, and the report names the phase that
  dominates.
- **SC-006**: With the timing mode enabled, the standard output bytes, the exit code, and every written file
  are identical to the same run with it disabled, on both ports.
- **SC-007**: The credential guarantee is identical on macOS, Linux, and Windows: on each, an encrypted
  operating-system store is the recommended persistent home of the token, resolution happens at run time, and
  the token appears on no channel the coding agent can observe.
- **SC-008**: No token, and no value derived from one, appears in any process argument list, standard stream,
  log, trace, transcript, child-process environment, or file — asserted at maximum verbosity on both ports.
- **SC-009**: Every exit code, warning line, and classification the bridge produces today is produced
  identically after this change, proven by the existing suites and the conformance corpus running unmodified
  where behaviour is unchanged.
- **SC-010**: On a repository upgrading to this version, the fingerprint's location is ignored by version
  control before the first fingerprint is written; no operator finds it staged.
- **SC-011**: An operator on Windows can store the token in an encrypted vault and reconcile successfully, and
  an operator on Windows who does nothing at all sees no change in behaviour and no new message.

## Assumptions

- **A-1**: The tracker offers a key-addressed bulk read that is immediately consistent for a ticket created
  seconds earlier — the same consistency property the per-ticket read has today. This is load-bearing for
  FR-015 and MUST be confirmed against the live instance during implementation. If it does not hold,
  recognition stays per-key and takes its speed from FR-029's connection reuse; SC-003 is then met by the write
  path and the short-circuit alone, and the shortfall is recorded rather than worked around.
- **A-2**: The fingerprint's inputs, as listed in FR-020, are complete — that is, nothing outside the
  specification document, the tasks document, the effective configuration, the routing decision, the recorded
  keys, and the action-changing invocation options can change what a run would do. Any input discovered to be
  missing from that list is a defect in the fingerprint, not a tolerable gap, because it produces a wrongful
  skip. This assumption is **not** discharged by inspection: the reconcile command accepts several options
  beyond the drift-handling mode, and each MUST be examined for whether it changes the action set before the
  first fingerprint is composed.
- **A-3**: The 3-to-7-minute figure, the per-request credential resolution, the per-request connection, and the
  helper-process counts in the request's research notes are hypotheses. FR-001's instrumentation confirms or
  refutes each before the corresponding optimisation is justified; an optimisation whose cost the instrument
  does not find is not built.
- **A-4**: "Fully successful with nothing left pending" means every planned action was applied, no warning was
  emitted, no confirmation is outstanding, and the run was not a preview. Anything less records no fingerprint.
- **A-5**: A run's phases are the eight named in FR-002. Sub-phases may exist internally but do not appear in
  the report, which is sized for a human reading one screen. `state` earns a phase of its own rather than
  folding into `prereq` because a short-circuited run reaches only those two, and SC-005 — attribute a slow run
  to a single phase — would otherwise be unserved on the one path SC-001 is written about.
- **A-6**: ~~Principle IV's Windows parenthetical receives an amendment before FR-033 is implemented.~~
  **RESOLVED 2026-08-07 — constitution v1.3.0.** The second credential rung is now defined by its requirement
  rather than by three product names, with PowerShell SecretManagement named as the Windows mechanism, and the
  rung is declared soft-optional on every platform. FR-033 through FR-040 are unblocked. The amendment carries
  a consequence this feature absorbs: its enforcement test demands, on **every** platform, a test proving each
  unavailability path falls through silently and without prompting. The existing Bash suite
  (`tests/bash/lib/test_credentials.bats`) proves the empty-source fall-through but not the tool-absent or
  tool-failing paths, so those tests are new work on the macOS and Linux rungs as well as the Windows one.
- **A-7**: The timing switch is an environment variable and not a flag, so it can be set once for a whole
  session of lifecycle hooks, which are invoked by the host and not by the operator.
- **A-8**: ~~Concurrency, where FR-031 permits it, uses facilities already guaranteed present on each port.~~
  **REVISED during analysis.** FR-031 is a prohibition, not a permission: research R6 rejected every
  concurrency mechanism available to either port — `curl --parallel` and `xargs -P` both reorder completions,
  which would make `calls.log` non-deterministic and break the corpus's cross-port diff. The speed this feature
  needs comes from doing less work (FR-021), from doing it in fewer exchanges (FR-015), and from reusing the
  connection (FR-029) — never from doing several things at once.

## Out of Scope

- Rewriting either port in another language.
- Changing the tracker data model, the marker format, or the label scheme.
- A generic user-declared retrieval-command rung for arbitrary secret managers. It is a credential feature in
  its own right; FR-033 deliberately limits itself to restoring three-operating-system symmetry.
- Removing the gitignored file rung. Headless and CI hosts need it; it remains documented as the least
  preferred rung on every operating system.
- Test-suite and CI performance, which is a separate feature.
- Caching tracker state across runs. Only the single-run local fingerprint of FR-019 is in scope; a cross-run
  response cache trades staleness for speed in a way this feature refuses.
- A time-bounded or expiring fingerprint. Considered as a way to keep Principle X's self-healing on a longer
  horizon while still collapsing a burst of lifecycle hooks, and rejected here for the simplicity of a single
  rule: the fingerprint matches or it does not. It is the natural follow-up if out-of-band drift proves to bite
  in practice.
- A configurable concurrency degree, a configurable chunk size, and a configurable fingerprint location. All
  three are internal choices, not operator decisions.
- Repairing or migrating any state written before this feature ships. The first run after the upgrade finds no
  fingerprint and reconciles in full, which is the correct behaviour and needs no migration.
