# 5. The reconcile flow — mirroring a specification

`reconcile` is what all six `after_*` hooks fire. It is the largest single
piece of the system, and it reads as one ordered pipeline.

## The pipeline

```mermaid
flowchart TD
    Start(["reconcile spec.md --json"]) --> Guard["0 · Dispatch guard<br/>is this event disabled by the operator?"]
    Guard -->|"disabled"| Inert(["exit 0, silently — no config read, no network"])
    Guard -->|"active"| Spec{"Readable spec file argument?"}
    Spec -->|"no"| Usage(["exit 1"])
    Spec -->|"yes"| Bound{"Base URL set and config.yml present?"}

    Bound -->|"no"| Notice(["Not bound yet — 3-line notice, exit 0"])
    Bound -->|"yes"| Avail{"Bridge entry points intact?"}
    Avail -->|"no"| Notice2(["Incomplete install — notice, exit 0"])

    Avail -->|"yes"| Route["1 · Resolve routing<br/>folder → project key, or an explicit override"]
    Route --> Validate["2 · Refuse a missing, malformed,<br/>placeholder, or undeclared project key"]
    Validate --> Assign["3 · ASSIGN durable story identifiers<br/>splice the marker line into spec.md"]
    Assign --> AssignTasks["3a · ASSIGN durable task identifiers<br/>splice the marker line into tasks.md, when task role declared (012)"]
    AssignTasks --> Parse["4 · PARSE — neutral content, engine only"]
    Parse --> ParseTasks["4a · PARSE tasks.md — neutral task content,<br/>attributed to its story (012)"]
    ParseTasks --> Build["5 · ASSEMBLE + schema-VALIDATE<br/>the neutral interchange document"]
    Build --> Recognise["6 · RECOGNISE — read every recorded ticket back by key<br/>parent, story AND sub-task"]
    Recognise --> Context["7 · Build the plan context from the local binding"]
    Context --> Plan["8 · PLAN the ordered action set<br/>epic → stories → tasks"]
    Plan --> Lifecycle["9 · LIFECYCLE filter<br/>drift, halted states, flagged, zero-churn drop"]
    Lifecycle --> Apply{"--dry-run?"}

    Apply -->|"yes"| Summary
    Apply -->|"no"| Write["10 · APPLY — privacy guard, then write<br/>stamp and record each created key immediately"]
    Write --> Complete["10a · COMPLETE — for each checked task,<br/>transition its recognised sub-task to a done-category status (012)"]
    Complete --> Summary["11 · Run summary<br/>counts · actions · warnings · notes · hook health"]
    Summary --> Hook{"Running inside a hook<br/>with a non-zero exit?"}
    Hook -->|"yes"| Downgrade(["one WARNING, exit downgraded to 0"])
    Hook -->|"no"| Exit(["exit with the mapped code"])
```

Every failure between step 1 and step 9 exits with **zero Jira writes**. That
is not incidental: the write path is the last thing that happens, after every
decision has already been made.

## The consolidated field-defaults question (011)

A recorded default makes an otherwise-unsatisfiable required field
satisfiable — the same predicate the config ceremony's gate uses. Before any
write, the planning pass (the exact computation `--dry-run` performs) checks
whether the pending creations would either send a recorded default or still
leave a required field unsatisfiable:

```mermaid
flowchart TD
    Plan["8 · PLAN the ordered action set"] --> Trigger{"Any pending creation sends<br/>a recorded default, OR leaves<br/>a required field unsatisfiable?"}
    Trigger -->|"no"| Continue["Continue to LIFECYCLE filter,<br/>then APPLY as usual"]
    Trigger -->|"yes"| Ask{"ask switch on,<br/>AND --accept-defaults<br/>not given?"}
    Ask -->|"no"| Continue
    Ask -->|"yes"| Stop["Stop before any write<br/>emit ONE confirmation-pending object<br/>naming every field once<br/>exit 0, zero writes"]
    Stop --> Reinvoke["Re-invoke with --accept-defaults<br/>and/or --field-value KEY=Type=Label=Value"]
    Reinvoke --> Plan
```

The planning pass and the writing pass are the same code, run twice, never a
second and divergent computation — so a `--dry-run` preview and the run that
follows it can never disagree about a defaulted value. A **decline** is
resumed exactly like an acceptance: re-invoke with `--accept-defaults`; there
is no decline flag. When no answer can be obtained and a required field
stays unsatisfiable, the run refuses for that specification with the
pre-existing exit code and a message carrying the copy-pasteable
`speckit.jira.config --field-default …` remedy line.

A field that is merely *defaultable*, with nothing recorded against it, is
never a trigger — a project that recorded nothing sees no question and no
change in behaviour (FR-028).

## Engine to sink, in sequence

```mermaid
sequenceDiagram
    autonumber
    participant Cmd as commands/reconcile
    participant Marker as engine/story_marker
    participant TMarker as engine/task_marker (012)
    participant Parse as engine/parse
    participant TParse as engine/tasks_parse (012)
    participant Inter as engine/interchange
    participant Recog as sink/recognition
    participant Adf as sink/adf
    participant Guard as sink/privacy_guard
    participant Apply as sink/plan_apply
    participant Disc as sink/jira/discovery (012)
    participant Jira as Jira Cloud

    Cmd->>Marker: assign an identifier to every unmarked story
    Marker->>Marker: byte-preserving splice into spec.md
    Note over Marker: a dry run computes the SAME assignment<br/>but never writes it
    Marker-->>Cmd: assigned document text

    Cmd->>TMarker: assign an identifier to every unmarked task (when task role declared)
    TMarker->>TMarker: byte-preserving splice into tasks.md
    TMarker-->>Cmd: assigned tasks.md text

    Cmd->>Parse: parse the assigned text
    Parse-->>Cmd: title ladder, description blocks, Gherkin, design, priority, estimation

    Cmd->>TParse: parse tasks.md — checkbox, reference, story attribution
    TParse-->>Cmd: neutral task content, nested under its story

    Cmd->>Inter: assemble + validate against the schema
    alt invalid
        Inter-->>Cmd: errors — every write is blocked
    else valid
        Inter-->>Cmd: neutral interchange document
    end

    Cmd->>Recog: recognition_run for the recorded markers
    Recog->>Jira: GET each recorded key, folding in the identity property
    Jira-->>Recog: issue fields + identity marker, or 404
    Recog-->>Cmd: bound / new / blocked

    Cmd->>Adf: render neutral content blocks
    Adf-->>Cmd: Atlassian Document Format
    Cmd->>Apply: apply_writes with the ordered action set
    Apply->>Guard: scan EVERY content payload first
    alt a BLOCK-tier match
        Guard-->>Apply: refuse
        Apply-->>Cmd: exit 9, zero writes
    else clean
        Apply->>Jira: POST /issue · PUT /issue/KEY (epic → stories → tasks)
        Jira-->>Apply: created keys
        Apply->>Apply: stamp the identity marker and record the key, per ticket, immediately
    end

    Note over Cmd,Jira: Completion pass (012, §6) — planned only for a checked task
    Cmd->>Disc: for each checked task's recognised sub-task not already done
    Disc->>Jira: GET available transitions
    Jira-->>Disc: transitions, each with a destination statusCategory
    Disc-->>Cmd: the one done-category transition, or none/ambiguous (reported, never guessed)
    Cmd->>Apply: POST /issue/KEY/transitions
    Apply->>Jira: transition the sub-task
```

The ordering in the last block is the invariant: **guard, then write**. A single
blocked payload aborts the whole apply — there is no gap through which a leak
could reach Jira.

## What the engine extracts from a specification

```mermaid
flowchart LR
    subgraph Doc["spec.md"]
        H1["# Title"]
        H2["### User Story headings"]
        H3["Given / When / Then"]
        H4["Design section"]
        H5["Priority P1 / P2 / P3"]
        H6["Declared estimation"]
    end

    subgraph Neutral["Neutral content — zero Jira identifiers"]
        N1["deterministic title ladder"]
        N2["never-empty structured description"]
        N3["acceptance_criteria"]
        N4["design"]
        N5["logical priority level"]
        N6["estimation value"]
    end

    subgraph Rendered["Rendered by the sink"]
        R1["summary field"]
        R2["ADF description body"]
        R3["ADF info panel"]
        R4["ADF Design section"]
        R5["priority id, via the team priority_map"]
        R6["estimation field id — create only, never re-sent"]
    end

    H1 --> N1 --> R1
    H2 --> N2 --> R2
    H3 --> N3 --> R3
    H4 --> N4 --> R4
    H5 --> N5 --> R5
    H6 --> N6 --> R6
```

The engine emits *logical* content; the sink resolves logical names to ids and
renders ADF. `sink/jira/adf.sh` is the only place ADF node names exist.

## The plan context — the facts the engine cannot know

```mermaid
flowchart TD
    Base["SPEC_KIT_JIRA_BASE_URL"] --> Ctx
    Local["config.local.yml<br/>resolved ids for the routed project"] --> Ctx
    Team["config.yml<br/>priority_map, epic_strategy, phase_status_map, halted_statuses"] --> Ctx
    Recognised["recognition results<br/>bound tickets, origins, current descriptions"] --> Ctx

    Ctx["Plan context"] --> Plan["plan_writes → ordered action set"]

    Ctx -.->|"an explicit SPEC_KIT_JIRA_PLAN_CONTEXT<br/>overrides the whole derived object"| Plan
```

Four failure states of the context resolve to four distinct, actionable
messages rather than one generic error:

| Situation | Outcome |
|---|---|
| No local binding file at all | Not bound yet — notice, exit `0` |
| Binding exists, this project is not in it | Run `/speckit.jira.config` to discover it — exit `4` |
| Binding predates parent support | The project *is* bound, its binding is a version behind — refresh it, exit `4` |
| Binding unreadable | Fail closed, zero writes — exit `4` |

## The run summary

Structured prose by default, JSON with `--json` — never the other way round.

```mermaid
classDiagram
    class RunSummary {
        +string schema_version
        +string command
        +bool dry_run
        +Counts counts
        +Action actions
        +list~string~ warnings
        +list~string~ notes
        +HookHealth hook_health
        +int exit_code
    }

    class Counts {
        +int created
        +int updated
        +int skipped
        +int recognised
        +int assigned
        +int warnings
        +int errors
        +TaskCounts tasks
    }

    class TaskCounts {
        +int created
        +int updated
        +int transitioned
        +int unchanged
        +int skipped
        +int withheld
    }

    Counts *-- "0..1" TaskCounts

    class Action {
        +string method
        +string url
        +object body
    }

    class HookHealth {
        +list~string~ present
        +list~string~ missing
        +list~string~ disabled
        +list~string~ duplicated
        +list~string~ held_disabled
        +bool unreadable
    }

    RunSummary *-- Counts
    RunSummary "1" *-- "0..n" Action
    RunSummary *-- HookHealth
```

Two details that make the summary trustworthy:

- **The base URL is stripped** from every reported action URL. The site host is
  a coordinate that must never appear in output.
- **A second, unchanged run reads `created: 0`, `updated: 0`, `recognised` equal
  to the story count, and `skipped` equal to it too.** That is the correct
  signature of an idempotent re-run, not a failure to mirror anything.
- **`counts.tasks` appears only when a `task` role is declared** — absence,
  not a zeroed-out object, is the off switch that keeps a run with no task
  tier byte-for-byte identical to before feature 012 (FR-011). Its own
  `transitioned` count is never folded into `updated`: a completion is a
  transition, not a content change (research R5).
