# Contract: Role Mapping

How the bridge decides, for one project, which issue type carries each artifact
the repository mirrors — and what it does when it cannot decide.

Everything here runs **before the first write of a run**. This contract extends
`008/contracts/hierarchy-resolution.md`; where the two overlap, the derivation
rules of 008 §2 and §3 are unchanged and are reached only as this contract's
step 3.

No Atlassian default type name appears in any implementation of this contract. A
reviewer can enforce it mechanically:

```sh
grep -REi '"(Epic|Story|Task|Bug|Sub-task|Sous-t)' scripts/   # must be empty
```

---

## 1. The role set — normative

Exactly three, closed, declared once per port:

```
specification   story   task
```

Any other key inside a `hierarchy` mapping is a configuration error (§6.1). The
set is a compile-time constant of the bridge, not a discovered value — it
enumerates the repository's own artifacts, not Jira's.

---

## 2. Inputs

### 2.1 The declaration — committed, `config.yml`

```yaml
projects:
  - key: PROJ
    hierarchy:            # OPTIONAL, per project
      specification: "…"  # OPTIONAL, an issue type NAME
      story: "…"          # OPTIONAL
      task: "…"           # OPTIONAL
```

Every value is **opaque text**. The bridge never parses, translates, normalises,
case-folds or pattern-matches it — it is compared for byte equality against the
`logical_name` the project reported, and nothing else.

### 2.2 The one-off answer — argv

```
--issue-type <KEY>=<role>=<name>     repeatable; last occurrence per (KEY, role) wins
--child-type <KEY>=<name>            accepted alias for --issue-type <KEY>=story=<name>
```

`<role>` MUST be a member of §1. A malformed value is a usage error (exit `1`),
not a configuration error — it is a mistake in the invocation, not in the
repository.

### 2.3 The project's metadata — discovered

Unchanged from 008 §1: `issue_types[]` with `logical_name`, `id`,
`hierarchy_level`, `subtask`; plus `required_fields` and
`parent_link_available` keyed by issue-type id.

---

## 3. Resolution — normative order

For each role, in one pass over all three:

| Step | Source | `source` recorded |
| --- | --- | --- |
| 1 | `projects[].hierarchy.<role>` | `declared` |
| 2 | the `--issue-type` / `--child-type` answer | `operator` |
| 3 | derivation (§3.1), only when it is unambiguous | `derived` |
| — | otherwise, for `specification` and `story` | **unresolved** → §6.2 |
| — | otherwise, for `task` | **absent** — not an error (§3.4) |

Step 1 outranks step 2 unconditionally. When both are present and disagree, the
declaration wins, the binding converges onto it, and the run reports the
supersession naming both types (§7.2). This is a one-time convergence: the next
run over the same inputs writes identical bytes.

### 3.1 Derivation — when it applies

| Role | Rule | Ambiguous when |
| --- | --- | --- |
| `story` | the lowest `hierarchy_level` over non-sub-task types | that level holds >1 type |
| `specification` | the lowest level **strictly above** the story level | that level holds >1 type |
| `task` | **never derived** | — never ambiguous; **absent** unless declared or answered (§3.4) |

`task` is never derived on purpose: a project having exactly one sub-task type
is not evidence that the team wants a task tier. Deriving it would create
sub-tasks nobody asked for, which Constitution X's self-healing mirror would
then keep creating.

### 3.2 One pass, all roles — normative

Resolution MUST evaluate every role before refusing. A run whose specification
role and story role are both unresolved MUST report **both** in one refusal.

Refusing on the first unresolved role is forbidden. It is what the pre-010
ceremony did — `hierarchy_derive`'s refusal aborted the run before
`_config_resolve_child_type` was reached — and it makes a two-ambiguity project
cost two round trips to diagnose.

### 3.3 Matching — normative

A declared or answered name matches a candidate when the two strings are
**byte-equal**. No trimming beyond the YAML scalar rules, no case folding, no
Unicode normalisation, no prefix matching, no "did you mean".

- Zero matches → §6.3 (unknown type).
- More than one match → §6.4 (duplicate name at a level).

The candidate set for `specification` and `story` is the project's **non-sub-task**
types; for `task` it is the project's **sub-task** types. A name that exists in
the project but in the other set fails §6.3 with the correct candidate list —
which is what makes the message useful rather than merely accurate.

### 3.4 Absent is not unresolved — normative

`task` is the only role the repository does not always mirror. When it is
neither declared (step 1) nor answered (step 2) it is **absent**: the resolver
records no `roles.task`, contributes no `unresolved_roles` entry, raises no
refusal, and the run proceeds exactly as if the role set held two members.

`specification` and `story` are always required. Reaching the end of §3 without
resolving either of them is §6.2.

The distinction is load-bearing. `task` is never derived (§3.1), so treating
"not resolved" as "unresolved" would refuse every project that has not declared
a task tier — the precise opposite of FR-004, and it would break every
installation that configures successfully today (SC-005).

---

## 4. Validation — normative, in this order

Runs after resolution, before any write, in the ceremony and again in reconcile
against the persisted binding (§8).

| # | Check | Refusal |
| --- | --- | --- |
| 1 | every resolved name matched exactly one candidate | §6.3 / §6.4 |
| 2 | `subtask(specification)` and `subtask(story)` are false | §6.5 |
| 3 | `subtask(task)` is true | §6.6 |
| 4 | `level(specification) > level(story)` | §6.7 |
| 5 | `parent_link_available[id(story)]` is true | 008 §6 message, unchanged |
| 6 | the mandatory-field gate over **every selected type** | 008 §5, unchanged |

Levels are compared **numerically** after conversion (`tonumber` / `[int]`). The
persisted `hierarchy_level` is a string — the YAML round-trip has no number type
— so a lexical comparison would order `"-1" > "0"` and is forbidden.

### 4.1 What is deliberately NOT checked

- **Adjacency.** `level(specification)` may exceed `level(story)` by any amount.
  A project offering three tiers may legitimately hang specifications from the
  middle one.
- **Sub-task-ness by level.** The `subtask` flag is authoritative. A project
  reporting a sub-task type at level `0` MUST be handled by the flag; inferring
  it from `-1` is a compiled-in assumption about Jira and is forbidden.
- **Whether Jira will accept the pairing.** Check 5 is the mechanism that
  surfaces a structurally-valid-but-rejected pairing. The bridge does not model
  Jira's own parent rules.
- **The `task` type's mandatory fields, before Phase 8.** "every selected
  type" in check 6 means `specification` and `story` only. Check 6 exists to
  catch a structurally-valid pairing that would still be REJECTED BY A WRITE
  — but until Phase 8 (§7) ships sub-task creation, the bridge never writes a
  `task`-typed issue at all, so there is no write for an unsatisfiable field
  on that type to protect. Gating it now would refuse a project whose task
  tier the bridge will never touch this release, which is a *broader*
  deviation from FR-024's "no behaviour change without a mapping" than
  leaving it unchecked. When Phase 8 adds sub-task creation, that is the
  natural point to extend check 6 to `task` — the same moment
  `hierarchy_mandatory_gate` first reads `.task_type` from the binding.

---

## 5. Persistence — normative

Under `resolved_ids.<KEY>` in the gitignored binding:

```yaml
roles:
  specification: { logical_name: "…", id: "…", hierarchy_level: "…", subtask: false, source: declared|operator|derived }
  story:         { logical_name: "…", id: "…", hierarchy_level: "…", subtask: false, source: … }
  task:          { logical_name: "…", id: "…", hierarchy_level: "…", subtask: true,  source: … }   # only when resolved
child_type:  { logical_name: "…", id: "…", source: … }   # MUST equal roles.story
parent_type: { logical_name: "…", id: "…", source: … }   # MUST equal roles.specification
```

`logical_name` is quoted on write, unconditionally (008 §1).

### 5.1 Dual-write — normative

`child_type` and `parent_type` MUST be written on every run that writes `roles`,
carrying the same `logical_name`, `id` and `source` as `roles.story` and
`roles.specification` respectively.

They remain the keys the reconcile path reads. Writing `roles` without them
would make every binding this release produces look *unresolved* to the
child-type check (`return 7`) of a reconcile that has not been updated in
lockstep — including a colleague's checkout mid-upgrade.

A binding where the two disagree is a bug in the writer, not a state to
tolerate: reconcile MUST NOT attempt to reconcile the difference, and a test
asserts the equality on every fixture.

### 5.2 Idempotency — normative

A second ceremony run over an unchanged project with an unchanged declaration
MUST write byte-identical YAML and MUST emit no question and no supersession
note.

---

## 6. Refusals

Every refusal here exits `EXIT_CONFIG` (`4`) with **zero Jira writes**, and is
downgraded to a single WARNING with a successful return under hook context
(Constitution III). Every message names types by the name the project reported,
never by an id.

`<LIST>` is the candidates' logical names in discovered order, comma-separated.

### 6.1 Unknown role

```
config: projects[<N>].hierarchy declares unknown role `<ROLE>`; the roles are
specification, story, task. Delete or rename the key
```

Raised by the schema layer, before any Jira call — which is why it is indexed by
array position rather than by project key, and why it carries no `(zero writes)`
tail: no Jira call has been made. The `config: ` prefix is prepended by the
caller (`commands/config.sh:421`), and the body follows the retired-key rule's
shape (`lib/config.sh:648-650`). This is the one refusal in §6 raised before
discovery; every other refusal below uses the `config: project <KEY>: ` form.

### 6.2 Unresolved role — the closed question

```
config: project <KEY>: the <ROLE> level (<LEVEL>) holds more than one issue
type: <LIST>. The bridge will not choose one for you (zero writes).
config: declare it in .specify/jira/config.yml under
projects[].hierarchy.<ROLE>, or answer once with
--issue-type <KEY>=<ROLE>=<one of them>.
```

When both roles are unresolved, one block per role, in the order
`specification`, `story`. The `task` role never appears here: it is absent
rather than unresolved (§3.4).

The `--json` summary carries the same information structurally so the agent can
render a closed enumeration rather than re-parse prose:

```json
{"unresolved_roles":[
  {"project":"PROJ","role":"specification","level":"1",
   "candidates":[{"logical_name":"…","id":"…"}],
   "declaration":"projects[].hierarchy.specification",
   "flag":"--issue-type PROJ=specification=<name>"}]}
```

This block MUST be emitted through the port's output module, never a bare `jq`
call — it is multi-line JSON, and the Windows `jq` build emits CRLF on
multi-line output (`docs/10-windows-portability.md`).

**FR-008 and FR-009 are this one path.** The bridge never prompts; the agent
reading this output asks the human and re-invokes. Adding an interactive prompt
is forbidden — it would break `--json`, the conformance corpus, and the hook
path.

### 6.3 Unknown type

```
config: project <KEY>: <ROLE> names issue type "<NAME>", which this project does
not offer at that tier. It offers: <LIST> (zero writes).
```

### 6.4 Duplicate name at a level

```
config: project <KEY>: <ROLE> names "<NAME>", which matches more than one issue
type at level <LEVEL>. The bridge will not choose one for you (zero writes).
```

### 6.5 Sub-task type for a non-sub-task role

```
config: project <KEY>: <ROLE> names "<NAME>", which is a sub-task type in this
project. A <ROLE> cannot be a sub-task (zero writes).
```

### 6.6 Non-sub-task type for the task role

```
config: project <KEY>: task names "<NAME>", which is not a sub-task type in this
project. Its sub-task types are: <LIST> (zero writes).
```

An empty `<LIST>` is rendered as the explicit words `none — this project offers
no sub-task type`, never an empty string.

### 6.7 Ordering

```
config: project <KEY>: specification names "<NAME_S>" at level <LEVEL_S>, which
is not above story "<NAME_C>" at level <LEVEL_C>. A specification must sit above
its stories (zero writes).
```

---

## 7. Reporting

### 7.1 Per-role audit

The configuration run summary reports, per project, each resolved role as
`<role>: <logical_name> (<source>)`. In `--json`, under the discovery effect:

```json
{"roles":{"specification":{"logical_name":"…","source":"declared"}}}
```

### 7.2 Supersession note

When a committed declaration overrides a recorded operator answer:

```
config: project <KEY>: <ROLE> is declared as "<DECLARED>" in config.yml; the
local answer "<LOCAL>" was superseded.
```

One note, not a warning. The run succeeded.

### 7.3 Promotion note

When any role resolved with `source: operator`:

```
config: project <KEY>: commit this so your team mirrors identically —
  hierarchy:
    <ROLE>: "<NAME>"
```

One note, not a warning, never a non-zero exit.

### 7.4 Task role recorded but not mirrored

Until the task tier ships, a resolved `task` role reports:

```
config: project <KEY>: task is recorded as "<NAME>" but is not mirrored yet —
this release creates no sub-tasks.
```

Omitting this is forbidden: a team that declares the role and sees no error
would reasonably conclude sub-tasks are being created.

---

## 8. Reconcile-time re-validation

Reconcile reads the persisted binding and re-runs §4 checks 4, 5 and 6 against
it. It does **not** re-read the project's metadata — that is a configuration-time
concern — so it detects a mapping that has gone internally inconsistent, and the
ceremony detects a mapping that has gone stale against the project.

A refusal here carries the same text as §6 with the `reconcile:` prefix in place
of `config:`, and the same zero-writes and hook-downgrade guarantees.

An absent `roles` key in an otherwise current binding is **not** an error: the
binding predates this feature, `child_type` / `parent_type` are present, and the
existing behaviour is unchanged (FR-004).

---

## 9. Invariants a test must assert

1. No mapping declared ⇒ byte-identical behaviour to the pre-010 release, in the
   ceremony and in reconcile.
2. `roles.story` ≡ `child_type` and `roles.specification` ≡ `parent_type` on
   every binding the ceremony writes.
3. Every §6 refusal issues zero Jira writes and exits `4` directly, `0` with one
   WARNING under a hook.
4. A second run over unchanged inputs writes byte-identical YAML.
5. Both ports emit byte-identical output for every message above, including one
   whose `<LIST>` contains non-ASCII names.
6. No `task` role resolved ⇒ no sub-task is created and the mirror output is
   byte-identical to today's.
7. An undeclared, unanswered `task` role produces no `roles.task` key, no
   `unresolved_roles` entry and no refusal — a project that never mentions a
   task tier configures exactly as it did before this release (§3.4).
