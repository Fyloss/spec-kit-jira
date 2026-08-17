---
name: "speckit.jira.feature"
description: "Ticket-first feature naming: resolve the Jira ticket, then name the branch and spec folder by the developer's team convention — a deterministic, non-blocking before_specify step. Also resolves --parent/--story designators to seed the specification from existing Jira issues (027)."
argument-hint: "Optional: a mentioned ticket key, or --parent/--story designators, then the feature description, e.g. IJT-42 invoice export"
---

# /speckit.jira.feature

Run the deterministic ticket-first naming step before a feature is created. It
is registered as the `before_specify` → `speckit.jira.feature` hook
(`enabled: true`, `optional: false`): you **perform** it as part of the host
command rather than offering it. Non-optional is a **dispatch** property, not a
blocking one — this step may improve the feature name, and it must never prevent
feature creation.

The heavy lifting is performed by the deterministic entry point; this file is
the exact, ordered ceremony the agent follows to drive it. **Never invent a
ticket key, a team id, or a naming convention** — each comes from the committed
`teams:` catalogue, the developer's personal selection, or a closed question
below.

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
"spec-kit-jira CLI not installed" message. Invoke the Bash entry point **through
the interpreter** (`bash <path>`) rather than by bare path: a zip install on an
older host does not always restore the executable bit, and the interpreter form
works either way (026 FR-016).

### When the entry point is missing — emit exactly as written

When the entry point is not found, emit the following text **exactly as
written**. Do not paraphrase it, do not summarise it, and do not compose your
own explanation of the situation:

```text
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found.
This spec-kit command completed normally and nothing was mirrored to Jira. To
restore the bridge, reinstall the extension with
`specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip --force`
(it will ask you to confirm an untrusted-source prompt — answer y).
```

## Inputs (all deterministic)

- The committed `teams:` catalogue in `.specify/jira/config.yml` (id, project,
  `folder_prefix`, `branch_pattern`).
- The human-owned, gitignored `.specify/jira/personal.yml` selection. No
  script ever writes this file.
- The feature description the developer gave, and optionally one mentioned
  ticket key (issue-key shape).

## Ordered ceremony

1. **Run the deterministic command** by its repository-relative path:

   ```text
   bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh feature [TICKET-KEY] [--use-team <id>] [--json] [--dry-run] <description>
   ```

   On Windows:

   ```text
   .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 feature [TICKET-KEY] [--use-team <id>] [--json] [--dry-run] <description>
   ```

2. **`{"active": false}`** ⇒ proceed **exactly as today**: drive the host
   specify flow unchanged, with the same short name it would have computed
   without this extension. When the output carries a warning (Jira unreachable
   or a create refused — FR-016), relay that single warning verbatim and still
   proceed; reconciliation attaches the ticket later.

3. **`confirmation_required`** ⇒ ask the closed question and nothing else: the
   mentioned ticket belongs to `ticket_team` (or to no catalogue team) while
   `selected_team` is selected. The two answers are exactly:
   - **use the ticket's convention** — re-invoke with
     `--use-team <ticket_team>` (accepted ids are catalogue ids only; the
     personal file is never modified), or
   - **stop** — end the ceremony without creating the feature.
   Unattended callers treat `confirmation_required` as a stop.

4. **Nominal output** (`active: true` with `branch_name`/`short_name`) ⇒ drive
   the host flow with the computed names:
   1. `create-new-feature.sh --short-name "<short_name>"` — the flat spec
      folder component; the team `folder_prefix` is already applied and never
      duplicated.
   2. Create/switch to the branch named exactly `branch_name` (a `/` in the
      pattern creates git hierarchy only — the branch name does not dictate
      the spec directory name).
   3. Report `override_used` and the ticket action (`attached` / `created` /
      `would-attach` / `would-create`) in the feature-creation output.

> **A mentioned ticket names the feature; it does not bind it.** `attached`
> means this command validated the key and derived the branch and folder from
> it — nothing more. No marker is written into `spec.md` (it does not even
> exist yet at `before_specify`), so the following `reconcile` sees an unbound
> specification and creates a **new** parent plus one issue per drafted user
> story, *alongside* the mentioned ticket rather than in it. That is by design:
> the bridge never adopts a ticket it did not create unless the operator names
> it as a designator.
>
> **State it before step 4.1**, while nothing has been created yet — the
> answer changes what you run next:
>
> - the operator is happy with new issues alongside the mentioned ticket ⇒
>   proceed with step 4 unchanged;
> - the operator wanted that existing issue reused ⇒ **do not create the
>   feature**. Re-invoke this command with `--parent`/`--story` instead, and
>   follow with `/speckit.jira.seed`.
>
> Those flags are honoured at **this** invocation only. Once the feature has
> been created without them, `/speckit.jira.seed` refuses `REF-EXISTS`
> (retro-seeding is out of scope) and the only paths left are a brand-new
> specification or a link made by hand in Jira. Raising it one step too late
> costs the operator the whole feature folder.

## Behaviour rules (normative)

- **Ticket resolution precedes naming** (FR-013): a mentioned key is validated
  against Jira (fail-closed — never substitute another key); with no key the
  ticket is guarded-created in the effective team's project using the
  binding's resolved story-type id. The PASS-1 privacy guard runs before any
  write (BLOCK ⇒ exit 9, zero writes).
- **Non-blocking fallback** (FR-016): Jira unreachable or a create refused ⇒
  `{active:false}` plus exactly one warning, exit 0. Never retry into a block.
- **No selection, no change** (FR-017): without a catalogue or a personal
  selection the entire flow is byte-for-byte today's behaviour — zero Jira
  calls.
- An invalid personal file is a located error naming
  `.specify/jira/personal.yml` and listing the valid team ids (exit 4);
  credential-shaped values are refused without being echoed (FR-018).

## Flags

- `TICKET-KEY` — optional positional: a mentioned ticket, validated before use.
- `--parent <designator>` — 027: at most once. A key, a browser URL, or free
  text (may contain spaces). A key or URL adopts an existing parent-role
  issue; free text is never resolved against Jira and is always the title of
  a parent to create.
- `--story <designator>` — 027: repeatable. A key or a browser URL naming a
  story-role issue. **Argv order is normative** (FR-054) — it fixes both the
  order the drafted user stories must be pinned in and the order the seed
  material below lists them.
- `--use-team <id>` — the answer to the cross-team closed confirmation;
  catalogue ids only; per-feature effect, the personal file stays untouched.
- `--json` — emit the canonical machine-readable result.
- `--dry-run` — predict the ticket action (`would-attach` / `would-create`)
  and compute the names with zero Jira writes.
- `--help` — usage; exits `0`.

## Seeding from named issues (027) — the mandatory follow-up

When you invoke this command with **any** `--parent` or `--story`
designator, a **second, non-optional step follows once `spec.md` exists**:
you MUST invoke `/speckit.jira.seed` before you consider this feature's
creation complete. This command's own read never writes to Jira — moment 1
(this command) parses and resolves the designators, refuses on anything
malformed, and hands you seed material and a provenance mapping; it never
binds or creates anything. Moment 2 (`/speckit.jira.seed`) is what asks the
operator to confirm and performs the writes.

- **With designators, and Jira unreachable** ⇒ this command exits non-zero
  (`EXIT_FAILCLOSED`) rather than falling back to `{active:false}`. Proceeding
  without a reliable read would create exactly the duplicate issues this
  feature exists to prevent. Relay the failure; do not retry into a
  successful-looking fallback.
- **With no designator at all** ⇒ nothing here changes: the ordinary
  fallback behaviour of the section above applies untouched, and there is no
  follow-up step.
- **Forgetting the follow-up is recoverable, never silently destructive**:
  moment 1 already recorded a seeded-not-bound state (the folder and
  `spec.md` exist, nothing was written to Jira). A later invocation of
  `/speckit.jira.seed` against the same feature resumes exactly where you
  left off. But do not rely on that recovery — invoke it in the same turn
  you finish drafting `spec.md`, as `/speckit.jira.seed`'s own definition
  states.

See `/speckit.jira.seed` for the pinning-marker drafting rules the seed
material obliges you to follow.

## Exit codes

`0` success, pass-through, fallback, or `confirmation_required` · `1` usage ·
`2` fail-closed read on a mentioned key (never for auto-create — that path
falls back) · `3` auth on a mentioned-key read · `4` personal-file/catalogue
refusal · `9` privacy BLOCK on the create payload. Identical on both ports.
