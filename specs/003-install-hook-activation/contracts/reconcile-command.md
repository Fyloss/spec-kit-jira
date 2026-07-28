# Contract: `speckit.jira.reconcile` — the command every `after_*` hook names

**New file**: `commands/speckit.jira.reconcile.md`
**Requirements**: FR-009, FR-010, FR-011, FR-012, FR-013, FR-014, FR-015 – FR-020

Six lifecycle events already register a hook naming `speckit.jira.reconcile`.
The command does not exist — no file, no manifest entry, nothing installed. This
contract defines it, in the same shape as the two existing command documents.

## Front matter

```yaml
---
name: "speckit.jira.reconcile"
description: "Mirror the current feature's spec-kit artifacts into Jira — a deterministic, non-blocking reconcile fired by every after_* lifecycle event."
argument-hint: "Optional: a spec file path; defaults to the active feature's spec.md"
---
```

`name` must match the manifest's `provides.commands[].name` and the `command`
of all six `after_*` hook entries, character for character.

## Invocation of the bridge — FR-012, FR-014

The procedure must invoke the entry point by **repository-relative path**,
selecting the port from the host. It must never name a bare `spec-kit-jira`
executable: the install places nothing on `PATH`, and that assumption is the
source of the reported "CLI not installed" message.

| Host | Entry point |
| --- | --- |
| macOS, Linux | `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile ...` |
| Windows | `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 reconcile ...` |

The same correction applies to the two existing documents, which currently
instruct the agent to run `spec-kit-jira config` and `spec-kit-jira feature`.

## Ordered procedure

1. **Locate the feature** — read `.specify/feature.json` for the active feature
   directory; with no active feature the step is inert and reports nothing.
2. **Invoke the bridge** by the path above, passing the spec file and `--json`.
3. **Interpret the outcome** and report exactly one line per run:
   - success — the created/updated counts from the run summary;
   - degraded — one warning naming the true cause (FR-017);
   - disabled — nothing at all (FR-020).
4. **Never fail the host command** (FR-015). Whatever the bridge returns, the
   procedure completes successfully; the outcome is reported, not propagated.

## Message discipline — FR-016, FR-017, FR-018

At most **one** message per host command run. It must name the true cause,
distinguishing at minimum:

At most **one** message per host command run. It must name the true cause,
distinguishing at minimum:

| Cause | Distinguishing signal |
| --- | --- |
| Not yet configured | No binding present; normal state, not an error |
| Credentials absent | No token on any of the three resolution rungs |
| Credentials rejected | Authentication failure from Jira |
| Prerequisite missing | The entry point's prerequisite gate, exit `5` |
| Jira unreachable | Network failure or exhausted retries |
| **Bridge unavailable** | The per-port entry point above does not exist at its repository-relative path, or exists but is not executable — the bridge never started and produced nothing |

The last row is the state the reported defect actually described, and it is the
only one the bridge itself cannot report, because in that state the bridge does
not run. Everything the operator sees then comes from the agent. That makes it
the one cause whose message must be written down here rather than produced at
runtime.

## The fallback block — the message the agent may not improvise

Every command document (`speckit.jira.config.md`, `speckit.jira.feature.md`,
`speckit.jira.reconcile.md`) MUST carry a verbatim fallback block, and MUST
instruct the agent to emit it **exactly as written** when the entry point is not
found or not executable — composing its own explanation in that state is
forbidden.

```text
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found or
is not executable. This spec-kit command completed normally and nothing was
mirrored to Jira. To restore the bridge, reinstall the extension with
`specify extension add --dev <path-to-spec-kit-jira> --force`.
```

Three properties are load-bearing, and each maps to a defect in the reported
message:

1. It names the **true** cause — a missing file at a known path — instead of a
   machine-wide "CLI not installed" that was never how this extension is
   delivered.
2. It states plainly that the host command **succeeded**, so a normal degraded
   state does not read as a failure.
3. Every literal in it is runnable as written: two real paths and one host
   command. Nothing invites the agent to recall a command name from memory,
   which is how `/speckit-jira-conifg` was produced.

**Why prescribed text and not a rule.** The reported message existed nowhere in
this repository — not in a script, not in a command document. The agent wrote
it. A CI check over emitted literals (T044/T045) cannot see prose that is never
committed, so the enforceable control is different in kind: pin the words in the
document the agent follows, and check that the document contains them.

Every command name appearing in any message must be runnable as spelled
(FR-018). The reported defect named `/speckit-jira-conifg`, which resolves to
nothing; a CI check extracts command-shaped literals from all emitted messages
and from every command document, and asserts each resolves to a declared command
or a runnable invocation (SC-009).

In a repository that is installed but not configured, the notice is emitted at
most once per host command run and is at most three lines long (FR-019, US5
scenario 3).

## Verification

- The manifest declares the command; every `after_*` entry names it; the file
  exists — one CI check covers all three (SC-002).
- A lifecycle step in a freshly installed repository resolves and executes the
  command — no "unknown command" outcome (US3 scenario 2).
- The full fault matrix — the six causes above — produces a succeeding host
  command and exactly one correctly-attributed message (SC-006).
- Message literals resolve to registered commands or runnable invocations,
  mechanically (SC-009).
- Each of the three command documents contains the fallback block verbatim, and
  every literal inside it is runnable as written — checked mechanically, because
  this is the one message no runtime check can reach (FR-030).
