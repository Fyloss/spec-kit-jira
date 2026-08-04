# 2. Module architecture

The bridge is four layers plus a single entry point, mirrored module-for-module
across two native ports.

## The layers

```mermaid
flowchart TB
    Entry["Entry point<br/>spec-kit-jira.sh · spec-kit-jira.ps1<br/>prerequisites → parse → route"]

    subgraph CommandsLayer["commands/ — orchestration"]
        direction LR
        C1["config"]
        C2["reconcile"]
        C3["feature"]
        C4["mention"]
    end

    subgraph EngineLayer["engine/ — NEUTRAL: zero Jira knowledge"]
        direction LR
        E1["parse"]
        E2["interchange"]
        E3["drift"]
        E4["idempotency"]
        E5["naming"]
        E6["managed_section"]
        E7["story_marker"]
        E8["task_marker (012)"]
        E9["tasks_parse (012)"]
        E10["markdown"]
    end

    subgraph SinkLayer["sink/jira/ — ALL Jira knowledge"]
        direction LR
        S1["client"]
        S2["discovery"]
        S3["identity"]
        S4["recognition"]
        S5["ticket"]
        S6["adf"]
        S7["privacy_guard"]
        S8["plan_apply"]
        S9["duplicate_probe (017, US4, droppable)"]
    end

    subgraph LibLayer["lib/ — port infrastructure, no Jira knowledge"]
        direction LR
        L1["cli — flags + exit-code table"]
        L2["config — YAML layers"]
        L3["credentials"]
        L4["output — canonical JSON"]
        L5["prereq"]
    end

    subgraph HooksLayer["hooks/ — host-integration vocabulary"]
        direction LR
        H1["register_hooks — registry READER"]
        H2["readme_block — managed block writer"]
    end

    Entry --> CommandsLayer
    CommandsLayer --> EngineLayer
    CommandsLayer --> SinkLayer
    CommandsLayer --> HooksLayer
    EngineLayer -->|"neutral interchange document"| SinkLayer
    CommandsLayer --> LibLayer
    EngineLayer --> LibLayer
    SinkLayer --> LibLayer
    HooksLayer --> LibLayer
    SinkLayer -->|"REST v3"| Jira[("Jira Cloud")]
```

## The one boundary rule that CI enforces

```mermaid
flowchart LR
    E["engine/<br/>parse · drift · idempotency<br/>naming · interchange"]
    S["sink/jira/<br/>client · discovery · adf<br/>identity · plan_apply"]
    L["lib/"]

    E -->|"ALLOWED: hands over the<br/>neutral interchange document"| S
    S -->|"ALLOWED: the sink may consume the engine"| E
    E -->|"ALLOWED"| L

    Forbidden["FORBIDDEN — the build fails<br/>an engine script that sources or imports sink/<br/>an engine script containing an Atlassian identifier"]
```

Two greps in `.github/workflows/boundary.yml` block the build:

1. **Gate 1** — no engine script `source`s (Bash) or `Import-Module`s
   (PowerShell) anything under `sink/`.
2. **Gate 2** — no engine script contains an Atlassian-specific identifier:
   issue-key patterns, `atlassian.net`, `createmeta`, ADF node names, Jira
   field ids, or type names.

That is why, for example, `engine/story_marker.sh` generates an opaque hex
identifier and treats the ticket key it is paired with as *opaque text handed
in by the caller* — the engine literally cannot know what a Jira key is. Only
the direction `engine → sink` is forbidden; the sink freely reuses neutral
engine primitives, which is how `sink/jira/adf.sh` can call
`engine/managed_section.sh` to splice a panel into a description.

## Module responsibilities

```mermaid
mindmap
  root(("spec-kit-jira"))
    engine
      parse
        title ladder
        never-empty description
        Given/When/Then extraction
        Design section
        P1 P2 P3 priority
        declared estimation
      markdown
        Markdown subset -> neutral blocks and spans
        source-format knowledge, not Jira knowledge
        no Atlassian identifiers (Gate #2)
      interchange
        schema validation before any write
      story_marker
        durable story identifier
        byte-preserving splice into spec.md
      task_marker
        durable task identifier (012)
        byte-preserving splice into tasks.md
      tasks_parse
        neutral tasks.md reader (012)
        checkbox, reference, story attribution
        never a Jira identifier, never a sub-task type
      drift
        transition or withhold or halt
      idempotency
        zero-churn diff
      managed_section
        marker-delimited byte splice
      naming
        slug and branch pattern and short name
    sink
      client
        the single HTTP conduit
        429 retry honouring Retry-After
        HTTP status to exit code
      discovery
        project metadata by logical name
      identity
        entity-property identity marker
      recognition
        reads recorded tickets back by key
      ticket
        validate and guarded create
      adf
        neutral blocks to Atlassian Document Format
      privacy_guard
        BLOCK tier and WARN tier
      plan_apply
        guard-then-write ordered actions
    lib
      cli exit code table
      config YAML layers
      credentials
      output canonical JSON
      prereq
    hooks
      register_hooks reader
      readme_block writer
```

## Twin ports, module for module

Every Bash module has exactly one PowerShell counterpart, and a CI gate
compares the two leaf sets modulo extension and case.

```mermaid
flowchart LR
    subgraph BashPort["scripts/bash/"]
        BA["engine/parse.sh"]
        BB["sink/jira/client.sh"]
        BC["lib/config.sh"]
    end

    subgraph PwshPort["scripts/powershell/"]
        PA["engine/Parse.psm1"]
        PB["sink/jira/Client.psm1"]
        PC["lib/Config.psm1"]
    end

    BA <-->|"byte-identical output"| PA
    BB <-->|"identical call sequence"| PB
    BC <-->|"identical YAML to JSON"| PC
```

Anything crossing platforms — files written into the repository, run
summaries, the neutral interchange document — must be **byte-identical**
between ports. That is why `lib/output.sh` reimplements a canonical JSON form
(sorted keys, compact, raw UTF-8, no trailing newline) rather than trusting
each language's native serialiser.

## Entry-point dispatch

```mermaid
sequenceDiagram
    autonumber
    participant Caller as Agent or developer
    participant Entry as spec-kit-jira.sh
    participant Prereq as lib/prereq
    participant Cli as lib/cli
    participant Cmd as commands module

    Caller->>Entry: reconcile spec.md --json
    Entry->>Prereq: prereq_check
    alt a prerequisite is missing
        Prereq-->>Entry: exit 5, named cause
        Entry-->>Caller: exit 5 — no Jira contact ever happened
    else prerequisites satisfied
        Prereq-->>Entry: ok
        Entry->>Cli: cli_parse argv
        Cli-->>Entry: key=value state lines
        alt usage error
            Entry-->>Caller: usage block, exit 1
        else help requested
            Entry-->>Caller: usage block, exit 0
        else
            Entry->>Cmd: source the module, call its cmd_ entry
            Cmd-->>Caller: run summary + exit code
        end
    end
```

The dispatcher sources the command module **on demand**, so a command that
does not exist is a usage error rather than a crash. Prerequisites gate every
path: no Jira interaction is possible before they pass.
