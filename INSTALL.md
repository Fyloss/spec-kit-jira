# spec-kit-jira — Installation & Prerequisites

The reconcile bridge ships as **twin native ports** — Bash (macOS/Linux) and
PowerShell 7+ (Windows) — with identical observable behaviour (NFR-1). Install the
prerequisites for your platform, then run the one-command install ceremony.

## Prerequisites (NFR-4)

The prerequisite check runs **before any Jira interaction** and exits with code
`5`, naming the missing item, if any of these is absent:

| Requirement                      | Notes                                                                                                                                                                                                    |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Bash ≥ 4** (macOS/Linux port)  | macOS ships Bash **3.2** — the check detects and names this case explicitly. Install a newer Bash (e.g. `brew install bash`).                                                                            |
| **PowerShell 7+** (Windows port) | The sole Windows implementation.                                                                                                                                                                         |
| `curl`                           | Required for the Bash port HTTP transport (the Authorization header is passed off-argv via `curl --config`, never on the command line). Not required for the PowerShell port (uses `Invoke-RestMethod`). |
| `jq`                             | Required for the Bash port JSON handling and the canonical serializer. Not required for the PowerShell port (native JSON + port serializer).                                                             |
| `git`                            | Repository context and the managed README block.                                                                                                                                                         |

## Credentials (NFR-3 — eliminatory)

The API token is resolved in order: environment, then a retrieval command you
declare — there is no third rung, and no file in the workspace is ever read
for it. The resolved token **never** appears in argv, logs, errors, or traces
at maximum verbosity (SC-007). Set:

```sh
export JIRA_EMAIL="you@example.com"
export JIRA_API_TOKEN="…"        # or declare JIRA_PAT_COMMAND instead — see docs/CREDENTIALS.md
```

`JIRA_PAT_COMMAND` names a program run without a shell (its declared value is
split into a program and arguments on whitespace) to back the token with an OS
credential store or any other retrieval mechanism; a command that fails,
is absent, times out (5s), or produces no output is a reported failure, not a
silent fall-through. See [docs/CREDENTIALS.md](docs/CREDENTIALS.md) for
platform-specific examples, the CI/unattended arrangement, and the Windows
`Get-Secret` wrapper.

The committable team config (`.specify/jira/config.yml`) is credential-free;
credential-shaped values in either YAML layer are rejected at config time (exit 4).
`config.yml` also carries the team's `base_url` (030) — see
[`docs/07-configuration-and-secrets.md`](docs/07-configuration-and-secrets.md)
for why that is a choice to make knowingly, not merely a convenience.

## Install & configure

1. Install the extension with the official Spec Kit command — it creates
   `.specify/extensions/jira-mirror/` in your repository automatically (and never
   writes into Spec Kit core's `.specify/scripts/` or `.specify/templates/`,
   FR-055/SC-009):

   ```sh
   specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira.zip
   # or, while developing the extension itself:
   specify extension add --dev <path-to-spec-kit-jira> --force
   ```

   To pin a specific released version instead of always installing the latest,
   substitute the version for the placeholder:

   ```sh
   specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/download/v<X.Y.Z>/spec-kit-jira-<X.Y.Z>.zip
   ```

   Both release addresses are outside spec-kit's configured extension catalog, so
   the host raises an `⚠ Untrusted Source` panel and blocks on
   `Continue with installation? [y/N]:` — answer `y`. There is no `--yes` flag on
   `specify extension add`; with no stdin available the install prints `Aborted.`
   and installs **nothing**, which in a script can look like a silent no-op.

   **This step registers the lifecycle hooks and activates them.** See below.

2. Run the deterministic configuration ceremony — the one remaining step before
   anything reaches Jira:

   ```
   /speckit.jira.config
   ```

   It binds the repository to a Jira project (metadata discovery), manages the
   README block, ensures `.gitignore` coverage, and **verifies** the hook
   registration the install performed. Each effect is reported separately.

3. Mirror your specs: `spec.md` / `plan.md` / `tasks.md` reconcile into Jira
   automatically at each Spec Kit lifecycle step, or run a reconcile manually.
   A bound repository needs **no environment variables** for this: the target
   project, the issue type, and the priority are all resolved from
   `.specify/jira/config.yml` and the binding `/speckit.jira.config` recorded.
   The `SPEC_KIT_JIRA_PROJECT_KEY` and `SPEC_KIT_JIRA_PLAN_CONTEXT` variables
   remain supported as explicit overrides, taking precedence over the
   config-derived values when set.

## The lifecycle hooks: active from install

Four properties, and they are worth stating plainly because the previous release
got all four wrong:

- **Registered and active from the install itself.** The extension manifest
  declares all seven lifecycle events, so `specify extension add` writes them
  into your `.specify/extensions.yml` and they are live immediately. No
  configuration ceremony is needed to wire them up, and none can: registration
  belongs to the install.

- **Performed, not offered.** Each entry is registered non-optional, so your
  assistant performs the mirroring step as part of the host `/speckit.*` command
  rather than printing a suggestion for you to run later.

- **A hook failure never fails a spec-kit command.** Non-optional decides whether
  the step *happens*, not whether a failure propagates. Whatever the bridge finds
  — no binding yet, no credentials, Jira unreachable — the host command completes
  with its normal outcome and you get at most one message saying why.

- **The extension never modifies the hook registry.** `.specify/extensions.yml` is
  read-only to this extension in every state, from every command: it is not
  created, modified, reordered or reformatted, and your comments survive every
  run. The official install is that file's only writer. What the configuration
  ceremony does instead is read it, classify every event, and report:

  | Report | What it means, and what to do |
  | --- | --- |
  | `healthy` | All seven events present and enabled |
  | `incomplete` | An event has no entry. Re-run `specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira.zip --force` (confirm the untrusted-source prompt with `y`) |
  | `held_disabled` | You disabled an event. No mirroring runs for it, whatever the registry says. Release it with `/speckit.jira.config --enable-hook <event>` |
  | `duplicated` | A leftover entry from a version before manifest-declared hooks. Neither the install nor the extension can remove it — the report gives you the exact edit |
  | `unreadable` | The registry could not be read. The file is named; no claim is made about the hooks |

### Disabling one event

Set `enabled: false` on its entry in `.specify/extensions.yml` and run
`/speckit.jira.config` once. The ceremony records your decision in the gitignored
`.specify/jira/config.local.yml`, and from then on no mirroring runs for that
event **even though a later `specify extension add` will set `enabled: true` back
in the registry** — the official install rewrites that field unconditionally and
this extension may not correct it. Release the event with
`/speckit.jira.config --enable-hook <event>`.

### Upgrading from a release that registered its own hooks

Versions before manifest-declared hooks registered them themselves, in a
four-field shape carrying no owning-extension field. The official install matches on that field when it
purges, so those entries are **not replaced** — a second entry is added beside
each one, and every lifecycle step fires twice.

The extension reports this as `duplicated` and names each affected event. Removing
it is a one-time manual edit: open `.specify/extensions.yml` and delete, under
each named event, the entry that has **no** `extension: jira-mirror` line. The remaining
entry is the canonical one the install wrote.

### Upgrading to the parent-hierarchy release

Every installation that ran `/speckit.jira.config` on a release before the
parent hierarchy shipped is bound, but its `.specify/jira/config.local.yml`
records issue types as a plain name-to-id map with no hierarchy level and no
sub-task flag — the shape this release replaces. The first `reconcile` after
upgrading refuses with:

> `reconcile: the local binding for <PROJECT> predates parent support and does
> not record issue-type hierarchy. The project is bound — its binding is
> simply a version behind. Run /speckit.jira.config to refresh it (zero
> writes)`

This is expected, and it happens before the first read, so nothing is written
and nothing is lost. Run `/speckit.jira.config` once — the ceremony
rediscovers the project's issue types in the new shape, may ask which type
mirrors a user story when the base hierarchy level holds more than one
candidate, and then `reconcile` proceeds normally. Tickets already mirrored
flat (no parent, created before this release) are left exactly as they are —
they are not migrated; see the CHANGELOG's Migration note.

### Upgrading to the provenance-label release

Every ticket the mirror manages now carries a `speckit-<slug>` label. An
existing consumer's first `reconcile` after upgrading back-fills it onto
every ticket that predates this release — one `PUT` per ticket, counted in
`counts.updated` exactly like an ordinary content change. A repository that also
declares a `task` role sees its sub-tasks back-filled the same way, counted
under the task tier's own `counts.tasks.updated` rather than `counts.updated`. This is expected,
not a sign anything else changed: any labels an operator already applied by
hand are kept, and a specification with nothing else to reconcile will still
report updates for this reason alone, once.

### Upgrading to the boundary-preservation release

Every managed description now carries a boundary marker separating the
mirror's own content from anything else in the ticket. A ticket this mirror
wrote before this release has no marker yet; its first `reconcile` after
upgrading gains one, counted in `counts.updated` exactly like an ordinary
content change — no manual step, no command of its own. Where the mirror can
identify its own former output unambiguously, the transition duplicates
nothing: that content becomes the managed region and everything above it is
kept as human text. Where it cannot — most often because the description was
also hand-edited before this release — the whole existing description is
kept above a fresh managed region instead of guessing, the mirror's own prior
output may then appear twice, and the run's `warnings` names the ticket so a
human can trim the duplicate by hand. Nothing is ever discarded either way. A
second reconcile after the transition reports zero writes, the same
zero-churn guarantee as any other settled ticket.

## Verifying the install

- Inspect `.specify/extensions.yml` straight after installing: seven events, one
  `jira-mirror` entry each, `enabled: true`, `optional: false`.
- Run the bridge by its repository-relative path with nothing done in between —
  the install places nothing on your `PATH`, by design:

  ```sh
  bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh --help
  # on Windows:
  .specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 --help
  ```

- Re-run `/speckit.jira.config` on an unchanged project: the produced
  `config.local.yml` is **byte-identical** (determinism, SC-004), and
  `.specify/extensions.yml` is byte-identical too — comments included.
- Re-run a reconcile on an unchanged corpus: **zero writes** of every kind
  (zero-churn idempotency, SC-001). This is possible because the first run
  writes one HTML comment line after each user story's heading —
  `<!-- speckit-jira story=<id> ticket=<KEY> -->` — that lets the next run
  recognise the ticket it already created instead of mirroring the story
  again. Leave this line where the bridge puts it; it is invisible in a
  rendered specification and carries no Jira coordinate, only a random
  identifier and the issue key.
- Confirm recognition worked by reading the `--json` run summary's `counts`:
  a second, unchanged run reports `created: 0`, `updated: 0`, `recognised`
  equal to the story count, and `skipped` equal to it too — not just an
  absence of errors.
- A forced reinstall preserves the team config and re-registers the seven events
  without duplicating them.
- `/speckit.jira.seed` is a **command**, not one of the seven hook events above
  — a confirmation prompt cannot live in a lifecycle hook, so it does not
  appear in `.specify/extensions.yml`'s `hooks:` block. Confirm it is
  reachable instead by checking `provides.commands` in the extension's own
  manifest, or simply invoking it directly:

  ```sh
  bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh seed --help
  ```

  See the README's "Seeding a specification from existing Jira issues" for
  the ceremony itself.
