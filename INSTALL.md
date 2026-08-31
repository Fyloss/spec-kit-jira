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
   `.specify/extensions/jira-mirror/` in your repository automatically (and
   never writes into Spec Kit core's `.specify/scripts/` or
   `.specify/templates/`,
   FR-055/SC-009):

   ```sh
   specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip
   # or, while developing the extension itself:
   specify extension add --dev <path-to-spec-kit-jira> --force
   ```

   To pin a specific released version instead of always installing the latest,
   substitute the version for the placeholder:

   ```sh
   specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/download/v<X.Y.Z>/spec-kit-jira-mirror-<X.Y.Z>.zip
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
   /speckit.jira-mirror.config
   ```

   It binds the repository to a Jira project (metadata discovery), manages the
   README block, ensures `.gitignore` coverage, and **verifies** the hook
   registration the install performed. Each effect is reported separately.

3. Mirror your specs: `spec.md` / `plan.md` / `tasks.md` reconcile into Jira
   automatically at each Spec Kit lifecycle step, or run a reconcile manually.
   A bound repository needs **no environment variables** for this: the target
   project, the issue type, and the priority are all resolved from
   `.specify/jira/config.yml` and the binding `/speckit.jira-mirror.config` recorded.
   The `SPEC_KIT_JIRA_PROJECT_KEY` and `SPEC_KIT_JIRA_PLAN_CONTEXT` variables
   remain supported as explicit overrides, taking precedence over the
   config-derived values when set.

## The lifecycle hooks: active from install

Three properties, worth stating plainly:

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

### The hook registry belongs to the host, not to this extension

`.specify/extensions.yml` is **not opened by this extension at all** — not for
writing, and no longer for reading either. `specify extension add`
writes it from the manifest and is its only writer; keeping those entries
registered across reinstalls and upgrades is the host's job.

Two consequences follow, and both are deliberate. They are stated here because
you would otherwise have to discover them:

- **If the hooks are not registered, nothing happens — and nothing says so.**
  You will not get a warning, because the extension no longer looks. The signal
  is the silence: you finish a `/speckit.*` command and no ticket moves. The
  remedy is the host's own install command.

- **A hook you disable by hand may be re-enabled by a reinstall, without
  warning.** Setting `enabled: false` on an entry stops that event — until the
  next `specify extension add`, which rewrites the field to `true`
  unconditionally. This extension will neither prevent that nor report it.

Earlier versions reported on the registry and offered a repair. That report was
removed because it was an assertion about a fact the extension could not act on,
and because it was observed being confidently **wrong**: in a real repository it
reported all seven events missing while the registry plainly carried them, and
the reinstall it recommended changed nothing.

### Checking the hooks yourself

Open the file:

```bash
cat .specify/extensions.yml
```

Each of the seven events should carry an entry with `extension: jira-mirror` and
`enabled: true`. If one is missing or disabled, re-run the install:

```bash
specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip --force
```

(confirm the untrusted-source prompt with `y`).


## Verifying the install

- Inspect `.specify/extensions.yml` straight after installing: seven events, one
  `jira` entry each, `enabled: true`, `optional: false`.
- Run the bridge by its repository-relative path with nothing done in between —
  the install places nothing on your `PATH`, by design:

  ```sh
  bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh --help
  # on Windows:
  .specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 --help
  ```

- Re-run `/speckit.jira-mirror.config` on an unchanged project: the produced
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
- `/speckit.jira-mirror.seed` is a **command**, not one of the seven hook events above
  — a confirmation prompt cannot live in a lifecycle hook, so it does not
  appear in `.specify/extensions.yml`'s `hooks:` block. Confirm it is
  reachable instead by checking `provides.commands` in the extension's own
  manifest, or simply invoking it directly:

  ```sh
  bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh seed --help
  ```

  See the README's "Seeding a specification from existing Jira issues" for
  the ceremony itself.
