---
name: "speckit.jira-mirror.reconcile"
description: "Mirror the current feature's spec-kit artifacts into Jira — a deterministic, non-blocking reconcile fired by every after_* lifecycle event."
argument-hint: "Optional: a spec file path; defaults to the active feature's spec.md"
---

# /speckit.jira-mirror.reconcile

Mirror the current feature's spec-kit artifacts into Jira Cloud. This command is
what all six `after_*` lifecycle hooks fire (`after_specify`, `after_clarify`,
`after_plan`, `after_tasks`, `after_implement`, `after_analyze`), and it is
registered **non-optional**: you perform it as part of the host command rather
than offering it as a suggestion.

Non-optional is a **dispatch** property, not a blocking one. Whatever this
command finds, **the host spec-kit command completes normally** — see step 4.

## Invoking the bridge — normative

The install places **nothing** on `PATH`: `specify extension add` copies the
extension into the consuming repository's `.specify/extensions/jira-mirror/` and
installs no machine-wide executable. Invoke the entry point by its
**repository-relative path**, selecting the port from the host:

| Host | Entry point |
| --- | --- |
| macOS, Linux | `.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh` |
| Windows | `.specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1` |

You MUST NOT invoke a bare `spec-kit-jira` command name. No such command exists
in a consuming repository, and assuming it does is what produced the reported
"spec-kit-jira CLI not installed" message. Invoke the Bash entry point **through
the interpreter** (`bash <path>`) rather than by bare path: a zip install on an
older host does not always restore the executable bit, and the interpreter form
works either way (026 FR-016).

## Ordered procedure

1. **Locate the feature** — read `.specify/feature.json` for the active feature
   directory and use its `spec.md`, unless a spec file path was passed as the
   argument. **The target is always that feature's own `spec.md` — never any
   other artifact, whichever host command just produced it.** `plan.md`,
   `tasks.md`, `research.md`, `data-model.md`, `quickstart.md`,
   `contracts/api.md`, and an analysis output are never targets, for this event
   or any other: this rule holds identically across all six `after_*` events.
   **With no active feature the step is inert**: do nothing and report nothing.

2. **Invoke the bridge** by the repository-relative path above, passing the spec
   file and `--json`. You MUST first set `SPEC_KIT_JIRA_HOOK_EVENT` to the
   lifecycle event that fired this invocation — the bridge is told nothing
   else about which step it is running for, and never infers it (contract
   `lifecycle-event.md` §2, §5 invariant E1). No new flag exists for this;
   the variable is the one door:

   | Host command | Hook | Event value |
   | --- | --- | --- |
   | `/speckit.specify` | `after_specify` | `after_specify` |
   | `/speckit.clarify` | `after_clarify` | `after_clarify` |
   | `/speckit.plan` | `after_plan` | `after_plan` |
   | `/speckit.tasks` | `after_tasks` | `after_tasks` |
   | `/speckit.implement` | `after_implement` | `after_implement` |
   | `/speckit.analyze` | `after_analyze` | `after_analyze` |

   ```text
   SPEC_KIT_JIRA_HOOK_EVENT=after_specify bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh reconcile <spec-file> --json
   ```

   On Windows:

   ```text
   $env:SPEC_KIT_JIRA_HOOK_EVENT = 'after_specify'; .specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 reconcile <spec-file> --json
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

## Message discipline — the nine distinguished causes

At most **one** message per host command run, naming the **true** cause:

| Cause | Distinguishing signal | What to say |
| --- | --- | --- |
| Rejected target | Exit `1`, message says a file "is not a feature specification" | Relay the entry point's own message verbatim — it names the rejected path and, when one exists, the correct `spec.md` for that folder. This is a caller defect (this procedure invoked the wrong artifact), not a degraded Jira state |
| Not yet configured | The bridge exits `0` and reports no binding | At most three lines: this repository is not yet bound to a Jira project; run `/speckit.jira-mirror.config` |
| Binding predates this release | Exit `4`, message says the binding "predates parent support" | The project is already bound; its local binding is a version behind. Run `/speckit.jira-mirror.config` to refresh it (see INSTALL.md, "Upgrading to the parent-hierarchy release") |
| Credentials absent, or a declared retrieval command failed | Exit `4`, no token from either resolution rung | The token resolved through neither `JIRA_API_TOKEN` nor a declared `JIRA_PAT_COMMAND`; a declared command that failed names the reason (missing, non-zero exit, timeout, empty output) |
| Credentials rejected | Exit `3` | Jira rejected the credentials — they exist but are not accepted |
| Routing unresolved | Exit `4`, message starts "routing could not be resolved for" | Relay the bridge's own message verbatim: it reports what each of the four routing ranks found — the committed rules, the team folder prefixes, the developer's own team selection, and `routing_default` — and offers all three remedies. Do **not** shorten it to "add routing_default": that key is optional, and a repository shared by several teams may have declined it deliberately |
| Prerequisite missing | Exit `5` | The named prerequisite is missing; relay the entry point's own message |
| Jira unreachable | Exit `2` after exhausted retries | Jira could not be reached; nothing was mirrored |
| **Bridge unavailable** | The entry point above does not exist at its repository-relative path | Emit the fallback block below **verbatim** |

The last row is the only cause the bridge cannot report on, because in that state
it never starts and produces nothing. Everything the developer sees then comes
from you — which is why its text is fixed here rather than composed at runtime.

## The fallback block — emit exactly as written

When the entry point is not found, emit the following text **exactly as
written**. Do not paraphrase it, do not summarise it, and do not compose your
own explanation of the situation:

```text
Jira bridge not available: the entry point
.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1) was not found.
This spec-kit command completed normally and nothing was mirrored to Jira. To
restore the bridge, reinstall the extension with
`specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip --force`
(it will ask you to confirm an untrusted-source prompt — answer y).
```

## Command literals — normative

Every command name you put in a message must be runnable exactly as spelled:

- an assistant command of this extension is one of `/speckit.jira-mirror.config`,
  `/speckit.jira-mirror.feature`, `/speckit.jira-mirror.reconcile` — never recalled from
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
operator answer, recorded once by `/speckit.jira-mirror.config`); the parent type is
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

## The provenance label (017)

Every ticket the mirror manages — the specification-role parent, each story-role
child, and each task-role sub-task — carries the label `speckit-<folder>`, where
`<folder>` is the specification's own folder reference (`speckit-001-test-page`
for `specs/001-test-page/`). Searching that label in Jira returns exactly that
specification's tickets and nothing else.

The label is additive: it is merged with any label the project's configuration
already sends and with any label an operator applied by hand, and the mirror
never removes one it did not add. A ticket that predates this behaviour gains
the label once, on its next ordinary run, counted as an ordinary `updated`
(`counts.tasks.updated` for a sub-task) — not as drift, and with no warning.
Once the estate is labelled, a further unchanged run reports zero created and
zero updated.

A project whose issue types cannot hold labels mirrors every ticket exactly as
before, with one named warning per issue type saying the label could not be
applied. A ticket whose write is suppressed — halted, flagged, drifted, or a
withheld sub-task — is not labelled either: the label follows the write and is
never an exception to a hold.

## The task tier (012)

When `tasks.md` sits beside the mirrored specification and the project's
binding declares a `task` role, every recognisable task line becomes one
sub-task under the story its `[US<N>]` tag or enclosing `## Phase …: User
Story <N>` heading names. A task with no such attribution — and a task
attributed to a story the specification does not contain — mirrors nothing
and is reported once, by its reference; every other task still mirrors. A
story that carries no task mirrors exactly as it did before this tier
existed.

Each sub-task carries its own durable identifier, written back into
`tasks.md` on the same line-insertion discipline as the story marker.
Completion:

- **checking a task off** transitions its already-recognised sub-task to
  whichever status the project's workflow classifies as done — never a
  named status, in either port, in any language;
- a run over a sub-task already in that status issues neither a read nor a
  transition (FR-031);
- a task reverting from checked to unchecked never pulls its sub-task
  backward on its own — the divergence is reported by key and only moves
  under `--on-drift=proceed` (FR-032);
- completion is never read back: a sub-task a person finishes in Jira never
  checks its task off in `tasks.md` (FR-033).

The run summary reports the tier under `counts.tasks` — present only when a
`task` role is declared — with its own `created`, `updated`, `transitioned`,
`unchanged`, `skipped` and `withheld` counts, alongside (never folded into)
the specification and story counts above.

### The withheld tier and its remedy

A sub-task type whose Jira project requires a field the bridge cannot
supply — no recorded default, no answer this run — withholds the **whole**
task tier: the specification and its stories still mirror exactly as they
would with no `task` role declared, zero sub-task writes happen, and the
summary names the tier `withheld` rather than reading as a complete mirror.
The remedy is the same consolidated field-defaults question every other
tier answers (see below) — once the operator records a default or answers
with `--field-value`, the very next run creates exactly the sub-tasks that
were withheld. There is no cleanup step, no flag, and no repair command.

## Configuring lifecycle safety: `phase_status_map` and `halted_statuses`

Two optional, hand-edited keys under a project entry in `config.yml` let
reconcile evaluate drift, operator-halted states, and board advancement
against a ticket's real, recognised status. Neither has a default table — an
operator's configured workflow is authoritative, and omitting both keeps this
machinery inert exactly as it was before recognition existed:

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
  dispatched for one of these events, a recognised ticket carries that status
  as its declared step: if the ticket already sits **ahead** of it, reconcile
  raises a named drift warning and reconciles content without moving anything;
  otherwise it looks up the ticket's real available transitions and, when
  exactly one of them lands on the declared step, issues it (023). Any other
  shape — two candidates landing on it, one gated on a field reconcile does
  not hold, or none reaching it at all — withholds the move instead, with one
  warning naming the ticket and the reason.
- `halted_statuses` names statuses the operator uses to pause a ticket by
  hand. A recognised ticket sitting in one of these statuses has its content
  write suppressed (not just its transition), with a named warning — an
  operator's manual hold is never silently overwritten.

A ticket carrying the Jira **Flagged** field is treated the same way as a
halted ticket: surfaced, its write withheld, and the flag itself is never
touched.

### Per-role mapping (023)

The shape above is role-blind: it routes wholesale to the `story` role, for
back-compatibility with every mapping written before this feature. An Epic
and a Story rarely share a workflow, so `phase_status_map` may instead declare
one mapping per hierarchy role — `specification`, `story`, and `task` — each
with its own set of lifecycle events and status names:

```yaml
projects:
  - key: COMP
    hierarchy: { specification: "Epic", story: "Story", task: "Sub-task" }
    phase_status_map:
      specification:
        after_plan: "Building"
      story:
        after_specify: "To Do"
        after_plan: "In Progress"
```

One run under `after_plan` here advances the parent to "Building" and every
story to "In Progress" — never comparing a ticket of one role against another
role's step name. A role omitted from the mapping (here, `task`) is never
evaluated at all: no warning, no request, exactly as if the project declared
no mapping. The two shapes — legacy (lifecycle-event keys at the top level)
and per-role (hierarchy-role keys, each holding its own lifecycle-event
mapping) — may not be mixed in one project's `phase_status_map`; a project
declaring both refuses to load.

## The consolidated field-defaults question (011)

Before writing any creation, the bridge plans the run — the same computation
`--dry-run` performs — and when that plan contains a creation for which
either a recorded default is about to be sent, or a required field is
unsatisfiable with nothing recorded for it, it stops before any write and
emits one `confirmation-pending` object naming every such field once, with
its recorded value where one exists. Ask the operator to keep or override
each named field, then re-invoke:

- keep the recorded values — re-invoke with `--accept-defaults`;
- override one or more fields — re-invoke with
  `--field-value <KEY>=<Type>=<Label>=<Value>` (repeatable), which takes
  precedence over the recorded default for this run only;
- both may be given together: an explicit `--field-value` overrides its own
  field even under `--accept-defaults`.

A **decline** — the operator dismisses the question, or the conversation
ends before they answer — is resumed with `--accept-defaults`: re-invoke with `--accept-defaults`. There is no decline flag and none should be
invented; the bridge receives one instruction, proceed with what is
recorded, and the run summary names that reason.

### Declaring an unreachable operator (research R4, contract §3.10)

Whether an operator can be asked is **stated by the caller**, never inferred
by the entry point — it never sniffs a TTY, because the bridge is invoked by
an agent and so never has one even when the operator is very much reachable.
A caller that cannot reach an operator — a continuous-integration pipeline,
an unattended agent run, a direct script invocation — MUST pass
`--accept-defaults` on its **first** invocation.

An `after_*` lifecycle hook is not such a caller: it fires this very
procedure, so the operator is reached through the conversation you are
already conducting. A hook-fired run therefore stops at the question exactly
as an ordinary run does, and step 4 keeps the host command green while it
waits.

## Flags

- `<SPEC-FILE>` — optional positional, accepting a feature specification file
  only: the target must be a feature folder's own `spec.md`; defaults to the
  active feature's `spec.md` when omitted. Any other path — `plan.md`,
  `tasks.md`, a research or analysis artifact, a differently named file —
  is refused before any read, write, or network call (the rejected-target
  cause above).
- `--json` — emit the machine-readable run summary (`run-summary.schema.json`).
- `--dry-run` — compute the full action set and report it, writing nothing to
  Jira. The dry-run action set equals the real run's exactly.
- `--force` (021) — skip the state-phase short-circuit and run the full
  pipeline even when the recorded state document matches every local input.
  Neither `--force` nor `--dry-run` ever reads or writes that document.
- `--accept-defaults` — proceed with every recorded default, skipping the
  consolidated question (011).
- `--field-value <KEY>=<Type>=<Label>=<Value>` — repeatable; an answer for
  this run only, taking precedence over a recorded default (011).
- `--on-drift=abort|proceed` — drift handling (default `abort`).
- `--verbose` — extra diagnostics (the token never appears, even here).
- `--help` — usage; exits `0`.

The shared command-line parser also accepts `speckit.jira-mirror.config`'s own flags —
`--style`, `--child-type`, `--issue-type`, `--field-default`, `--task-mirror`,
`--use-team`, `--enable-hook` — on `reconcile` without refusing them. They have
**no effect** here: `reconcile` never reads the values this parser stores for
them. Pass them to `speckit.jira-mirror.config` instead, where they are documented
and acted on.

## Exit codes

`0` success, an inert run, or a reported degraded state · `1` usage · `2`
fail-closed read or Jira unreachable · `3` auth · `4` config refusal · `5`
prerequisite failure · `9` privacy BLOCK. Monotonically escalating
(Constitution III); identical on both ports.

**None of these ever becomes the host command's exit code.** They are what the
bridge returns to this procedure; what this procedure returns to the host is
always success.
