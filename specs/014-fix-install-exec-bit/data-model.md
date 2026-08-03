# Phase 1 — Data Model

**Feature**: `specs/014-fix-install-exec-bit` | **Date**: 2026-08-03

This feature stores nothing, reads no new file, and adds no field to any existing one. It introduces
no persistent entity, so there is no schema here to design.

What it *does* change is a small vocabulary shared by the two ports — the strings and the predicate
that must stay identical on both sides or the conformance diff goes red. Those are the entities
worth writing down, because "shared between two independently written implementations" is exactly
what a model is for. The normative text lives in
[`contracts/bridge-invocation.md`](./contracts/bridge-invocation.md); this page is the map.

## Shared constants

| Name (Bash / PowerShell) | Kind | Value | Changed? |
| --- | --- | --- | --- |
| `PREREQ_BRIDGE_BASH` / `$script:PrereqBridgeBash` | Filename | `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` | No — it names a file |
| `PREREQ_BRIDGE_PWSH` / `$script:PrereqBridgePwsh` | Filename | `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` | No |
| `JIRA_BRIDGE_BASH_ENTRY` / `$script:JiraBridgeBashEntry` | Invocation stem | gains the `bash ` prefix at the emission seam | **Yes** — C3 |
| `JIRA_BRIDGE_PWSH_ENTRY` / `$script:JiraBridgePwshEntry` | Invocation stem | unchanged | No |

The distinction between the first two rows and the third is the whole model: **a filename and an
invocation are different types that happen to share a substring.** Conflating them produces "the
bridge entry point bash .specify/… was not found", which is why the contract states the rule
mechanically rather than by example.

## The degraded-cause set

The sixth degraded cause (003 FR-017) is the only element that changes shape.

| Cause | Before | After |
| --- | --- | --- |
| not configured | unchanged | unchanged |
| credentials absent | unchanged | unchanged |
| credentials rejected | unchanged | unchanged |
| prerequisite missing | unchanged | unchanged |
| Jira unreachable | unchanged | unchanged |
| bridge entry point | **absent or not executable** | **absent** |

## State transitions

One, and it is the feature:

```text
installed (mode 0644)  ──run any command──▶  works, identical output to 0755
installed (mode 0755)  ──run any command──▶  works
entry point deleted    ──run any command──▶  named degraded cause, host command completes, no mirror
```

There is no fourth state. "Installed but unusable" is the state this feature deletes.

## Validation rules

- The predicate in C6 is total: three inputs, three outputs, no file-mode input.
- The invariant in C7 — same output for either mode — is the only cross-cutting rule, and it is
  enforced by comparison rather than by inspection.
