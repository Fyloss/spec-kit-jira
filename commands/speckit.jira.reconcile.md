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
   - **success** — the `counts.created` / `counts.updated` / `counts.
     recognised` / `counts.skipped` figures from the run summary. On a
     second run over an unchanged specification, `created` and `updated`
     are both `0`; `recognised` equals the story count and `skipped` does
     too — this is the correct signature of an idempotent re-run, not a
     failure to mirror anything;
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
| Binding predates this release | Exit `4`, message says the binding "predates parent support" | The project is already bound; its local binding is a version behind. Run `/speckit.jira.config` to refresh it (see INSTALL.md, "Upgrading to the parent-hierarchy release") |
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

## The story marker line

Immediately after each `### User Story` heading (or after the document's `#`
title, for a specification with no such headings), reconcile writes one HTML
comment line:

```markdown
<!-- speckit-jira story=7f3a9c1e40b2d85a ticket=PROJ-142 -->
```

This is how a **second** run recognises the ticket it already created instead of
mirroring the story again — the identifier is assigned once, persists across a
retitle, reorder, or a specification-folder rename, and is never recomputed. It
is spec-kit-jira's own bookkeeping; leave it exactly where it is. Deleting it (or
regenerating `spec.md` from the template) makes the next run treat that story as
new, mirroring it again — the ticket it used to point at is left untouched.

## The parent artifact

Every specification mirrors as one parent issue plus its children. The parent is
created first, before any child, and every child's creation carries the parent's
key. Immediately after the document's `#` title, reconcile writes one HTML
comment line naming the parent, using the same durable-identifier discipline as
the story marker:

```markdown
<!-- speckit-jira spec=3f2a91c04b7e6d18 ticket=PROJ-140 -->
```

The parent's description carries the specification's overview prose, a named
Success Criteria section, a named Out of Scope section, and — when the feature
folder holds an implementation plan — a named Implementation Plan section built
from `plan.md`'s `## Summary` prose. It never carries a list of user stories:
Jira already shows the children under their parent in its own issue view.

The child issue type is whichever type the project's binding records (an
operator answer, recorded once by `/speckit.jira.config`); the parent type is
derived from the project's issue-type hierarchy — the level immediately above
the child's, when exactly one type occupies it. A project with no level above
the child's, or two or more candidates at that level, refuses before any write,
naming every candidate.

A project whose parent type declares a required field the bridge cannot supply
(anything beyond summary, description, issue type, project, priority, reporter,
and — on the child type only, when the project's own metadata offers it — a
parent reference) refuses before any write too, naming every unsatisfiable
field of every affected type in one message, and a project whose child type's
create metadata offers no `parent` field at all refuses the same way. Both
refusals are reported as their own named cause, never a rejected-request or
transport error, and `--dry-run` predicts them exactly as a real run would.

## Recognition and the run summary

Before planning any write, reconcile reads back every ticket a story's marker
already names and verifies its identity marker. A recognised ticket is updated
(or skipped, if nothing changed) instead of duplicated. The run summary's
`counts` reflect this:

- `recognised` — stories bound to an existing ticket by this run.
- `assigned` — durable identifiers newly written into `spec.md` by this run.
- `skipped` — recognised tickets whose write was dropped because nothing
  changed (this is what makes a second, unchanged run a true no-op).

A story whose recorded ticket cannot be verified (a mismatched or missing
identity marker, a duplicate identifier, or a ticket claimed by another
specification) is reported in `warnings` and left untouched; it never blocks
its siblings.

## Configuring lifecycle safety: `phase_status_map` and `halted_statuses`

Two optional, hand-edited keys under a project entry in `config.yml` let
reconcile evaluate drift and operator-halted states against a ticket's real,
recognised status. Neither has a default table — an operator's configured
workflow is authoritative, and omitting both keeps this machinery inert
exactly as it was before recognition existed:

```yaml
projects:
  - key: COMP
    # ...
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
    halted_statuses:
      - "Blocked"
```

- `phase_status_map` maps a lifecycle event name (`after_specify`,
  `after_clarify`, `after_plan`, `after_tasks`, `after_implement`,
  `after_analyze`) to the Jira status that event implies. When the run was
  dispatched for one of these events, a recognised ticket already sitting
  **ahead** of that status raises a named drift warning; its content still
  reconciles, but reconcile never issues a status transition itself.
- `halted_statuses` names statuses the operator uses to pause a ticket by
  hand. A recognised ticket sitting in one of these statuses has its content
  write suppressed (not just its transition), with a named warning — an
  operator's manual hold is never silently overwritten.

A ticket carrying the Jira **Flagged** field is treated the same way as a
halted ticket: surfaced, its write withheld, and the flag itself is never
touched.

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
