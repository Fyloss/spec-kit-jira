# Data model — reconcile performance

Three entities, one of which is never allowed to exist anywhere but in memory.

Nothing here is part of the neutral interchange document, and nothing here is sent to Jira. The run-state
document is the only new artefact written to disk.

---

## 1. Run state document

The recorded evidence that one specific set of local inputs was mirrored to completion.

**Location**: `.specify/jira/state/<feature-dir>.json`, where `<feature-dir>` is the basename of the
directory holding the `spec.md` being reconciled (e.g. `021-reconcile-performance`). Feature 017's target
guard means reconcile only ever addresses `<feature-dir>/spec.md`, so this name is unique per
specification and is already a filesystem-safe slug on all three hosts.

**Ignored by**: `.specify/jira/state/.gitignore`, containing the single line `*`, written by the bridge
when it creates the directory. A gitignore `*` matches dotfiles, so the ignore file ignores itself and
nothing under that directory can ever be staged — including in a repository bound before this release.

**Serialisation**: canonical JSON via `json_canonical` / the PowerShell twin — stable key order, compact,
raw UTF-8, no trailing newline. The two ports produce identical bytes for identical inputs.

### Fields

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | integer | Shape version of this document. `1` at introduction. A change to the *set* of recorded inputs bumps it, invalidating every existing file. |
| `extension_version` | string | `extension.version` from `extension.yml` at the time of the successful run. Any difference invalidates the state — a bridge upgrade changes rendered output for unchanged inputs. |
| `base_url` | string | The resolved Jira base URL. Re-pointing the bridge at another instance invalidates. |
| `email` | string | The resolved Basic-auth email. A different operator invalidates. Not a secret; already present in the config layer. |
| `on_drift` | string | The drift-handling mode this run was invoked with. It changes which drifted tickets are written, so a run under one mode must never reuse a state recorded under the other. |
| `inputs` | object | Map of relative path → `git hash-object` blob hash. See below. |

There is deliberately **no** `project_key` field. See the note below the `inputs` table.

### `inputs` members

| Key | Present when | Value when absent |
| --- | --- | --- |
| `spec.md` | always | — (a run without it cannot reach the gate) |
| `tasks.md` | the file exists | the key is omitted entirely, so appearing/disappearing invalidates |
| `.specify/jira/config.yml` | the file exists | key omitted |
| `.specify/jira/config.local.yml` | the file exists | key omitted |
| `.specify/jira/personal.yml` | the file exists | key omitted |

Recorded ticket keys are **not** a separate field: they live inside `spec.md` and `tasks.md` as marker
lines, so their hashes already cover every recorded key, every durable identifier, and every binding a
marker expresses. Spec FR-020's "recorded ticket keys" is satisfied transitively, and recording them
twice would create two sources of truth for the same fact.

The **routing decision** is not a separate field either, for the same reason and for one more. Routing is a
pure function of the feature-directory name — which is this document's own filename — and the config files
hashed above, so any change that could re-route the run already changes a hash here. The additional reason is
decisive: `_reconcile_resolve_routing` takes the parsed configuration as an argument, so the routing decision
does not exist until the config phase has run, and the gate is placed deliberately **before** that phase
(§2 of `contracts/run-state.md`, research R7). A `project_key` field would be a field the composer cannot
fill at the moment it composes. Spec FR-020's "resolved routing decision" is therefore satisfied by hashing
routing's inputs rather than recording its output — which is also the stricter of the two.

### Validation rules

- A document whose `schema` is unknown → **no match** (fail open to a full reconcile).
- A document that is unreadable, not valid JSON, or missing any required field → **no match**.
- Any single differing field or hash → **no match**.
- A match requires byte equality of the freshly composed document with the recorded one. There is no
  partial or per-field match, and no repair of a stale document.

### Lifecycle

```text
absent ──(fully successful real run)──> recorded
recorded ──(inputs identical, no --force)──> SHORT-CIRCUIT: exit 0, zero requests, zero writes
recorded ──(any difference, or --force, or unreadable)──> full reconcile
recorded ──(full reconcile completes fully successfully)──> recorded (overwritten atomically)
recorded ──(full reconcile fails / warns / stops for confirmation / is a preview)──> left untouched
```

The state is **never deleted** by the bridge and never repaired. A stale document is invalidated by
comparison, not by maintenance.

### Write discipline

Composed in memory, written to a sibling temporary file in the same directory, then `mv`/`Move-Item`
onto the final name. Two racing reconciles therefore each read a whole document or none. The loser's
write is overwritten by an equally valid document, so a lost update costs at most one full reconcile —
the fail-open direction.

**A credential never enters this document**, in any field, in any form. The `email` and `base_url` it
carries are the two non-secret connection settings that already live in the config layer.

---

## 2. Phase timing record

The elapsed time and request count of one named phase of one run. It exists for the duration of the run,
is emitted on stderr when the timing mode is on, and is never persisted, compared, or transmitted.

### Fields

| Field | Type | Meaning |
| --- | --- | --- |
| `phase` | enum | One of the eight phases below, in this fixed order. |
| `elapsed_ms` | integer | Wall time between this phase's start and end mark. |
| `requests` | integer | `JIRA_REQUEST_COUNT` delta across the phase — curl **attempts**, retries included. |

### The eight phases

`prereq` → `state` → `config` → `parse` → `gate` → `recognition` → `plan` → `apply`

Fixed, identical on both ports, and identical in order. A run that does not reach a phase does not report
it; a run that skips a phase by short-circuit reports the phases it did reach and nothing else. Sub-phases
may exist internally and are never reported — the report is sized for one screen (spec A-5).

Two of these names need pinning to the pipeline, because "gate" is a word this codebase uses for several
different things:

- **`state`** is the run-state short-circuit of §1 above. It sits between the target guard and the config
  phase, so a short-circuited run reports `prereq` and `state` and nothing else. That is why it is a phase
  of its own rather than time folded into `prereq`.
- **`gate`** is the mandatory-field gate — `hierarchy_mandatory_gate` in
  `scripts/bash/commands/reconcile.sh` — which runs after parsing and **before** recognition, not between
  recognition and planning. The drift and zero-churn lifecycle filter, which runs after planning, is a
  sub-phase of `plan` and is not reported separately.

### Invariants

- Confined to stderr. Standard output, exit code, and every written file are byte-identical with the mode
  on and off.
- Carries no credential, no derived authorisation value, and no URL that could contain one.
- Never causes a phase's existing trace suspension to be lifted.
- Whole-second resolution on a host without a sub-second clock, announced in the report rather than
  silently reported as `0` (research R1).

---

## 3. Per-run resolved credential

The token, held in memory for the lifetime of one process. It is listed here to state precisely what it
is *not*.

| Property | Value |
| --- | --- |
| Storage | Bash: a non-exported shell variable. PowerShell: a `$script:`-scoped variable in `Credentials.psm1`. |
| Scope | One process. Subshells inherit the parent's copy; nothing propagates back up, and nothing propagates into a child *process*'s environment. |
| States | `unset` (not yet consulted) → `resolved` (a token is held) or `unresolved` (every rung was consulted and none provided one). |
| Lifetime | Ends with the process. Never written to any file, temp file, run-state document, timing line, log, trace, or transcript. |
| Persistence | None, on any operating system. The OS secret store remains the only persistent store the bridge ever reads a secret from. |
| Rotation | A token rotated or revoked in the secret store takes effect on the very next reconcile; no cache can outlive the run that filled it. |

The `unresolved` state is a distinct value, not an empty string, so a token-less run consults its sources
once and then reproduces today's exit code and message on every subsequent call (spec FR-013).

The derived Basic authorisation value is treated identically to the token in every respect above.

---

## 4. Prefetch map (transient)

Not persisted, not serialised, and listed only because its emptiness is meaningful.

A map from recorded issue key → the issue object returned by `POST /issue/bulkfetch`, populated once per
run before recognition and discarded when the process ends. It has exactly two observable states from a
caller's point of view:

- **hit** — the reader projects the entry down to its own field list and proceeds as if it had performed
  its own `GET`.
- **miss** — the reader performs exactly today's `GET`, and today's status code produces today's
  classification.

An empty map (prefetch not attempted, or failed) means every read is a miss, which is today's behaviour
at today's cost. The map can therefore only ever remove requests; it can never change an outcome, and no
classification in the system is derived from a key's absence from it.
