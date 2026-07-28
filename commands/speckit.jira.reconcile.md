---
name: "speckit.jira.reconcile"
description: "Mirror the current feature's spec-kit artifacts into Jira — a deterministic, non-blocking reconcile fired by every after_* lifecycle event."
argument-hint: "Optional: a spec file path; defaults to the active feature's spec.md"
---

# /speckit.jira.reconcile

Mirror the current feature's spec-kit artifacts into Jira Cloud. This command is
what all six `after_*` lifecycle hooks fire (`after_specify`, `after_clarify`,
`after_plan`, `after_tasks`, `after_implement`, `after_analyze`), and it is
registered **non-optional**: you perform it as part of the host command rather
than offering it as a suggestion.

Non-optional is a **dispatch** property, not a blocking one. Whatever this
command finds, **the host spec-kit command completes normally** — see step 4.

## Invoking the bridge — normative

The install places **nothing** on `PATH`: `specify extension add` copies the
extension into the consuming repository's `.specify/extensions/jira/` and
installs no machine-wide executable. Invoke the entry point by its
**repository-relative path**, selecting the port from the host:

| Host | Entry point |
| --- | --- |
| macOS, Linux | `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` |
| Windows | `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` |

You MUST NOT invoke a bare `spec-kit-jira` command name. No such command exists
in a consuming repository, and assuming it does is what produced the reported
"spec-kit-jira CLI not installed" message.

## Ordered procedure

1. **Locate the feature** — read `.specify/feature.json` for the active feature
   directory and use its `spec.md`, unless a spec file path was passed as the
   argument. **With no active feature the step is inert**: do nothing and report
   nothing.

2. **Invoke the bridge** by the repository-relative path above, passing the spec
   file and `--json`:

   ```text
   .specify/extensions/jira/scripts/bash/spec-kit-jira.sh reconcile <spec-file> --json
   ```

   On Windows:

   ```text
   .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 reconcile <spec-file> --json
   ```

3. **Interpret the outcome and report exactly one line** — never more than one
   message per host command run, whatever the outcome:
   - **success** — the `counts.created` / `counts.updated` figures from the run
     summary;
   - **degraded** — one warning naming the true cause, from the table below;
   - **disabled** — for an event the operator disabled, the bridge exits `0`
     silently. Report **nothing at all**; do not announce that it was skipped.

4. **Never fail the host command.** Whatever the bridge returns, this procedure
   completes successfully. The outcome is **reported, not propagated**: a Jira
   mirror that could not run is never a reason for `/speckit.plan` or
   `/speckit.implement` to fail.

## Message discipline — the six distinguished causes

At most **one** message per host command run, naming the **true** cause:

| Cause | Distinguishing signal | What to say |
| --- | --- | --- |
| Not yet configured | The bridge exits `0` and reports no binding | At most three lines: this repository is not yet bound to a Jira project; run `/speckit.jira.config` |
| Credentials absent | Exit `4`, no token on any of the three resolution rungs | The token resolved through none of env, OS secret manager, or `.specify/jira/.env` |
| Credentials rejected | Exit `3` | Jira rejected the credentials — they exist but are not accepted |
| Prerequisite missing | Exit `5` | The named prerequisite is missing; relay the entry point's own message |
| Jira unreachable | Exit `2` after exhausted retries | Jira could not be reached; nothing was mirrored |
| **Bridge unavailable** | The entry point above does not exist at its repository-relative path, or exists but is not executable | Emit the fallback block below **verbatim** |

The last row is the only cause the bridge cannot report on, because in that state
it never starts and produces nothing. Everything the developer sees then comes
from you — which is why its text is fixed here rather than composed at runtime.

## The fallback block — emit exactly as written

When the entry point is not found or is not executable, emit the following text
**exactly as written**. Do not paraphrase it, do not summarise it, and do not
compose your own explanation of the situation:

```text
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found or
is not executable. This spec-kit command completed normally and nothing was
mirrored to Jira. To restore the bridge, reinstall the extension with
`specify extension add --dev <path-to-spec-kit-jira> --force`.
```

## Command literals — normative

Every command name you put in a message must be runnable exactly as spelled:

- an assistant command of this extension is one of `/speckit.jira.config`,
  `/speckit.jira.feature`, `/speckit.jira.reconcile` — never recalled from
  memory, never abbreviated;
- an invocation of the bridge is always one of the two repository-relative paths
  in the table above;
- a host command is given in the form the operator actually runs.

## Flags

- `<SPEC-FILE>` — optional positional: the specification to mirror; defaults to
  the active feature's `spec.md`.
- `--json` — emit the machine-readable run summary (`run-summary.schema.json`).
- `--dry-run` — compute the full action set and report it, writing nothing to
  Jira. The dry-run action set equals the real run's exactly.
- `--on-drift=abort|proceed` — drift handling (default `abort`).
- `--verbose` — extra diagnostics (the token never appears, even here).
- `--help` — usage; exits `0`.

## Exit codes

`0` success, an inert run, or a reported degraded state · `1` usage · `2`
fail-closed read or Jira unreachable · `3` auth · `4` config refusal · `5`
prerequisite failure · `9` privacy BLOCK. Monotonically escalating
(Constitution III); identical on both ports.

**None of these ever becomes the host command's exit code.** They are what the
bridge returns to this procedure; what this procedure returns to the host is
always success.
