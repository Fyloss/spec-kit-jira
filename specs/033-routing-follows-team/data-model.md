# Phase 1 — Data Model: The routing fallback follows the developer's team

No new file, no new configuration key, and no new persisted state. This feature
changes one function's inputs and one schema rule; everything below already
exists except where marked **NEW**.

---

## 1. Routing inputs

The resolver's parameters, before and after.

| # | Parameter | Source | Change |
| --- | --- | --- | --- |
| 1 | folder name | the specification's own directory, basename | unchanged |
| 2 | labels JSON | the parser (always `[]` today — labels are not extracted) | unchanged |
| 3 | config JSON | merged `config.yml` + `config.local.yml` | unchanged |
| 4 | selected team id | `personal.yml` `team:`, via `config_personal_load` | **NEW** |

Parameter 4 carries an **id**, never a project key (research R1). It is either a
catalogue-validated id or the empty string. It is never the reason a run fails:
an unknown id has already been refused upstream with its own located error.

**NEW — boundness flag.** Not a resolver parameter. The caller evaluates it and
uses it to decide whether to *supply* parameter 4 at all. An already-bound
specification is routed with parameter 4 empty, which is byte-identical to
today's three-parameter behaviour.

---

## 2. The resolution chain

Four ranks, first non-empty wins.

| Rank | Name | Expression | Evidence it rests on |
| --- | --- | --- | --- |
| 1 | rule route | first `routing:` rule whose every declared condition holds | the specification |
| 2 | team route | first `teams[]` whose `folder_prefix` prefixes the de-numbered folder name | the specification |
| 3 | **personal route** | `teams[]` whose `id` equals parameter 4, its `project` | **the operator** |
| 4 | committed default | `routing_default` | the repository |
| — | refusal | `EXIT_CONFIG` (4), zero writes | — |

Rank 3 is the only rank whose evidence is about the person rather than the
artifact, and it is the only rank that is conditional (§3).

**Invariant.** With parameter 4 empty, the chain is byte-identical to the
pre-feature chain. That is what makes FR-009 true by construction rather than by
inspection: every repository without a selected team takes the same path it took
before.

---

## 3. Rank 3's precondition

Rank 3 is consulted **only** when no story in the specification carries a bound
marker.

| Marker form | Source | Counts as bound |
| --- | --- | --- |
| `<!-- speckit-jira story=<id> ticket=<KEY> -->` | `story_marker.sh:80` | **yes** |
| `<!-- speckit-jira story=<id> creating -->` | `story_marker.sh:79` | no |
| `<!-- speckit-jira story=<id> -->` | `story_marker.sh:81` | no |
| no marker at all | — | no |

Evaluated once per run against the pre-run text of the specification, before any
marker this run assigns. "Bound" therefore means "bound by an earlier run", which
is the property that makes the routing of a given specification stable across
operators.

The other three ranks are unconditional on boundness: they read committed values
every operator resolves identically, so they carry no divergence risk.

---

## 4. Configuration surface

| Key | Layer | Before | After |
| --- | --- | --- | --- |
| `routing` | committed `config.yml` | optional | unchanged |
| `teams[]` | committed `config.yml` | optional | unchanged; `project` gains a second consumer |
| `routing_default` | committed `config.yml` | **required**, must be a project key | **optional**; if present, must still be a project key |
| `team` | gitignored `personal.yml` | governs naming | **also governs routing** (rank 3) |

No key is added anywhere. `personal.yml` deliberately gains no
`routing_default` — the spec records why (one fact, one key).

---

## 5. Validation rules

| Rule | Where | Change |
| --- | --- | --- |
| `routing_default` must be present | `config.sh:875`, `Config.psm1:767` | **removed** |
| `routing_default`, when present, must be a project key | same | **kept, unchanged** |
| `routing_default` is a legal top-level key | `config.sh:877`, `Config.psm1:772` | **kept** — the key stays legal |
| `teams[].project` must be a valid project key | `config.sh:929` | unchanged; now load-bearing for rank 3 |
| the selected team id must exist in the catalogue | `config.sh:1385` | unchanged; runs before routing |
| a resolved project must be declared in `projects[]` | `reconcile.sh:759` | unchanged; already covers a rank-3 result |

The last row matters: a catalogue team naming a project absent from `projects[]`
is already refused with its own message, and rank 3 inherits that refusal without
a new rule.

---

## 6. Refusal states

One message, reporting all four findings (research R6).

| Rank | States to distinguish |
| --- | --- |
| 1 | no rule matched / no `routing:` declared |
| 2 | no team prefix matched / no `teams:` declared |
| 3 | no `personal.yml` / a `personal.yml` selecting no team / rank 3 not consulted because the spec is already bound |
| 4 | no `routing_default` declared |

The third rank-3 state exists so that an operator who *has* selected a team is
never told they have not. Being skipped for boundness and having no selection are
different situations with different remedies, and a message that conflated them
would send the operator to edit a file that is already correct.

---

## 7. What this model does not introduce

- No persisted record of a resolved project. The specification's own markers are
  the record (Constitution I), and adding a second one would create exactly the
  two-sources-of-truth problem FR-004 exists to avoid.
- No per-operator override of a committed routing rule. Ranks 1 and 2 stay ahead
  of rank 3 unconditionally.
- No new exit code. Every refusal in this feature is `EXIT_CONFIG` (4).
