# Feature Specification: The Time Reconcile Spends Is Its Own, and the Instrument That Says So Works Everywhere

**Feature Branch**: `worktree-fix+optimize-code`

**Created**: 2026-08-10

**Status**: Draft

**Input**: User description: "Make reconcile's local processing fast, and its timing instrumentation reliable on any
locale." — with a profile taken on a real consuming repository (macOS M1 Max, timing mode on, forced run):
3–6 minutes total wall time against `requests: 0ms`; four phases at ~80 seconds each (config 84s, gate 79s,
plan 83s, apply 82s), parse 20s, recognition under 1s; 75s user + 109s system CPU at 50–70% utilisation;
run-to-run variance of 3:14 against 5:50 on identical input. Plus a crash of the timing instrument itself on a
French-locale host, with success criteria for both halves and an explicit out-of-scope list.

## Why this is a defect and not a wish

Feature 021 asked where a slow reconcile spent its time, and built the instrument that answers. The answer has
now arrived, and it is not the one 021 expected.

A three-to-six-minute reconcile of a specification a human reads in a minute is a defect on its own terms,
whatever the mechanism turns out to be. Seventy-five seconds of user time and a hundred and nine seconds of
system time, against three to six minutes of wall clock, is the signature of a program spending most of its
life inside the kernel rather than computing — a program whose cost is in the calls it makes, not in the work
it does. Which calls, this specification first got wrong; see below.

Three facts make this a defect rather than an optimisation opportunity:

- **The cost is invisible to the operator and unbounded in their input.** Six lifecycle events fire the same
  reconcile. A working session pays three to six minutes, repeatedly, for a command that reports success. And
  the cost grows with the size of the specification the operator writes, so the better they document, the worse
  the tool behaves.
- **The variance is worse than the mean.** 3:14 against 5:50 on byte-identical input is a 79% spread. A tool
  whose duration is unpredictable cannot be reasoned about, and a performance regression cannot be detected
  against a baseline that wide.
- **The configuration phase costs 84 seconds to read files that did not change during the run.** Whatever the
  right number is for parsing a handful of YAML documents once, it is not eighty-four seconds. That phase is
  re-reading and re-parsing, and every later phase that asks a configuration question pays the parse again.

### The mechanism, corrected by measurement

**This specification first attributed the cost to process creation, and that was wrong.** The correction is
recorded rather than quietly overwritten, because the reasoning that produced the error is reasoning a reader
would otherwise repeat.

The motivating profile reported `requests: 0ms` on every phase. That reading came from a **defective counter** —
the defect FR-036 now describes, which reported zero against 123 requests actually issued. Read as "the network
has left the profile, so every second is local CPU", and combined with a system-time-heavy signature, it
pointed at forking: *nothing is slow, everything is forked*. The spawn count was then measured — 20 243 `jq`
invocations for 61 items — and the attribution looked confirmed.

It was not. Measured directly on the machine that motivated this feature:

| | |
| --- | ---: |
| One bare process spawn (`jq -n '1'`, no redirection) | **1.1 ms** |
| The same spawn with a one-byte here-string attached (`<<< "x"`) | **6.1 ms** |
| The same, with a 50 KB payload | 8.6 ms |
| Cutting the run's spawn count by 38% (1 350 → 836) | **−4.5% wall time** |
| Removing **one** duplicated read of `config.local.yml` | **−91% on that phase** |

A bare spawn on that host costs 1.1 ms, not the 9–18 ms the profile's arithmetic implied. Attaching a
here-string multiplies it by five and a half, and the payload's size barely matters after that. The cost tracks
**file operations**, not `exec`. A syscall-heavy profile looks identical under both hypotheses, which is why the
first reading was plausible and why only a direct measurement could separate them.

So the defect keeps its shape and loses its mechanism: **the run re-reads and re-parses what it has already
read, and on the machine that matters each of those reads is expensive.** The third bullet above stated this
correctly from the start; the paragraph that used to sit above it did not. Per-item forking is real too, worth
removing, and bounded by FR-016 through FR-019 below — but it is the second-order cost, not the first.

And underneath both of those sits a smaller defect with an outsized consequence.

**The instrument crashes on most of Europe — and when it does not crash, it lies.** The Bash port's clock
reads `EPOCHREALTIME` and splits it on a dot to separate seconds from microseconds. On a host whose numeric
locale uses a comma — French, German, Spanish, Italian, Portuguese, Dutch, Polish, Russian, and every Latin
American locale — the shell renders that variable as `1786381617,093486`. The split finds no dot, so both
halves come away holding the entire string, comma and all.

What happens next was reproduced on this machine and is worse than the reported crash, because the crash is
the *visible* half of it. The shell's arithmetic evaluator treats the comma as an operator: it evaluates the
seconds, discards them, and keeps only the digits after the comma as the value of the whole expression.

- When those digits begin with a zero — `,093486` — they are read as an octal literal, and `8` and `9` are
  not octal digits. That is the reported crash, *valeur trop grande pour la base*.
- When they begin with any other digit — `,226619` — there is no error at all. The instrument reports a
  duration computed from the microseconds alone, with the seconds thrown away, and prints it with the same
  confidence as a correct one.

So the defect fires loudly about one time in ten and silently the other nine. Any fix, and any test of that
fix, has to be written against correctness of the reported duration rather than against the absence of an
error message — a test that merely asserts the run did not crash passes against the broken code most of the
time. The operator who most needs to measure a slow run is the one who cannot, and may not know it.

That ordering is why this specification measures first. Every performance number below is produced by the
instrument, so an instrument that fails on the measuring host makes every success criterion unverifiable there.
The locale fix is not a courtesy to European operators; it is the precondition for accepting this feature at
all.

## Two boundaries this feature does not cross

Both are named here so planning starts from them rather than rediscovering them.

**The network is not the problem, so the network does not change.** Feature 021's bulk fetch, its connection
reuse, its once-per-run credential, and its request ordering all measured well and stay exactly as they are.
This specification changes what happens between requests, never the requests themselves. A change that alters
a single Jira payload, request, or ordering is out of scope by construction, and the conformance corpus is the
proof.

**Speed is never bought with behaviour.** The corpus, the bats suite, and the Pester suite pass unmodified.
An unchanged re-run still writes nothing. Recognition still classifies every ticket the way it does today, and
every idempotency guarantee 005, 017, and 019 established stays intact. This is a change of mechanism with a
null observable diff — which is exactly the shape of change that breaks things quietly, so the requirements
below spend as much text on what must not move as on what must get faster.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The instrument works on the operator's own machine, whatever language it speaks (Priority: P1)

An operator on a French-locale macOS laptop — the machine the profile above came from — turns the timing mode
on and runs reconcile. They get the same per-phase report their English-locale colleague gets: the same phase
names, the same shape, durations that are correct rather than absent. Nothing about the reconcile itself
behaves differently, and nothing about their locale is special-cased anywhere.

**Why this priority**: Every other story in this specification is verified by reading this report. An
instrument that fails on the host doing the measuring makes the remaining success criteria unfalsifiable
there. It is also the only story that is a live crash today rather than a slowness.

**Independent Test**: Run the same fixture under `LC_ALL=C`, `LC_ALL=fr_FR.UTF-8`, and `LC_ALL=de_DE.UTF-8`
with the timing mode on. Assert the reported durations are correct and the report's shape is byte-identical
across all three, that no error text appears on any channel, and that the exit code and every written file
match the run with timing off. Delivers value alone: European operators regain the diagnostic even if nothing
else here ships.

**Acceptance Scenarios**:

1. **Given** a host whose numeric locale uses a comma decimal separator, **When** reconcile runs with the
   timing mode on, **Then** the per-phase report is produced with correct durations and no error appears on
   any channel.
2. **Given** a comma-locale host and a clock reading whose fractional part does not trigger an error, **When**
   a phase is measured, **Then** its reported duration is the true elapsed time — a report that is merely
   error-free is not evidence of a fix, because the pre-change code is error-free for most readings while
   reporting a duration computed from the discarded seconds.
3. **Given** any host locale whatsoever, **When** the clock is read, **Then** the reading is interpreted
   without reference to which character the locale uses as a decimal separator — the handling is correct by
   construction, not by recognising a list of known separators.
4. **Given** a clock reading that cannot be interpreted at all, **When** the timing mode is on, **Then** the
   run's outcome, exit code, standard output, and written files are exactly those of the same run with timing
   off; the instrument degrades in silence rather than failing the run it is measuring.
5. **Given** any failure inside the timing instrument at any point of the run, **When** the run completes,
   **Then** the reconcile's own result is unaffected — timing is observability, and observability never
   decides an outcome.
6. **Given** the three locales above, **When** the same fixture is reconciled with a fixed injected clock,
   **Then** the timing report is byte-identical across all three.
7. **Given** a host with no sub-second clock, **When** the timing mode is on, **Then** today's whole-second
   degraded behaviour and its notice are unchanged.

---

### User Story 2 - Configuration is read once, and every phase after that is free (Priority: P1)

A reconcile reads the team configuration and the local binding, parses them, resolves the effective
configuration for this run, and then never touches those files again. The mandatory-field gate, the planner,
and the apply phase each ask the resolved result whatever they need to know, and each answer costs nothing.

**Why this priority**: The configuration phase alone is 84 seconds of the profile, and the same parsing cost
is embedded in the three other 80-second phases, which spend their time asking configuration questions. It is
the single largest attributable cost in the profile and the one whose fix is the most contained.

**Independent Test**: With an instrumented stand-in that counts how many times each configuration source is
opened and how many times it is parsed, run a full reconcile of the reference specification. Assert each
source is read at most once and parsed at most once, regardless of how many stories, tasks, and configuration
questions the run involves. Assert the resolved answers are identical to today's for every key, including
absent keys, defaulted keys, and keys that produce a validation error.

**Acceptance Scenarios**:

1. **Given** a reconcile of any specification, **When** it completes, **Then** each configuration source has
   been opened at most once and parsed at most once for the whole run.
2. **Given** a phase after the configuration phase, **When** it needs a configuration answer, **Then** it
   obtains it from the already-resolved result without re-reading or re-parsing any file.
3. **Given** a malformed, unreadable, or absent configuration source, **When** the run reaches it, **Then**
   the error, the warning, the exit code, and the point in the run at which they occur are exactly today's —
   caching a failure must not convert a fatal into a silent success, nor a single diagnostic into a repeated
   one.
4. **Given** the run itself writes to a configuration source it owns, **When** a later phase asks a question
   whose answer that write changed, **Then** it receives the post-write answer.
5. **Given** a configuration source edited on disk by something else while the run is in flight, **When**
   later phases run, **Then** they use the snapshot taken at first read; the run is internally consistent and
   this is stated in the documentation rather than left to chance.
6. **Given** the full conformance corpus, **When** it runs after this change, **Then** every output is
   byte-identical to before it.

---

### User Story 3 - The per-item loops stop forking (Priority: P1)

A specification with a parent, ten stories, and fifty tasks is reconciled. The gate, the plan, and the apply
phases walk those sixty-one items and spawn no external process per item — and none per field of an item. The
work they do is the same work; it simply happens inside the process that is already running.

**Why this priority**: Three phases at roughly eighty seconds each, on a machine at half utilisation with more
system time than user time, is process creation and nothing else. It is the largest remaining cost after the
configuration phase, and it is the one that scales with the operator's input, which makes it the one that gets
worse over time.

**Independent Test**: With a counting wrapper interposed on external process creation, reconcile the reference
specification and record the total. Assert the count is bounded by a small constant per phase plus one per
Jira request, and that doubling the number of stories and tasks leaves that count unchanged. Assert the
recorded call sequence and every written byte are identical to the pre-change run.

**Acceptance Scenarios**:

1. **Given** a specification with N stories and M tasks, **When** it is reconciled, **Then** the number of
   external processes the run spawns does not grow with N or M.
2. **Given** the same specification reconciled before and after this change, **When** the outputs are
   compared, **Then** the standard output, the error stream, the exit code, every written file, and the
   recorded Jira call sequence are byte-identical.
3. **Given** a per-item transformation that genuinely requires an external tool, **When** it is applied to
   many items, **Then** the tool is invoked a bounded number of times for the whole set rather than once per
   item.
4. **Given** a specification with zero stories and zero tasks, **When** it is reconciled, **Then** the process
   count equals the same phase floor as the sixty-one-item case.
5. **Given** the Windows host, **When** the consolidated paths run, **Then** line endings, encoding, and every
   byte of output are what the conformance corpus expects — no consolidation may reintroduce a platform
   divergence.

---

### User Story 4 - The hook feels instantaneous, and feels the same every time (Priority: P2)

A developer runs a lifecycle command over a typical specification they have just changed. The mirror does its
local work in a few seconds rather than a few minutes, and it takes about the same few seconds every time.
The developer stops noticing the bridge, which is the point of a bridge.

**Why this priority**: It is the outcome the operator actually experiences, and the aggregate that the three
stories above are means to. It ranks below them because it is measured rather than built: no code exists for
this story that is not already required by Stories 1 through 3.

**Independent Test**: With the timing mode on, reconcile the reference specification — one parent, ten
stories, fifty tasks — five times on the same hardware class, with a stand-in tracker so that request time is
excluded. Assert the sum of the non-request phases is under 20 seconds every time, that no individual phase
exceeds 5 seconds, and that the spread between the fastest and slowest run is within 20% of the median.

**Acceptance Scenarios**:

1. **Given** the reference specification with changes to mirror, **When** it is reconciled, **Then** the total
   of all phases excluding request time is under 20 seconds.
2. **Given** the same run, **When** the per-phase report is read, **Then** no single phase exceeds 5 seconds.
3. **Given** five consecutive runs over byte-identical input, **When** their wall clocks are compared, **Then**
   the spread between fastest and slowest is within 20% of the median.
4. **Given** a specification reconciled successfully with nothing changed since, **When** reconcile runs again,
   **Then** feature 021's short-circuit still applies unchanged: zero requests, zero writes, and a run that
   ends in well under a second.
5. **Given** a specification several times larger than the reference, **When** it is reconciled, **Then** the
   local processing time grows sub-linearly with the item count rather than proportionally to process
   creation.

---

### User Story 5 - The two ports stay the same program (Priority: P3)

The PowerShell port is measured on the same reference specification. Wherever it shares the per-item external
invocation pattern that costs the Bash port its eighty seconds, it receives the same consolidation. Wherever
it does not, it is left alone. Both ports remain module-for-module equivalent and byte-identical in output.

**Why this priority**: Portability is constitutional and non-negotiable, but this feature's measured defect is
a Bash-port profile, and the locale crash is specific to a Bash shell variable. Applying a fix the PowerShell
port does not need would be churn on the port that is harder to test. It ranks last because it is conditional
on a measurement rather than on a known cost.

**Independent Test**: Profile the PowerShell port on the reference specification and record its per-phase
timings. For each phase whose cost is dominated by per-item external invocation, apply the consolidation and
re-measure. Assert the Pester suite and the conformance corpus pass unmodified throughout, and that the module
map of the two ports still corresponds one-to-one.

**Acceptance Scenarios**:

1. **Given** the reference specification, **When** the PowerShell port reconciles it with timing on, **Then**
   a per-phase profile is produced and recorded alongside the Bash one.
2. **Given** a PowerShell phase that spawns an external process per story, per task, or per configuration
   line, **When** this feature is complete, **Then** it no longer does.
3. **Given** a PowerShell phase whose cost has no per-item external invocation, **When** this feature is
   complete, **Then** it is unchanged.
4. **Given** both ports after this change, **When** the conformance corpus runs, **Then** every scenario is
   byte-identical between them.
5. **Given** the module maps of the two ports, **When** they are compared after this change, **Then** they
   still correspond one-to-one; no consolidation may exist on one port as a module the other lacks.

---

### Edge Cases

- **A locale whose separator is neither dot nor comma, or which groups digits.** The requirement is
  locale-independence by construction, so an unfamiliar separator is not a new case to handle — a solution
  that would need extending for one has already failed Story 1 scenario 2.
- **The locale changes between two phases of one run.** A run that alters its own numeric environment must
  still produce a coherent report; each reading is interpreted on its own terms and the total remains the sum
  of the phases.
- **The clock is absent, or a reading is garbage.** The instrument reports what it can and stays silent about
  what it cannot, and the reconcile's outcome does not move. This is the fail-open rule, and it holds for
  every failure mode of the instrument, not only the parsing ones.
- **A configuration source that does not exist.** Reading it once means failing to find it once. The absence
  must produce today's behaviour, not a repeated warning collapsed into one, nor one collapsed into none.
- **A configuration source the run writes during the run.** The hooks-disabled toggle is the known case. A
  stale snapshot here would make a later phase act on a superseded answer, so the write path and the snapshot
  are one mechanism, not two.
- **A specification with one story and no tasks, and one with hundreds of tasks.** Both must land inside the
  same process-count bound; a bound that holds only at the reference size is not a bound.
- **An item whose content genuinely needs an external tool — a rich description, a structured payload.** The
  tool is still available; it is invoked once for the batch rather than once per item, and its output must
  survive being batched without a byte changing.
- **A run under `--dry-run`, and a run stopped by the mandatory-field gate.** Both are shortened runs. Their
  process counts must be no worse than the full run's, and their outputs must not move.
- **A run whose fingerprint matches.** It reaches only the first two phases and does no configuration work at
  all. The once-per-run parse must not pull configuration reading earlier than feature 021 placed it, or the
  short-circuit stops being free.
- **The timing mode and command tracing on at once.** Feature 021's guarantee stands: no credential becomes
  traceable, and the phases with trace suspension keep it.
- **Windows.** Every consolidated path is a new opportunity for a line-ending or encoding divergence, and the
  established rule applies without exception — a Windows-only difference is diagnosed by measurement on the
  real runner, never by emulation.

## Requirements *(mandatory)*

### Functional Requirements

**The instrument is correct everywhere, and harmless when it is not**

- **FR-001**: The timing instrument MUST produce a correct per-phase report regardless of the host's numeric
  locale.
- **FR-002**: The instrument's interpretation of a clock reading MUST NOT depend on identifying the host's
  decimal separator. A solution that enumerates known separators does not satisfy this requirement, whatever
  the length of the list.
- **FR-003**: Any failure inside the timing instrument — an unreadable clock, an uninterpretable reading, an
  arithmetic failure, or any other — MUST leave the reconcile's outcome, exit code, standard output, and every
  written file exactly as they would be with the timing mode off. The instrument never fails the run it
  measures.
- **FR-004**: A timing failure MUST NOT emit diagnostic noise that would break the conformance corpus's
  byte-comparison of the error stream. The instrument degrades quietly.
- **FR-005**: The regression suite MUST cover a comma-decimal locale explicitly, and MUST verify the report
  under at least the neutral locale, a French locale, and a German locale. Each such test MUST assert the
  **correctness of the reported duration** against a known elapsed time, not merely the absence of an error:
  the pre-change behaviour is error-free for the majority of clock readings while reporting a duration derived
  from the fractional part alone, so an error-absence assertion does not fail against the defect and is not a
  regression test for it.
- **FR-006**: Under a fixed injected clock, the timing report MUST be byte-identical across every locale
  tested.
- **FR-007**: Feature 021's timing guarantees MUST be preserved without exception: the report goes to the
  error stream only, the phase names and their order are unchanged and identical between the ports, no
  credential material appears in it, and with the mode off the run emits nothing additional on any channel.
- **FR-008**: The whole-second degraded mode on a host with no sub-second clock MUST keep today's behaviour
  and today's notice.

**The instrument's request count is truthful**

*(FR-036 and FR-037 are numbered out of sequence: they were added by amendment after planning measured the
defect they describe. They belong to the instrument group above and are read with it.)*

- **FR-036**: Every tracker request a run issues MUST be counted exactly once — retries included — by a
  counter whose scope is the reconcile process, not whichever shell happens to issue the request. A phase's
  reported request count MUST equal the number of requests issued between its begin and end marks. Today
  every phase reports zero against a run that issues 123 requests, which makes "the total of all phases
  excluding request time" — the quantity SC-005 and FR-023 are written about — a quantity that does not
  exist.
- **FR-037**: A failure to count MUST NOT change a request, a payload, an ordering, or an outcome. The
  counter is observability, and observability never decides an outcome — the same fail-open discipline
  FR-003 places on the clock.

**Configuration is read once per run**

- **FR-009**: Every configuration source a run consults MUST be opened at most once and parsed at most once
  for the lifetime of that run, regardless of how many questions later phases ask of it. **"Source" means a
  distinct file path, not a logical configuration layer**: two phases reading different keys of the same file
  are two reads of one source, and MUST be satisfied by one parse. This clause is not a refinement but a
  correction — the looser reading is what allowed a run that reads `config.local.yml` twice, once for its
  `overrides` and once for its `resolved_ids`, to be recorded as satisfying this requirement.
- **FR-010**: Every phase after the configuration phase MUST obtain configuration answers from the resolved
  result of that single parse, and MUST NOT re-read or re-parse any configuration source.
- **FR-011**: The resolved answer for every key MUST be identical to today's, including absent keys, defaulted
  keys, keys resolved through the team-config-then-local-binding precedence, and keys that produce a
  validation error.
- **FR-012**: A configuration error, warning, or exit MUST occur at the same point in the run, with the same
  text and the same exit code, as it does today. Reading once MUST NOT collapse a repeated diagnostic that is
  emitted once today, nor suppress one that is emitted today.
- **FR-013**: When the run itself writes to a configuration source, the resolved result MUST reflect that
  write for every subsequent phase.
- **FR-014**: The resolved result MUST NOT be persisted beyond the process, MUST NOT be written to any file,
  and MUST NOT contain credential material.
- **FR-015**: The point in the run at which configuration is first read MUST NOT move earlier. Feature 021's
  short-circuit MUST continue to complete without reading configuration at all.

**The run stops spawning a process per item**

- **FR-016**: The number of external processes a run spawns MUST NOT grow with the number of stories, the
  number of tasks, or the number of configuration lines.
- **FR-017**: The number of external processes a run spawns MUST be bounded by a small constant per phase plus
  one per Jira request issued.
- **FR-018**: No loop on the reconcile path may spawn an external process per item, and none may spawn one per
  field of an item.
- **FR-019**: Where a transformation genuinely requires an external tool, that tool MUST be invoked a bounded
  number of times for the whole set of items rather than once per item, and its batched output MUST be
  byte-identical to the concatenation of its per-item outputs today.
- **FR-020**: The consolidation MUST preserve the existing platform disciplines exactly: the Bash port's
  structured-output handling MUST continue to go through the port's output module rather than calling the
  external JSON tool directly, and every path handed to the transport MUST keep its existing Windows path
  spelling.
- **FR-021**: The recorded Jira call sequence — the requests issued, their order, and their payloads — MUST be
  byte-identical to today's for every scenario in the conformance corpus.
- **FR-022**: No concurrency may be introduced anywhere on the reconcile path. Feature 021's determinism
  requirement stands: requests are issued in one deterministic order, and the run's output is identical
  between the two ports and between repeated runs.

**The run does not re-read what it has already read**

*(FR-038 through FR-040 are numbered out of sequence: they were added by amendment after implementation
measured the cost mechanism this specification had originally mis-attributed. They belong beside FR-016
through FR-022 above — both groups bound a per-operation cost — and are read with them.)*

- **FR-038**: No file may be opened and parsed more than once in a run for content already parsed in that same
  run. Where two phases need different parts of the same file, they MUST share a single read rather than each
  performing their own. FR-009 is this requirement's configuration-specific instance and is not weakened by it.
- **FR-039**: The number of file reads a run performs MUST NOT grow with the number of stories, the number of
  tasks, or the number of configuration lines — the same bound FR-016 places on process creation.
- **FR-040**: File reads MUST be countable by a deterministic counting stand-in, on the same terms as FR-016's
  process count, so that a re-read regression is caught by a test rather than by a wall-clock measurement on
  one operator's machine.

> **Why this group exists.** On the machine that motivated this feature, one full read-and-parse of
> `config.local.yml` costs **~33 s**, against **1.1 ms** for a bare process spawn on the same host — a ratio
> of roughly 30 000 to 1. Two phases were each performing one such read of the same file. This is the
> first-order cost; FR-016 through FR-022's process budget is the second. See "The mechanism, corrected by
> measurement" above, and research R3a.

**The run is fast, and predictably so**

- **FR-023**: On the reference specification — one parent, ten stories, fifty tasks — the sum of all phase
  durations excluding request time MUST be under 20 seconds.
- **FR-024**: On the reference specification, no single phase MUST exceed 5 seconds.
- **FR-025**: Over repeated runs on byte-identical input and identical hardware, the spread between the
  fastest and the slowest run MUST be within 20% of the median.
- **FR-026**: Local processing time MUST grow sub-linearly with the number of stories and tasks, so that a
  specification several times larger than the reference remains usable.
- **FR-027**: The performance figures above MUST be measured with the timing mode of FR-001, on the same
  hardware class as the profile that motivated this feature, and recorded so that a future regression is
  detectable against them.

**What may not change**

- **FR-028**: No Jira request, request pattern, payload, header, or ordering may change. Feature 021's
  bulk-fetch batching, connection reuse, and once-per-run credential resolution are kept exactly as they are.
- **FR-029**: The recognition contract MUST be unchanged: every classification, warning, and fail-closed
  decision is the one produced today, for every case.
- **FR-030**: Every idempotency guarantee MUST be preserved exactly — markers, durable identifiers, duplicate
  blocking on a slug change, managed-region splicing, and label restoration behave as specified today.
- **FR-031**: An unchanged re-run MUST still write nothing, and feature 021's short-circuit MUST behave
  exactly as it does today.
- **FR-032**: The full conformance corpus, the complete Bash suite, and the complete PowerShell suite MUST
  pass unmodified, except for tests newly added by this feature and for the single expectation that encoded
  the FR-036 defect. Correcting that one is demanded by a requirement rather than accommodating a behaviour
  change, and its corrected values MUST be derived from the harness's request log rather than from the
  changed implementation's output — a test rewritten to agree with fresh code encodes a new bug in place of
  the old one. A **second** changed expectation is evidence that this feature has exceeded its scope, and
  stops the work.
- **FR-033**: Both ports MUST remain module-for-module equivalent. A consolidation may exist as a different
  mechanism on each port; it may not exist as a module on one port and nowhere on the other.
- **FR-034**: Every existing exit code, warning line, and degraded-run behaviour MUST be preserved exactly, and
  a mirroring failure MUST still never fail the host command.
- **FR-035**: No new mandatory runtime dependency may be introduced on either port.

### Key Entities

- **Clock reading**: one observation of the host's wall clock, taken at a phase boundary. It has a whole part
  and a fractional part, and the way those two parts are separated in text is a property of the host, not of
  the reading. Its only consumer is the difference between two of them.
- **Resolved configuration**: the single in-memory answer to every configuration question this run will ask,
  produced once from the team configuration and the local binding and consulted thereafter. It lives for the
  process, is never written anywhere, holds no credential, and is updated when the run itself writes to a
  source it owns.
- **Phase process budget**: the number of external processes one phase is permitted to spawn. It is a property
  of the phase, never of the specification being mirrored — the operator's document size may change what the
  run does, never how many times it forks to do it.
- **File read budget**: the number of times one run opens and parses a given file path. Like the phase process
  budget it is a property of the code rather than of the document being mirrored. Unlike it, its unit cost is
  set almost entirely by what the host's security software does on each open — on the motivating machine, some
  30 000 times the cost of a process spawn — which is why it is the first-order quantity and the process
  budget the second.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Unaffected. Nothing here deletes a ticket, adds an exception, or changes a drift decision. The filesystem is read fewer times; what it says is unchanged, and FR-011 makes the resolved answers identical key by key. |
| II | Zero-Churn Idempotency | Preserved and explicitly guarded. FR-030 keeps every identity mechanism untouched and FR-031 keeps the unchanged re-run silent. This feature's null observable diff (FR-021, FR-032) is a stronger statement than idempotency alone: not only does the re-run write nothing, the changed run writes exactly the same bytes it wrote before. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Preserved, with one deliberate asymmetry. Writes keep today's fail-closed behaviour verbatim (FR-029, FR-034). The timing instrument alone fails **open** (FR-003) — it is observability, it decides nothing, and a diagnostic that can abort the run it is diagnosing is the defect this feature is fixing. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Respected, and the two new in-memory artefacts are held to it. FR-014 keeps the resolved configuration free of credential material and unpersisted; FR-007 keeps the timing report free of it. Feature 021's once-per-run credential cache and its trace-suspension discipline are unchanged, and FR-028 forbids touching the request path where the credential lives. |
| V | Separation of Team Config / Local Binding / Secrets | Load-bearing here and preserved exactly. FR-011 requires the team-config-then-local-binding precedence to resolve identically; FR-013 keeps the local binding authoritative after the run writes to it. Reading each source once does not merge them: the resolved result records which rung each answer came from, exactly as today. |
| VI | macOS / Linux / Windows Portability | FR-033 requires module-for-module equivalence and FR-032 requires both suites and the corpus to pass unmodified. FR-020 names the two disciplines a consolidation is most likely to breach — the Bash port's structured-output module and Windows path spelling — and forbids breaching them. The locale defect is a Bash-shell-variable defect, so FR-001 lands on the Bash port; FR-005's locale matrix runs where the ports run. Any Windows-only divergence found here is diagnosed on the real runner. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. No status, transition, issue type, field, or hierarchy assumption is added, removed, or changed. FR-028 forbids touching payloads at all. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Respected. The clock is port infrastructure and stays free of tracker knowledge. The resolved configuration is a command-layer artefact; the phases that consult it consult it across the existing interface. No engine module gains a sink import, and no consolidation moves work across the boundary. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected in kind and preserved in ordering: the guard still runs over every payload before every write. Batching a transformation (FR-019) MUST NOT batch a payload past the guard — the guard's per-payload decision is behaviour, and FR-021's byte-identity covers it. |
| X | Self-Healing Automatic Mirror | Preserved. Hook health checking, idempotent registration, and respect for a disabled hook are untouched. This feature strengthens the principle in practice: a mirror that costs three minutes is one an operator disables, and one that costs three seconds is one they leave on. |
| XI | Universal Dry-Run and Auditability | Preserved. `--dry-run` still predicts the real run's action set exactly (FR-021, FR-032), and the edge cases require the shortened runs to be no worse on process count. FR-027 makes the performance claim auditable from the tool's own output rather than from a stopwatch. |
| XII | Quality and Catalog Publication | A performance and reliability change to shipped behaviour, carrying a CHANGELOG entry, gated by the full suite, the conformance corpus, and the linters on all three operating systems, and dogfooded against the real consuming repository whose profile motivated it — the dogfood profile is the acceptance evidence for FR-023 through FR-027, not a formality. |
| XIII | TDD With a Minimum 80% Coverage | The decisive tests here are counting tests, not timing tests, and they are written first: the configuration sources are opened once (FR-009), the process count does not grow with the item count (FR-016), the report is produced under a comma locale (FR-005). Each is deterministic and each fails today. The timing budgets of FR-023 through FR-025 are measured separately and recorded, because a wall-clock assertion in a suite that runs on a shared CI runner is a flake, not a test. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | Each change removes work rather than adding machinery: parse once instead of caching cleverly, hold one resolved result instead of building a configuration service, do the loop's work in-process instead of orchestrating a worker pool. FR-002 chooses the simplest correct reading of a clock over the more elaborate one that enumerates separators. No new abstraction, no new dependency (FR-035). |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Every artefact is demanded by a requirement and exercised by a test. Nothing is built speculatively: no configuration reload mechanism, no cross-run cache, no parallelism, no configurable budget, no new operator-facing switch. The PowerShell work in User Story 5 is explicitly conditional on a measurement rather than assumed. |
| XVI | Human Readable — Readable by a Human Above All | The timing report stays the prose a human reads in a terminal, and this feature's whole point is that a European operator can read it at all. FR-012 protects the diagnostics a human relies on from being collapsed or lost by the caching that makes the run fast. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

**Instrument reliability — verified first, because the rest is measured with it**

- **SC-001**: The per-phase timing report is produced correctly on a host whose numeric locale uses a comma
  decimal separator. Verified under at least `LC_ALL=C`, `fr_FR.UTF-8`, and `de_DE.UTF-8`.
- **SC-002**: Under a fixed injected clock, the timing report is byte-identical across every locale tested.
- **SC-003**: A regression test covering a comma-decimal locale exists, fails against the pre-change code, and
  passes after it. It fails on a wrong duration, not only on an error, and therefore fails against the
  pre-change code for **every** clock reading rather than for the roughly one in ten that raises an error.
- **SC-004**: With the timing instrument deliberately made to fail, the reconcile's exit code, standard
  output, and every written file are identical to the same run with the timing mode off.
- **SC-014**: The summed per-phase request counts equal the number of requests the run actually issued,
  asserted against the harness's own request log rather than against the instrument's own output. It fails
  against the pre-change code, which reports zero for every phase against 123 issued requests.

**Local performance — measured with the now-reliable instrument**

- **SC-005**: On the reference specification, the total of all phases excluding request time is under 20
  seconds, against the 3-to-6 minutes measured today. Measured on the same hardware class as the motivating
  profile.
- **SC-006**: On the reference specification, no single phase exceeds 5 seconds — against today's four phases
  of roughly 80 seconds each.
- **SC-007**: Each configuration source is opened at most once and parsed at most once per run, asserted by a
  counting stand-in rather than by timing.
- **SC-008**: The number of external processes a run spawns is bounded by a small constant per phase plus one
  per Jira request, and is unchanged when the number of stories and tasks is doubled — asserted by a counting
  stand-in.
- **SC-009**: Over five consecutive runs on byte-identical input, the spread between the fastest and the
  slowest is within 20% of the median, against today's 79%.
- **SC-015**: No file is opened and parsed twice in one run for content already parsed, asserted by a counting
  stand-in rather than by timing. It fails against the pre-change code, in which `config.local.yml` is read
  and parsed twice — once by the configuration load for its `overrides`, once by the binding resolution for
  its `resolved_ids` — at a directly measured cost of ~33 s per read on the motivating machine.

**Nothing else moved**

- **SC-010**: The full conformance corpus, the complete Bash suite, and the complete PowerShell suite pass
  unmodified, except for tests newly added by this feature.
- **SC-011**: For every conformance scenario, the standard output, the error stream, the exit code, every
  written file, and the recorded Jira call sequence are byte-identical to the pre-change run.
- **SC-012**: A reconcile with nothing changed since the last successful run still issues zero requests,
  performs zero writes, and completes in well under a second.
- **SC-013**: The two ports remain module-for-module equivalent, and their conformance outputs remain
  byte-identical to each other.

## Assumptions

- **A-1**: The reference specification for the **wall-clock** figures is one parent, ten stories, and fifty
  tasks — the shape named in the request and the shape feature 021 used for its own targets, so the
  before-and-after figures are comparable. The conformance rig that carries the **spawn-count** baseline,
  `repo-with-widget-spec-61`, has the same item count and a different shape: one parent, sixty stories, and
  no tasks at all. The two are interchangeable for a count that must be flat in item count, and are not
  interchangeable for FR-016's task clause — a fixture with zero tasks cannot demonstrate that the count is
  flat in the number of tasks. The task dimension is therefore asserted by a test-owned fixture, and the
  conformance rig is left untouched so the baseline it carries stays comparable across the whole feature.
- **A-2**: The profile's attribution is a hypothesis until the instrument confirms it. The request infers tens
  of thousands of process spawns from the CPU-time signature; that inference is confirmed by the counting
  stand-in of SC-008 before any consolidation is justified by it. A cost the counter does not find is not
  optimised.
- **A-3**: FR-023's 20-second budget and FR-024's 5-second budget are wall-clock measurements on the
  motivating hardware class, recorded as evidence and asserted in a suite only where the assertion is
  deterministic. CI runners are an order of magnitude slower than a developer laptop on this project, so a
  wall-clock gate in CI would measure the runner rather than the change.
- **A-4**: "Locale-independent by construction" is satisfied by making the clock reading unambiguous before it
  is interpreted, or by interpreting it in a way that does not depend on a separator character at all. Which of
  those the implementation chooses is a planning decision; enumerating separators is not among the options.
- **A-4b**: The intermittency described in the narrative is measured, not inferred. Both branches were
  reproduced directly on a comma-locale shell: a fractional part beginning with `0` raises the reported error,
  and any other fractional part completes silently with the seconds discarded. Planning may rely on this
  behaviour when constructing the failing test, and it is the reason FR-005 and SC-003 are written against
  duration correctness rather than error absence.
- **A-5**: The configuration snapshot is per-process. A source edited on disk by a third party mid-run is not
  observed by the remainder of that run. This is a deliberate change from whatever today's repeated reads
  happen to do, it makes the run internally consistent, and it is documented rather than left implicit.
- **A-6**: The only configuration source the run writes to during a run is the local binding, through the
  bridge's own write path. FR-013 is discharged by making that write path and the snapshot one mechanism; if a
  second self-writing source is discovered, it is covered by the same requirement rather than exempted.
- **A-7**: The PowerShell port's numeric handling is unaffected by the locale defect, which is specific to the
  Bash shell's own real-time variable. This is asserted rather than assumed: the PowerShell port's timing path
  is checked under the same locale matrix, and if it shares the defect it is fixed under FR-001 too.
- **A-8**: The PowerShell port's per-phase profile is not yet known. User Story 5 measures it first and applies
  consolidation only where the same per-item pattern is found, so the scope of the PowerShell work is an
  output of this feature rather than an input to it.
- **A-9**: Feature 021's phases — prereq, state, config, parse, gate, recognition, plan, and apply — remain the
  unit of measurement. This feature adds no phase, removes none, and renames none.

## Out of Scope

- Any change to Jira request patterns, payloads, headers, or ordering. Feature 021's bulk-fetch batching,
  connection reuse, and once-per-run credential resolution are kept exactly as they are.
- Any change to the recognition contract or to any idempotency contract.
- Asynchronous or background execution of the lifecycle hook. Making the reconcile fast and making it
  invisible are different features; this one is the first and does not prejudge the second.
- Concurrency or parallelism of any kind on the reconcile path. Feature 021 rejected it on determinism grounds
  and that decision stands; this feature's speed comes from doing less work per item, never from doing several
  items at once.
- Caching anything across runs. The single-run resolved configuration is in scope; a persisted parse, a
  warmed index, or a cross-run response cache is not. Sharing one parse between two phases of the **same** run
  is not merely in scope but required (FR-038) — the exclusion here is about outliving the process, never
  about reuse within it.
- Rewriting either port in another language, and introducing any new runtime dependency.
- Test-suite and CI performance, which remains a separate feature.
- A new operator-facing switch, a configurable process budget, or a configurable snapshot policy. All three
  are internal choices, not operator decisions.
- Adding, removing, or renaming a timing phase, and changing the timing report's shape. The report's
  cross-port byte identity is a constraint this feature inherits, not a surface it may redesign.
