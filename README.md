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
which creates `.specify/extensions/jira/` there automatically:

```sh
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
# or, while developing the extension itself:
specify extension add --dev <path-to-spec-kit-jira> --force
```

Then run the one-command install ceremony in the consuming repository:

```text
/speckit.jira.config
```

See [INSTALL.md](INSTALL.md) for prerequisites (Bash ≥ 4 or PowerShell 7+,
`curl`, `jq`, `git`) and credential setup — the API token never enters the
tree, argv, logs, or traces. Once the three connection settings below are in
place, a bound repository needs **no further environment variables** to mirror
specs: the target project, issue type, and priority are all resolved from
`.specify/jira/config.yml` and the discovered binding — see
[INSTALL.md's mirroring step](INSTALL.md#install--configure) for the override
variables that remain supported.

## Step-by-step setup on macOS

The bridge reads exactly three connection settings. `SPEC_KIT_JIRA_BASE_URL`
and `JIRA_EMAIL` are not secret and live in your shell profile; the API token
is resolved from the environment, then the macOS Keychain, then a gitignored
`.specify/jira/.env` — the steps below use the Keychain.

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

### 3. Store the token in the macOS Keychain

The service name `spec-kit-jira` is the one the credential resolver looks up,
so use it verbatim:

```sh
security add-generic-password -U -s spec-kit-jira -a "$USER" -w
```

`-w` with no value prompts for the token twice with masked input, keeping it
out of your shell history. Confirm it landed:

```sh
security find-generic-password -s spec-kit-jira -w > /dev/null && echo "token present"
```

The first read from a script raises a macOS access prompt — choose **Always
Allow** to answer it once.

### 4. Export the site URL and your account email

Add to `~/.zshrc`, substituting your own values:

```sh
export SPEC_KIT_JIRA_BASE_URL="https://your-site.atlassian.net"
export JIRA_EMAIL="you@example.com"
```

No trailing slash on the URL — the sink appends `/rest/api/3/…` directly.
Reload with `source ~/.zshrc`, then check both with `echo`.

### 5. Install the extension into the consuming repository

```sh
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
```

This copies the extension to `.specify/extensions/jira/` **and registers and
activates the seven lifecycle hooks**. Verify the bridge answers:

```sh
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help
```

### 6. Bind the repository to a Jira project

```text
/speckit.jira.config
```

The ceremony discovers the project metadata, writes `.specify/jira/config.yml`,
covers the gitignored config layer, and reports the hook registration. If it
reports a degraded run, it names the connection setting that is missing — go
back to the step that supplies it.

### 7. Mirror

From here every `/speckit.specify`, `/speckit.plan`, `/speckit.tasks`, and the
other lifecycle steps reconcile into Jira on their own. A mirroring failure
never fails the spec-kit command that triggered it.

## Step-by-step setup on Linux

Same three settings. The token's secret-manager rung is libsecret, queried as
`secret-tool lookup service spec-kit-jira`, so the attribute name matters.

### 1. Install the runtime prerequisites

Bash ≥ 4 (every current distribution ships 5.x), `curl`, `jq`, `git`, and
`secret-tool` for the Keyring step:

```sh
sudo apt install curl jq git libsecret-tools     # Debian / Ubuntu
sudo dnf install curl jq git libsecret           # Fedora / RHEL
sudo pacman -S curl jq git libsecret             # Arch
```

### 2. Create a Jira API token

At <https://id.atlassian.com/manage-profile/security/api-tokens>, choose
*Create API token*, name it, and copy the value — Jira shows it once.

### 3. Store the token in the keyring

```sh
secret-tool store --label="spec-kit-jira" service spec-kit-jira
```

The command reads the token from the terminal, so it never enters your shell
history. Confirm it:

```sh
secret-tool lookup service spec-kit-jira > /dev/null && echo "token present"
```

On a headless machine or a container there is no keyring daemon and this step
cannot work — skip it and use the gitignored file instead, which is the third
rung of the same resolution order:

```sh
mkdir -p .specify/jira
printf 'JIRA_API_TOKEN="%s"\n' 'your-token' > .specify/jira/.env
chmod 600 .specify/jira/.env
```

`/speckit.jira.config` adds that path to `.gitignore` for you. Note that the
parser reads **only** `JIRA_API_TOKEN` from this file — the site URL and email
must be real environment variables.

### 4. Export the site URL and your account email

Add to `~/.bashrc` (or `~/.zshrc`), then reload it:

```sh
export SPEC_KIT_JIRA_BASE_URL="https://your-site.atlassian.net"
export JIRA_EMAIL="you@example.com"
```

No trailing slash on the URL — the sink appends `/rest/api/3/…` directly.

### 5. Install the extension into the consuming repository

```sh
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help
```

### 6. Bind the repository and mirror

Run `/speckit.jira.config`. If it reports a degraded run, it names the missing
connection setting. From then on every lifecycle step mirrors on its own.

## Step-by-step setup on Windows (PowerShell 7+)

The PowerShell port needs fewer tools — it uses `Invoke-RestMethod` and native
JSON, so neither `curl` nor `jq` is required.

**There is no OS secret-manager rung on Windows.** `Get-JiraSecretManagerToken`
is a deliberate no-op, so the token must come from the environment or the
gitignored `.specify/jira/.env`. Do not put it in the Credential Manager
expecting the bridge to find it — nothing reads from there.

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

### 3. Store the token

Read it in masked so it stays out of your console history, and persist it for
your user account:

```powershell
$token = Read-Host 'Jira API token' -AsSecureString
[Environment]::SetEnvironmentVariable(
    'JIRA_API_TOKEN',
    (ConvertFrom-SecureString $token -AsPlainText),
    'User')
```

A user environment variable is stored in the registry in clear text. If that is
unacceptable on your machine, use the gitignored file instead — same resolution
order, third rung:

```powershell
New-Item -ItemType Directory -Force .specify/jira | Out-Null
'JIRA_API_TOKEN="your-token"' | Set-Content .specify/jira/.env
```

The parser reads **only** `JIRA_API_TOKEN` from that file; the two settings
below must be real environment variables.

### 4. Set the site URL and your account email

```powershell
[Environment]::SetEnvironmentVariable('SPEC_KIT_JIRA_BASE_URL', 'https://your-site.atlassian.net', 'User')
[Environment]::SetEnvironmentVariable('JIRA_EMAIL', 'you@example.com', 'User')
```

No trailing slash on the URL. **Open a new terminal now** — a `User` variable
does not reach sessions that were already running. Check with
`$env:SPEC_KIT_JIRA_BASE_URL`.

### 5. Install the extension into the consuming repository

```powershell
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
.specify\extensions\jira\scripts\powershell\spec-kit-jira.ps1 --help
```

### 6. Bind the repository and mirror

Run `/speckit.jira.config`. If it reports a degraded run, it names the missing
connection setting. From then on every lifecycle step mirrors on its own.

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

The token stays in the Keychain, the keyring, or the gitignored `.env` — never
put it in that file.

## Repository layout

This is the extension's SOURCE repository, following the official extension
layout: the manifest (`extension.yml`), `commands/`, `scripts/`, and
`templates/` live at the root and are what `specify extension add` copies;
`specs/`, `tests/`, `.specify/`, and `.github/` are development-only and are
excluded from installation by `.extensionignore`.

| Path | Role |
|------|------|
| `extension.yml` | Manifest — the single source of truth for the version |
| `commands/` | Agent command definitions (`/speckit.jira.config`) |
| `scripts/bash/`, `scripts/powershell/` | The twin ports (module-for-module mirrors) |
| `templates/` | Config scaffold and managed README block template |
| `specs/`, `tests/`, `.specify/`, `.github/` | Development only — never installed |

## Development

The project is built spec-first with Spec Kit itself: the active feature lives
in `specs/001-jira-reconcile-engine/` and the governance rules in
`.specify/memory/constitution.md`. Both ports are proven behaviourally
equivalent by a language-agnostic conformance corpus (`tests/conformance/`);
`bats` and `Pester` cover each port, with lint (`shellcheck`,
`PSScriptAnalyzer`) and CI gates (engine/sink boundary, module parity,
coverage, single-sourced version) blocking on the three-OS matrix.

## License

[MIT](LICENSE)
