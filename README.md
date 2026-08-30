# spec-kit-jira

Enterprise Spec Kit ↔ Jira Cloud bridge: mirrors a repository's spec-kit
artifacts (`spec.md`, `plan.md`, `tasks.md`) into Jira as a self-healing,
idempotent, fail-closed bridge. Configurable workflows and hierarchies
(Scrum/SAFe), multi-project routing, Gherkin-rich stories, team-shareable
config. Twin native ports: Bash (macOS/Linux) and PowerShell 7+ (Windows) —
no build step, no download step.

## Install

This repository is a [Spec Kit extension](https://github.com/github/spec-kit/tree/main/extensions).
Install it into a consuming repository with the official Spec Kit command,
which creates `.specify/extensions/jira-mirror/` there automatically:

```sh
specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip
# or, while developing the extension itself:
specify extension add --dev <path-to-spec-kit-jira> --force
```

Installing from this address is outside spec-kit's configured extension catalog, so the
host raises an `⚠ Untrusted Source` panel and asks `Continue with installation? [y/N]:` —
answer `y`. With no stdin available (e.g. piped into a non-interactive script) it prints
`Aborted.` and installs nothing, which can otherwise look like a silent no-op.

Then run the one-command install ceremony in the consuming repository:

```text
/speckit.jira-mirror.config
```

See [INSTALL.md](INSTALL.md) for prerequisites (Bash ≥ 4 or PowerShell 7+,
`curl`, `jq`, `git`) and credential setup — the API token never enters the
tree, argv, logs, or traces. Once the three connection settings below are in
place, a bound repository needs **no further environment variables** to mirror
specs: the target project, issue type, and priority are all resolved from
`.specify/jira/config.yml` and the discovered binding — see
[INSTALL.md's mirroring step](INSTALL.md#install--configure) for the override
variables that remain supported.

## How the bridge fits your project — team-managed and company-managed

Nothing about your Jira is compiled into the extension: no default issue-type
name, no status name, no field id. `/speckit.jira-mirror.config` **detects the project
style first**, then follows the path that style allows, and records what it
found in the gitignored `.specify/jira/config.local.yml`. The committed
`config.yml` holds only what your team decides.

**Issue types and hierarchy.** The issue types, their hierarchy levels and their
sub-task flags come from the project's own create metadata. Three mirror roles —
`specification`, `story`, `task` — are resolved in one pass with the precedence
*declared → operator → derived*: a role is derived only where the level offers
exactly one non-sub-task candidate, otherwise the ceremony asks once and records
your answer under `hierarchy:` in `config.yml`. A project offering both `Epic`
and `Service Category` above `Story` is a question, never a guess, and an
unresolved role refuses at configuration time with zero writes.

**What a team-managed project may not do, refused before any ticket exists.** A
company-managed project may declare levels above the Epic tier, and the bridge
uses them if the instance declares them. A team-managed project has only an
Epic-tier parent and sub-task children — so a configured mapping that asks for a
level above that tier is refused at config time (exit `4`, zero writes) rather
than at the first reconcile, which would already have created tickets it cannot
parent. The "Epic tier" is the top non-sub-task hierarchy level **as discovered**
in your project, never a name compiled into the script.

**Fields.** Field discovery reads the project's own field schema, not the global
field catalogue — the distinction that matters for a team-managed project, where
the estimation field is project-scoped rather than the instance-wide custom
field. Numeric candidates are ranked by documented signals and the top one is
*proposed for confirmation*, never assumed. The flagged field is identified by
shape, not by id.

**Workflow.** Statuses and their categories are read from the project, and
`phase_status_map` in `config.yml` says where each spec-kit lifecycle event
should leave a ticket, per role, by the destination status name spelled exactly
as your project spells it. The move is then resolved against the ticket's **real
available transitions** — never against a declared workflow: a ticket moves only
when exactly one available transition lands on that status and is not gated on a
field the bridge does not hold. Two candidates, a gated one, or none reachable
in a single move each withhold the move and warn once, naming the ticket and the
reason. A project that declares no mapping is never moved at all, and statuses
listed under `halted_statuses` are surfaced and left alone — no transition, no
content write.

The whole binding is re-derivable: a forced reinstall wipes and rewrites the
extension folder without touching a single setting, because the configuration
lives at `.specify/jira/`, outside it.

## Step-by-step setup on macOS

The bridge reads exactly three connection settings. `SPEC_KIT_JIRA_BASE_URL`
and `JIRA_EMAIL` are not secret and live in your shell profile (or the
committed `config.yml` / your gitignored `personal.yml`, respectively); the
API token is resolved from `JIRA_API_TOKEN` in the environment, or from a
retrieval command you declare in `JIRA_PAT_COMMAND` — the steps below use the
OS keychain, which is what step 3 below sets up. See
[CREDENTIALS.md](docs/CREDENTIALS.md) if you would rather back the token with
the macOS Keychain or another credential store.

### 1. Install the runtime prerequisites

macOS ships Bash 3.2, which does not qualify — the prerequisite check exits
with code `5` and names it:

```sh
brew install bash jq
```

`curl` and `git` are already present on a standard macOS install (`git` comes
with the Xcode Command Line Tools). Verify:

```sh
/opt/homebrew/bin/bash --version   # 5.x
jq --version
git --version
```

### 2. Create a Jira API token

At <https://id.atlassian.com/manage-profile/security/api-tokens>, choose
*Create API token*, name it (e.g. `spec-kit-jira`), and copy the value — Jira
shows it once and never again.

### 3. Put the token in the Keychain, and declare how to read it

The token is the one setting that must never reach a file in your repository.
Store it in the OS vault once, and tell the bridge the command that reads it
back — so you never paste, echo, or hold the token yourself.

```sh
security add-generic-password -U -s spec-kit-jira -a "$USER" -w
```

`-w` with no value prompts twice with masked input, keeping the token out of
your shell history. Then add the retrieval command to `~/.zshrc`:

```sh
export JIRA_PAT_COMMAND="security find-generic-password -s spec-kit-jira -w"
```

Reload with `source ~/.zshrc`. The first read from a script raises a macOS
access prompt — choose **Always Allow** to answer it once and for all.

The Keychain is one option among several. `JIRA_PAT_COMMAND` accepts any
command that prints the token on stdout and nothing else:

| Secret manager | `JIRA_PAT_COMMAND` value |
| --- | --- |
| macOS Keychain | `security find-generic-password -s spec-kit-jira -w` |
| 1Password CLI | `op read op://Private/spec-kit-jira/credential` |
| `pass` | `pass show spec-kit-jira` |
| `secret-tool` (Linux) | `secret-tool lookup service spec-kit-jira` |

The site URL and your email are *not* environment variables: they belong to the
repository's configuration, and step 5 puts them there. See
[CREDENTIALS.md](docs/CREDENTIALS.md) for the full treatment, including
unattended contexts.

### 4. Install the extension into the consuming repository

```sh
specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip
```

Answer `y` at the `⚠ Untrusted Source` confirmation prompt this address raises.

This copies the extension to `.specify/extensions/jira-mirror/` **and registers
and activates the seven lifecycle hooks**. Verify the bridge answers:

```sh
bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh --help
```

### 5. Bind the repository to a Jira project

```text
/speckit.jira-mirror.config
```

The ceremony discovers the project metadata, writes `.specify/jira/config.yml`,
covers the gitignored config layer, and reports the hook registration.

It will report a **degraded run**, naming two settings it does not invent for
you. Supply them now that the files exist:

```yaml
# .specify/jira/config.yml — committed, reviewed in a pull request
base_url: "https://your-site.atlassian.net"
```

```yaml
# .specify/jira/personal.yml — yours, gitignored
email: "you@example.com"
```

No trailing slash on the URL, and `https://` is required — a committed
`base_url` is refused at load time on any other scheme, except a loopback
address. The site URL is committed because it identifies the team's Jira, not
you; the email is gitignored because it identifies you, not the team. Re-run
`/speckit.jira-mirror.config` and the degraded report clears.

Committing the site URL is a disclosure worth choosing knowingly: it enters
**git history irreversibly**, so every clone — past and future — can see which
Jira the team mirrors to, including after someone removes the key. It is not a
secret, but if your team would rather keep the site name out of history,
export `SPEC_KIT_JIRA_BASE_URL` instead and leave the file's key unset. The
environment variable always takes precedence, so the file value never has to
be filled in at all.

### 6. Mirror

From here every `/speckit.specify`, `/speckit.plan`, `/speckit.tasks`, and the
other lifecycle steps reconcile into Jira on their own. A mirroring failure
never fails the spec-kit command that triggered it.

Reconcile mirrors the whole specification as one parent issue plus one child
per user story, the parent created first and every child carrying its key.
Each carries a durable identifier, recorded in its own HTML comment line —
one beside the document's title for the parent, one beside each story's
heading — and stamped on the ticket itself. A second run reads those
identifiers back, recognises the same tickets, and updates them instead of
creating duplicates — an unchanged re-run writes nothing to Jira at all. A
story's identifier survives a retitle, a reorder, and a specification-folder
rename. The parent's is tied to the repository and the specification slug: it
survives a retitle and a reorder, and a folder rename so long as the slug
stays the same. Change the slug and reconcile blocks the parent — naming the
slug that already claims the ticket — rather than opening a second one. Leave
the comment lines where reconcile put them.

Every ticket the mirror creates or manages also carries a `speckit-<slug>`
label naming its specification folder, so the whole specification is one
search away on the board — filtering, say, `labels = "speckit-001-billing"`.
The label is added alongside any you apply by hand and is restored if you
remove it; it is never sent on the single ticket a feature-creation ceremony
opens directly, since that ticket predates its specification folder.

## Step-by-step setup on Linux

Same settings as macOS. The token resolves from `JIRA_API_TOKEN` in the
environment, or from a retrieval command you declare in `JIRA_PAT_COMMAND` —
see [CREDENTIALS.md](docs/CREDENTIALS.md) to back it with the libsecret
keyring instead of exporting it directly.

### 1. Install the runtime prerequisites

Bash ≥ 4 (every current distribution ships 5.x), `curl`, `jq`, and `git`:

```sh
sudo apt install curl jq git     # Debian / Ubuntu
sudo dnf install curl jq git     # Fedora / RHEL
sudo pacman -S curl jq git       # Arch
```

### 2. Create a Jira API token

At <https://id.atlassian.com/manage-profile/security/api-tokens>, choose
*Create API token*, name it, and copy the value — Jira shows it once.

### 3. Put the token in the keyring, and declare how to read it

```sh
secret-tool store --label="spec-kit-jira" service spec-kit-jira
```

The command reads the token from the terminal, so it never enters your shell
history. Then add the retrieval command to `~/.bashrc` (or `~/.zshrc`) and
reload it:

```sh
export JIRA_PAT_COMMAND="secret-tool lookup service spec-kit-jira"
```

Any of the retrieval commands in the macOS table works here too. The site URL
and your email are not environment variables — they go into the repository's
configuration at step 5. A machine with no keyring daemon is an unattended
context; see the section below.

### 4. Install the extension into the consuming repository

```sh
specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip
bash .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh --help
```

### 5. Bind the repository and mirror

Run `/speckit.jira-mirror.config`. It will report a degraded run naming two settings:
add `base_url` to the committed `.specify/jira/config.yml` and `email` to your
gitignored `.specify/jira/personal.yml`, exactly as in the macOS step 5 above,
then run it again. From then on every lifecycle step mirrors on its own.

## Step-by-step setup on Windows (PowerShell 7+)

The PowerShell port needs fewer tools — it uses `Invoke-RestMethod` and native
JSON, so neither `curl` nor `jq` is required.

Same two-rung token resolution as macOS and Linux: `JIRA_API_TOKEN` in the
environment, or a retrieval command you declare in `JIRA_PAT_COMMAND` — the
steps below use the vault-backed command, as on the other two platforms. See
[CREDENTIALS.md](docs/CREDENTIALS.md) to back it with a PowerShell
SecretManagement vault instead, including the wrapper `JIRA_PAT_COMMAND` needs
since `Get-Secret` is a cmdlet, not an executable.

### 1. Install the runtime prerequisites

```powershell
winget install --id Microsoft.PowerShell
winget install --id Git.Git
```

Run everything below from `pwsh` (PowerShell 7+), not Windows PowerShell 5.1 —
the prerequisite check exits with code `5` on 5.1 and names the version.

### 2. Create a Jira API token

At <https://id.atlassian.com/manage-profile/security/api-tokens>, choose
*Create API token*, name it, and copy the value — Jira shows it once.

### 3. Put the token in a vault, and declare how to read it

Store it once in PowerShell SecretManagement:

```powershell
Set-Secret -Name spec-kit-jira -Secret (Read-Host 'Jira API token' -AsSecureString)
```

`Get-Secret` is a cmdlet, not an executable, and `JIRA_PAT_COMMAND` names a
program to run directly, without a shell — so point it at a small wrapper
script instead:

```powershell
'Get-Secret -Name spec-kit-jira -AsPlainText' |
    Set-Content "$HOME\bin\get-jira-token.ps1"
[Environment]::SetEnvironmentVariable(
    'JIRA_PAT_COMMAND', "pwsh -NoProfile -File $HOME\bin\get-jira-token.ps1", 'User')
```

The same wrapper requirement applies from Git Bash or WSL on a Windows
machine, since those run the Bash port.

**Open a new terminal now** — a `User` variable does not reach sessions that
were already running.

The site URL and your email are not environment variables; step 5 puts them in
the repository's configuration.

### 4. Install the extension into the consuming repository

```powershell
specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip
.specify\extensions\jira-mirror\scripts\powershell\spec-kit-jira.ps1 --help
```

### 5. Bind the repository and mirror

Run `/speckit.jira-mirror.config`. It will report a degraded run naming two settings:
add `base_url` to the committed `.specify/jira/config.yml` and `email` to your
gitignored `.specify/jira/personal.yml`, exactly as in the macOS step 5 above,
then run it again. From then on every lifecycle step mirrors on its own.

## Unattended: CI, containers, and cloud agents

A build runner, a container, and a cloud agent have no OS vault and no keyring
daemon, so the retrieval command above has nothing to reach. There the token
comes from the platform's own secret store, injected as an environment
variable:

```yaml
# GitHub Actions
env:
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
  SPEC_KIT_JIRA_BASE_URL: ${{ secrets.JIRA_BASE_URL }}
  JIRA_EMAIL: ${{ secrets.JIRA_EMAIL }}
```

The environment is consulted before `JIRA_PAT_COMMAND`, so a runner needs no
vault and a developer needs no environment variable. This is the only context
in which the token is expected to reach a variable — on a workstation, keep it
in the vault, where a `printenv`, a crash dump, or a shell history cannot
reach it.

This repository's own [`live.yml`](.github/workflows/live.yml) is that pattern
in practice: it runs the double-run zero-churn suite against a real Jira site,
with all four settings supplied from repository secrets.

## Naming features by team

By default a feature is named the way spec-kit names it. Declare a `teams:`
catalogue in the committed `.specify/jira/config.yml` and each developer's
features carry their team's convention instead — with the real ticket number in
the branch, decided *before* the feature is created rather than renamed
afterwards:

```yaml
# .specify/jira/config.yml — committed, reviewed in a pull request
teams:
  - id: ijt
    project: IJT
    folder_prefix: "ijt-"
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
```

Which team you personally work in is not a team decision, so it does not live
in that file. It lives in `.specify/jira/personal.yml`, which is yours and
gitignored. `/speckit.jira-mirror.config` creates it if it is absent and never
rewrites it afterwards, so anything you put there survives every later run:

```yaml
# .specify/jira/personal.yml — yours, gitignored
team: ijt
```

With that, `IJT-453` and the description "fix issue" produce the branch
`ijt-453/fix-issue`. `<ID>` is the ticket number with its project prefix
removed; `<FEATURE_NAME>` is the slug of your description. A `/` builds branch
hierarchy only — the spec folder stays one flat component, which spec-kit then
numbers (`specs/001-ijt-fix-issue`).

Two developers on one repository can therefore ship under different
conventions without either of them editing a committed file. Without a
`personal.yml`, or with the `team` line left commented, nothing changes at all:
naming is exactly what it would be without this extension, and no Jira request
is made.

### Your team also decides where your work is mirrored

That one line does a second job. When a specification matches no committed
`routing:` rule and carries no team folder prefix, it is mirrored into **your**
team's project rather than into whatever `routing_default` the repository
happens to name. Routing resolves in four ranks, first one that answers wins:

1. a committed `routing:` rule — matched against the raw folder name;
2. a committed `teams:` `folder_prefix` — matched against the folder name with
   its leading `NNN-` removed;
3. **your `team:` selection**;
4. `routing_default`, which is optional.

Nothing answers and the run is refused, telling you what each of the four ranks
found rather than naming one missing key.

The two committed ranks stay ahead of yours on purpose: a specification that
says where it belongs must outrank whoever happens to be reconciling it. And
rank 3 applies only while a specification is still **unbound** — once its
stories carry ticket markers, the specification itself fixes its project, and
every developer resolves it identically whatever team each has selected.
Changing your `team:` will not move work that is already mirrored.

In a repository shared by several teams this is what stops one team's work
being mirrored into another team's project. Such a repository can leave
`routing_default` out of `config.yml` entirely — there is no value that is
correct for all of them.

### Overriding your team's convention

Rarely, your team's convention does not work for you — a constraint from your
git host, a temporary assignment. Override it in your own file rather than
changing your team's:

```yaml
# .specify/jira/personal.yml
team: ijt
override:
  folder_prefix: "special-"
  branch_pattern: "special-<ID>/<FEATURE_NAME>"
```

Either key may be given alone; the one you omit is inherited from the
catalogue entry. Both are validated exactly as a catalogue entry is.

The override is deliberately hard to forget: every feature-creation output
reports `override_used`, so it announces itself on every run and can never
quietly become the norm.

## Telling the bridge where each lifecycle step leaves a ticket

By default nothing on your board moves: the bridge mirrors content and never
touches a ticket's status. Moving one is opt-in, per project, through
`phase_status_map` in `.specify/jira/config.yml` — declared per hierarchy role:

```yaml
projects:
  - key: PROJ
    phase_status_map:
      specification:
        after_plan: In Progress
      story:
        after_specify: To Do
        after_implement: In Review
    halted_statuses:
      - Blocked
```

Each value is the **destination status name, spelled exactly as your project
spells it**. A ticket moves only when exactly one of its real available
transitions lands on that status and is not gated on a field the bridge does not
hold; two candidates, a gated one, or none reachable in a single move each leave
the ticket alone and warn once, naming it and the reason. There is no built-in
status table: your workflow is authoritative, and a project that declares
nothing keeps today's no-movement behaviour.

The lifecycle events are `after_specify`, `after_clarify`, `after_plan`,
`after_tasks`, `after_implement`, and `after_analyze`; the roles are
`specification`, `story`, and `task` (the last applies only where tasks are
mirrored as sub-tasks). A mapping whose keys are all events is the story role's —
the original role-blind shape, still valid. Mixing the two key sets in one
mapping is refused with exit `4`.

`/speckit.jira-mirror.config` proposes a draft over the statuses discovered in your own
project and records the answer you confirm; `halted_statuses` — the statuses at
which a ticket is surfaced and otherwise left completely alone — stays
hand-written. Both are yours to edit afterwards: the ceremony never rewrites a
mapping it finds, and deleting the key restores the no-movement behaviour.

## Seeding a specification from existing Jira issues

When the work already exists on your board — an epic and its stories, written
by a human before spec-kit ever entered the picture — you do not have to
re-describe it from scratch. Paste the keys (or the browser links) when you
start the feature:

```sh
specify /speckit.specify PROJ-1 PROJ-11 PROJ-12 "add payment webhooks"
```

The bridge reads each one back and asks a single closed question: it names
every detected issue by key, summary, type and status, states the role it
would be attached in (in your own project's type names — an Epic, a Story,
whatever your hierarchy calls them, never an internal label), and offers two
answers — reuse them, or create new issues instead. A type your hierarchy
doesn't map to any role — a Bug, say — is proposed in the story role rather
than refused; it just needs no parent. Answer `yes` and the bridge routes
straight into the seeding flow below, deriving `--parent`/`--story` from the
roles it already computed — no need to type them yourself. Answer `no` and it
proceeds exactly as if nothing had been named.

**Naming designators directly skips the question.** If you already know which
issue plays which role — or the parent doesn't exist yet — supply them
up front and the question is never asked:

```sh
specify /speckit.specify --parent PROJ-1 --story PROJ-11 --story PROJ-12 "add payment webhooks"
```

A key, a full issue URL, or the browser board link all resolve the same way.
A specification-role designator you type as free text — not a key, not a
URL — is never looked up: it is always the title of a new parent, created only
once you confirm (see below). Naming an existing parent by key or URL adopts
it; typing a title creates one — this is how the bridge tells "this is an
existing issue" apart from "this does not exist yet" on the designator path.

Either route lands in the same place. The agent then drafts `spec.md` from those issues' own summaries and
descriptions — their words are the draft, not a paraphrase of it — and marks
which user story came from which issue. Nothing has been written to Jira yet.
Once you are ready to bind it, the agent runs:

```text
/speckit.jira-mirror.seed specs/<your-feature>/spec.md
```

This shows you the exact write plan — which issues will be adopted, which
(if any) will be created, and whether any named story is being moved off a
parent it currently sits under (that line is marked with a leading `!`, since
it is the one write here that touches something you did not directly name).
Nothing is written until you say yes; re-invoking without `--confirm` shows
you the same gate again, recomputed against Jira as it now stands. Say yes,
and the agent re-invokes with `--confirm` to bind everything.

**A decision that lives only in a Jira comment thread will never reach
`spec.md`.** The bridge reads an issue's summary and description — never its
comments — both when it seeds the draft and on every later reconcile. If the
real decision is buried in a comment, promote it into the issue's description
first, or it will not make it into the specification.

## If the lifecycle hooks do not see your variables

The hooks run in the shell the agent spawns, which does not always load your
profile. Declare the two non-secret settings per project in
`.claude/settings.json`:

```json
{
  "env": {
    "SPEC_KIT_JIRA_BASE_URL": "https://your-site.atlassian.net",
    "JIRA_EMAIL": "you@example.com"
  }
}
```

The token stays with `JIRA_API_TOKEN` or `JIRA_PAT_COMMAND` — never put it in
that file. `.claude/settings.json`'s `permissions.deny` is also where you keep
the agent from reading your credential-store commands directly; see
[CREDENTIALS.md](docs/CREDENTIALS.md#keeping-the-agent-out-of-the-credential-store).

## If a configuration file cannot be read

`.specify/jira/config.yml`, `config.local.yml`, `personal.yml`, and the host's
`.specify/extensions.yml` are all read through the same restricted YAML
parser. A line that cannot be interpreted as a mapping entry — or a key
repeated at the same level — fails the read closed rather than silently
dropping the rest of the file:

```
config: <file>:<line>: cannot parse this line as a mapping entry: <content>
config: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"
config: re-run /speckit.jira-mirror.config to regenerate <file> from the Jira instance.
```

This exits `4` on a direct run. Inside a lifecycle hook, the same three lines
are followed by one `WARNING:` and the host command still completes normally
— nothing is mirrored until the file is fixed or regenerated. Re-running
`/speckit.jira-mirror.config` rediscovers and rewrites the machine-owned parts
of `config.local.yml`, which resolves the great majority of cases; a
hand-edited `config.yml` or `personal.yml` needs the named line corrected by
hand.

One thing a plain re-run deliberately does **not** fix: a `config.yml` whose
`base_url` now names a different Jira site from the one this checkout is bound
to. The bridge refuses that before its first request, and the ceremony refuses
to re-record it too — otherwise following the refusal's own instruction would
be enough to accept a redirection somebody else introduced. Accepting a genuine
site change means naming it:

```bash
/speckit.jira-mirror.config --accept-site https://your-new-site.atlassian.net
```

## Repository layout

This is the extension's SOURCE repository, following the official extension
layout: the manifest (`extension.yml`), `commands/`, `scripts/`, and
`templates/` live at the root and are what `specify extension add` copies;
`specs/`, `tests/`, `.specify/`, `.github/`, `docs/`, `AGENTS.md`, `CLAUDE.md`,
and `.gitattributes` are development-only and are excluded from installation
by `.extensionignore`.

| Path | Role |
|------|------|
| `extension.yml` | Manifest — the single source of truth for the version |
| `commands/` | Agent command definitions (`/speckit.jira-mirror.config`) |
| `scripts/bash/`, `scripts/powershell/` | The twin ports (module-for-module mirrors) |
| `templates/` | Config scaffold and managed README block template |
| `specs/`, `tests/`, `.specify/`, `.github/` | Development only — never installed |
| `docs/`, `AGENTS.md`, `CLAUDE.md` | Contributor architecture and instructions — describe how THIS repository is built, not the installed bridge; excluded so a coding agent in a consuming repository never mistakes them for its own marching orders |
| `.gitattributes` | This repository's own line-ending policy (protects its Windows test fixtures) — excluded so it never governs a consumer's tree |

## Development

The project is built spec-first with Spec Kit itself: the active feature lives
in `specs/001-jira-reconcile-engine/` and the governance rules in
`.specify/memory/constitution.md`. Both ports are proven behaviourally
equivalent by a language-agnostic conformance corpus (`tests/conformance/`);
`bats` and `Pester` cover each port, with lint (`shellcheck`,
`PSScriptAnalyzer`) and CI gates (engine/sink boundary, module parity,
coverage, single-sourced version) blocking on the three-OS matrix.

Run the suites locally with:

```bash
tests/run-bash.sh                                             # Bash port — needs only bats + jq
pwsh -NoProfile -Command "Invoke-Pester -Path tests/powershell -PassThru"
```

`tests/run-bash.sh` needs only `bats` and `jq` — no PowerShell, no GNU
`parallel`. It shards across cores via `xargs -P` (no dependency, never a
silent zero-tests run) and drives the mocked Jira double through a pure
`bash`+`jq` `curl` shim, so the 35 mock-dependent test files run without
spawning any process. Each test isolates its own tmpdir, so concurrent runs
cannot collide.

For the fast inner loop, `tests/run-bash.sh --since <ref>` runs only the test
files affected by the diff against `<ref>` (fail-open to the full suite on any
doubt) — local only, never used in CI.

## License

[MIT](LICENSE)
