# 6. Feature naming — the ticket-first ceremony

`/speckit.jira.feature` is the `before_specify` hook. It resolves the Jira
ticket **before** naming anything, so the branch and the spec folder can carry
the real ticket number instead of a placeholder that has to be renamed later.

## The flow

```mermaid
flowchart TD
    Start(["before_specify fires"]) --> Cat{"A teams: catalogue in config.yml?"}
    Cat -->|"no"| Pass(["active: false — pass through,<br/>the host names the feature exactly as it would without the extension"])

    Cat -->|"yes"| Personal{"Read .specify/jira/personal.yml"}
    Personal -->|"unreadable or invalid"| Fail(["exit 4 — a located error"])
    Personal -->|"no selection"| Cross{"A cross-team --use-team answer?"}
    Cross -->|"no"| Pass
    Cross -->|"yes"| Team

    Personal -->|"team selected"| Team["Resolve the effective team<br/>and its naming rule"]
    Team --> Desc{"Description supplied?"}
    Desc -->|"no"| Fail2(["a description is required once a team is in play"])
    Desc -->|"yes"| Ticket

    Ticket{"A mentioned issue key<br/>in the leading positional?"}
    Ticket -->|"yes"| Validate["ticket_validate — READ-ONLY GET /issue/KEY"]
    Ticket -->|"no"| Create["ticket_create — guarded POST /issue<br/>in the team's project, with the resolved story-type id"]

    Validate -->|"fail-closed read"| Warn(["active: false + one warning<br/>a mentioned key never silently falls back"])
    Create -->|"refused or unreachable"| Warn

    Validate --> Name
    Create --> Name["Naming — pure engine, zero tracker vocabulary"]
    Name --> Out(["branch name + flat folder short-name"])
```

Non-blocking by construction: no team selected means `{active:false}`; Jira
unreachable or a create refused means `{active:false}` plus one warning. The
host `specify` flow then proceeds exactly as it does today.

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
    Short --> Folder["ijt-add-payment-webhooks"]
```

Two rules make this predictable:

- A `/` inside the pattern is preserved verbatim — it creates branch hierarchy
  and nothing else.
- The folder short-name is **always a single flat component**, whatever the
  branch pattern looks like.

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

    subgraph Human["personal.yml — gitignored, human-owned, never written by any script"]
        S["team: ijt"]
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

`--parent` and `--story` extend `/speckit.jira.feature` past the mentioned-key
case above: instead of naming (or leaving unnamed) a single ticket, the
operator can name a whole set of **existing** Jira issues that already carry
the human intent for this feature, and seed `spec.md` from their content
rather than draft it from scratch.

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
    Draft --> Seed(["/speckit.jira.seed — moment 2, see below"])
```

A key or a browser URL resolves to an existing issue and is **adopted**, never
created. A specification-role designator supplied as free text is never
resolved against Jira at all (no lookup of any kind) — it is always the title
of a parent to **create**, deferred to `/speckit.jira.seed --confirm`.

## The two-moment flow

Seeding from named issues splits into two moments because a confirmation
prompt cannot live in a lifecycle hook (Constitution IV — "a wait is
indistinguishable from a hang").

```mermaid
sequenceDiagram
    participant Host as spec-kit host
    participant M1 as speckit.jira.feature<br/>(before_specify hook)
    participant Agent
    participant M2 as speckit.jira.seed<br/>(agent-invoked, no hook)
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
`speckit.jira.seed` with the same designator set resumes at the gate — it
re-reads Jira to recompute the plan (a story closed or re-parented in the
meantime shows up), but it **never** re-drafts `spec.md`. A different
designator set refuses `REF-RESEED`.

See `commands/speckit.jira.seed.md` for the full agent-facing procedure and
`docs/08-safety-model.md` for the seeded-not-bound state machine and the
pinning marker's consume-at-binding mechanics.
