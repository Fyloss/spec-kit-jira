# Phase 0 Research: A Specification Mirrors as a Jira Hierarchy

Ten decisions. R1, R2 and R4 are load-bearing: R1 changes what the feature can promise, R2
decides where the answer to R1 lives, and R4 removes an assumption the design would otherwise
have had to make about how Jira attaches a child to a parent.

Every claim about the current code was checked against the tree at `e8e7bb1`, and the file and
line references are there so a reviewer can check them again.

---

## R1 — Hierarchy level alone cannot name the child issue type

**Decision**: The derivation rule "the single non-sub-task type at this level" is correct and
sufficient for the **parent**. It is not sufficient for the **child**, because the base level is
ambiguous by construction. The child's type is therefore resolved from the persisted binding by a
recorded logical name, and the bridge refuses rather than guessing when the binding carries none.

**Rationale**: Jira assigns `hierarchyLevel: 0` to every ordinary work-item type. A default
company-managed project offers Story, Task and Bug there; a default team-managed project offers
Story, Task and Bug there as well. The ambiguity is not an edge case, it is the normal shape.

This repository's own fixtures already prove it:

- `tests/conformance/mock-jira/fixtures/createmeta-issuetypes-company.json` declares
  `Initiative` (level 2), `Deliverable` (level 1), `Story` (level 0), `Defect` (level 0) and
  `Sub-task` (level -1). Level 0 holds two candidates.
- `createmeta-issuetypes-team.json` declares `Epic` (1), `Story` (0), `Sub-task` (-1). Level 0
  holds one, which is why the naive rule looks fine until you read the other fixture.

So a uniform "refuse when the level is ambiguous" rule, applied at the child level, would refuse
`us8-reconcile-company-managed` — an existing, passing conformance scenario — and would refuse
essentially every real project. Applying the rule only at the parent level leaves FR-001 with no
mechanism, because the spec forbids the literal `.issue_types.Story` lookup
(`scripts/bash/commands/reconcile.sh:236`) that stands there today.

The parent level does not have this problem. In the company fixture level 1 holds `Deliverable`
alone; in a default Scrum project level 1 holds `Epic` alone; in a SAFe programme Feature sits
alone at the level between Story and Epic. The parent derivation of FR-002 works, and FR-006's
ambiguity refusal is a genuine edge case there rather than the default outcome.

**Alternatives considered**:

- *Pick the first level-0 type the project returns.* Deterministic per project and free of
  literals, but arbitrary: the company fixture would mirror user stories as `Story` by luck of
  ordering, and a project listing Bug first would mirror them as bugs. Rejected — a wrong answer
  delivered confidently is worse than a refusal.
- *Refuse on child-level ambiguity, uniformly with the parent.* Honest, minimal, and consistent.
  Rejected as the primary design because it makes the feature undeliverable for the one consumer
  it exists to serve. Retained as the fallback in R2 if the ceremony question is not wanted.
- *Match the type name against a list of known story-type names in several languages.* A
  hard-coded Atlassian assumption wearing a disguise. Rejected by Constitution VII outright.
- *Infer from what the parent type accepts as children.* Jira's create metadata does not expose
  the allowed child types of an issue type. Not available.

---

## R2 — Where the child's logical name comes from

**Decision**: From the gitignored `config.local.yml` binding, recorded during the configuration
ceremony with its provenance, exactly as `style` and `style_source` are today. Not from the
committable `config.yml`.

**Rationale**: Constitution V puts "instance-specific resolved ids" in the local binding and
reserves the committable layer for team decisions. Constitution VII requires mappings to reference
logical names resolved to ids on the Jira side. The configuration ceremony already asks closed
questions of exactly this shape and already persists an operator answer with its origin:
`commands/speckit.jira.config.md` step 5 records `style` plus `style_source: "operator"` when the
API signal is ambiguous, and `_disc_style` (`scripts/bash/sink/jira/discovery.sh:65`) prints
nothing at all rather than substituting a default. The child-type question is the same question in
a different field, so it gets the same treatment: derive when the level holds one candidate, ask
when it holds several, persist the answer and where it came from.

Concretely, the ceremony gains one closed question, and the binding gains one field per project:

```yaml
resolved_ids:
  COMP:
    child_type: { logical_name: "Story", id: "10102", source: "operator" }
```

`source` is `derived` when the level held one candidate and `operator` when it held several and
the operator chose. Reconcile reads `child_type.id`; a binding with no `child_type` fails closed
telling the operator to re-run `/speckit.jira.config`.

**Status: signed off 2026-07-31, with two conditions. Condition 1 is below; condition 2 is R11.**

### Condition 1 — the per-developer divergence risk, and why the committable key has a date

`style` and the child type look like the same kind of question and are not, in one way that
matters. `style` is an **objective property** of the Jira project: every developer who asks gets
the same answer, so a per-machine binding can hold it safely. The child issue type is a **team
preference**: in a project offering both, `Story` and `Defect` are each a legitimate answer, and
nothing about the project decides between them.

Because `config.local.yml` is gitignored, every developer answers independently. Two developers
on the same repository, mirroring into the same Jira project, can therefore create new
specifications as different issue types. Each mirror stays internally consistent and idempotent —
identity is keyed on the marker, not the type — so nothing breaks. What degrades is the project's
backlog, and it degrades invisibly: nobody notices until someone reads the issue types.

The consequence for scheduling is precise, and it is recorded in the spec's Out of Scope with a
trigger rather than as an undated follow-up:

- The committable, team-wide key is **required before the extension is rolled out to a second
  team**. That is the moment two developers with different answers become likely.
- It is **purely additive**. A project entry declaring the key uses it; one that does not falls
  back to the local answer, exactly as this feature behaves. No existing configuration changes
  meaning, and no consumer edits a committed file to keep working.
- The cost of deferring it is therefore **inconsistency at rollout, not breakage** — which is why
  it is a scheduled follow-up rather than a blocker on this feature.

Note the asymmetry with the parent-type key, also in Out of Scope: that one has a *conditional*
trigger (FR-006's ambiguity refusal firing at a real consumer) because an ambiguous parent tier is
genuinely rare. The child-type key has a *dated* trigger, because the ambiguity is the norm.

**This is the one place the plan goes beyond the spec, and it is flagged rather than absorbed.**
The spec's Out of Scope says "the child issue type is NOT configurable in this feature". What
stays out of scope under this decision is the *committable, team-wide* Story-versus-Task switch —
a key in `config.yml` that one tech lead sets for everybody and that a reviewer sees in a pull
request. What comes in scope is a per-developer, machine-local disambiguation answer with no
committed footprint. The distinction is real, but it should be stated plainly: because level 0 is
ambiguous in nearly every project, this question will fire for nearly every operator, so in
practice the operator does pick the story type at configuration time.

**Alternatives considered**:

- *Add `story_type: Récit` to the committable `config.yml` now.* Defensible: Constitution VII
  says the issue-type hierarchy must be configurable, and the rollout window for committed-format
  changes closes at the same moment as the two changes this feature already makes. Rejected as the
  default because the spec explicitly excludes it and because the local binding satisfies the
  requirement without touching a committed file. If you prefer this, it is a one-key change to
  `contracts/hierarchy-resolution.md` and two tasks.
- *Refuse on child-level ambiguity and ship nothing else.* The R1 fallback. It keeps the
  configuration ceremony untouched at the cost of leaving the consumer unable to run. Recorded as
  the reversal path.

---

## R3 — The parent marker cannot collide with the implicit story marker

**Decision**: The parent marker is a new key in the existing grammar,
`<!-- speckit-jira spec=<16 hex> -->`, spliced immediately after the document's H1. It reuses
`story_marker.sh`'s byte-offset primitives, line-ending detection, atomic write and `creating`
state; the shared primitives are lifted so `spec_marker.sh` can call them without duplicating a
single splice routine.

**Rationale**: The obvious hazard is placement. `_smk_scan_anchors`
(`scripts/bash/engine/story_marker.sh:139`) anchors on every `^#{2,4}\s+User Story` heading, and
when a specification has none it falls back to the document's first H1 — the same line the parent
marker sits under. If the parent marker counted as "a marker in this section", a specification
with no user-story headings would never get its implicit story marker assigned, and that story
would be silently dropped from every run.

It does not count, and the reason is already in the code: `story_marker_parse_line`
(`story_marker.sh:72`) matches the body against `^story=([^\s]+)(\s+(.*))?$` and returns
`{"kind":"none"}` for anything else, including `spec=...`. `_smk_section_has_marker`
(`story_marker.sh:167`) skips every `kind == "none"` line. So the two markers are mutually
invisible by construction rather than by convention. A regression test pins this exact case: a
specification with an H1, no `User Story` headings, and a `spec=` marker must still receive its
own `story=` marker.

The same property gives forward compatibility for free. A bridge version that predates this
feature reads a `spec=` line as `kind: "none"` — an ordinary comment — and neither trips over it
nor rewrites it.

**Alternatives considered**:

- *A separate marker vocabulary, e.g. `<!-- speckit-jira-parent id=... -->`.* Rejected: the
  generic prefix regex `^<!--\s+speckit-jira\s+(.*)-->\s*$` already frames every marker, and a
  second vocabulary would need its own parser, its own splice and its own tests for the same job.
- *Front-matter instead of a comment line.* Rejected: not every specification has front-matter,
  adding one would rewrite the top of the file, and Constitution XVI wants a marker a developer
  understands on sight.
- *Placement at the end of the file.* Rejected: the identifier belongs beside the thing it names,
  and the H1 is the parent's own title.

---

## R4 — The parent link is read from create metadata, never assumed

**Decision**: A child creation carries `fields.parent = {"key": "<parent key>"}`. Whether that
field is available is read from the child type's own create metadata rather than assumed, and the
same fetch supplies the required-field set for FR-022 and the estimation candidates already
consumed today.

**Rationale**: Jira Cloud's REST v3 create metadata for a single issue type
(`GET /rest/api/3/issue/createmeta/{projectIdOrKey}/issuetypes/{issueTypeId}`) returns a `fields`
array whose entries already carry everything three separate requirements need:

```json
{"fieldId": "summary", "name": "Summary", "required": true, "schema": {"type": "string"}}
```

`required` is the mandatory-field detection of FR-022, verbatim and already present in this
repository's fixtures (`createmeta-fields-company.json` carries `"required": true` on `summary`
and `false` on the rest). `name` is the logical name FR-022 asks refusals to use. And the presence
or absence of a `parent` entry answers whether this project accepts a parent reference on that
type, which means the bridge never has to encode a rule about company-managed versus team-managed
projects, or about Epic Link versus parent, or about which Jira generation the site is on. The
project's own metadata says.

This makes FR-021 cheap rather than merely necessary. Today `discover_binding`
(`scripts/bash/sink/jira/discovery.sh:176`) fetches this document once for
`.issueTypes[0].id` — whichever type the project happened to list first — and mines it only for
estimation candidates and the flagged field. The change is to fetch it for each type the bridge
writes to (two) and to keep three facts per type instead of one.

**Alternatives considered**:

- *Assume `parent` and let Jira reject the payload.* Exactly the "rejected creation surfacing as
  a generic transport error" the spec forbids in FR-024. Rejected.
- *Branch on project style.* Style already exists in the binding, so it is tempting. Rejected:
  it encodes an Atlassian assumption that has changed once already and would be a Constitution VII
  violation, when the metadata answers directly.
- *Fetch create metadata for every issue type in the project.* Rejected by KISS and by cost: the
  bridge writes two types, so it reads two. A project with fifteen types would otherwise pay
  fifteen requests at every configuration run.

---

## R5 — The persisted binding must stop flattening issue types

**Decision**: `config_resolved_ids_for` keeps `hierarchy_level` and `subtask` per issue type, and
gains a per-type `required_fields` list. The binding's `issue_types` becomes a list of objects
rather than a name-to-id map.

**Rationale**: This is the second of the three defects and the least visible. Discovery reads the
hierarchy correctly — `discovery.sh:213` emits
`{logical_name, id, subtask, hierarchy_level}` for every type — and then
`config_resolved_ids_for` (`scripts/bash/commands/config.sh:107`) reduces it to
`{logical_name: id}` before writing it into `config.local.yml`. The level and the sub-task flag
are discarded at the exact moment they become durable, so the reconcile path — which reads only
the persisted binding — could not resolve by hierarchy even after the literal lookup is fixed.
Every other repair in this feature is blocked on this one.

The shape change is not backward compatible, and it should not pretend to be: a binding written by
an earlier version carries a map where the new code expects a list.

**The stale-binding refusal gets its own message and its own test.** An earlier draft of this
decision said reconcile would reuse the existing "project has not been bound yet" message. That is
wrong twice over. It is inaccurate — the project *is* bound, its binding is simply a generation
behind — and it is unhelpful, because an operator who has already run the ceremony reads
"not bound yet" as a bug rather than as an instruction. Worse is the failure mode if nothing
detects the shape at all: `jq -r '.child_type.id'` over an old binding yields an empty string, the
plan context carries an empty issue type, and the run fails much later inside `plan_writes` with
a message about an incomplete creation — the obscure failure this feature exists to eliminate.

So the detection is explicit and the message is distinct
(`binding-shape-stale` in [contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md)
§6): the binding predates parent support, re-run `/speckit.jira.config`.

This is not a hypothetical path. Every existing installation is in exactly this state on the first
run after the change, the maintainer's own machine first of all. It therefore ships with a test in
both ports and a conformance scenario, not a release note — quickstart Step 3b.

The remedy itself stays a one-command remedy that costs nothing: the binding is gitignored,
machine-local and regenerated by discovery in seconds.

**Alternatives considered**:

- *Keep the map and add a parallel `hierarchy` section.* Two structures describing the same types,
  free to disagree. Rejected.
- *Re-derive the hierarchy at reconcile time with a fresh `createmeta` call.* Rejected: it puts a
  network round-trip on the reconcile path for a fact that does not change between runs, and it
  would fail closed on a network blip where a persisted fact would not.
- *Migrate the old shape in place on read.* Rejected by YAGNI: one consumer exists, the file is
  gitignored, and a migration branch would be dead code within a week.

---

## R6 — The identity marker gains a role, not a second property

**Decision**: The identity marker keeps its single entity-property key and gains a `role` field
whose value is `parent` or `story`. A parent's marker is
`{origin, repo, spec_slug, role: "parent"}`; a story's is
`{origin, repo, spec_slug, role: "story", story: "<id>"}`.

**Rationale**: `identity_marker` (`scripts/bash/sink/jira/identity.sh:33`) already builds
`{origin, repo, spec_slug}` and appends `story` only when a story id is supplied — the
feature-naming ceremony and the mentioned-ticket flow deliberately omit it. That means "no `story`
field" already has an established meaning, and it is *not* "this is a parent". Overloading it
would make a feature-ceremony ticket indistinguishable from a parent artifact, which FR-015
forbids. An explicit `role` is one field, reads correctly to a human inspecting the property, and
leaves the existing omission semantics untouched.

`identity_claimed_by_other` compares `repo` and `spec_slug` only, so it keeps working unchanged
for both roles: a parent claimed by another specification is detected by the same comparison a
story is.

**Alternatives considered**:

- *A second entity property, `spec-kit-jira-parent`.* Rejected: a second read per ticket, two
  places for one truth, and `_recognition_read` already folds the single property into the issue
  GET (`recognition.sh:41`) so there is nothing to gain.
- *Infer the role from the issue type.* Rejected: the type can be changed in Jira by a human, and
  Constitution II forbids keying identity on anything mutable.

---

## R7 — The parent is a planning step, not element zero of the action array

**Decision**: `plan_writes` returns `{parent: <action|null>, stories: [<action>, ...]}` instead of
a flat array. `apply_writes_with_recognition` performs the parent action first, reads the created
key from its response, and injects that key as `fields.parent` into every story action before
performing it.

**Rationale**: The obvious design is to prepend the parent to the existing array and let the
existing loop run. It cannot work, and the reason is ordering rather than style. Every child's
payload needs the parent's issue key, and on a first run that key does not exist until the parent
has been created and Jira has answered. A pre-computed flat array would have to carry a
placeholder and rewrite itself mid-loop, which defeats the property that makes `--dry-run`
trustworthy: today the dry-run report *is* the action set, byte for byte (FR-033 depends on this).

Splitting the structure keeps that property. In dry-run the parent action is reported with the
identifier the run assigned and the children are reported with a resolved-at-apply-time parent
reference, which is exactly what the real run will do; nothing is invented and nothing is
rewritten. On a run where the parent is recognised rather than created, its key is known before
planning, so the children carry it literally and the parent action is `null` — the zero-write
second run of FR-034.

The split also expresses FR-012 structurally rather than by convention: if the parent action fails
or is refused, the stories array is simply never reached. A story cannot be orphaned by a
half-built hierarchy because there is no code path that reaches it.

`plan_lifecycle` continues to fold over `stories` alone and is unchanged in behaviour; the parent's
own zero-churn comparison is a separate, simpler case because a parent has no status transition,
no Flagged handling and no blockers.

**Alternatives considered**:

- *Two `plan_writes` calls, one per level.* Rejected: the neutral document would be traversed
  twice and the two calls could disagree about the project key.
- *Create the children first and re-parent them afterwards.* Rejected: it violates FR-012 by
  construction — every child exists orphaned for a window — and it doubles the writes.

---

## R8 — The privacy guard sees the parent first, and that is the point

**Decision**: The pre-write scan runs over the parent's payload and every story payload before any
write, unchanged in mechanism. Because the parent is written first, a blocked parent means zero
writes for the whole specification.

**Rationale**: `apply_writes_with_recognition` (`plan_apply.sh`) already scans every payload in a
first pass and only then enters the write pass, returning `EXIT_BLOCK` with zero writes if any
payload is blocked. Adding the parent to the scanned set is a one-line change to the collection
being iterated. What is worth recording is the consequence: the parent now carries the
specification's success criteria and out-of-scope prose, which is more text than any single story
carries, so the guard's exposure grows. That is the intended direction — a leaked coordinate in a
specification's success criteria should block the mirror — and the allowlist of Constitution IX
continues to neutralise Confluence links and declared corporate domains so the BLOCK tier keeps
its precision.

---

## R9 — Every new refusal reuses `_reconcile_fault`

**Decision**: The six new refusals (no parent level, ambiguous parent level, unresolvable child
type, unsatisfiable mandatory field, retired configuration key, inconclusive parent read) all
return through `_reconcile_fault` with an existing exit code. No new code is written for the
hook-context behaviour of FR-032.

**Rationale**: `_reconcile_fault` (`scripts/bash/commands/reconcile.sh:90`) returns the mapped
exit code on a direct invocation and, under `SPEC_KIT_JIRA_HOOK_CONTEXT`, prints
`WARNING: <message> (exit N). This spec-kit command completed normally.` and returns 0. That is
precisely the split FR-031 and FR-032 describe, already implemented and already covered by tests.
The configuration refusals map to `EXIT_CONFIG` (4); the inconclusive parent read propagates the
transport code it received, unchanged, so Constitution III's monotonic escalation holds.

The retired-key refusal needs one thing the existing code does not provide, and R10 covers it.

---

## R10 — Retiring a configuration key is new code, not a deletion

**Decision**: `_CFG_TEAM_ERRORS_JQ` and its PowerShell mirror gain an explicit retired-key rule
naming `epic_strategy`, `task_strategy` and `link_type`, emitting one error per occurrence that
names the key, the project index and the file.

**Rationale**: The working assumption was that deleting the three validation rules would produce
the refusal for free, because the validator already rejects unknown keys. It does not. The
unknown-key rule is scoped to the **top level** —
`keys_unsorted[] | select(IN("version_compat","projects","routing","routing_default","privacy","teams")|not)`
at `scripts/bash/lib/config.sh:620`, mirrored at `scripts/powershell/lib/Config.psm1:678` — and
the same check exists for `config.local`, `hooks`, `personal` and `override`. There is **no
unknown-key check inside `projects[]` entries** in either port; project entries are validated
field by field. Deleting the three rules would therefore accept a stale `epic_strategy: per_repo`
in silence, which is option C of the clarification and the outcome the spec rejects.

There is corroborating evidence that this gap already bites: the conformance fixture
`tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira/config.yml` declares a
project-level `issue_types:` map that no code reads and no validator rejects. It has been sitting
there accepted and inert.

**Alternatives considered**:

- *A general unknown-key check inside project entries.* It would catch the retired keys, typos,
  and the dead `issue_types` map above, and it uses an idiom the file already contains four times.
  Rejected here and recorded in the spec's Out of Scope: it changes the outcome for any stray key
  a consumer has, which is a broader blast radius than this feature's requirements justify, and no
  functional requirement asks for it. It is the natural follow-up.
- *Warn instead of refuse.* Settled by the clarification: refuse, with the hook path downgrading
  to a warning through R9.

---

## R11 — `projects[].issue_types` is deleted, not reserved

**Decision**: Delete the stray `projects[].issue_types` map from the conformance fixture that
declares it. Do **not** reserve the key as the syntactic slot for the future committable
Story-versus-Task switch, and do **not** add a retirement rule for it.

**Rationale**: This is condition 2 of the R2 sign-off, and the concern behind it is real —
removing a key now and reintroducing the same shape later means two edits to a committed file
where one would do. Four facts settle it, and the first one dissolves the concern entirely.

1. **It is not in the shipped configuration template.** `templates/config.yml.template` declares
   `key`, `style`, `epic_strategy`, `task_strategy`, `link_type`, `priority_map` and
   `estimation_field` — there is no `issue_types`. The only occurrence in the repository is
   `tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira/config.yml`. So this is
   not a shipped surface like `epic_strategy`; it is a stray key in one test fixture. No
   consumer's committed file contains it, and deleting it edits nothing a consumer owns. The
   "two edits where one would do" cost is zero here.

2. **It is the wrong shape to reserve.** The fixture declares
   `issue_types: {Epic: "10001", Story: "10002"}` — a logical name to **identifier** map.
   Identifiers are instance facts and belong in the gitignored binding (Constitution V). The
   future committable switch declares a **name** the operator writes by hand
   (`story_type: Récit`), resolved to an id through the binding, which is the shape `priority_map`
   already uses and the one Constitution VII prescribes. Reserving `issue_types` would reserve a
   slot shaped for the wrong content.

3. **The fixture already demonstrates the trap.** Its committed `issue_types` says
   `Story: "10002"`; its own `config.local.yml` binding says `Story: "10004"`. Two committed
   sources of one truth, already disagreeing, in the fixture that exists to exercise reconcile.
   Nothing caught it because nothing reads either one of them through this path. A committed
   identifier map is not a slot worth keeping warm.

4. **Keeping it would be incoherent with FR-031.** This feature refuses three keys precisely
   because they resolve to nothing. Leaving a fourth key that resolves to nothing, deliberately,
   makes it impossible for a reviewer to tell which dead keys are intentional.

**No retirement rule is added for it.** The three retired keys need one because they were shipped
and consumers have them; `issue_types` was never shipped, so there is nothing in the field to
refuse. An operator who invents the key still has it silently accepted — which is exactly the gap
the general unknown-key check inside project entries would close. That check stays in the spec's
Out of Scope, and this fixture is now recorded there as the concrete evidence that it is the right
next piece of work.

**Alternatives considered**:

- *Keep the key and grow it into the future switch.* Rejected on fact 2: name-to-id is not the
  shape the switch needs.
- *Add a retirement rule so it refuses like the other three.* Rejected on YAGNI: no consumer has
  the key, so the rule would have no subject outside the repository's own fixture.
- *Add the general unknown-key check now and let it catch this.* Tempting and correct in the long
  run, rejected here on blast radius: it changes the outcome for any stray key any consumer has,
  and no functional requirement of this spec asks for it.

---

## Summary of decisions

| # | Decision | Consequence |
| --- | --- | --- |
| R1 | Hierarchy names the parent's type; it cannot name the child's | The child resolves from a recorded logical name; refusing uniformly would refuse every real project |
| R2 | The child's name is an operator answer in the gitignored binding | **Signed off with two conditions.** The committable format is untouched and the ceremony gains one closed question; the committable key becomes required before rollout to a second team, because developers answer independently |
| R3 | `spec=<id>` is a new key in the existing marker grammar | No collision with the implicit story marker, proven by the parser's own return value |
| R4 | The parent link and the required fields both come from create metadata | No assumption about project style or Jira generation |
| R5 | The binding keeps hierarchy level, sub-task flag and required fields | Old bindings fail closed with their **own** distinct message and a one-command remedy; every existing installation hits this, so it ships with a test |
| R6 | The identity marker gains `role` | A parent is distinguishable from a feature-ceremony ticket |
| R7 | `plan_writes` returns a parent plus stories, not a flat array | Ordering and FR-012 are structural, and `--dry-run` stays exact |
| R8 | The guard scans the parent first | A blocked parent means zero writes for the specification |
| R9 | Refusals reuse `_reconcile_fault` | FR-032's hook split costs no new code |
| R10 | Retiring a key needs an explicit rule | The free-deletion hypothesis is false; verified in both ports |
| R11 | `projects[].issue_types` is deleted, not reserved | It is a fixture-only, name-to-**id** map; the future switch declares a name. No consumer file changes |
