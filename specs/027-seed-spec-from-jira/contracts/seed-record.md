# Contract — The seeded-not-bound record

**Feature**: 027 | **Module**: `lib/seed_state.sh` · `lib/SeedState.psm1`

Port infrastructure only. **No Jira knowledge** — every function is a pure
function of its arguments, exactly as `lib/run_state.sh` and `lib/config.sh` are.

---

## §1 Path and ownership

```
${JIRA_CONFIG_DIR}/state/<feature-dir>.seed.json
```

Sibling of `run_state_path`'s `<feature-dir>.json`, so the directory, its
creation, and its gitignore rules are already settled by 021.

**A separate document, not a key in the run-state one.** Two reasons, and the
first is measurable: the run-state schema comment states that a change to the set
of recorded inputs bumps the version and "invalidat[es] every existing file", so
folding this in would cost one full reconcile to every consumer of the extension,
including those who never seed from Jira. The second is semantic — the run-state
document means "the hashed inputs of the last fully successful reconcile", and a
pending seed is not that.

---

## §2 Shape (schema 1)

```json
{
  "schema_version": 1,
  "extension_version": "0.17.0",
  "slug": "ijt-add-payment-webhooks",
  "designators": [
    {"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},
    {"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},
    {"role":"story","form":"url","key":"PROJ-12","raw":"https://…/browse/PROJ-12","position":1}
  ],
  "bindings": [],
  "plan_digest": "a3f1…"
}
```

Canonical JSON, through `lib/output.sh` — never a bare `jq` multi-line write
(Windows CRLF, `AGENTS.md`).

| Field | Requirement served |
| --- | --- |
| `slug` | FR-060 — computed once, read on resume, **never re-derived** |
| `designators` | FR-054 order; FR-041's `REF-RESEED` comparison |
| `bindings: []` | FR-049 — states explicitly that zero were performed |
| `plan_digest` | FR-064 — the delta against the previously displayed plan |

`bindings` is an empty array rather than an omitted key. FR-049 requires the
state to be **recorded**, not inferred, and an explicit empty list is a
statement where a missing key is a silence.

`plan_digest` stores a digest of the *rendered* plan, never the plan itself. The
plan is always recomputed from Jira and from the current `spec.md` (FR-062,
FR-064); the digest exists only so the delta can be shown.

---

## §3 The `REF-RESEED` comparison (FR-041)

Two designator sets are **the same** when, for each role, the ordered list of
reduced keys is equal, and the free-text parent value is byte-equal when present.

- Comparison is on **reduced keys**, so `PROJ-11` and its browse URL are the same
  designator across two invocations (`raw` is retained for messages only).
- Order is part of identity: FR-054 makes it normative for pinning, so a
  reordered set is a different set.
- Any difference → `REF-RESEED`, whether the specification is seeded-not-bound
  or fully bound.

---

## §4 Lifecycle

```
absent ──moment 1 reaches the gate──> present, bindings: []
present ──same set──> resume (FR-050, FR-062, FR-063, FR-064)
present ──different set──> REF-RESEED
present ──--confirm, binding completes──> DELETED
absent, folder present ──> REF-EXISTS
```

The record is **deleted** on success, not marked done. Its absence beside a bound
specification is the ordinary steady state; a stale record left behind would make
every later invocation try to resume something already finished.

### The distinction FR-049 buys

| On disk | State |
| --- | --- |
| Record present, pins present, no identity | Seeded-not-bound — resume |
| No record, folder present | Crashed mid-draft — `REF-EXISTS`, fail closed |
| No record, identity present | Bound — ordinary reconcile territory |

The middle row is why the record cannot be inferred from "pins present, identity
absent": that is also what a crash mid-draft looks like, and the spec's own edge
case calls refusing there the correct answer.

---

## §5 Dry-run

`--dry-run` MUST NOT write, update, or delete this record — mirroring 021's
invariant that a dry run never touches the run-state document, so a preview can
never change what a following real run does.

---

## §6 Test obligations

| # | Assertion | Requirement |
| --- | --- | --- |
| S-1 | Decline writes the record with `bindings: []` and the ordered set | FR-049 |
| S-2 | Recorded slug is read on resume, never re-derived — proven by editing the description between decline and resume | FR-060 |
| S-3 | Key and URL for one issue compare equal across invocations | §3 |
| S-4 | Reordered `--story` flags → `REF-RESEED` | §3, FR-054 |
| S-5 | Successful binding deletes the record | §4 |
| S-6 | Folder present with no record → `REF-EXISTS` | §4 |
| S-7 | `--dry-run` leaves the record absent, or unchanged when present | §5 |
| S-8 | Document is byte-identical between ports for the same inputs | FR-046 |
| S-9 | The record is gitignored and never appears in `git status` | Principle V |
