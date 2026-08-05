# 3. Lifecycle hooks — how the mirror becomes automatic

The extension is not something you run. Once installed, it runs itself on
every spec-kit lifecycle step.

## The seven declared events

`extension.yml` declares them at the **manifest root** — a sibling of
`provides:`, not nested under it. Placement is load-bearing and its failure
mode is silent: a `hooks:` block nested under `provides:` still validates and
registers nothing at all, which is exactly the defect that once made the whole
extension inert from install.

```mermaid
flowchart LR
    subgraph Before["Before the host command"]
        BS["before_specify"] --> F["/speckit.jira.feature"]
    end

    subgraph After["After the host command"]
        A1["after_specify"]
        A2["after_clarify"]
        A3["after_plan"]
        A4["after_tasks"]
        A5["after_implement"]
        A6["after_analyze"]
    end

    A1 --> R["/speckit.jira.reconcile"]
    A2 --> R
    A3 --> R
    A4 --> R
    A5 --> R
    A6 --> R

    F -->|"names the branch and the spec folder"| Out1["ticket-first naming"]
    R -->|"mirrors spec.md"| Out2["Jira tickets"]
```

## Installation — who writes what

```mermaid
sequenceDiagram
    autonumber
    participant Dev as Developer
    participant Specify as specify CLI
    participant Manifest as extension.yml
    participant Registry as .specify/extensions.yml
    participant Bridge as spec-kit-jira

    Dev->>Specify: specify extension add jira --from ...
    Specify->>Manifest: read schema, commands, hooks
    Specify->>Specify: copy extension into .specify/extensions/jira/
    Note over Specify,Registry: .extensionignore keeps specs/, tests/,<br/>.specify/ and .github/ out of the install
    Specify->>Registry: purge this extension's old entries, write the seven declared hooks
    Registry-->>Specify: registry updated

    Dev->>Bridge: /speckit.jira.config
    Bridge->>Registry: READ ONLY — classify every event
    Bridge-->>Dev: report present / missing / disabled / duplicated / leftover
```

The registry purge predicate the host uses is literally
`entry.extension == manifest.id`. A **leftover** entry — one written by a
pre-manifest version of this extension, carrying one of our command names but
no `extension:` field — never satisfies that predicate, so the installer adds
a *second* entry beside it rather than replacing it. Neither the host nor the
bridge can remove it, so the config ceremony reports it with a manual edit
instead of pretending it is not there.

## A hook firing, end to end

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Developer
    participant Host as Spec Kit host
    participant Agent as Coding agent
    participant Bridge as Bridge entry point
    participant Jira as Jira Cloud

    Dev->>Host: /speckit.plan
    Host->>Host: produce plan.md
    Host->>Agent: EXECUTE_COMMAND speckit.jira.reconcile
    Note over Agent: optional false means the step HAPPENS,<br/>not that its failure propagates

    Agent->>Agent: read .specify/feature.json for the active feature
    alt no active feature
        Agent-->>Dev: nothing at all — the step is inert
    else
        Note over Agent,Bridge: the target is ALWAYS the active feature's own<br/>spec.md — never plan.md, the artifact this<br/>host command just produced (017, the target guard)
        Agent->>Bridge: .specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile spec.md --json
        Bridge->>Jira: read, then write only what changed
        Jira-->>Bridge: responses
        Bridge-->>Agent: run summary JSON + exit code
        Agent-->>Dev: exactly ONE line, whatever the outcome
    end
    Host-->>Dev: /speckit.plan completed normally
```

Three properties are worth stating explicitly:

- **The agent invokes the bridge by repository-relative path.** The install
  puts nothing on `PATH`; a bare `spec-kit-jira` command does not exist in a
  consuming repository. Assuming it does is what produced the reported
  "spec-kit-jira CLI not installed" message.
- **At most one message per host command run**, naming the true cause.
- **The bridge's exit code never becomes the host's exit code.** It is
  reported, not propagated.

## The seven distinguished causes of a degraded run

```mermaid
flowchart TD
    Start["Bridge invoked"] --> Exists{"Entry point exists<br/>and is executable?"}
    Exists -->|"no"| Cause7["Bridge unavailable<br/>emit the verbatim fallback block<br/>the bridge cannot report this itself"]
    Exists -->|"yes"| Run["Run"]

    Run --> Code{"Exit code"}
    Code -->|"1, rejected target"| Cause0["Rejected target (017)<br/>relay the entry point's own message —<br/>this is a caller defect, not a degraded Jira state"]
    Code -->|"0, no binding"| Cause1["Not yet configured<br/>run /speckit.jira.config"]
    Code -->|"5"| Cause4["Prerequisite missing<br/>relay the entry point's own message"]
    Code -->|"4"| Cause2["Credentials absent<br/>no token on any of the three rungs"]
    Code -->|"3"| Cause3["Credentials rejected by Jira"]
    Code -->|"2"| Cause5["Jira unreachable<br/>nothing was mirrored"]
    Code -->|"0, mirrored"| Ok["Report created / updated / recognised / skipped"]
```

The last row of the table in `commands/speckit.jira.reconcile.md` is the only
cause the bridge cannot report on, because in that state it never starts and
produces nothing. Everything the developer sees then comes from the agent —
which is why that text is fixed in the command document rather than composed
at runtime.

## The operator's disable decision

A hook the operator explicitly disabled must be respected **forever**: no
repair and no upgrade may re-enable it. The decision is recorded in the
bridge's own gitignored local binding, not in the registry the installer
rewrites — so a reinstall cannot erase it.

```mermaid
stateDiagram-v2
    [*] --> Declared: manifest declares the event
    Declared --> Registered: specify extension add writes the registry
    Registered --> Active: hook fires on every lifecycle step

    Active --> HeldDisabled: operator disables the event
    HeldDisabled --> HeldDisabled: reinstall / upgrade / repair — still disabled
    HeldDisabled --> Active: operator re-enables it explicitly

    Active --> Inert: no active feature, or repository not bound
    Inert --> Active: binding completed
```

When a run is dispatched for a disabled event, the bridge exits `0`
**silently** — before any prerequisite check, any config read, and any network
call. No warning either: a warning on every single lifecycle command for an
event the operator deliberately turned off is precisely the noise the design
forbids.
