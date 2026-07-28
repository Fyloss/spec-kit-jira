# Phase 1 Data Model: Label-Based Adoption

**Feature**: 003-label-based-adoption | **Spec**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

Every entity below is an in-memory JSON value passed between the engine and the
sink, or a section of an existing on-disk file. **This feature persists nothing
new**: no file is created, and the only thing written anywhere is the identity
entity property on an adopted Jira ticket.

Canonical serialisation (sorted keys, compact form, LF) applies to every JSON
value crossing a port boundary or reaching `--json` output, via the existing
`json_canonical` / its PowerShell twin — that is what makes SC-008's
byte-identity assertion possible.

---

## 1. Adoption configuration (`config.yml` → `adoption:`)

The only new persisted surface. Committable team config, layer 1, credential-free.

| Field | Type | Default | Validation | FR |
|-------|------|---------|-----------|----|
| `adoption.enabled` | boolean | `false` | must be a boolean; absent section ⇒ disabled | FR-001 |
| `adoption.label_prefix` | string | `speckit-adopt:` | non-empty; no whitespace of any kind; prefix + longest implied suffix ≤ 255 characters (Jira's label limit) | FR-002 |

**Rules**

- The `adoption` key is added to the team-config top-level allowlist in
  `_CFG_TEAM_ERRORS_JQ` (`scripts/bash/lib/config.sh`), alongside
  `version_compat`, `projects`, `routing`, `routing_default`, `privacy`,
  `teams`. Without that addition the section is rejected as an unknown key.
- Validation runs at **config load**, before any Jira read. An invalid prefix is
  a located configuration error, exit 4, with nothing searched and nothing
  written (FR-002).
- `enabled: false` (including "section absent") short-circuits the whole command
  before discovery: zero reads against candidate tickets, zero writes (FR-001,
  SC-009).

Schema: [`contracts/adoption-config.schema.json`](./contracts/adoption-config.schema.json).

---

## 2. Adoption target

One per bindable spec artifact in scope. Derived purely from disk — no Jira
involved. Produced by the engine.

```json
{
  "spec_folder": "003-label-based-adoption",
  "level": "feature",
  "story_ordinal": null,
  "project_key": "PROJ",
  "labels": ["speckit-adopt:003-label-based-adoption", "speckit-adopt:003"]
}
```

| Field | Type | Rules |
|-------|------|-------|
| `spec_folder` | string | basename of a directory under `specs/`; must exist on disk |
| `level` | `"feature"` \| `"story"` | a spec yields one `feature` target plus one `story` target per user story parsed from `spec.md` |
| `story_ordinal` | integer ≥ 1 \| `null` | non-null exactly when `level = "story"`; the ordinal the bridge already assigns in `parse_spec` |
| `project_key` | string | resolved by the existing `routing_resolve` (folder prefix → spec label → team catalogue prefix → `routing_default`); FR-004 |
| `labels` | array of string | the exact label values this target implies (§3 below); the *only* values ever searched for (NFR-6) |

**Ordering**: targets are ordered by `spec_folder` ascending, then `feature`
before `story`, then `story_ordinal` ascending. The order is total and
deterministic so both ports emit the same plan bytes.

---

## 3. Adoption label

Not a stored entity — a derived string. The grammar is the whole discovery
signal (research §3).

| Form | Pattern | Applies to |
|------|---------|-----------|
| Full folder | `<prefix><spec_folder>` | `level = "feature"` |
| Story | `<prefix><spec_folder>:us<N>` | `level = "story"`, `N = story_ordinal` |
| Short number | `<prefix><NNN>` | `level = "feature"`, where `NNN` is the folder's leading numbering component |

**Rules**

- The short form is emitted into a target's `labels` **only when exactly one
  spec folder in scope carries that numbering component**. When two folders
  share it, neither gets the short form and both are refused with
  `ambiguous-short-number` if a short-form-labelled candidate would otherwise
  bind (spec edge case).
- Matching is case-sensitive and exact — Jira labels are case-sensitive, and
  normalising would collide two distinct labels into one binding.
- A label carrying the prefix alone, or naming a folder absent from disk, is
  never in any target's `labels` array and therefore never searched: FR-003's
  "never infer" is structural, not a runtime rejection.

---

## 4. Candidate

One per Jira issue returned by discovery, plus its identity read. Produced by
the sink; consumed by the engine as opaque JSON.

```json
{
  "key": "PROJ-42",
  "project_key": "PROJ",
  "labels": ["speckit-adopt:003-label-based-adoption"],
  "parent_key": "PROJ-7",
  "identity": { "origin": "human", "repo": "acme/app", "spec_slug": "003-label-based-adoption" }
}
```

| Field | Type | Rules |
|-------|------|-------|
| `key` | string | the Jira issue key, opaque to the engine |
| `project_key` | string | from `fields.project.key`; compared against the target's routed project (FR-004, FR-005) |
| `labels` | array of string | from `fields.labels`; matched against target `labels` |
| `parent_key` | string \| `null` | from `fields.parent.key`; `null` when the issue has no parent (FR-015) |
| `identity` | object \| `null` | the marker read from `GET /issue/{key}/properties/spec-kit-jira`; `null` when unclaimed (a 404 is "unclaimed", not a failure — existing `identity_read` behaviour) |

**Rules**

- A candidate the operator's credentials cannot see never appears — the search
  simply does not return it, and its target reports zero candidates. There is no
  partial or unauthorised read (spec edge case).
- Identity is read for every candidate **and** for every `--bind` pinned key,
  because the claim check applies identically to both (FR-020).
- Candidates are ordered by `key` ascending within a target, so
  `several-candidates` refusal messages list keys in a stable order across ports.

---

## 5. Explicit binding (`--bind`)

The operator's override, repeatable.

```json
{ "spec_folder": "003-label-based-adoption", "issue_key": "PROJ-42", "level": "feature", "story_ordinal": null }
```

| Field | Rules |
|-------|-------|
| `spec_folder` | must exist on disk; unknown ⇒ **usage error, exit 1, whole run stops, zero writes** (FR-021) |
| `issue_key` | shape-validated in the **sink** (research §9); a malformed key is a usage error |
| `level` / `story_ordinal` | `<folder>` pins the feature-level target; `<folder>:us<N>` pins story N |

**Rules**

- A pinned target **replaces** label discovery for that target and is validated
  exactly like a discovered candidate: routed-project match, claim check, and
  both hierarchy checks, producing the same refusal classes and exit codes
  (FR-020, US4 AS-3).
- When a pin and a discovered candidate disagree, the pin wins and the plan
  states **both** keys — the pinned one and the discovered one it overrode
  (FR-022, US4 AS-5).
- A pin needs no label on the ticket, and adoption never adds one (US4 AS-2,
  Out of Scope).

---

## 6. Adoption scope (`--spec`)

The subset of spec folders the run considers. Repeatable; absent ⇒ every spec
folder on disk.

**Rules**

- A folder outside the scope is reported as **out of scope** with zero reads and
  zero writes against its tickets (FR-026, US6 AS-1). "Zero reads" is the
  assertion: an out-of-scope folder contributes no label to any query.
- A scope naming a folder absent from disk stops the run as a usage error, exit
  1, zero writes (FR-026, US6 AS-3) — same class as FR-021.
- Scope is applied **before** label derivation, so the short-number uniqueness
  test in §3 is evaluated over the folders in scope, not over the whole
  repository.

---

## 7. Adoption plan

The read-only result of the discovery phase. Printed before any write; identical
to the `--dry-run` report; embedded in the run summary (FR-023, FR-024).

```json
{
  "bindings": [
    { "spec_folder": "003-label-based-adoption", "level": "feature", "story_ordinal": null,
      "issue_key": "PROJ-42", "reason": "label-match", "overrode_key": null, "status": "adopt" }
  ],
  "refusals": [
    { "spec_folder": "004-other", "level": "feature", "story_ordinal": null,
      "reason": "several-candidates", "issue_keys": ["PROJ-51", "PROJ-52"],
      "message": "…", "remediation": "spec-kit-jira adopt --bind 004-other=PROJ-51" }
  ],
  "out_of_scope": ["001-jira-reconcile-engine", "002-config-discovery-team-prefix"]
}
```

### 7.1 Binding

| Field | Type | Rules |
|-------|------|-------|
| `spec_folder`, `level`, `story_ordinal` | — | identify the target (§2) |
| `issue_key` | string | the ticket to be stamped |
| `reason` | `"label-match"` \| `"explicit-binding"` | FR-024 requires the reason in the summary |
| `overrode_key` | string \| `null` | non-null only when a pin overrode a discovered candidate (FR-022) |
| `status` | `"adopt"` \| `"already-adopted"` | `already-adopted` when the candidate already carries **this** spec's marker with origin `human` — skipped, counted as skipped, **not** an error (FR-027) |

### 7.2 Refusal

| Field | Type | Rules |
|-------|------|-------|
| `spec_folder`, `level`, `story_ordinal` | — | identify the target |
| `reason` | enum of eight classes (§8) | closed set, so the corpus can assert one fixture per class (SC-005) |
| `issue_keys` | array of string | every key involved — for `several-candidates` that is **all** of them, never a truncated pair (NFR-6) |
| `message` | string | names the spec folder and the keys (Principle XVI) |
| `remediation` | string | a copy-pasteable command line |

### 7.3 Ordering

`bindings` and `refusals` each follow the target order of §2. `out_of_scope` is
sorted ascending. Nothing in the plan depends on the order Jira returned
results — FR-012 forbids result order from influencing any decision, and a
stable plan order is what makes SC-008's byte-identity assertion meaningful.

Schema: [`contracts/adoption-plan.schema.json`](./contracts/adoption-plan.schema.json).

---

## 8. Refusal classes

Closed enumeration. Each leaves **zero writes for its binding**; unambiguous
bindings in the same run still apply (FR-013).

| Class | Trigger | FR | Whole-run or per-binding |
|-------|---------|----|--------------------------|
| `no-candidate` | zero accessible tickets carry the target's labels | FR-009 | per-binding |
| `several-candidates` | more than one accessible candidate | FR-010 | per-binding |
| `already-claimed` | candidate carries **another** spec's marker | FR-011 | per-binding |
| `spec-owns-bridge-ticket` | candidate carries **this** spec's marker with origin `bridge-created` | FR-011 | per-binding |
| `wrong-project` | candidate's project ≠ the target's routed project (reachable only via `--bind`, FR-005) | FR-005 | per-binding |
| `unbound-parent` | a `story` target whose spec's `feature` target is neither already bound nor bound in this run | FR-014 | per-binding |
| `wrong-parent` | candidate's `parent_key` ≠ the spec's bound feature-level key | FR-015 | per-binding |
| `ambiguous-short-number` | two spec folders in scope share the numbering component a short-form label names | edge case | per-binding |

Any per-binding refusal makes the run exit **4**. Whole-run aborts (usage error,
unreliable read, authentication failure, prerequisite failure, privacy block)
leave zero writes overall and return their own code; when classes co-occur, the
highest applicable code wins (FR-013, FR-030).

---

## 9. Ticket identity marker (existing — reused unchanged)

The per-issue entity property `spec-kit-jira`, already defined by feature 001.

```json
{ "origin": "human", "repo": "acme/app", "spec_slug": "003-label-based-adoption" }
```

**Rules**

- Adoption writes `origin: "human"` — the same literal `mention` already writes.
  The bridge-created counterpart on the wire is `bridge-created` (hyphen); the
  spec's `bridge_created` names the concept, not the wire value (research §4).
- **No new field is added to the marker.** Stamping origin `human` is what
  selects, for the rest of the ticket's life: the managed-panel splice below
  human prose (`adf.sh`), the managed-section-only churn diff
  (`plan_managed_description_status`), and the human-origin exclusion from hard
  deletion (FR-017).
- The origin is never rewritten by any later run (FR-016).

---

## 10. State transitions

A ticket's lifecycle through this feature:

```text
unclaimed (no marker)
    │  adopt, confirmed
    ▼
adopted (marker: origin=human, spec_slug=<this spec>)
    │  adopt re-run          → skipped, status "already-adopted", zero writes  (FR-019/FR-027)
    │  first reconcile after → managed panel ADDED below existing prose, human bytes intact (FR-018, SC-002)
    │  every later reconcile → zero writes on an unchanged corpus              (SC-006)
    │  destructive prune     → identity may be detached; ticket NEVER hard-deleted (FR-017)
    ▼
adopted (terminal for this feature; unbinding is Out of Scope)
```

A candidate whose marker names another spec, or names this spec with origin
`bridge-created`, never enters this lifecycle — it is refused (§8) with zero
writes.
