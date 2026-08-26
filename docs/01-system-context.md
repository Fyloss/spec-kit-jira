# 1. System context

Who talks to whom, and where every piece of state lives.

## Actors and external systems

```mermaid
flowchart TB
    Dev(["Developer"])
    Lead(["Tech lead / PO"])

    subgraph Repo["Consuming repository"]
        direction TB
        SpecKit["Spec Kit host<br/>slash commands + hook dispatch"]
        Ext["spec-kit-jira<br/>.specify/extensions/jira-mirror/"]
        Artifacts[("spec.md · plan.md · tasks.md")]
        TeamCfg[(".specify/jira/config.yml<br/>committed")]
        LocalCfg[(".specify/jira/config.local.yml<br/>gitignored")]
        Personal[(".specify/jira/personal.yml<br/>gitignored, human-owned")]
        Registry[(".specify/extensions.yml<br/>hook registry — read only")]
        Readme[("README.md<br/>managed block")]
    end

    subgraph Host["Developer machine"]
        EnvVars["Environment variables"]
        PatCmd["Operator-declared JIRA_PAT_COMMAND<br/>run tokenized, no shell — the only<br/>path to a credential store (030)"]
    end

    Jira["Jira Cloud<br/>REST API v3"]

    Dev -->|"runs slash commands"| SpecKit
    Dev -->|"writes specs"| Artifacts
    Lead -->|"reviews in a PR"| TeamCfg

    SpecKit -->|"fires lifecycle hooks"| Ext
    Ext -->|"reads"| Artifacts
    Ext -->|"writes one story marker line"| Artifacts
    Ext -->|"reads"| TeamCfg
    Ext -->|"reads + writes"| LocalCfg
    Ext -->|"reads"| Personal
    Ext -->|"reads only, never writes"| Registry
    Ext -->|"splices a managed block"| Readme

    EnvVars -->|"1st rung — JIRA_API_TOKEN"| Ext
    PatCmd -->|"2nd rung, only if declared"| Ext
    TeamCfg -->|"base_url (030)"| Ext

    Ext <-->|"HTTPS, Basic auth"| Jira
    Lead -->|"reads mirrored tickets"| Jira
```

## What the extension owns, and what it only borrows

The distinction matters: a reinstall of the extension must never destroy the
operator's configuration, and the bridge must never damage a file another tool
owns.

```mermaid
flowchart LR
    subgraph Owned["Written by the bridge"]
        L1[".specify/jira/config.local.yml<br/>resolved ids, machine-owned"]
        L2["The story marker line in spec.md"]
        L3["The managed README block"]
        L4[".gitignore coverage entries"]
        L5["Jira tickets carrying the bridge identity marker"]
    end

    subgraph Borrowed["Read, never written"]
        R1[".specify/jira/config.yml — the team owns it"]
        R2[".specify/jira/personal.yml — the human owns it"]
        R3[".specify/extensions.yml — the Spec Kit installer owns it"]
        R4["Everything else in spec.md"]
        R5["Jira tickets with no bridge identity marker"]
    end
```

Two consequences worth internalising:

- **The hook registry has exactly one writer, and it is not this extension.**
  `specify extension add` writes `.specify/extensions.yml` from the manifest's
  top-level `hooks:` block. The bridge only reads and reports on it — a CI test
  (`tests/bash/ci/test_no_registry_write.bats`) fails the build if a writer ever
  comes back. The reason: this port parses a deliberately restricted YAML
  subset that drops comments, so any round-trip would silently damage a file
  the extension neither owns nor can faithfully reproduce.

- **Configuration never lives inside the extension folder.** It lives in
  `.specify/jira/` at the repository root, so `specify extension add --force`
  can wipe and reinstall `.specify/extensions/jira-mirror/` without touching a single
  setting.

## Runtime prerequisites

Checked before anything else happens — no Jira interaction occurs until they
pass, and a failure exits `5` with a named, remediable message.

```mermaid
flowchart LR
    subgraph Bash["Bash port — macOS, Linux"]
        B1["Bash >= 4<br/>macOS ships 3.2: does not qualify"]
        B2["curl"]
        B3["jq"]
        B4["git"]
    end

    subgraph Pwsh["PowerShell port — Windows"]
        P1["PowerShell 7+<br/>5.1 does not qualify"]
        P2["Invoke-RestMethod<br/>built in"]
        P3["Native JSON<br/>built in"]
        P4["git"]
    end
```

No build step, no download step, no compiled binary — the scripts in the
repository are what runs.
