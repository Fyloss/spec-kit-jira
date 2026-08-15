# Phase 0 — Research: Seed a Specification From Existing Jira Issues

**Feature**: 027 | **Date**: 2026-08-15 | **Spec**: [spec.md](./spec.md)

Every entry below resolves something the specification deliberately left to the
plan, or something the repository answers only when you go and look. Each is
stated as **Decision / Rationale / Alternatives rejected**, and each names the
file or the constitutional rule that forced the answer.

---

## R1 — The confirmation gate cannot live in an `after_*` hook

**Decision.** The feature spans **two moments**, and the second one is a **new
agent-invoked command, `speckit.jira.seed`**, declared in `extension.yml` under
`provides.commands` and bound to **no** hook event.

- **Moment 1 — `before_specify`**, inside the existing `speckit.jira.feature`
  (`scripts/bash/commands/feature.sh`). It parses the designators, issues the
  one bulk resolution read, evaluates every refusal class that depends only on
  Jira state, computes the slug, writes the seeded-not-bound record, and hands
  the drafting agent its seed material and provenance. **Zero Jira mutations.**
- **Moment 2 — `speckit.jira.seed`**, invoked by the agent after `spec.md`
  exists. It validates the pinning markers (FR-058), recomputes the write plan
  from the current file, obtains confirmation, and only then binds, creates, and
  re-parents.

**Rationale.** FR-033 requires the operator to confirm before the first Jira
mutation. The constitution forbids putting that prompt in a hook, and says so in
as many words under Principle IV: the bridge "runs inside lifecycle hooks, where
there is nobody to answer a prompt and a wait is indistinguishable from a hang".
Principle III adds that an `after_*` hook must never fail the host command,
whereas FR-035 requires every refusal to exit non-zero. A gated, refusing command
is therefore structurally not a hook. The split is forced, not chosen.

The plan for moment 2 also cannot be computed in moment 1: FR-033 enumerates the
issues to create, which depends on the user stories the agent has not yet
drafted, and FR-064 requires the plan to reflect `spec.md` **as it now stands**.

**Alternatives rejected.**

- *Fold moment 2 into `after_specify`'s reconcile run.* Reconcile is a hook. It
  cannot prompt and it cannot fail the host. Both are requirements here.
- *Do everything in moment 1, confirming the designators rather than the plan.*
  The plan would then predict creates it cannot know about, breaking FR-034 and
  Principle XI — a preview that does not predict the run is not a preview.
- *Repoint `after_specify` at the seed command.* It would break the ordinary
  mirror for every run that names nothing, which FR-048 forbids outright.

**Carried risk, named rather than buried.** Moment 2 reaches the bridge only
because the agent invokes it. That is the same conveyance as
`SPEC_KIT_JIRA_HOOK_EVENT`, and it is only as reliable as the agent. Two
mitigations: `commands/speckit.jira.feature.md` states the follow-up as a
mandatory step with the exact invocation, and — more importantly — the failure
mode is **safe by construction**. An agent that forgets leaves a
seeded-not-bound specification: markers on disk, nothing written to Jira,
resumable by FR-050. Nothing is duplicated and nothing is lost. Contrast this
with 023's hook-event defect, where a missed conveyance silently did no work at
all; here the missing step is visible in the tree and named in the record.

Also relevant, and a lesson taken directly: `mention` has been implemented and
tested in both ports since 001 but was never listed in `extension.yml`, so no
user can reach it (`docs/VISION.md` §6). **Declaring `speckit.jira.seed` in the
manifest is part of this feature, not a follow-up.**

---

## R2 — Designator parsing belongs to the **sink**, not the engine

**Decision.** A new sink module pair — `scripts/bash/sink/jira/designator.sh`
and `scripts/powershell/sink/jira/Designator.psm1` — owns the key grammar
(FR-002), URL reduction (FR-004, FR-005), host comparison (FR-006),
de-duplication and ordering (FR-008, FR-054), and the blank-versus-absent
distinction (FR-055).

**Rationale.** Constitution VIII's enforcement test is a CI grep: "no engine
script contains any Atlassian-specific identifier (issue key patterns,
`atlassian.net`, `createmeta`, ADF node names, Jira field ids or type names)".
An issue-key regex and a `selectedIssue` query parameter are precisely that.
`engine/naming.sh` makes the point by counter-example — `naming_ticket_number`
"does not know what a Jira key is; it strips an upper-case-led prefix from an
opaque string" (`docs/06-feature-naming.md`). Putting designator parsing in the
engine would fail the boundary job in `.github/workflows/`.

**Alternatives rejected.**

- *Extend `engine/naming.sh`.* Same grep, and it would give the naming engine
  the tracker vocabulary it was deliberately built without.
- *Inline it in `commands/feature.sh`.* The seed command needs the same
  reduction to compare designator sets for `REF-RESEED`; duplicating the grammar
  across two commands is how the two ports drift.

---

## R3 — The pinning marker belongs to the **engine**

**Decision.** A new engine module pair — `scripts/bash/engine/pin_marker.sh` and
`scripts/powershell/engine/PinMarker.psm1` — owns the `pin=` grammar (FR-056),
the placement scan, the FR-058 validation, and the consume-at-binding
replacement (FR-057).

**Rationale.** This is the mirror image of R2, and the precedent is exact.
`engine/story_marker.sh` already writes `<!-- speckit-jira story=<id>
ticket=PROJ-142 -->` from the engine side; its header states the rule — "the
identifier is opaque; the ticket key it is paired with is opaque text handed in
by the caller — exactly as `managed_section.sh` takes its markers as parameters
without knowing about READMEs". A `pin=KEY` marker carries the same opaque
string under the same rule. The module never validates the key's shape; that is
R2's job, upstream.

Three primitives are inherited unchanged rather than rewritten:
`marker_splice.sh` for the byte-preserving, line-ending-correct, atomic
line-replacement; `_smk_scan_anchors`'s heading scan (`^#{2,4}\s+User Story`,
falling back to the document's first H1) for placement; and `story_marker.sh`'s
non-collision discipline — `spec_marker_parse_line` already documents that a
`story=` body "is a DIFFERENT marker and MUST fall through to `none` here, by
construction". `pin=` becomes the third member of that closed, mutually
non-matching set.

**Alternatives rejected.**

- *Reuse the `story=` marker with a sentinel id.* It would make an intention
  indistinguishable from a binding at the grammar level, which is exactly what
  FR-057 exists to prevent.
- *Keep the pinning in a side-car file.* The operator edits `spec.md` between
  drafting and confirmation (FR-063); a side-car would silently desynchronise
  from the file the operator actually changed.

---

## R4 — The resolution read cannot reuse `prefetch.sh`

**Decision.** A second bulk-read module, `sink/jira/adoption.sh` /
`Adoption.psm1`, issues `POST /rest/api/3/issue/bulkfetch` for the designated
keys. It reuses the chunking shape of `prefetch.sh` and **inverts its failure
posture**.

**Rationale.** `prefetch.sh` is explicitly and correctly fail-**open**. Its
header states the governing rule: "the prefetch may only ever remove requests —
it may never change an outcome", and invariant P2 empties the map on any non-2xx
so every key falls through to an unchanged per-key GET. That is right for an
optimisation and wrong here: FR-038 requires a run that named issues to **refuse**
on an unreliable read rather than degrade, because degrading manufactures the
duplicates this feature exists to prevent. A module whose contract is "never
change an outcome" cannot be the module that decides to refuse.

The two also disagree on scope: `prefetch.sh`'s map is keyed for the recognition
readers and its field union is theirs.

**Alternatives rejected.**

- *Add a fail-closed mode to `prefetch.sh`.* It would put two opposite failure
  postures behind one flag, in the module whose whole correctness argument is
  that it has exactly one. This is where the "prefetch field union must mirror
  recognition fields" class of defect comes from.
- *One GET per designated issue.* FR-043 and Principle-level process budget
  forbid a per-item request; and `docs/11-process-budget.md` forbids the per-item
  spawn that would come with it.

---

## R5 — The resolution read's field union

**Decision.** The adoption read requests exactly:

```
summary, description, status, issuetype, project, parent
```

plus the `spec-kit-jira` entity property.

**Rationale.** Each field is demanded by a named requirement, and nothing else is
requested — FR-020 forbids comment bodies, and Principle XV forbids fetching a
field no requirement consumes.

| Field | Required by |
| --- | --- |
| `issuetype` | FR-013 role validation, `REF-ROLE` |
| `project` | `REF-ROUTING`, `REF-MULTIPROJECT` |
| `status` | `REF-TERMINAL`, and FR-062's re-evaluation on resume |
| `parent` | FR-026 re-parenting, FR-051 disclosure, FR-061 scatter report |
| `description` | FR-015 seeding, FR-021 `REF-THIN` |
| `summary` | FR-015 seeding, FR-051 disclosure of the current parent |
| entity property | `REF-CLAIMED` (FR-027, `identity_claimed_by_other`) |

Note that `_PREFETCH_FIELDS` in `prefetch.sh` today is
`summary,description,priority,status,issuelinks,parent,labels,subtasks,Flagged`
— it carries **neither `issuetype` nor `project`**. Reusing it would have made
FR-013 and `REF-ROUTING` unsatisfiable without a second request, breaking FR-043's
"0 additional requests" line for role validation. This is R4's argument restated
in field terms.

**Cost consequence.** FR-051 requires the current parent's **summary and status**,
not just its key, and a parent is not itself a designated key. Those parents are
folded into the *same* bulkfetch call as a second id list — one call for
designators and their distinct current parents together — so the ceiling stays
`ceil(N / B)` and never becomes one request per parent.

---

## R6 — CLI flag shape for designators

**Decision.** Two new flags on the `feature` and `seed` commands:

- `--parent <designator>` — at most once. Value may contain spaces (free text).
- `--story <designator>` — repeatable, **argv order is the normative order**
  (FR-054).

Both are accumulated and emitted by `cli_parse` as a **`\x1f`-joined stream**,
not a space-joined one.

**Rationale.** `lib/cli.sh` already draws exactly this distinction and documents
why: `field_defaults`/`field_values` are "`\x1f`-joined … (NOT space-joined like
every other repeatable flag — a field VALUE may itself contain spaces)". A
free-text parent title has the same property. Space-joining would silently split
`--parent "Payment webhooks rollout"` into three designators.

`\x1f` also gives FR-055 for free: an empty element is preserved in a
`\x1f`-joined stream and is indistinguishable from nothing only if it is dropped
— so the accumulator must record that the flag was *seen*, separately from its
value. The parse state therefore carries `parent_seen=true|false` alongside
`parent=<value>`.

Order preservation (FR-054) is a property of a bash array append and a
PowerShell `+=` on a typed list; the risk is not the append but the later
transformations. De-duplication (FR-008) keeps the **first** occurrence's
position, and the bulkfetch response — which makes no ordering promise — is
joined back onto the designator array by key, never iterated in response order.

**Alternatives rejected.**

- *A leading positional list, extending today's single mentioned key.* It cannot
  express roles, and a free-text parent with spaces is unparseable positionally.
  Today's single-key positional is preserved unchanged for FR-048/US5 AC3.
- *`--parent KEY` plus `--parent-title TEXT`.* Two flags for one slot, and the
  operator must know in advance whether their parent exists — which is precisely
  the thing FR-023 removes the need to know.

---

## R7 — The confirmation gate reuses an existing payload shape

**Decision.** `speckit.jira.seed` without `--confirm` emits the provenance
report and the write plan and returns a `confirmation_required` payload, exit 0,
zero mutations. The agent puts the question to the operator; on a yes it
re-invokes with `--confirm`.

**Rationale.** `commands/feature.sh` already has this exact shape for the
cross-team question — `{active:true, confirmation_required:{…}}` with a
dedicated prose renderer. Reusing it means one confirmation idiom in the
extension rather than two, and the prose renderer's byte-identity across ports is
already proven by the corpus. Principle XVI is served by reuse here, not by
invention.

`--dry-run` remains distinct and unchanged in meaning: it predicts and never
writes, including never writing the seeded-not-bound record.

**Alternatives rejected.**

- *Read from the terminal.* The command may run non-interactively, and a blocking
  read is the hang Principle IV warns about. The agent owns the interaction.
- *A `--yes` flag on a single invocation.* It collapses the two-step gate into
  one, so the operator could confirm without the plan ever being rendered.

---

## R8 — The seeded-not-bound record

**Decision.** A sibling of the run-state document:
`.specify/jira/state/<feature-dir>.seed.json`, owned by a new
`lib/seed_state.sh` / `SeedState.psm1`, schema `1`.

Recorded fields: `schema_version`, `slug` (FR-060), `designators` — the ordered
list, each with role and reduced key or free text (FR-054) — `bindings: []` with
the explicit statement that zero were performed (FR-049), and the extension
version.

**Rationale.** `run_state_path` is `${JIRA_CONFIG_DIR}/state/<feature-dir>.json`,
gitignored and already the home for per-feature machine state, so the directory
and its ignore rules are settled. It must be a **separate document**, not a new
key in the run-state one, for two reasons: the run-state document's identity is
"the hashed inputs of the last fully successful reconcile", and its schema
comment says a change to the *set* of recorded inputs bumps the version and
"invalidat[es] every existing file" — every consumer would take a full-reconcile
penalty for a feature most of them never use. Second, FR-049 requires the state
to be recorded, never inferred; a document that exists only when seeding is
pending says that by its own existence.

FR-049's third property — distinguishing a declined run from a crashed one — is
what the record buys. A crash mid-draft leaves no record, so `REF-EXISTS` fires,
which the spec's own edge case calls the correct fail-closed answer.

**Alternatives rejected.**

- *Infer the state from "pins present, identity absent".* FR-049 forbids it in
  terms, and it cannot carry the slug (FR-060) or the designator order (FR-054).
- *Keep it in the feature directory.* It is machine state, not a spec artifact,
  and it must not be committed.

---

## R9 — Slug derivation

**Decision.** FR-059's rule is implemented in `commands/feature.sh` step (5),
between designator resolution and the existing call to `naming_expand_pattern`.
It selects the **number source** and leaves `engine/naming.sh` untouched.

**Rationale.** The existing code already does exactly this for one key:
`number="$(naming_ticket_number "${ticket_key}")"`. FR-059 changes *which* key is
handed to that function, not what the function does — the parent's key, else the
first story-role key, else nothing. The fifth shape (free-text parent, no
stories) falls through to the current no-key branch, which is the "ordinary
naming behaviour" FR-059 requires, with no new code at all.

`naming.sh` therefore gains **zero** lines, keeping its boundary-grep cleanliness
and its "no key-shaped literal" property intact.

---

## R10 — Process and request budget

**Decision.**

- One `bulkfetch` POST per 100 designated keys, chunked exactly as
  `prefetch_load` chunks (`docs/11-process-budget.md`).
- The batched request body is built with a **single** `jq -n` invocation over an
  ids array, and is written to a **temp file** before being handed to
  `jira_request`, never passed as a growable command-line argument.
- The designator array is transformed with shell-native string operations, not
  one `jq`/`sed`/`cut` per designator.
- FR-058's validation is a **single pass** over `spec.md`, collecting marker
  lines and their line numbers, then one comparison against the designator array
  in memory. Not one grep per key.

**Rationale.** `AGENTS.md` states the rule as one inseparable pair, and records
that the second half has been reintroduced twice because Linux caps a single
argument at 128 KiB (`MAX_ARG_STRLEN`) while macOS does not — so the defect is
invisible on the maintainer's own machine. `prefetch.sh` already demonstrates the
compliant shape: it writes the response to `mktemp` rather than capturing it, for
the same family of reasons.

100 designators at ~10 bytes a key is only ~1 KiB, so the growable-argument
hazard is not acute here — but the rule is unconditional, and the seeding
payload handed to the agent (N descriptions) is emphatically not small.

---

## R11 — Windows portability

**Decision.** Three named hazards, each with its countermeasure fixed in the
contracts rather than left to implementation.

1. **Never put `$'\r\n'` in a glob pattern.** URL reduction strips a fragment and
   a query string with `${x%%\#*}` and `${x%%\?*}`; a designator read from a file
   or a CRLF-ended stream must be trimmed with a CR-by-CR walk, reusing
   `_ms_count_crlf`'s discipline from `engine/managed_section.sh`. The MSYS bash
   matcher lets a CRLF inside a glob match a bare LF — this is the documented root
   cause of the 15 `bash=0d` divergences (`docs/10-windows-portability.md`).
2. **Never call `jq` directly for multi-line output in the Bash port.** The
   provenance report, the write plan, and the seeding payload are all multi-line.
   Every one goes through `scripts/bash/lib/output.sh`.
3. **`cygpath -m` for any path handed to `curl`.** The temp file of R10 is handed
   to `jira_request`, which is the boundary where this applies.

**Method.** Constitution VI's measurement-over-emulation rule governs: a
divergence that shows up only on Windows is diagnosed by a push to
`ci/windows-probe`, never by emulating MSYS locally. Note the standing hazard
recorded in this repository's own history — the probe baseline on `main` has been
red, so a red probe must be triaged against the baseline before it is attributed
to this feature.

---

## R12 — Where the untestable requirement lives

**Decision.** FR-015 is implemented as normative text in
`commands/speckit.jira.feature.md`, the agent-facing command definition the agent
already reads during `before_specify`. The same file carries the FR-056 marker
format, the FR-054 ordering obligation, and the mandatory follow-up invocation of
R1.

**Rationale.** The spec's own testability table (under FR-019) records that FR-015
cannot be proven by the corpus. The plan's job is to say where it lives instead
rather than pretend otherwise. Three accountability mechanisms surround it and
*are* testable: the provenance report (FR-032) makes the attribution visible
before confirmation; FR-058 mechanically catches the structural failures that
matter; and Principle XII's dogfood requirement puts a human in front of the
result against a real instance before release.

`commands/*.md` is shipped content — `.extensionignore` excludes development
material, not the command definitions — so this text reaches consumers.

---

## R13 — OD-4: adopted versus created stays machine-readable

**Decision for this plan.** Ship **option A** — the distinction lives only in the
identity marker's existing `origin` field (`human` versus `bridge`). No new
label, no line in the managed panel.

**Rationale.** `identity_marker` already writes `origin` and it is already
load-bearing: human origin is what triggers the managed-panel splice (018) and
what earns a ticket the never-hard-deleted protection of Principle I. Nothing in
this feature requires more, and Principle XV forbids building what no requirement
demands. Option B would add a write to every adopted issue — measurably against
Principle II's zero-churn rule — to surface a distinction no acceptance scenario
asks for.

**Status.** Adopted into the spec by the third clarification pass; FR-031 now
states it as a requirement. It is the answer that costs nothing to reverse:
adding a visible marker later is additive, whereas removing one that consumers
have started reading is not.

---

## R14 — OD-5: a partial binding resumes, it does not roll back

**Decision for this plan.** Ship **option B** — a run that began binding and
failed part-way leaves its completed bindings in place, reports exactly which
completed and which did not, and the next invocation resumes from them.

**Rationale.** Option A is very likely unavailable rather than merely unattractive:
Principle I forbids the bridge deleting a Jira artifact, and a rollback would have
to delete a created parent. Option C (refuse until the operator resolves it by
hand) conflicts with FR-040, which requires a re-invocation with the identical
designator set to be a no-op — and a no-op is only reachable if the run can tell
what is already done and skip it, which is resumption.

The mechanism already exists and needs no new invention: FR-028 mandates the
per-item stamp-and-record ordering the bridge has used since 005 — "each created
key is stamped and recorded immediately, per ticket, never batched. A run
interrupted after three creations has three recorded keys"
(`docs/08-safety-model.md`). Resumption is then recognition doing its ordinary
job: a story whose marker already carries `ticket=KEY` is bound and skipped.

**Status.** Adopted into the spec by the third clarification pass; FR-042 and
US2 AC7 now state it. What it settles is the case that
was already forced by the constitution and by FR-040; the residual question —
whether a partially bound state should additionally be surfaced as a distinct
warning class — is left to the tasks phase and changes no requirement.

---

## Summary of decisions

| # | Decision | Forced by |
| --- | --- | --- |
| R1 | Two moments; moment 2 is a new non-hook command `speckit.jira.seed`, declared in `extension.yml` | Constitution III & IV — a prompt in a hook is a hang |
| R2 | Designator parsing in the **sink** | Constitution VIII boundary grep |
| R3 | Pin marker in the **engine**, reusing `marker_splice.sh` | `story_marker.sh` precedent |
| R4 | New fail-**closed** bulk read; `prefetch.sh` untouched | FR-038 versus prefetch's "never change an outcome" |
| R5 | Field union incl. `issuetype` + `project` (absent from `_PREFETCH_FIELDS`) | FR-013, `REF-ROUTING`, FR-043 |
| R6 | `\x1f`-joined repeatable flags; `parent_seen` separate from `parent` | Free text contains spaces; FR-055 |
| R7 | Reuse `confirmation_required` payload + `--confirm` | Existing `feature.sh` idiom |
| R8 | Separate `<feature>.seed.json`, schema 1 | Run-state schema bump would penalise every consumer |
| R9 | Slug rule selects the number source; `naming.sh` gains zero lines | Boundary cleanliness |
| R10 | Chunked bulk read, temp file, single-pass validation | `docs/11-process-budget.md` |
| R11 | CR-by-CR trim, `lib/output.sh`, `cygpath -m`; probe, not emulation | `docs/10-windows-portability.md`, Constitution VI |
| R12 | FR-015 lives in `commands/speckit.jira.feature.md` | Spec's own testability table |
| R13 | OD-4 → origin field only (adopted into FR-031) | Principle XV |
| R14 | OD-5 → resume, never roll back (adopted into FR-042) | Principle I + FR-040 |
