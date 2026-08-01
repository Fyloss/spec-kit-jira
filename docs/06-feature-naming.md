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
