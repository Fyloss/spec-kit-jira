# Phase 1 — Data Model: Seed a Specification From Existing Jira Issues

**Feature**: 027 | **Date**: 2026-08-15 | **Spec**: [spec.md](./spec.md)

Six entities. Three are new documents or markers this feature introduces; three
are existing structures it extends. Every field traces to a functional
requirement — Principle XV admits no other kind.

---

## §1 Designator

The operator's typed string, plus the role they declared for it. Produced by
`sink/jira/designator.sh` (research R2), consumed by everything downstream.

| Field | Type | Notes |
| --- | --- | --- |
| `role` | `"specification"` \| `"story"` | Declared by the operator, never inferred from the issue's type (FR-001) |
| `raw` | string | Exactly as typed, before any transformation. Retained for refusal messages (FR-035) |
| `form` | `"key"` \| `"url"` \| `"free_text"` | `free_text` is legal only for `role = specification` (FR-001) |
| `key` | string \| null | The reduced, upper-cased key. Null exactly when `form = free_text` |
| `position` | integer | 0-based argv position among same-role designators. The normative order (FR-054) |

### Reduction (FR-002, FR-004)

```
raw ──strip fragment──> ──strip query, capturing selectedIssue──> candidate
                                                                     │
   selectedIssue present? ──yes──> percent-decode its value ─────────┤
   path contains /browse/? ─yes──> segment after it ─────────────────┤
   final path segment matches grammar? ─yes──> that segment ─────────┤
                                                                     ▼
                                              upper-case ──> ^[A-Z][A-Z0-9_]+-[0-9]+$
                                                                     │
                                             no match ──> REF-DESIGNATOR
```

The grammar is the one `commands/feature.sh` already applies to its leading
positional — reused verbatim so the existing path and the new one cannot drift.

### Validation rules

| Rule | Refusal | Requirement |
| --- | --- | --- |
| Candidate fails the key grammar | `REF-DESIGNATOR` | FR-002, FR-053 |
| `role = specification`, `form = free_text`, value blank or whitespace-only | `REF-DESIGNATOR` | FR-053 |
| Flag supplied but value blank ≠ flag absent | — (`parent_seen` distinguishes) | FR-055 |
| URL scheme/host/port ≠ configured base URL | `REF-HOST` | FR-006 |
| Same reduced key twice, or once per role | `REF-DUPLICATE` | FR-008 |

De-duplication removes the **later** occurrence and preserves the earlier one's
`position` (FR-054).

---

## §2 Named issue

One resolved issue, produced by `sink/jira/adoption.sh`'s bulk read (research
R4, R5). Joined back onto its designator **by key** — never by response order,
which `bulkfetch` does not promise.

| Field | Source | Consumed by |
| --- | --- | --- |
| `key` | response | joining, binding, all messages |
| `issuetype` | `fields.issuetype` | FR-013 → `REF-ROLE` |
| `project` | `fields.project` | `REF-ROUTING`, `REF-MULTIPROJECT` |
| `status` | `fields.status` | `REF-TERMINAL`, FR-062 re-evaluation |
| `parent` | `fields.parent` | FR-026, FR-051, FR-061 |
| `summary` | `fields.summary` | FR-015 seeding; FR-051 parent disclosure |
| `description` | `fields.description` | FR-015 seeding; FR-021 → `REF-THIN` |
| `marker` | property `spec-kit-jira` | `REF-CLAIMED` via `identity_claimed_by_other` |

**Absence is not a status.** A designated key missing from the response is
`REF-UNRESOLVED`, and FR-037 forbids the message from claiming to know whether
it is deleted or merely invisible — `bulkfetch` reports both as absence.

### Key substitution

Jira answers a read of a moved issue under its **new** key. The bound key is the
key the response returned, and the substitution is reported (spec Edge Cases).
The join therefore matches on the returned key *or* the requested one, and
records both.

---

## §3 Pinning marker — new

Written by the **agent**, at drafting time. Expresses an intention (FR-056,
FR-057). Owned by `engine/pin_marker.sh` (research R3).

```
<!-- speckit-jira pin=PROJ-142 -->
```

| Property | Value | Requirement |
| --- | --- | --- |
| Placement | Immediately after the user-story heading, the position `_smk_scan_anchors` already computes (`^#{2,4}\s+User Story`, else the document's first H1) | FR-056 |
| Cardinality | At most one per user story; a user story with no named counterpart carries none | FR-056, FR-018 |
| Carries | The designated key, opaque to this module | FR-056 |
| Never carries | A durable identifier | FR-056 |
| Non-collision | A `story=` or `spec=` body parses as `none` here, and a `pin=` body parses as `none` in those two — closed, mutually exclusive set | FR-056 |
| Lifetime | Consumed at binding: replaced in place by `story=<id> ticket=KEY` | FR-057 |

### The disjointness that carries the state machine

```
                  pins present        pins absent
identity absent   SEEDED-NOT-BOUND    not yet drafted, or crashed mid-draft
identity present  (unreachable)       BOUND
```

The unreachable cell is what FR-057's consume-at-binding rule buys: the two live
states are distinguishable by inspection alone. FR-049 still requires the
seeded-not-bound state to be *recorded* rather than inferred — §5 — because the
top-right cell is ambiguous and only the record disambiguates it.

---

## §4 Identity marker — existing, extended by use only

`sink/jira/identity.sh`'s `identity_marker` already carries every field this
feature needs. **No schema change.**

| Field | Value used here | Requirement |
| --- | --- | --- |
| `origin` | `"human"` for every adopted issue; `"bridge"` for a created parent | FR-027, FR-030, R13 |
| `repo`, `spec_slug` | This specification | `REF-CLAIMED` |
| `role` | `"parent"` \| `"story"` | FR-012 |
| `story` | The durable story id, for a bound story | FR-027 |
| `summary` | Last-written summary record | FR-030, FR-052 |

That `origin: human` is what makes US6 work: it is already the trigger for 018's
managed-panel splice, so preserving the human's prose needs no new mechanism —
only the correct origin at binding.

---

## §5 Seeded-not-bound record — new

`.specify/jira/state/<feature-dir>.seed.json`, gitignored, schema `1`
(research R8). Owned by `lib/seed_state.sh`.

| Field | Type | Requirement |
| --- | --- | --- |
| `schema_version` | `1` | — |
| `extension_version` | string | Diagnostics, per run-state precedent |
| `slug` | string | FR-060 — computed once, read on resume, never re-derived |
| `designators` | ordered array of §1 objects | FR-054 order; FR-041 `REF-RESEED` comparison |
| `bindings` | `[]` | FR-049 — explicitly empty, stating zero were performed |
| `plan_digest` | string \| null | FR-064 — the previously displayed plan, for the delta |

### Lifecycle

```
absent ──first run reaches the gate──> present (bindings: [])
present ──same designator set──> resume: re-read Jira, revalidate, re-plan (FR-062, FR-063, FR-064)
present ──different designator set──> REF-RESEED (FR-041)
present ──confirmation passed, binding completes──> deleted
absent + folder exists ──> REF-EXISTS (the crashed-mid-draft case)
```

The record is deleted, not marked done: its absence beside a bound
specification is the ordinary steady state, and a stale record is a trap.

`plan_digest` exists only to satisfy FR-064's delta disclosure. It stores a
digest of the rendered plan, not the plan itself — the plan is always recomputed
from Jira and from the current `spec.md`, never replayed (FR-062, FR-064).

---

## §6 Write plan — new, in-memory only

Produced by `commands/seed.sh`, rendered before the first mutation (FR-033),
predicted identically by `--dry-run` (FR-034).

| Line kind | Fields | Requirement |
| --- | --- | --- |
| `adopt` | key, role, current summary | FR-027 |
| `create-parent` | summary (from free text), description body (from overview) | FR-023, FR-052 |
| `create-story` | drafted user-story title | FR-018 |
| `reparent` | story key; **current parent key, summary, status**; count of children that parent loses | FR-026, FR-051 |
| `scatter-note` | story key, current parent key, remediation | FR-061 — disclosure only, never a write, never an exit-code change |

`reparent` MUST render visually distinct from `adopt` and `create-*` (FR-051):
it is the only line whose blast radius reaches an artifact the operator did not
name.

---

## Traceability

| Entity | Requirements |
| --- | --- |
| §1 Designator | FR-001…FR-008, FR-053, FR-054, FR-055, FR-059 |
| §2 Named issue | FR-013, FR-021, FR-036 (8 classes), FR-037, FR-043 |
| §3 Pinning marker | FR-016, FR-017, FR-018, FR-019, FR-056, FR-057, FR-058, FR-063 |
| §4 Identity marker | FR-027, FR-028, FR-029, FR-030, FR-031 |
| §5 Seed record | FR-040, FR-041, FR-049, FR-050, FR-060, FR-062 |
| §6 Write plan | FR-032, FR-033, FR-034, FR-051, FR-061, FR-064 |
