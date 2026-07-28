# Phase 0 Research: Label-Based Adoption of Pre-Existing Jira Tickets

**Feature**: 003-label-based-adoption | **Date**: 2026-07-27 | **Spec**: [spec.md](./spec.md)

Every decision below resolves a `NEEDS CLARIFICATION` raised by the Technical
Context of [plan.md](./plan.md). Each is recorded as *Decision → Rationale →
Alternatives rejected*, and each names the existing code it builds on so the
implementation has no open question left to invent an answer for.

---

## §1 — How candidates are discovered: JQL over labels, not entity properties

**Decision**: discovery is a JQL search over the `labels` field, one query per
routed Jira project, scoped to the exact label values the spec folders in scope
imply. The endpoint is `GET /rest/api/3/search/jql`, paginated by the
`nextPageToken` cursor the response returns, with
`fields=labels,parent,project` and `maxResults=100`.

**Rationale**: the ticket identity marker is a per-issue *entity property*
(`scripts/bash/sink/jira/identity.sh`). Jira Cloud cannot search entity
properties in JQL unless a Connect/Forge app has registered a property index —
spec-kit-jira is a script extension with no app registration, so the marker is
readable per key and invisible to search. That asymmetry is exactly why the
constitution reserves a *label*-based adoption exception: a label is the only
signal both a human can apply in the Jira UI and the bridge can search for.

`GET /rest/api/3/search` (the offset-paginated `startAt`/`total` form still used
by `fetch_mentioned` for a best-effort sibling read) was removed for Jira Cloud
in the 2025 search-API migration; `/search/jql` with token pagination is the
supported replacement. `fetch_mentioned` degrades to an empty sibling list on
failure and is therefore not broken today, but a *new* read path that adoption
depends on must target the supported endpoint. Migrating `fetch_mentioned` is
out of scope for this feature.

The JQL is assembled from the label set, never from free text:

```text
project = "<KEY>" AND labels IN ("<label1>", "<label2>", ...)
```

**Alternatives rejected**:

- *Enumerate the backlog and filter client-side* — unbounded, and it would make
  a label naming a non-existent spec folder discoverable, which the spec
  explicitly puts Out of Scope (NFR-6 requires discovery bounded by the spec
  folders in scope).
- *Search entity properties* — impossible without an app registration; adding
  one would break "no build step, no download step" (Principle VI).
- *A per-issue `GET` over keys read from somewhere else* — there is nowhere else
  to read them from; that is the problem this feature exists to solve.

---

## §2 — Pagination and the silent-truncation trap

**Decision**: the sink loops on `nextPageToken` until the response omits it,
accumulating issues; `isLast`/absence of the token is the only stop condition. A
page that returns neither issues nor a token ends the loop. No result cap is
applied client-side.

**Rationale**: NFR-6 requires that a large project cannot silently truncate a
candidate list, because a truncated list turns a two-candidate ambiguity (which
must be refused, FR-010) into a one-candidate binding (which would be applied).
Silent truncation is therefore not a performance concern here — it is a
correctness hole that would write identity onto the wrong human's ticket.

The existing `discovery_list_projects` (`scripts/bash/sink/jira/discovery.sh:93`)
already establishes the paginated-read shape for this codebase with
`startAt`/`maxResults`; adoption follows the same structure with the newer
cursor.

**Alternatives rejected**:

- *Single request with `maxResults=1000`* — Jira caps page size server-side and
  the cap is not contractual; this is exactly the silent truncation NFR-6 bans.
- *Stop after two candidates are found* (enough to prove ambiguity) — it would
  make the refusal message list two keys when more exist, and FR-010 requires
  the message to name **every** candidate.

---

## §3 — Label grammar and its validation

**Decision**: three recognised forms over an operator-declared prefix (default
`speckit-adopt:`):

| Form | Example (prefix `speckit-adopt:`) | Binds |
|------|-----------------------------------|-------|
| Full folder | `speckit-adopt:003-label-based-adoption` | the spec's feature-level ticket |
| Story | `speckit-adopt:003-label-based-adoption:us2` | user story 2 of that spec |
| Short number | `speckit-adopt:003` | the feature-level ticket of the single spec folder numbered `003` |

The prefix is validated at config load: non-empty, no whitespace of any kind,
and total label length (prefix + longest implied suffix) at or below Jira's
255-character label limit. A prefix failing validation is a located
configuration error (exit 4) raised *before* any search — nothing is read and
nothing is written.

**Rationale**: Jira Cloud labels reject whitespace and are capped at 255
characters; `:` and `-` are accepted, which is what makes a structured,
human-typeable suffix possible. Anchoring the story form on the *ordinal* the
bridge already assigns in `spec.md` (`parse_spec`, `engine/parse.sh`) means the
label grammar introduces no new identifier — Principle XIV.

The short form exists because `speckit-adopt:003` is what a Product Owner will
realistically type into the Jira UI. It resolves only when exactly one spec
folder in scope carries that numbering component; two folders sharing a number
make the short form ambiguous and the binding is refused naming both folders
(spec edge case), which is the same fail-closed posture as everywhere else.

A label carrying the prefix alone, or naming a folder absent from disk, matches
nothing: the bridge searches for label values *derived from the folders in
scope*, so an unnamed label is not even in the query. That is FR-003's "never
infer" implemented structurally rather than as a runtime check.

**Alternatives rejected**:

- *Slug-only form without the numbering component* — collides across
  repositories that renumber, and offers nothing the full form does not.
- *A `spec-kit-jira` label plus a separate `spec` custom field* — a custom field
  is not guaranteed to exist and would violate Principle VII.
- *Case-insensitive matching* — Jira labels are case-sensitive; normalising
  would make two distinct Jira labels collide into one binding.

---

## §4 — The identity origin value on the wire

**Decision**: adoption stamps the existing marker with origin `human` — the
exact string the `mention` command already writes
(`scripts/bash/commands/mention.sh:103`). The bridge-created counterpart on the
wire is `bridge-created` (hyphen), as written by `ticket.sh` and consumed by
`adf.sh:139` and `plan_apply.sh:92`. No new marker field is introduced.

**Rationale**: the spec's prose says `bridge_created`; the shipped wire value is
`bridge-created`. Renaming the wire value would invalidate every marker already
stamped on real tickets, for no behavioural gain — Principle II (identity is
stable) beats prose symmetry. The plan therefore treats the spec's
`bridge_created` as naming the *concept* and pins the literal to the shipped
value, which is what the tests will assert.

Reusing origin `human` verbatim is what makes US3 free: `adf.sh` and
`plan_apply.sh` already splice the managed panel below human prose and already
diff description churn on the managed section alone
(`plan_managed_description_status`). Adoption writes no new preservation logic —
it selects the existing one by stamping the origin the existing code already
branches on.

**Alternatives rejected**:

- *A third origin value (`adopted`)* — every consumer would need a new branch
  meaning "behave exactly like `human`"; YAGNI (Principle XV) and a new field to
  keep in sync forever.
- *Renaming to `bridge_created` in the same change* — a migration of live ticket
  properties, unrelated to this feature, with a real regression surface.

---

## §5 — Where "this spec already owns a bridge-created ticket" is detectable

**Decision**: FR-011's second clause is enforced through the *candidate*: a
candidate carrying **this** spec's marker with origin `bridge-created` means the
spec already owns a bridge-created ticket, and the binding is refused naming
both the spec folder and the ticket. No repository-side spec→ticket index is
introduced.

**Rationale**: there is no persisted spec→ticket map in the tree today —
`reconcile` receives existing keys through its plan context
(`_reconcile_plan_context`), not from a committed file, and entity properties
cannot be searched (§1). Introducing an index purely to widen this check would
add a new persisted artifact that can itself drift, for a case that the
candidate check already covers whenever the two tickets are the same ticket.

This is a **stated limitation, not a silent gap**: if a spec owns a
bridge-created ticket *elsewhere* (a different key, not carrying an adoption
label), adoption cannot see it, and the following reconcile is the layer that
resolves the resulting two-parent situation through its existing drift
reporting. The plan records this in Complexity Tracking, and the CLI contract
states it in the refusal-class table so no reader assumes a stronger guarantee
than shipped.

**Alternatives rejected**:

- *A committed `.specify/jira/bindings.yml` index* — a fourth configuration
  artifact, guaranteed to drift from Jira, contradicting Principle I (the
  filesystem is the source of truth for *specs*, not for Jira keys).
- *A per-project sweep of every bridge marker* — impossible (§1) and unbounded
  (NFR-6).

---

## §6 — Confirmation, and how the corpus exercises the apply phase

**Decision**: `adopt` prints the plan, then reads a single confirmation line
from the terminal. `--yes` pre-confirms and is the flag the conformance corpus
and every scripted invocation use. When stdin is not a terminal and `--yes` was
not passed, the run behaves exactly as its `--dry-run` twin: the plan is
printed, the summary records zero writes, and the output names `--yes` as the
way to proceed.

Exit codes: an operator decline is **0** (a choice, not a failure); a run
carrying any per-binding refusal is **4** whether confirmed or declined, because
FR-013 makes the highest applicable code win.

**Rationale**: FR-006 requires explicit confirmation and says nothing about the
decline's exit code; treating a deliberate "no" as a failure would make the
command unusable in a shell with `set -e`. Collapsing the no-TTY case onto the
dry-run path rather than inventing a new error means one code path fewer and no
new exit code (FR-030 forbids new codes). It also keeps the spec's Out of Scope
line honest: this is not a headless-execution mode, because nothing is ever
written without `--yes`.

**Alternatives rejected**:

- *`--force`* — the wrong word for "the operator already said yes"; `--yes` is
  the conventional, self-documenting name (Principle XVI).
- *Decline exits 1 (usage)* — conflates operator choice with operator error.
- *No-TTY exits 5 (prerequisite)* — a terminal is not a prerequisite of the
  extension; the prerequisite ladder is about interpreter versions and tooling.

---

## §7 — Reusing `apply_writes` for the stamps

**Decision**: the apply phase builds an ordered action set of
`PUT /rest/api/3/issue/{key}/properties/spec-kit-jira` actions and hands it to
the existing `apply_writes` (`scripts/bash/sink/jira/plan_apply.sh:254`) rather
than calling `identity_write` in a loop.

**Rationale**: three requirements collapse into one line of reuse.

- FR-028 (privacy guard before every write, no exemption) — `apply_writes`
  scans every payload through the BLOCK guard *before* the first write and
  returns exit 9 with zero writes on a match. Adoption inherits it by
  construction rather than by remembering to call it.
- FR-023 (dry-run predicts the real run exactly) — the action set *is* the
  prediction, exactly as `--dry-run` works for `reconcile` today.
- FR-008 (an unreliable transport aborts) — `apply_writes` already aborts the
  remaining writes on any transport result at or above exit 2 and returns the
  worst code.

`identity_write` remains the single-ticket path used by `mention`; adoption
composes the same URL and the same `identity_marker` payload builder, so the two
paths cannot drift in what they stamp.

**Alternatives rejected**:

- *Loop over `identity_write`* — bypasses the guard, produces no action set for
  the dry-run twin, and re-implements the abort ladder.

---

## §8 — Engine / sink split, and the boundary greps

**Decision**:

| Concern | Layer | Module |
|---------|-------|--------|
| Label derivation from folder names, prefix validation, short-number ambiguity | engine | `engine/adoption.sh` / `Adoption.psm1` |
| Scope resolution, unknown-folder usage errors | engine | same |
| Ambiguity classification and plan assembly (bind / refuse + reason class) | engine | same |
| Candidate search (JQL, pagination), candidate context reads | sink | `sink/jira/adoption.sh` / `Adoption.psm1` |
| Claim reads and identity stamps | sink | existing `identity.sh` + `plan_apply.sh` |
| Routed-project resolution | engine | existing `routing_resolve` (`engine/interchange.sh:115`) |

The engine module receives candidates as an opaque JSON array and returns a
plan; it never learns what a Jira issue key looks like.

**Rationale**: `.github/workflows/boundary.yml` greps every file under
`scripts/*/engine/` for `[A-Z]{2,}-[0-9]+` (the issue-key shape), `atlassian`,
`createmeta`, `customfield_[0-9]+`, and ADF node names, and fails the build on a
match — **including in comments**. So the engine adoption module must not carry
a single example issue key, even illustratively. `engine/naming.sh` is the
precedent: it manipulates ticket numbers using the pattern `[A-Z]*-*` (which the
grep does not match) and documents the constraint in its header.

The same rule drives §9's flag-validation placement.

**Alternatives rejected**:

- *One module in the sink doing everything* — the ambiguity rules are the
  feature's whole value and must be unit-testable without a mock server;
  Principle VIII forbids the shortcut.

---

## §9 — Flag surface, and where each flag is validated

**Decision**: three new flags, all repeatable where noted, parsed in
`lib/cli.sh` (port infrastructure, outside the boundary grep) with **structural**
validation only; issue-key *shape* validation happens in the sink.

| Flag | Repeatable | Parsed shape | Validated where |
|------|-----------|--------------|-----------------|
| `--bind <folder>=<KEY>` | yes | non-empty `=` non-empty | folder exists → engine; key shape → sink |
| `--spec <folder>` | yes | non-empty | folder exists → engine |
| `--yes` | no | boolean | n/a |

**Rationale**: `cli.sh` already validates a project-key shape for `--style`
(`^[A-Z][A-Z0-9_]+=`), so precedent allows shape checks there. But keeping the
issue-key regex out of the CLI parser concentrates every key-shaped literal in
the sink, which is where Principle VIII wants it, and it makes the "unknown spec
folder" usage error (FR-021, FR-026) a pure engine check testable with no Jira
at all.

`--bind` is chosen over `--pin` because the spec's own vocabulary is *binding*
throughout (Key Entities), and error messages that reuse the flag's own noun
read better (Principle XVI).

**Alternatives rejected**:

- *`--bind folder:KEY`* — `:` is already the label grammar's separator (§3);
  reusing it invites confusion in a message that shows both.
- *A single `--bind` accepting a comma-separated list* — worse errors, and the
  repeatable form matches `--style`/`--use-team` already shipped.

---

## §10 — Refusal classes, and the shape of a remediation

**Decision**: eight named refusal classes, each carrying the spec folder, every
issue key involved, and a copy-pasteable remediation command.

| Class | Trigger | FR |
|-------|---------|----|
| `no-candidate` | zero accessible tickets carry the implied labels | FR-009 |
| `several-candidates` | more than one | FR-010 |
| `already-claimed` | candidate carries another spec's marker | FR-011 |
| `spec-owns-bridge-ticket` | candidate carries this spec's marker, origin `bridge-created` | FR-011 |
| `wrong-project` | candidate's project ≠ the spec's routed project | FR-005 |
| `unbound-parent` | a story binding whose feature-level ticket is not bound | FR-014 |
| `wrong-parent` | candidate's Jira parent ≠ the spec's bound feature-level ticket | FR-015 |
| `ambiguous-short-number` | two spec folders share the numbering component | edge case |

The remediation is a literal command line the operator can paste — for
`several-candidates` and `no-candidate` that is the `--bind` invocation which
resolves it, which is precisely why US4 is the documented answer to US2.

**Rationale**: Principle XVI requires every message to name the problem, the
artifact, and a copy-pasteable fix. A closed enumeration of classes (rather than
free-form strings) is what lets the conformance corpus assert one fixture per
class (SC-005) and what keeps the machine-readable summary schema closed
(`additionalProperties: false`).

**Alternatives rejected**:

- *Free-text reasons* — untestable as a set, and drifts between ports; NFR-1
  requires byte-identical summaries.

---

## §11 — Mock-server work this feature requires

**Decision**: the pwsh mock (`tests/conformance/mock-jira/mock-server.ps1`)
gains a real `GET /rest/api/3/search/jql` handler driven by a per-scenario
issues map, plus a per-issue `labels`/`parent`/`project` fixture source. The
existing `Get-IdentityMarker` path already serves per-key identity markers and
needs only scenario data, not new code.

**Rationale**: today `^/rest/api/3/(search|search/jql)$` returns the fixed
`search-siblings` fixture regardless of the JQL — sufficient for
`fetch_mentioned`, useless for asserting that a two-candidate corpus refuses and
a one-candidate corpus binds. NFR-5 requires fixtures covering zero, one, and
several candidates, claimed candidates, hierarchy cases, both project styles,
and the existing fault injections; none of that is expressible without a
JQL-aware handler.

The fault-injection map already keys on project/issue key, so the "unreliable
read during discovery aborts before any write" scenario (FR-008, AS US2-6)
needs no new mock capability.

**Alternatives rejected**:

- *Assert only at the bats/Pester unit level* — Principle VI makes cross-port
  conformance the portability proof; a rule proven only per-port is not proven.

---

## §12 — Coverage measurement for the new modules

**Decision**: the new Bash modules are measured by the existing two-collector
gate (kcov denominator + traced bats) on Linux only; PowerShell by Pester
CodeCoverage on every runner. `jq` program literals in the new engine module
carry `# kcov-excl-start` / `# kcov-excl-stop` markers, matching
`interchange.sh:117` and `config.sh`.

**Rationale**: kcov counts each line of a multi-line `jq` string literal as an
uncovered statement, which would drag the new module's statement coverage down
for lines that are data, not code. The exclusion convention is already
established in this repository for exactly this reason; adoption's classification
logic will be jq-heavy for the same reason the rest of the engine is.

**Alternatives rejected**:

- *Rewrite the classification in pure Bash string handling to avoid jq* — less
  readable (Principle XVI), and jq is already a declared prerequisite (NFR-2).
