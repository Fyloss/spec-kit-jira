# 6. Feature naming — the ticket-first ceremony

`/speckit.jira-mirror.feature` is the `before_specify` hook. It resolves the Jira
ticket **before** naming anything, so the branch and the spec folder can carry
the real ticket number instead of a placeholder that has to be renamed later.

## The flow

```mermaid
flowchart TD
    Start(["before_specify fires"]) --> Repo{"An ancestor of the working<br/>directory carries .specify/?<br/>(031)"}
    Repo -->|"no"| Report0(["active: false — REPORTED: no project located,<br/>the directory walked from named (031)"])
    Repo -->|"yes"| Cat{"A teams: catalogue in config.yml?"}
    Cat -->|"absent"| Pass(["active: false — pass through,<br/>the host names the feature exactly as it would without the extension"])
    Cat -->|"present, unloadable"| Report1(["active: false — REPORTED: file + located reason (031)"])
    Cat -->|"valid, zero teams"| Pass

    Cat -->|"yes, >=1 team"| Personal{"Read .specify/jira/personal.yml"}
    Personal -->|"unreadable or invalid"| Report2(["active: false — REPORTED: file + located reason,<br/>never fatal (031, FR-013)"])
    Personal -->|"no selection"| Cross{"A cross-team --use-team answer?"}
    Cross -->|"no"| Pass
    Cross -->|"yes"| Team

    Personal -->|"team selected"| Team["Resolve the effective team<br/>and its naming rule"]
    Team --> Desc{"Description supplied?"}
    Desc -->|"no"| Fail2(["a description is required once a team is in play"])
    Desc -->|"yes"| Ticket

    Ticket{"A mentioned issue key<br/>in the leading positional?<br/>(bare key or a browser URL)"}
    Ticket -->|"yes, no designator, no answer"| Validate["ticket_validate — READ-ONLY GET /issue/KEY<br/>widened to summary/type/status (029)"]
    Ticket -->|"no"| Create["ticket_create — guarded POST /issue<br/>in the team's project, with the resolved story-type id"]

    Validate --> Ask{"reuse question (029)<br/>one line per detected issue,<br/>role derived from the hierarchy"}
    Ask -->|"--reuse no"| Name
    Ask -->|"--reuse yes"| Designators["routes into the designator path below,<br/>--parent/--story derived from the computed roles"]
    Ask -.->|"unattended (--accept-defaults)"| Name

    Validate -->|"fail-closed read"| Warn(["active: false + one warning<br/>a mentioned key never silently falls back"])
    Create -->|"refused or unreachable"| Warn2(["active: false + one warning naming the cause —<br/>never claims a ticket will be attached later"])

    Create --> Name["Naming — pure engine, zero tracker vocabulary"]
    Name --> Out(["branch name + flat folder short-name"])
```

Non-blocking by construction: no team selected means `{active:false}`; Jira
unreachable or a create refused means `{active:false}` plus one warning naming
the cause. The host `specify` flow then proceeds exactly as it does today. A
ticket named in a repository with no applicable team configuration is told so
— the file to fix and the command that fixes it — rather than met with
silence (029, FR-026).

### Every `{active:false}` names which of seven states produced it (031)

Before 031, `{active:false}` was a single, undifferentiated outcome — an
operator whose `config.yml` had a typo saw exactly the same nothing as an
operator who had never adopted the extension at all. The pass-through now
carries that distinction:

| State | Reported by default? |
| --- | --- |
| No `config.yml` at the resolved directory | silent |
| `config.yml` present, fails to load | **reported** — file + located reason |
| Valid `config.yml`, `teams:` declares zero entries | silent (a supported single-project setup) |
| No `personal.yml` | silent |
| `personal.yml` present, no `team` key | silent |
| `personal.yml` present, fails to load | **reported** — file + located reason, never fatal |
| No ancestor of the working directory carries `.specify/` | **reported** — the directory walked from |

Two of the seven speak without being asked, because a file that exists is a
statement its author is owed an answer about, and a file that does not exist
is not a statement. All seven are nameable on request: `--verbose` names the
resolution state, the absolute directory consulted, and what would change it
— without moving the default or `--json` output by one line or one key.

**The mentioned key is a naming input, and the operator is asked whether it
is also a binding (029).** `ticket_validate` is read-only, and answering the
reuse question with "create new" (or letting it fall through unattended)
leaves `spec.md` unlinked at `before_specify`: the following `reconcile` finds
an unbound specification and creates a new parent plus one issue per user
story, alongside the mentioned ticket — exactly as today, and exactly what
answering "reuse" avoids. Seeding a specification from an issue that already
exists is the designator path below, reached either by answering the
question or by naming `--parent`/`--story` directly, and it is chosen **at
invocation time**: a feature already created without either cannot be seeded
after the fact (`REF-EXISTS`).

## The naming engine — four pure string operations

```mermaid
flowchart LR
    Key["Opaque ticket key<br/>e.g. TEAM-142"] --> Num["naming_ticket_number<br/>strip the leading prefix"]
    Num --> ID["142"]

    Desc["Free-text description"] --> Slug["naming_slug<br/>folder-safe slug"]
    Slug --> FeatureName["add-payment-webhooks"]

    ID --> Expand["naming_expand_pattern<br/>substitute the two placeholders"]
    FeatureName --> Expand
    Pattern["branch_pattern from the team catalogue"] --> Expand
    Expand --> Branch["ijt-142/add-payment-webhooks"]

    FeatureName --> Short["naming_short_name<br/>prefix without duplicating it"]
    Prefix["folder_prefix"] --> Short
    Short --> ShortName["short-name:<br/>ijt-add-payment-webhooks"]
```

Two rules make this predictable:

- A `/` inside the pattern is preserved verbatim — it creates branch hierarchy
  and nothing else.
- The folder short-name is **always a single flat component**, whatever the
  branch pattern looks like.

The short-name is not yet the folder name: the host prefixes its own feature
number, so `ijt-add-payment-webhooks` lands on disk as
`specs/001-ijt-add-payment-webhooks`. That numbering belongs to spec-kit and
has no flag to suppress it.

### Who creates the branch — the extension does not

Both strings above are **outputs**. This extension names; it does not act on
the repository. The host's `create-new-feature.sh` (spec-kit 0.13.x) creates
the spec folder and an empty `spec.md`, and runs no git command at all — so the
branch is created by whichever `before_specify` hook the repository registers
for that job, dispatched after this one.

`branch_name` reaches it through **`GIT_BRANCH_NAME`** — the **host's** own
documented channel for using a branch name verbatim, "bypassing all
prefix/suffix generation". The agent that sequences the hooks is what exports
it; without that export the receiving hook regenerates a name of its own and
the ticket number is lost from the branch.

**This is a convention, not a dependency.** The extension names no counterpart
in its manifest, detects none at run time, and behaves identically when none is
installed — `branch_name` is simply emitted and unused. What it depends on is
`GIT_BRANCH_NAME`, which belongs to spec-kit, the host already declared in
`requires:`. The commonly installed git extension happens to read that variable
in both of its ports, which is why the convention works in practice; if it is
absent, or replaced, or renamed, nothing here breaks.

One trap worth knowing: with a git extension installed there are two scripts
called `create-new-feature.sh` doing opposite halves of the job — the host's
makes the folder and runs no git, the extension's makes the branch and no
folder. Anything invoking one by bare name is ambiguous. Widening this hook to create the branch itself is what let a
single dispatch absorb the whole specify command in the 2026-08-22 consumer
incident; the boundary is stated normatively in
`commands/speckit.jira-mirror.feature.md`.

The module carries no key-shaped literal and no tracker vocabulary at all; a
boundary grep in the suite proves it. `naming_ticket_number` does not know what
a Jira key is — it strips an upper-case-led prefix from an opaque string, and
returns anything that is not prefix-shaped unchanged.

## Where the naming rules come from

```mermaid
flowchart TB
    subgraph Committed["config.yml — committed, PR-reviewable"]
        T["teams:<br/>id · project · folder_prefix · branch_pattern"]
    end

    subgraph Human["personal.yml — gitignored, human-owned,<br/>created once if absent, never rewritten"]
        S["team: ijt<br/>(naming AND routing rank 3)"]
        O["override:<br/>folder_prefix + branch_pattern"]
    end

    T --> Resolve["Effective team"]
    S --> Resolve
    O -->|"exceptional, auditable —<br/>every output reports that it was used"| Resolve

    Resolve --> Engine["engine/naming"]
```

The catalogue is the team's shared decision, reviewed in a pull request. The
selection is personal and gitignored, so two developers on the same repository
can ship under different conventions without editing a committed file. The
override exists for the exceptional case and is reported every time it fires,
so it can never quietly become the norm.

## Naming from named issues — the designator flags (027)

`--parent` and `--story` extend `/speckit.jira-mirror.feature` past the mentioned-key
case above: instead of naming (or leaving unnamed) a single ticket, the
operator can name a whole set of **existing** Jira issues that already carry
the human intent for this feature, and seed `spec.md` from their content
rather than draft it from scratch. **Two ways in (029):** type the flags from
the start, or paste bare keys and answer the reuse question with `yes` — the
bridge derives the same flags from the roles it already computed. A type the
declared hierarchy maps to no role is proposed in the story role rather than
refused, and needs no parent; a type that collides with the *other* role
refuses instead, naming both types, before either answer is given.

```mermaid
flowchart TD
    Flags{"--parent and/or --story supplied?"} -->|"no"| Ordinary["the ordinary ceremony above, unchanged"]
    Flags -->|"yes"| Classify["classify each designator:<br/>key · URL · free text (specification role only)"]
    Classify -->|"REF-DESIGNATOR / REF-HOST"| Refuse1(["exit 4, zero requests"])
    Classify --> Dedupe["de-duplicate on the reduced key"]
    Dedupe -->|"REF-DUPLICATE"| Refuse1
    Dedupe --> Slug["resolved slug (FR-059):<br/>a key/URL designator wins;<br/>free-text-only falls through to the description"]
    Slug --> Bulk["ONE bulkfetch — every designated key,<br/>one request per 100 (FR-043)"]
    Bulk -->|"unreachable"| FailClosed(["EXIT_FAILCLOSED — designators were named,<br/>so this path never degrades to active:false"])
    Bulk --> Refusals["REF-UNRESOLVED · REF-ROLE · REF-ROUTING ·<br/>REF-MULTIPROJECT · REF-TERMINAL · REF-CLAIMED · REF-THIN,<br/>evaluated over the WHOLE set, reported together"]
    Refusals -->|"any fires"| Refuse1
    Refusals --> Record["write the seeded-not-bound record + hand the agent<br/>the seed material (summary, description, status, current parent)"]
    Record --> Draft(["the agent drafts spec.md from that material,<br/>pinning each story-role issue after its heading"])
    Draft --> Seed(["/speckit.jira-mirror.seed — moment 2, see below"])
```

A key or a browser URL resolves to an existing issue and is **adopted**, never
created. A specification-role designator supplied as free text is never
resolved against Jira at all (no lookup of any kind) — it is always the title
of a parent to **create**, deferred to `/speckit.jira-mirror.seed --confirm`.

## The two-moment flow

Seeding from named issues splits into two moments because a confirmation
prompt cannot live in a lifecycle hook (Constitution IV — "a wait is
indistinguishable from a hang").

```mermaid
sequenceDiagram
    participant Host as spec-kit host
    participant M1 as speckit.jira-mirror.feature<br/>(before_specify hook)
    participant Agent
    participant M2 as speckit.jira-mirror.seed<br/>(agent-invoked, no hook)
    participant Jira

    Host->>M1: before_specify
    M1->>Jira: ONE bulkfetch (the designated keys)
    M1-->>Agent: seed material + seeded-not-bound record
    Note over M1,Jira: zero mutations
    Agent->>Agent: draft spec.md, place pinning markers
    Agent->>M2: seed spec.md --json
    M2->>M2: validate pins (REF-DECOMP / REF-DRAFT-EDIT)
    M2-->>Agent: write plan + provenance (confirmation_required)
    Note over M2,Jira: zero mutations — the gate
    Agent->>Agent: relay the plan, then ask the operator
    Agent->>M2: seed spec.md --confirm --json
    M2->>Jira: bind / create / re-parent, per-item, stamp-then-record
    M2-->>Agent: bindings
```

A decline (or an unattended run) leaves the **seeded-not-bound** state exactly
as it was: the folder and `spec.md` exist, the pinning markers are still
`pin=`, and no identity marker exists on either side. Re-invoking
`speckit.jira-mirror.seed` with the same designator set resumes at the gate — it
re-reads Jira to recompute the plan (a story closed or re-parented in the
meantime shows up), but it **never** re-drafts `spec.md`. A different
designator set refuses `REF-RESEED`.

See `commands/speckit.jira-mirror.seed.md` for the full agent-facing procedure and
`docs/08-safety-model.md` for the seeded-not-bound state machine and the
pinning marker's consume-at-binding mechanics.

## What `team:` governs, beyond naming

Since 033 the `team:` key of `personal.yml` governs **two** things, and this
document describes only the first:

1. **Naming** — the folder prefix and branch pattern a new feature is created
   under, taken from that team's catalogue entry. That is everything below.
2. **Routing** — where a specification is mirrored when no committed `routing:`
   rule and no committed team folder prefix places it. The selected team's
   project is rank 3 of four, ahead of `config.yml`'s `routing_default`, so a
   repository shared by several teams never mirrors one team's work into
   another's. See `docs/07-configuration-and-secrets.md`, "Routing: four ranks".

The routing half applies only while a specification is still unbound. Once its
stories carry ticket markers the specification fixes its own project, and
changing this key will not move it.
