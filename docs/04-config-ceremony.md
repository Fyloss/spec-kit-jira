# 4. The config ceremony — `/speckit.jira.config`

The one-command install ceremony. Every step is an API read, a config read, or
a closed enumerated question — **no step is left to model judgement**, and the
`--json` summary plus the resolved-id table make any run reproducible.

## What one run does

```mermaid
flowchart TD
    Start(["/speckit.jira.config"]) --> Hooks["1 · Hooks effect<br/>read the registry, classify every event<br/>needs no Jira and no committed config"]
    Hooks --> Load["2 · Load and validate the committed team config"]
    Load --> Degraded{"Connection settings present?<br/>base URL · email · token"}

    Degraded -->|"one is absent"| Report["Degraded run<br/>name the missing setting, exit 0<br/>hook + gitignore + README effects still reported"]
    Degraded -->|"all present"| Key["3 · Resolve the project key<br/>positional arg → committed non-placeholder key<br/>→ closed question over discovered accessible projects"]

    Key --> Seed["4 · Read the existing local binding<br/>prior resolved ids seed the run, so a re-run<br/>only re-binds the projects it was asked about"]
    Seed --> Discover["5 · Discover each project's metadata by API read"]
    Discover --> Validate["6 · Validate the mapping<br/>an impossible hierarchy is refused with exit 4"]
    Validate --> Persist["7 · Persist the resolved-id table<br/>config.local.yml, canonical serialisation"]

    Persist --> Teams["8 · Teams catalogue check<br/>warn, never block, on a team project you cannot see"]
    Teams --> Ignore["9 · Gitignore effect<br/>cover config.local.yml, .env, personal.yml"]
    Ignore --> Readme["10 · README effect<br/>splice the version-marked managed block"]
    Readme --> Summary(["Run summary — every effect reported separately"])
    Report --> Summary
```

## The discovery sequence — nothing about Jira is assumed

Discovery detects the project **style first**, then follows the per-style,
scheme-based path. No default Atlassian type name, status name, or field id is
compiled into the extension anywhere.

```mermaid
sequenceDiagram
    autonumber
    participant Cmd as commands/config
    participant Sink as sink/jira/discovery
    participant Jira as Jira Cloud REST v3

    Cmd->>Sink: discover_binding PROJECT_KEY

    Sink->>Jira: GET /project/KEY
    Jira-->>Sink: company_managed or team_managed

    Sink->>Jira: GET /issue/createmeta/KEY/issuetypes
    Jira-->>Sink: issue types + hierarchy levels + subtask flags

    Sink->>Jira: GET /issue/createmeta/KEY/issuetypes/FIRST_TYPE
    Note over Sink,Jira: the PROJECT's own field schema — never the<br/>global /field catalogue: for a team-managed<br/>project the estimation field is project-scoped
    Jira-->>Sink: estimation candidates, mandatory fields, the flagged field by SHAPE

    Sink->>Jira: GET /project/KEY/statuses
    Jira-->>Sink: statuses + status categories

    Sink->>Jira: GET /priority
    Jira-->>Sink: priorities

    Sink->>Jira: GET /field
    Jira-->>Sink: logical-name catalogue

    Sink-->>Cmd: canonical binding JSON — byte-identical on both ports
```

The estimation field is **ranked, not assumed**: numeric project fields are
scored by documented signals and the top candidate is proposed to the operator
for confirmation. A fail-closed read at any step prints nothing on stdout and
propagates the transport's mapped exit code.

## What gets written

```mermaid
flowchart LR
    Discovery["Discovered binding"] --> Local

    subgraph Local[".specify/jira/config.local.yml — gitignored, machine-owned"]
        direction TB
        R1["style — with its provenance"]
        R2["issue_types — logical name, id, hierarchy_level, subtask"]
        R3["parent_type / child_type — derived, or the operator's answer"]
        R4["required_fields — per issue type"]
        R5["priorities — name to id"]
        R6["statuses — name to id"]
        R7["estimation_field_id"]
        R8["the operator's hook disable decisions"]
    end

    Local -->|"read on every reconcile"| Reconcile["reconcile plan context"]
```

The serialisation is deterministic: a second run over an unchanged instance
rewrites the file byte-for-byte identically. Each project's ids live under
their own key, so distinct projects never share a namespace.

## Mapping validation — refusing the impossible at config time

```mermaid
flowchart TD
    Style{"Project style"} -->|"company_managed"| Free["Hierarchy above the Epic tier is permitted<br/>if the instance declares it"]
    Style -->|"team_managed"| Limited["Only an Epic parent and Sub-task children exist"]

    Limited --> Ask{"Configured mapping asks for a level<br/>ABOVE the Epic tier?"}
    Ask -->|"yes"| Refuse["Refuse now — exit 4<br/>zero writes, before any ticket exists"]
    Ask -->|"no"| Accept["Accept and persist"]
    Free --> Accept
```

The "Epic tier" is identified from the **discovered** binding — the top
non-subtask hierarchy level — never from a name compiled into the script.
Refusing at config time is the whole point: an impossible mapping discovered at
reconcile time would already have created tickets it cannot parent.

## The four effects, reported separately

A run reports what it did to each surface independently, so a partial success
is legible rather than a single opaque "ok".

```mermaid
flowchart LR
    Run(["One config run"]) --> E1["Discovery<br/>created · unchanged · written"]
    Run --> E2["Hooks<br/>present · missing · disabled · duplicated · leftover · unreadable"]
    Run --> E3["Gitignore<br/>covered · updated"]
    Run --> E4["README<br/>created · updated · unchanged · refused"]
```

The README block is spliced through the neutral `engine/managed_section`
byte-splice: only the region between the markers is replaced, every byte
outside it is preserved, the host's dominant line ending is respected, and an
up-to-date block is left byte-for-byte untouched. Malformed markers are refused
with zero writes and exit `4` rather than guessed at.
