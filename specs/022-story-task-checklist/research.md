# Phase 0 Research: A Story Carries Its Task List as a Checklist

**Feature**: 022-story-task-checklist | **Date**: 2026-08-09

Six questions. Five are decided here from the code as it stands. The sixth is decided by measurement
against a real Jira instance, and this document specifies the measurement rather than guessing its
result — the spec's own Assumptions section, and Constitution VI's measurement-over-emulation rule,
both require that.

---

## 1. What ADF shape carries the checklist — DECIDED: `bulletList` with a leading glyph

**Question**: the spec (FR-015) requires a rendering that shows each entry's completion state, with no
Marketplace add-on, preferring an interactive one. Jira Cloud's rich-text format has a candidate node
pair for exactly this — `taskList` / `taskItem`, where each item carries `attrs.state` of `TODO` or
`DONE`. Two candidates were carried into planning:

| | Candidate | Shape |
| --- | --- | --- |
| A | `taskList` + `taskItem` | `{type:"taskList", attrs:{localId}, content:[{type:"taskItem", attrs:{localId, state:"TODO"\|"DONE"}, content:[…spans]}]}` |
| B | `bulletList` with a leading glyph | the existing `bulletList` renderer, each item's first span being `"☑ "` or `"☐ "` |

**Decision**: **candidate B ships.** Candidate A is not a supported API contract.

**The measurement**, taken against Atlassian's published sources rather than a live instance — which is
what made it decisive, because what a single instance accepts today is weaker evidence than what
Atlassian commits to:

- **`taskList`/`taskItem` are not in the ADF node reference.** `developer.atlassian.com/cloud/jira/
  platform/apis/document/nodes/taskList/` returns **404**, and the [ADF structure page](https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/)
  states that nodes present in the JSON schema "may not be valid in a given implementation".
- **The nodes exist, but as an undocumented internal of the Action items feature.** Atlassian's
  [official announcement](https://community.atlassian.com/forums/Jira-articles/Introducing-Action-items-in-Jira/ba-p/2876018)
  (Jira Product Manager, 20 Nov 2024) describes "lightweight, checklist-style tasks embedded directly
  within your Jira issues", present "in the description and comment fields", and interactive in Jira's
  own UI. It justifies the feature by saying sub-tasks "can feel overwhelming for smaller, ad-hoc
  tasks" — this feature's own argument. It says nothing about API access, and points readers wanting
  more to Marketplace checklist apps.
- **Every primary source that tried the REST API failed.** The [one thread carrying a real ADF
  payload](https://community.atlassian.com/forums/Jira-questions/How-to-add-a-action-item-using-a-Rest-API-rest-api-3-issue/qaq-p/3129075)
  received `HTTP 400 INVALID_INPUT`; its accepted answer states the capability "is not *publicly*
  supported yet, and it is not in the ADF documentation". [A second
  thread](https://community.atlassian.com/forums/Jira-Service-Management/Create-a-actual-task-item-in-ticket-description-via-API/qaq-p/3033616)
  closes on "Cant be done via API".
- **Official support is an open suggestion, not a commitment.** [JRACLOUD-85414](https://jira.atlassian.com/browse/JRACLOUD-85414)
  — "Manage Action items in Jira via JQL or REST API or Automations" — is **Gathering Interest**,
  unresolved, with no Atlassian response.

**Why that settles it rather than merely discouraging A.** The question stopped being *"which rendering
does Jira accept"* — a measurement — and became *"is the shipped task tier built on an undocumented node
Atlassian has not committed to"*. Constitution VII forbids hard-coding assumptions about a given
project's Jira; an undocumented node is the same bet made against Atlassian's roadmap instead of against
a project's configuration. FR-015 accepts B in terms — "a rendering that merely *states* each entry's
completion state legibly satisfies this requirement" — so B is a compliant rendering, not a degraded one.

**What choosing B buys, beyond compliance:**

- `bulletList` is a node the sink already emits (016) and the boundary gate already lists, so it cannot
  be rejected and needs no new token in `.github/workflows/boundary.yml`.
- **`bulletList` carries no identity attribute**, so §2's `localId` question — this feature's stated main
  risk — does not arise. The comparison normalisation in `contracts/checklist-rendering.md` §5 becomes
  the identity function, and is kept only as a defensive no-op.
- The renderer no longer waits on a live instance. T001 is requalified from a **blocking measurement**
  to an **optional pre-release verification**.

**The cost, stated plainly**: no clickable checkbox. A reader sees ☑ and ☐ and knows what is done; they
cannot tick it in Jira — which FR-026/FR-028 forbid mattering anyway, since `tasks.md` is the source of
truth and a tick in Jira is drift to be reported and overwritten.

**Revisiting A** is a separate, later change, conditioned on Atlassian documenting the nodes and
JRACLOUD-85414 moving off Gathering Interest. It would rewrite every existing checklist's bytes once, so
it belongs to a release that says so, not to a silent upgrade.

**Alternatives rejected**: a Marketplace checklist app's custom field (ruled out by FR-015 and the
spec's Out of Scope — it would need per-project discovery and a degradation path for every project
without the app); a checklist in a Jira *comment* rather than the description (a comment is not managed
by the 018/020 boundary, so human-prose preservation and zero churn would both need building from
nothing); a plain paragraph of "3/12 done" (states progress but loses which task, failing FR-014).

---

## 2. How zero churn survives a field Jira may rewrite — LARGELY CLOSED BY §1's DECISION

> **Status after §1.** This section was written while candidate A was live, and it named the feature's
> main risk. Candidate B carries **no identity attribute on any node**, so the specific hazard below —
> Jira regenerating a `localId` and turning every reconcile into a PUT — cannot occur. What remains of
> this section is kept because the *discipline* still applies to anything Jira may normalise, and because
> the comparison-only normalisation ships as a defensive no-op rather than being deleted: it costs one
> function, and it is what makes a future return to candidate A a one-file change. The paragraphs below
> stand as written; read "if A had shipped" over each of them.


**Question**: `plan_managed_description_status` (`plan_apply.sh:608`) decides whether a story's
description is a write by splitting both the current and the new document at the managed marker and
comparing the managed halves through `json_canonical`. The checklist lives inside that managed half. If
Jira normalises anything about the nodes it stores — regenerating a `localId`, reordering attributes,
adding a default — the comparison reports `changed` on every single reconcile, and Constitution II is
violated permanently and invisibly.

**Decision**: introduce a **comparison-only** normalisation. Before the two managed halves are compared,
strip from both every attribute that is identity-of-the-node rather than content: `attrs.localId` on
`taskList` and `taskItem`. The normalisation is applied nowhere else — never to what is sent, never to
what is recorded.

The precedent is exact and already in this file: `_summary_normalise` (`plan_apply.sh:624`) carries the
comment *"For COMPARISON only — never applied to a value recorded or sent."* The new function follows it
in name, placement and discipline.

**Why not avoid `localId` altogether**: it is not optional on these nodes in candidate A. Under candidate
B the question disappears (a `bulletList` has no identity attribute), which is one more reason the probe
is cheap insurance rather than ceremony.

**Why deterministic `localId` values are still required**, even with the normalisation: the value is sent
on every write, and a *randomly* generated one would differ between the planning pass and the writing
pass — the two passes are the same code run twice (`docs/05-reconcile-flow.md`), and a `--dry-run`
preview that disagrees with the run that follows it is its own defect. Scheme:
`<story local_id>-<zero-padded entry ordinal>`. Deterministic, unique within the document, and derived
from nothing a `tasks.md` regeneration can change (FR-017): the ordinal is the entry's position in the
story's own list, not the `T012` reference.

**Alternatives rejected**: comparing a digest of the rendered checklist instead of the nodes (moves the
problem — the digest is computed from the same bytes Jira may have rewritten); skipping the comparison
and always sending the description (a direct Constitution II violation); recording the sent description
verbatim in the identity property and comparing against that instead of against Jira (doubles the
storage, and still cannot tell a human's edit from Jira's normalisation, which is §3's actual job).

---

## 3. How a human's tick is detected as drift

**Question**: FR-027 requires a named warning when the checklist on the ticket differs from the one the
mirror last wrote — ticked, unticked, reworded, added or removed by a person — *before* it is rewritten.
Comparing "what is on the ticket" against "what we are about to write" cannot distinguish a human's edit
from an ordinary `tasks.md` change; both look like a difference.

**Decision**: record what the mirror last wrote, in the identity entity property, and make the decision a
three-way comparison — exactly the shape `contracts/summary-record.md` already defines for summaries
(018). The identity stamp gains one field, `checklist`, holding a **digest** of the normalised checklist
nodes (§2's normalisation, then `git hash-object --no-filters` — the one content hash guaranteed present
and identical on all three hosts, already the run-state cache's primitive per `lib/run_state.sh`).

| current on ticket | recorded | outcome |
| --- | --- | --- |
| — (no record yet) | absent | write, no warning — no record means no warning (mirrors `plan_summary_drift_status`) |
| == recorded | present | nobody intervened; write the desired checklist silently |
| != recorded, == desired | present | a person already made it match `tasks.md`; nothing to protect them from, not drift |
| != recorded, != desired | present | **genuine drift**: emit the FR-027 warning naming the story, then write |

**The one deliberate divergence from the summary contract**: a drifted *summary* is **omitted** from the
payload and only sent under `--on-drift=proceed`. A drifted *checklist* is **warned about and then
written**. This is not an inconsistency to be tidied away — FR-026 states it directly: an entry's state
follows `tasks.md` in both directions because a checklist is content the mirror owns inside the managed
region, whereas a summary is an independent Jira field a Product Owner legitimately owns. The warning is
what Constitution I requires ("a named warning identifying the ticket and the divergent field before any
overwrite decision"); withholding the write is not.

**Alternatives rejected**: storing the full checklist rather than a digest (entity properties have a size
ceiling and a hundred-entry checklist is not small; the digest answers the only question asked of it);
deriving "did a human touch it" from Jira's changelog API (an extra read per story per run, against
feature 021's whole purpose); not detecting it at all (FR-027).

---

## 4. Where the setting lives, and in what shape

**Question**: `field_defaults` is a top-level map keyed by project, written into a marked managed region
of `config.yml`. `hierarchy` is nested under `projects[]` and hand-written. The new setting has to be
both ceremony-written and hand-editable, so which precedent does it follow?

**Decision**: follow `field_defaults`. A top-level `task_mirror` mapping, project key to value, inside its
own managed region:

```yaml
# --- spec-kit-jira:task_mirror:begin ---
task_mirror:
  CONSUMER: checklist
# --- spec-kit-jira:task_mirror:end ---
```

**Rationale**: the ceremony writes this key, and the only byte-preserving writer this project has is
`managed_section_splice`, which replaces the bytes between two marker lines. Splicing a value into a
*nested entry of a sequence* — `projects[]`'s third item's fifth key — is a new and materially harder
operation than replacing a top-level block, and it would have to be written, tested and ported for one
key. Reusing `_config_field_defaults_write`'s shape verbatim (`commands/config.sh:579`) is the KISS
answer, and it inherits that function's four already-tested outcomes: `created`, `written`, `unchanged`,
`inert`. `inert` matters here — a project that has recorded nothing must never have the key introduced
(FR-002, FR-011).

Two consequences for `lib/config.sh`:

- `task_mirror` joins the known top-level keys in `_cfg_schema_errors` (`config.sh:683`), otherwise the
  key is rejected as unknown.
- The retired-key list `["epic_strategy","task_strategy","link_type"]` (`config.sh:733`) is **left exactly
  as it is**. FR-006 requires the retired name to stay retired, and the new name is different, so this is
  a rule to not break rather than code to write — and it earns a regression test that asserts
  `task_strategy` is still refused after this feature ships.

**Alternatives rejected**: `projects[].task_mirror` (above); a value in `config.local.yml` (machine-owned
and gitignored — the wrong layer for a team decision, Constitution V); reusing `task_strategy` (FR-006).

---

## 5. What "a closed question" means in a ceremony with no prompts

**Question**: FR-008 requires the ceremony to "offer the choice as a closed question over exactly the two
accepted values". A reader could take that as an interactive prompt.

**Decision**: it is not a prompt. `grep -rn 'read -r|Read-Host'` across `commands/config.sh`,
`lib/cli.sh` and `commands/Config.psm1` finds no interactive read anywhere in the ceremony — every
"closed question" this project ships is an **enumerated set of accepted values reported with a
copy-pasteable flag**. `_config_field_default_notes` (`commands/config.sh:502`) is the pattern verbatim:

```
config: project CONSUMER, type Story requires a value for Team — choose one of: A, B
        (answer with --field-default 'CONSUMER=Story=Team=<value>')
```

So the new question is a report line naming both values and the flag that answers it, and the flag is
`--task-mirror KEY=<subtask|checklist>`, parsed beside `--issue-type` and `--field-default` in
`lib/cli.sh`.

This is not a workaround, it is the constitution: a prompt inside a lifecycle hook is a hang, and
Constitution III forbids an `after_*` hook failing or blocking its host command. The constitution's own
v1.3.0 amendment note makes the same point about a lockable secret vault.

**Consequence for FR-011** ("when no answer can be obtained… nothing is recorded"): this is the *default*
path, not an error path. A ceremony run with no `--task-mirror` flag records nothing and reports the
question. That is also what keeps FR-002's byte-for-byte compatibility promise: a team that never passes
the flag never gets the region.

---

## 6. How the two modes are gated, and how a switch is noticed

**Question**: today one condition drives the whole task tier — `task_type_id` non-empty, read from the
binding's resolved `task` role (`reconcile.sh:396`, `plan_writes_tasks` returning nothing without it).
Checklist mode needs the tier *on* with no role and no type at all (FR-005).

**Decision**: split the single gate into two independent conditions.

| Condition | Today | After |
| --- | --- | --- |
| Read `tasks.md` and nest `tasks[]` under stories | `task_type_id != ""` | mode is `subtask` **or** `checklist` |
| Assign durable identifiers into `tasks.md` | same condition | mode is `subtask` **only** (FR-031) |
| Plan sub-task writes (`plan_writes_tasks`) | same condition | mode is `subtask` **only** |
| Render a checklist into the story description | — | mode is `checklist` **only** |

Two things fall out of this that are worth stating because they are why the design is small:

- **The neutral document does not change.** `stories[].tasks[]` already carries `title`, `done`, `phase`
  and `attribution` — that *is* neutral checklist content, and `interchange.sh`'s existing rules already
  validate it. No schema version bump, no new engine field, no new engine module. Constitution VIII is
  satisfied by construction rather than by care.
- **`_adf_content_nodes` already receives the whole story object**, `.tasks` included
  (`plan_apply.sh:341` passes `${story}` straight to `adf_render_managed_description`). The renderer
  needs one added argument telling it the mode — a fourth positional parameter defaulting to off, so
  every existing call site stays byte-identical.

**Switch detection (FR-033/FR-034)**, without a single extra Jira read: FR-031 leaves every durable task
identifier already recorded in `tasks.md` untouched. So in checklist mode, a `tasks.md` that still carries
task markers is *exactly* the evidence that sub-tasks were once created — and each marker carries the
recorded issue key, which is what makes FR-034's copy-pasteable query possible and exact:

```
issue in (PROJ-41, PROJ-42, PROJ-43)
```

Not a `LIKE` guess, not a label filter: the literal set of keys the mirror itself created and is now
abandoning. The reverse switch (checklist → sub-task) needs nothing new — those same preserved
identifiers are what `recognition_run` already re-binds to, which is FR-035's "re-binding rather than
duplicating" for free.

**Alternatives rejected**: recording the previous mode in `config.local.yml` to detect the transition (a
second source of truth for a fact `tasks.md` already holds); querying Jira for sub-tasks of each story (a
read per story per run, and it cannot distinguish the mirror's sub-tasks from a human's); doing nothing
and letting the operator notice (FR-034).

---

## Cross-cutting findings

- **The run-state cache needs no change.** `run_state_compose` (`lib/run_state.sh:53`) already hashes
  `config.yml` among its inputs, so editing `task_mirror` invalidates the short-circuit automatically and
  FR-003's "editing it is the only action needed" holds without touching feature 021's code. Worth an
  assertion in the test suite so a future refactor of the input set cannot silently break it.
- **The privacy guard needs no new call site.** The checklist rides inside the story's `description`,
  and `apply_writes` (`plan_apply.sh:1215`) already sweeps every action's body before the first write.
  FR-038 is satisfied by not breaking the existing sweep.
- **Windows portability adds no new surface.** No glob gains a `$'\r\n'`, no new multi-line `jq` read is
  introduced outside `lib/output.sh`, and no new path reaches `curl`. The two hazards in
  `docs/10-windows-portability.md` are untouched — but the conformance corpus still runs on the Windows
  probe before this ships, because "untouched" is a claim and the probe is the measurement.
- **`main` is currently red on `windows-latest`** (a known baseline, unrelated to this feature). Phase 2
  must diff this branch's annotations against `main`'s rather than reading a red Windows run as a
  regression.
