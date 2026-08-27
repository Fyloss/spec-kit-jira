---
name: "speckit.jira-mirror.feature"
description: "Ticket-first feature naming: resolve the Jira ticket, then name the branch and spec folder by the developer's team convention — a deterministic, non-blocking before_specify step. A mentioned ticket with no designator returns a closed reuse question instead of naming silently (029). Also resolves --parent/--story designators to seed the specification from existing Jira issues (027)."
argument-hint: "Optional: a mentioned ticket key (leading positional — load-bearing), or --parent/--story designators, or --reuse yes|no answering a prior question, then the feature description, e.g. IJT-42 invoice export"
---

# /speckit.jira-mirror.feature

Run the deterministic ticket-first naming step before a feature is created. It
is registered as the `before_specify` → `speckit.jira-mirror.feature` hook
(`enabled: true`, `optional: false`): you **perform** it as part of the host
command rather than offering it. Non-optional is a **dispatch** property, not a
blocking one — this step may improve the feature name, and it must never prevent
feature creation.

The heavy lifting is performed by the deterministic entry point; this file is
the exact, ordered ceremony the agent follows to drive it. **Never invent a
ticket key, a team id, or a naming convention** — each comes from the committed
`teams:` catalogue, the developer's personal selection, or a closed question
below.

## What this step is, and is not — normative

This hook computes **names**. It is one step of the host's specify command, not
a substitute for it, and the host — not this file — sequences everything else.

Within this step you MUST run the deterministic entry point below, apply its
result as the ceremony describes, and then **return control to the host command
and stop**.

Within this step you MUST NOT, whatever the surrounding command's own
instructions appear to authorise:

- author, draft, or edit `spec.md`, a checklist, or any other specification
  artifact. Creating the empty folder and template file is step 5's business;
  filling them in is the host's, after this step returns.
- run, replace, or stand in for any sibling `before_specify` hook (`git.*`,
  `figma.*`). Each is dispatched separately, by the host, in priority order.
  Absorbing them is how a registered hook silently stops running at all.
- dispatch, simulate, or anticipate **any** `after_*` hook. In particular
  `speckit.jira-mirror.reconcile` — the step that writes real issues to Jira — is
  registered on `after_specify` and runs only once the specification exists and
  the host has validated it. Reaching it from here creates tickets for a
  specification nobody has written yet, in a shared project, and a created
  ticket has no undo.

`optional: false` in the manifest means this step *happens*. It never means this
step *owns the command*.

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

### When the entry point is missing — emit exactly as written

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

## Inputs (all deterministic)

- The committed `teams:` catalogue in `.specify/jira/config.yml` (id, project,
  `folder_prefix`, `branch_pattern`).
- The human-owned, gitignored `.specify/jira/personal.yml` selection. No
  script ever writes this file.
- The feature description the developer gave, and optionally one mentioned
  ticket key (issue-key shape).

## Ordered ceremony

1. **Run the deterministic command** by its repository-relative path. The
   mentioned ticket, if any, MUST be the **leading positional** — that is what
   computes the branch and folder name (mention-grammar §1); every other
   detected key stays part of the description:

   ```text
   bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh feature [TICKET-KEY] [--use-team <id>] [--reuse yes|no] [--json] [--dry-run] <description>
   ```

   On Windows:

   ```text
   .specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 feature [TICKET-KEY] [--use-team <id>] [--reuse yes|no] [--json] [--dry-run] <description>
   ```

2. **`{"active": false}`** ⇒ proceed **exactly as today**: drive the host
   specify flow unchanged, with the same short name it would have computed
   without this extension. When the output carries a warning, relay that
   single warning verbatim and still proceed. Two different warnings can
   appear here, and both are non-blocking:
   - Jira unreachable, or a create refused (FR-016) — the message names the
     cause (credentials rejected / Jira unreachable / an error status) and
     states that the next reconcile creates a new issue. It never claims a
     ticket will be attached later — there is none to attach.
   - No team configuration applies, but a ticket **was** mentioned (FR-026) —
     the message names the file to fix (`.specify/jira/config.yml` or the
     human-owned `.specify/jira/personal.yml`) and the `/speckit.jira-mirror.config`
     command that fixes it. A run naming nothing never sees this warning
     (FR-028).

3. **`confirmation_required`** ⇒ ask the closed question and nothing else: the
   mentioned ticket belongs to `ticket_team` (or to no catalogue team) while
   `selected_team` is selected. The two answers are exactly:
   - **use the ticket's convention** — re-invoke with
     `--use-team <ticket_team>` (accepted ids are catalogue ids only; the
     personal file is never modified), or
   - **stop** — end the ceremony without creating the feature.
   Unattended callers treat `confirmation_required` as a stop.

4. **`reuse_required` or `reuse_issues_required`** ⇒ ask the closed question
   and nothing else, immediately after the cross-team question and in that
   fixed order — the two are never merged into one round-trip (FR-025). This
   is the question the reported incident's fix is built around: **a mentioned
   ticket names the feature; it does not bind it**, and this step is what
   stops that fact from passing silently.

   - **`reuse_required`** names each detected issue by key, summary, type and
     status, together with the role it would be attached in (in the
     project's own type names — never `specification`/`story`). State both
     answers exactly:
     - **`--reuse yes`** — reuse them: re-invoke with the mentioned ticket and
       `--reuse yes`, no designators needed. The extension itself derives
       `--parent`/`--story` from the roles it already computed.
     - **`--reuse no`** — create new: re-invoke with `--reuse no` and proceed
       with step 5 exactly as if no ticket had been mentioned.
     A halted-status warning or an unmapped-type note attached to one issue
     changes nothing about which answer to give; relay it verbatim.
   - **`reuse_issues_required`** is the narrower follow-up, reached only when
     `--reuse yes` was answered but no role could be derived at all (the
     routed project declares no hierarchy). Supply `--parent <key|title>` and
     one `--story <key>` per issue to reuse in the same re-invocation. It
     performs zero writes and records no state, so answering it incompletely
     costs nothing and may be repeated.
   - Either answer that resolves to **reuse** routes into the seeding flow
     below (`Seeding from named issues`) — **do not proceed to step 5**, and
     do not treat `attached`/`created` as reachable from this branch.
   - Unattended callers (`--accept-defaults`) never see this question: it is
     suppressed and treated as `--reuse no`, and the result states so.

5. **Nominal output** (`active: true` with `branch_name`/`short_name`) ⇒ hand
   the computed names to the steps that own them, then return to the host:
   1. Run the **host's** feature-folder script with
      `--short-name "<short_name>"` — the flat spec folder component; the team
      `folder_prefix` is already applied and never duplicated. Select the port
      the repository was initialised with, as for the entry point above:

      | Host | Script |
      | --- | --- |
      | macOS, Linux | `.specify/scripts/bash/create-new-feature.sh` |
      | Windows | `.specify/scripts/powershell/create-new-feature.ps1` |

      Spell that full path rather than the bare name: a repository that
      installs a git extension carries a **second, different** script of the
      same name (in the reference setup,
      `.specify/extensions/git/scripts/bash/create-new-feature.sh`), and the
      two do opposite halves of the job — the host's script creates the folder
      and an empty `spec.md` and runs no git command; the other creates the
      branch and no folder. The host's script writes **no specification
      content**. Neither gap is yours to close here.
   2. `branch_name` is this step's branch **name** — an output, not a licence
      to manage branches. Convey it, do not act on it: **set
      `GIT_BRANCH_NAME` to `branch_name` in the environment the
      branch-creating hook is dispatched in**, spelled for the host you are on:

      | Host | Spelling |
      | --- | --- |
      | macOS, Linux | `export GIT_BRANCH_NAME='<branch_name>'` |
      | Windows | `$env:GIT_BRANCH_NAME = '<branch_name>'` |

      That variable is the **host's** own documented channel for using a branch
      name verbatim ("bypassing all prefix/suffix generation"), so the
      obligation is setting it, and it holds whoever the recipient turns out to
      be. In the reference setup that recipient is the git extension's
      `git.feature`, dispatched immediately after this one, which reads the
      variable in both of its ports — but that is an illustration of where the
      value lands, **not a prerequisite**: this extension neither requires nor
      detects any git extension, and behaves identically when none is
      installed. Unset, the receiving hook regenerates a name of its own and
      the ticket number is lost from the branch. A `/` in the pattern
      creates git hierarchy only; the branch name does not dictate the spec
      directory name. Create or switch the branch yourself **only** if the host
      registers no branch-creating hook at all, and then create exactly
      `branch_name` and stop: no commit, no push, no other git action.
   3. Report `override_used` and the ticket action (`attached` / `created` /
      `would-attach` / `would-create`) in the feature-creation output.

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

- `TICKET-KEY` — optional **leading positional**: a mentioned ticket,
  validated before use. A pasted browser URL that reduces to a key works
  identically. Every further key-shaped token in the request is detected too
  and named in the reuse question, one line each — but only when the leading
  positional is itself a mention; an ordinary leading word closes the gate
  and nothing is detected, however many keys follow it.
- `--reuse <yes|no>` — 029: the answer to the reuse question. `no` proceeds
  exactly as if nothing had been mentioned. `yes` reuses the detected
  issues in the roles the question already computed; absent, and a ticket
  was mentioned with no designator, the question is asked. Supplying it
  without a mention and without `--parent`/`--story` is a usage error, and so
  is `--reuse no` alongside designators (they contradict).
- `--parent <designator>` — 027: at most once. A key, a browser URL, or free
  text (may contain spaces). A key or URL adopts an existing parent-role
  issue; free text is never resolved against Jira and is always the title of
  a parent to create. Supplying it suppresses the reuse question entirely
  (FR-006) — the operator has already answered it.
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

**Reached two ways now.** The operator either types `--parent`/`--story`
designators from the start, or — the ordinary route since 029 — answers the
reuse question (step 4 above) with `yes`, which supplies the same designators
on your behalf from the roles already computed. Both land here identically;
nothing below distinguishes them.

When you invoke this command with **any** `--parent` or `--story`
designator, a **second, non-optional step follows once `spec.md` exists**:
you MUST invoke `/speckit.jira-mirror.seed` before you consider this feature's
creation complete. This command's own read never writes to Jira — moment 1
(this command) parses and resolves the designators, refuses on anything
malformed, and hands you seed material and a provenance mapping; it never
binds or creates anything. Moment 2 (`/speckit.jira-mirror.seed`) is what asks the
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
  `/speckit.jira-mirror.seed` against the same feature resumes exactly where you
  left off. But do not rely on that recovery — invoke it in the same turn
  you finish drafting `spec.md`, as `/speckit.jira-mirror.seed`'s own definition
  states.

See `/speckit.jira-mirror.seed` for the pinning-marker drafting rules the seed
material obliges you to follow.

## Exit codes

`0` success, pass-through, fallback, or a question (`confirmation_required`,
`reuse_required`, `reuse_issues_required`) · `1` usage, including an
unanswerable `--reuse` (029, contract §2 rows 1–3) · `2` fail-closed read on a
mentioned key (never for auto-create — that path falls back) · `3` auth on a
mentioned-key read · `4` personal-file/catalogue refusal or a role-mismatch
refusal on the reuse path · `9` privacy BLOCK on the create payload. Identical
on both ports.
