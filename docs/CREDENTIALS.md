# Credentials

How the Jira API token is resolved, how to declare a retrieval command that
backs it with a credential store, and what to do when a message here points
you at this document.

## The two rungs, in order

1. **`JIRA_API_TOKEN`**, read directly from the process environment.
2. **A retrieval command**, named by `JIRA_PAT_COMMAND`, run to produce the
   token on demand.

There is no third rung. The old hardcoded probe of an OS secret manager under
a fixed service name — Keychain via `security` on macOS, `libsecret` via
`secret-tool` on Linux, a PowerShell SecretManagement vault via `Get-Secret`
on Windows — is gone. A credential store is reached only through a
`JIRA_PAT_COMMAND` you declare yourself; nothing is probed automatically, and
nothing is read from `.specify/jira/.env` or any other file in the workspace.

If neither rung resolves a token, the run fails with an error naming both
possible sources. If a declared `JIRA_PAT_COMMAND` fails — missing, a
non-zero exit, exceeding the bound below, or empty output — that failure is
**reported**, not silently skipped: a WARNING in a lifecycle hook (the host
command still completes normally), an error everywhere else. This is a
deliberate departure from how the old rungs behaved: they fell through to the
next one without a word, so a broken second or third rung was invisible until
every rung had failed. A declared command failing now says so.

## Declaring `JIRA_PAT_COMMAND`

The value is a full command line: a program, and optionally its arguments,
separated by whitespace. It is executed **without a shell** — no pipe, no
`$(...)`, no `&&`, no environment-variable expansion by the retrieval process
itself performs any of that; those characters arrive as literal, inert
argument text if you include them. This also means the declared value is
**split into a program and arguments on whitespace**, so a single argument
that must itself contain a space is not directly expressible — write a small
wrapper script instead and name that.

The command's **standard output**, with surrounding whitespace trimmed, is
taken as the token. Nothing written to standard error becomes part of the
token — that stream is diagnostic only, and its content (trimmed) is folded
into the reported failure message when the command exits non-zero, so put
anything useful for you there rather than on stdout.

The command is bounded at **5 seconds**. A retrieval command that is still
running when the bound elapses is terminated and reported as a timeout,
naming the bound — this is a fixed value, identical in both ports, not
configurable, so the two ports report the same sentence.

Declare it in your shell profile, the same place you would export any other
environment variable:

```sh
# ~/.zshrc or ~/.bashrc
export JIRA_PAT_COMMAND="security find-generic-password -s spec-kit-jira -w"
```

```powershell
# PowerShell $PROFILE
$env:JIRA_PAT_COMMAND = 'C:\Users\you\bin\get-jira-token.cmd'
```

## macOS — backing the token with the Keychain

Store it once:

```sh
security add-generic-password -U -s spec-kit-jira -a "$USER" -w
```

`-w` with no value prompts for the token twice with masked input, keeping it
out of your shell history. The first read from a script raises a macOS access
prompt — choose **Always Allow** to answer it once. Then declare the
retrieval command:

```sh
export JIRA_PAT_COMMAND="security find-generic-password -s spec-kit-jira -w"
```

`security find-generic-password -w` prints only the password to stdout,
nothing else, which is exactly the shape this rung expects.

## Linux — backing the token with libsecret

Store it once (the command reads the token from the terminal, so it never
enters your shell history):

```sh
secret-tool store --label="spec-kit-jira" service spec-kit-jira
```

Then declare the retrieval command:

```sh
export JIRA_PAT_COMMAND="secret-tool lookup service spec-kit-jira"
```

On a headless machine or a container there is no keyring daemon and this
approach cannot work — export `JIRA_API_TOKEN` directly instead (see the
CI/unattended section below), or point `JIRA_PAT_COMMAND` at any other
retrieval mechanism the host does offer.

## Windows — backing the token with a SecretManagement vault

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name SecretStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name spec-kit-jira
```

`Set-Secret` prompts for the token masked, keeping it out of your console
history.

**`Get-Secret` is a cmdlet, not an executable** — `JIRA_PAT_COMMAND` names a
program to run directly, without a shell, so it cannot name a PowerShell
cmdlet the way it can name `security` or `secret-tool`. Point it at a small
wrapper script instead, and declare the wrapper:

```powershell
# get-jira-token.ps1
Get-Secret -Name spec-kit-jira -AsPlainText
```

```powershell
$env:JIRA_PAT_COMMAND = "pwsh -NoProfile -File C:\Users\you\bin\get-jira-token.ps1"
```

The same wrapper requirement applies from **Git Bash or WSL** even on a
Windows machine: those shells run the *bash* port, whose `JIRA_PAT_COMMAND` is
also executed without a shell, so it needs a program on `PATH` — `pwsh.exe`
invoking the wrapper script above works from either.

### The SecretStore master-password prompt

SecretStore defaults to a master-password prompt on every access, which blocks
a lifecycle hook that runs non-interactively — the hook has nowhere to show
that prompt, and `JIRA_PAT_COMMAND`'s 5-second bound would time it out even if
it could. If you intend to mirror from hooks, trade that prompt away once:

```powershell
Set-SecretStoreConfiguration -Authentication None
```

That leaves the vault protected by OS user-account access only — the same
trade the macOS Keychain and the Linux keyring already make once unlocked for
your login session.

## CI and other unattended arrangements

The simplest unattended setup is exporting `JIRA_API_TOKEN` directly from
whatever secret store the platform already provides — a GitHub Actions
secret, a Codespaces secret, or an equivalent — since the first rung needs no
further setup and no credential-store tooling on the runner at all:

```yaml
# GitHub Actions
env:
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
```

`JIRA_PAT_COMMAND` is there for the case where the runner should fetch the
token itself rather than have it injected as a plain environment variable —
point it at whatever CLI the platform's own secret manager offers, subject to
the same tokenized-exec and 5-second-bound rules as everywhere else.

## Keeping the agent out of the credential store

If a coding agent runs commands in your repository, it should not be able to
read the retrieval command's own output, or invoke the credential-store
commands directly to extract a token outside the bridge's own bounded,
non-echoing call path. Deny the specific commands in the project's
`.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Bash(security find-generic-password:*)",
      "Bash(secret-tool lookup:*)",
      "Bash(pwsh:*get-jira-token*)"
    ]
  }
}
```

Adjust the patterns to whatever retrieval command you actually declared. This
does not weaken the bridge itself — its own credential path never echoes the
token or the retrieval command's stdout (C4.4) — it only closes the separate
risk of an agent choosing to run the same lookup command on its own.

## Secrecy in flight

Regardless of which rung resolves it, the token is protected identically once
resolved: xtrace is suspended for the whole duration of every function that
touches it, the Authorization header is built in memory and delivered to
`curl` via `--config` on stdin (never on the command line, never visible in
`ps`), and it never appears in a log line, an error message, `--verbose`
output, or any tracked file — including test fixtures. See
[`07-configuration-and-secrets.md`](07-configuration-and-secrets.md#how-the-token-is-protected-in-flight)
for the full picture.
