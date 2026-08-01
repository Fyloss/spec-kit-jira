# Contract: Hierarchy Resolution and the Mandatory-Field Gate

How the bridge decides which issue type to write at each level, how it discovers what those types
require, and what it does when it cannot decide. Everything here runs **before** the first write
of a run.

No Atlassian default type name, status name or field id appears in any implementation of this
contract. A reviewer can enforce that mechanically: `grep -REi '"(Epic|Story|Task|Bug|Sub-task)"'`
over `scripts/` must return nothing outside test fixtures.

---

## 1. Inputs

Everything comes from the project's own metadata, persisted in the gitignored binding at
configuration time.

```yaml
issue_types:                        # discovered, order preserved
  - { logical_name: "…", id: "…", hierarchy_level: <int>, subtask: <bool> }
child_type:  { logical_name: "…", id: "…", source: derived | operator }
parent_type: { logical_name: "…", id: "…", source: derived }
required_fields:                    # only for the two written types
  "<issue-type-id>": [ { logical_name: "…", field_id: "…" } ]
```

Every `logical_name` is quoted on write, unconditionally, and a name the reader cannot unescape
refuses with feature 007's located, redacted message rather than truncating the document. A
logical name is opaque text in whatever script the instance uses — the bridge never parses,
translates, normalises, case-folds or pattern-matches it (FR-003b).

### Detecting a binding from before this feature — normative

A binding whose `issue_types` is a name-to-id **map** rather than a list of objects was written by
an earlier version. It MUST be detected explicitly, before any type resolution is attempted, and
refused with `binding-shape-stale` (§6). It is refused, not migrated.

Two behaviours are forbidden here, and both are the natural thing to do by accident:

- It MUST NOT be reported as an unbound project. The project *is* bound; its binding is a
  generation behind. An operator who has already run the ceremony reads "not bound yet" as a bug.
- It MUST NOT be allowed to fall through to type resolution. `.child_type.id` over an old binding
  yields an empty string, the plan context carries an empty issue type, and the run fails much
  later inside the write planner with a message about an incomplete creation — precisely the
  obscure failure this feature exists to remove.

Every existing installation is in this state on its first run after the change. The detection
therefore ships with unit tests in both ports and a conformance scenario, not a release note.

---

## 2. Deriving the child level

The child level is the **lowest hierarchy level occupied by a non-sub-task type**. In practice
Jira numbers this level `0`, but the rule is expressed as a minimum over the discovered set so no
number is compiled in either.

```text
candidates := issue_types where subtask = false
child_level := min(hierarchy_level over candidates)
child_candidates := candidates where hierarchy_level = child_level
```

`child_candidates` almost always holds several types — Story, Task and Bug in a default project.
The level therefore identifies the *tier*, not the *type*, and the type comes from the binding's
recorded `child_type`:

| `child_candidates` at configuration time | `child_type.source` | How it was decided |
| --- | --- | --- |
| exactly one | `derived` | The single candidate |
| two or more | `operator` | The configuration ceremony asked a closed question and recorded the answer |

At **reconcile** time no derivation happens for the child: `child_type.id` is read from the
binding. A binding with no `child_type` refuses (§6, `child-type-unresolved`).

> **Why the type is not derived at reconcile time.** The base level is ambiguous in essentially
> every real project — including this repository's own company-managed fixture, where `Story` and
> `Defect` both sit at level 0. Deriving would mean guessing; refusing would mean refusing every
> consumer. The ceremony asks once, records the answer with its provenance beside `style` /
> `style_source`, and the reconcile path reads a settled fact. See research R1 and R2.

---

## 3. Deriving the parent level

The parent level is the **lowest hierarchy level strictly above the child level that is occupied
by a non-sub-task type**.

```text
above := issue_types where subtask = false and hierarchy_level > child_level
parent_level := min(hierarchy_level over above)
parent_candidates := above where hierarchy_level = parent_level
```

| `parent_candidates` | Outcome |
| --- | --- |
| exactly one | That type is the parent type. `source: derived`. |
| zero | **Refuse** — `no-parent-level` (§6) |
| two or more | **Refuse** — `parent-level-ambiguous` (§6) |

The parent is derived at configuration time *and* re-derived at reconcile time from the same
persisted `issue_types` list; the two must agree, and a disagreement means the binding was edited
by hand and is refused as stale.

**Worked examples**, all from real or fixture data:

| Project | Levels | Child level | Parent |
| --- | --- | --- | --- |
| Default Scrum | Epic 1, Story 0, Task 0, Bug 0, Sub-task -1 | 0 | Epic |
| Company-managed fixture | Initiative 2, Deliverable 1, Story 0, Defect 0, Sub-task -1 | 0 | Deliverable |
| SAFe | Epic 2, Feature 1, Story 0, Sub-task -1 | 0 | Feature |
| Localised Jira (Latin diacritics) | Épopée 1, Récit 0, Tâche 0, Sous-tâche -1 | 0 | Épopée |
| Localised Jira (non-Latin) | エピック 1, ストーリー 0, Задача (QA) 0, サブタスク -1 | 0 | エピック |
| Team-managed, flat | Story 0, Sub-task -1 | 0 | **refused** — `no-parent-level` |
| Two at the parent tier | Capability 1, Feature 1, Story 0 | 0 | **refused** — `parent-level-ambiguous` |

**Why the parent is never asked for and the child is.** The ambiguous parent tier is a genuine
edge case; the ambiguous child tier is the norm. FR-006 refuses on parent ambiguity precisely
because that refusal firing at a real consumer is the evidence that the parent-type configuration
key — recorded in the spec's Out of Scope — has become necessary. Answering the question in the
ceremony instead would erase the signal.

---

## 4. Create metadata, per written type

For each of the two written types, at configuration time:

```http
GET /rest/api/3/issue/createmeta/{projectKey}/issuetypes/{issueTypeId}
```

Two requests per configuration run, never per reconcile. Today there is one, against
`.issueTypes[0].id` — whichever type the project happened to list first — which is why the parent
level's own field schema has never been seen.

From each response the binding keeps:

| Kept | From | Used for |
| --- | --- | --- |
| `required_fields[typeId]` | every `fields[]` entry with `required: true` | The gate in §5 |
| `parent` availability | whether a `fields[]` entry has `fieldId: "parent"` | Whether a child creation may carry a parent reference |
| estimation candidates, flagged field | unchanged | Existing behaviour, now sourced from the child type rather than an arbitrary one |

**The parent link is read, never assumed.** The bridge does not encode a rule about
company-managed versus team-managed projects, about Epic Link versus `parent`, or about which
generation of Jira the site runs. The child type's own create metadata says whether `parent` is
offered; if it is not, the run refuses with `parent-link-unavailable` rather than sending a
payload for Jira to reject.

---

## 5. The mandatory-field gate

Runs after derivation and before recognition, so no read and no write has happened yet.

For each written type, a required field is **satisfied** when the bridge supplies it from what it
already knows:

| Field | Satisfied by |
| --- | --- |
| `summary` | The title from the neutral document |
| `description` | The rendered description |
| `issuetype` | The derived type |
| `project` | The routed project key |
| `parent` | The parent's key — on the child type only; on the parent type a required `parent` is unsatisfiable |
| `priority` | The two-step priority resolution, when the level maps to a discovered priority |
| `reporter` | The authenticated account, which Jira fills |
| anything else | **Not satisfiable.** Refuse. |

The gate emits one refusal listing **every** unsatisfiable field of **every** written type — not
the first one it finds. An operator fixing three fields should learn about three fields in one
run.

```text
reconcile: issue type "Deliverable" requires fields this bridge cannot supply: "Business Owner",
"Program Increment". Issue type "Récit" requires: "Team".
Nothing was written (zero writes).
Either make these fields optional for these types in the project's field configuration, or create
the parent and its stories by hand and record their keys in specs/…/spec.md.
```

**`--dry-run` predicts this refusal exactly**, naming the same types and the same fields in the
same order, and predicts no writes. FR-025 depends on the gate running at the same point in both
modes, which it does because it runs before the first read.

---

## 6. Refusals

Every message names what failed, where, and what to do. All are emitted through
`_reconcile_fault`, so a direct invocation returns the code and a lifecycle hook emits one
`WARNING: … (exit N). This spec-kit command completed normally.` and returns 0.

| Reason | Exit | Message |
| --- | --- | --- |
| `no-parent-level` | 4 | `reconcile: project <KEY> offers no issue type above its <CHILD> level, so a specification has nowhere to hang. Its non-sub-task types are: <LIST>. A parent level must exist in the project before it can be mirrored (zero writes).` |
| `parent-level-ambiguous` | 4 | `reconcile: project <KEY> offers more than one issue type at the level above <CHILD>: <LIST>. The bridge will not choose one for you (zero writes).` |
| `child-type-unresolved` | 4 | `reconcile: project <KEY> has no recorded issue type for user stories. Run /speckit.jira.config to record it (zero writes).` |
| `binding-shape-stale` | 4 | `reconcile: the local binding for <KEY> predates parent support and does not record issue-type hierarchy. The project is bound — its binding is simply a version behind. Run /speckit.jira.config to refresh it (zero writes).` |
| `parent-link-unavailable` | 4 | `reconcile: issue type <CHILD> in project <KEY> does not accept a parent reference, so its stories cannot hang from a parent (zero writes).` |
| `mandatory-fields-unsatisfiable` | 4 | *(see §5)* |

`<LIST>` is the candidates' logical names in discovered order, comma-separated — the names the
operator sees in Jira, never ids.

**None of these is a transport error.** FR-024 requires a rejected creation never to surface as a
generic transport failure again, and the gate is how: the refusal happens before the request that
would have been rejected.

---

## 7. Parent recognition

Runs after the gate, before any story is planned. One read, by the recorded key, never a search.

```http
GET /rest/api/3/issue/{key}?properties=spec-kit-jira&fields=summary,description
```

| Marker state | Read | Result | Stories |
| --- | --- | --- | --- |
| `absent`, `assigned` | *(none)* | `new` | planned |
| `creating`, `malformed`, `duplicate` | *(none)* | `blocked` | **none planned** |
| `bound` | 404 | `new`, re-created, noted in the summary | planned |
| `bound` | ok, `role: parent`, same `repo` + `spec_slug` | `bound` | planned |
| `bound` | ok, different `repo` or `spec_slug` | `blocked` | **none planned** |
| `bound` | ok, no identity property, or no `role` | `blocked` | **none planned** |
| `bound` | auth / network / exhausted retries | *(propagate the code, zero stdout)* | **none planned** |

An inconclusive read is **never** downgraded to "no parent exists". That downgrade is exactly the
defect spec 005 was written to fix, and applying it to the parent would re-create the parent —
and therefore duplicate the entire hierarchy — on every network blip.

---

## 8. Zero-churn on the parent

A recognised parent is written to only when its bridge-owned content differs. The comparison
reuses `idempotency_field_status` on `{summary, description}`, and on a parent whose description a
human has edited it reuses `plan_managed_description_status` so prose above the managed panel is
compared out.

A parent has no status target, no Flagged handling and no blockers, so `plan_lifecycle` continues
to fold over stories alone. There is no transition to withhold on a parent and none is emitted.

**The second-run assertion** of Constitution II is extended by one write kind. The live suite must
assert `0 created / 0 updated / 0 transitioned / 0 commented / 0 linked / 0 labeled` **and** that
no parent reference was written, over a run that includes a parent.

---

## 9. Retired configuration keys

Not hierarchy, but validated at the same moment and refused through the same path.

`epic_strategy`, `task_strategy` and `link_type` are retired. A team configuration declaring any
of them is refused:

```text
config: .specify/jira/config.yml projects[0] declares `epic_strategy`, which this version of
spec-kit-jira no longer uses. Delete the line (zero writes).
```

One error per occurrence, naming the key, the project index and the file.

**This requires an explicit rule; it is not free.** The validator's unknown-key check is scoped to
the top level (`version_compat`, `projects`, `routing`, `routing_default`, `privacy`, `teams`) and
to `config.local`, `hooks`, `personal` and `override`. There is no unknown-key check inside
`projects[]` entries in either port, so deleting the three validation rules would accept a stale
`epic_strategy: per_repo` in silence. Both ports need the retirement rule, added in the same
commit.

### `projects[].issue_types` — deleted, not retired, not reserved

A fourth key resolves to nothing today: `projects[].issue_types`, declared in
`tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira/config.yml` as
`{Epic: "10001", Story: "10002"}`. It is read by nothing and rejected by nothing.

It is treated differently from the three above, deliberately (research R11):

| | The three retired keys | `projects[].issue_types` |
| --- | --- | --- |
| In the shipped template | yes | **no** |
| In a consumer's committed file | yes | **no** |
| Action | refuse by name (above) | **delete from the fixture** |
| Retirement rule | required | **none** — no subject exists in the field |

It is **not** reserved as the slot for the future committable Story-versus-Task switch. That
switch declares a logical **name** the operator writes by hand — `story_type: Récit` — resolved to
an identifier through the binding, the shape `priority_map` already uses. `issue_types` is a
name-to-**identifier** map, and identifiers are instance facts that belong in the gitignored
binding under Constitution V. The fixture proves the hazard on its own: its committed map says
`Story: "10002"` while its own binding says `Story: "10004"` — two committed sources of one truth,
already disagreeing, in the fixture that exists to exercise reconcile.

An operator who invents the key still has it accepted in silence. Closing that is the general
unknown-key check inside project entries, which stays in the spec's Out of Scope with this fixture
recorded as the evidence for doing it next.
