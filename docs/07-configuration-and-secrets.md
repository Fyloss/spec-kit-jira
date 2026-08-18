# 7. Configuration and secrets

Three strictly separate layers, and a credential that never enters the tree.

## The three layers

```mermaid
flowchart TB
    subgraph L1["1 · Team config — COMMITTABLE"]
        A[".specify/jira/config.yml"]
        A1["projects · epic_strategy · task_strategy"]
        A2["priority_map · estimation_field · hierarchy"]
        A3["routing + routing_default"]
        A4["teams catalogue"]
        A5["privacy.allowlist"]
        A6["phase_status_map (per role since 023) · halted_statuses"]
        A7["task_mirror per project (022) — subtask | checklist"]
        A8["base_url (030) — the Jira site, committed"]
    end

    subgraph L2["2 · Local binding — GITIGNORED, machine-owned"]
        B[".specify/jira/config.local.yml"]
        B1["resolved_ids per project"]
        B2["issue types, resolved roles (specification/story/task),<br/>each with its provenance"]
        B3["priorities · statuses · estimation field id"]
        B4["the operator's hook disable decisions"]
    end

    subgraph L3["3 · Personal — GITIGNORED, human-owned"]
        C[".specify/jira/personal.yml"]
        C1["team selection · email (030)"]
        Leftover[".specify/jira/.env — leftover only (030)<br/>never read; the ignore rule stays so an<br/>older install's file is never un-ignored"]
    end

    subgraph L4["4 · Run-state cache (021) — GITIGNORED, machine-owned"]
        E[".specify/jira/state/&lt;feature&gt;.json"]
        E1["hashes of the local inputs a run<br/>saw last time it fully succeeded"]
    end

    A -->|"logical names"| Resolve["Reconcile"]
    A -->|"base_url"| Sink["sink/jira/client"]
    B -->|"resolved ids"| Resolve
    C -->|"team selection"| Feature["Feature naming"]
    C -->|"email"| Sink
    Resolve -->|"records on success"| E
```

The run-state cache is not a fourth configuration layer — it holds no setting
an operator sets, only hashes `run_state_record` computes from the other
three's own inputs plus `spec.md`/`tasks.md`. It is machine-owned and never
committed, self-ignoring through the `*` `.gitignore` `run_state_record`
writes beside it the first time it creates the directory, and it never holds
a credential (FR-019, Constitution V). See
[`contracts/run-state.md`](../specs/021-reconcile-performance/contracts/run-state.md) for what it
records and why staleness there is an accepted trade, not a bug.

Rules that hold across all three:

- **The team layer must stay credential-free.** A value shaped like an
  Atlassian token, a real `*.atlassian.net` host, or an email address is
  refused with exit `4` — and the offending value is never echoed back.
- **Nothing lives inside `.specify/extensions/`.** A reinstall or upgrade of the
  extension must never be able to destroy the operator's configuration.
- **Keys use business language**, not Jira internals: `epic_strategy: per_feature`,
  never an opaque id where a logical name exists. A tech lead should be able to
  review their team's config without opening the documentation.

## Credential resolution — two rungs, in order

```mermaid
flowchart LR
    Start(["Need the API token"]) --> R1{"Environment<br/>JIRA_API_TOKEN"}
    R1 -->|"found"| Use(["Use it"])
    R1 -->|"absent"| R2{"Operator-declared JIRA_PAT_COMMAND<br/>run tokenized — no shell, no eval"}
    R2 -->|"stdout, trimmed"| Use
    R2 -->|"absent, non-zero exit,<br/>timeout (5s), or empty output"| Fail(["Reported failure — names the reason<br/>no Jira call is attempted"])
```

Both platforms share the same two-rung shape; there is no third rung. The old
hardcoded OS secret-manager probe — Keychain via `security` on macOS,
`libsecret`/`find-generic-password` on Linux, `Get-Secret -Name spec-kit-jira`
against a registered PowerShell SecretManagement vault on Windows — is
**deleted**, not deprioritised: a credential store is reached only through a
`JIRA_PAT_COMMAND` the operator declares themselves. See
[`CREDENTIALS.md`](CREDENTIALS.md) for how to declare one on each platform,
including the Windows wrapper a `Get-Secret`-backed store needs (it is a
cmdlet, not an executable, so `JIRA_PAT_COMMAND` cannot name it directly).

A failure at the second rung is no longer silent. The old rungs fell through to
the next one without a word; a declared `JIRA_PAT_COMMAND` that fails now
**raises** — reported as a WARNING in hook context (the host still never
fails there, unchanged) and as an error everywhere else — because an operator
who bothered to declare a retrieval command almost always wants to know why it
didn't work, not have the run continue as if it were still unset. The one
deliberate exception is the config ceremony itself (FR-038): a declared
command's failure is reported there too, but the ceremony still completes in
degraded mode rather than refuse, because the operator running it is the one
who has no working credentials yet.

## How the token is protected in flight

```mermaid
flowchart TD
    Token["Resolved token"] --> Trace["xtrace suspended for the whole<br/>duration of every function that touches it"]
    Trace --> Header["Authorization header built in memory"]
    Header --> Config["Delivered to curl via --config on STDIN"]
    Config --> Request["HTTPS request"]

    Header -.->|"NEVER"| Argv["argv — visible in ps"]
    Header -.->|"NEVER"| Log["logs, errors, or --verbose output"]
    Header -.->|"NEVER"| Tree["any tracked file, including test fixtures"]
```

The `set +x` bracket uses a **function-local** saved state, never a global, so
nested calls cannot clobber each other's tracing state. The guard stays down
through the final emptiness test — xtrace is only restored once no token value
remains live.

## The three connection settings

Only three, and only one of them is secret. All three now have a **file home**
as well as an environment variable, and the environment variable always wins
when set (`config_resolve_connection` / `Resolve-JiraConnection`, the single
chokepoint every command entry point calls through):

```mermaid
flowchart LR
    S1["base_url<br/>not secret — config.yml (committed),<br/>or SPEC_KIT_JIRA_BASE_URL"] --> Bridge
    S2["email<br/>not secret — personal.yml (gitignored),<br/>or JIRA_EMAIL"] --> Bridge
    S3["token<br/>SECRET — two-rung resolution only,<br/>never a file (FR-002)"] --> Bridge
    Bridge["The bridge"] --> Rest["Everything else comes from<br/>config.yml + the discovered binding"]
```

Once those three are in place and the repository is bound, mirroring needs **no
further environment variables**: the target project, issue type, and priority
are all resolved from the config and the binding.

If the lifecycle hooks cannot see the environment-variable form of any of
these — the hooks run in the shell the agent spawns, which does not always
load a profile — declare them per project in `.claude/settings.json` under
`env`, or commit `base_url` to `config.yml` / record `email` in `personal.yml`
instead. The token is the one setting that never has a file home: it comes
from `JIRA_API_TOKEN` or a declared `JIRA_PAT_COMMAND` only.

**The base URL enters git history irreversibly.** Committing `config.yml` with
a `base_url` set means every clone of the repository, past and future, can see
which Jira site the team mirrors to — including anyone who later removes the
key, since prior commits still hold it. This is not a secret in the FR-020
sense (a host is refused when it looks like a credential, not when it looks
like a URL), but it is disclosure a team should choose knowingly rather than
discover after the fact. An adopter who would rather keep the site name out of
history should export `SPEC_KIT_JIRA_BASE_URL` instead and leave `config.yml`'s
key unset — the environment variable always takes precedence, so the file
value never has to be filled in at all.

Two rules here are easy to meet as surprises rather than as documentation:

- **The committed base URL must use an encrypted scheme.** `config.yml`'s
  `base_url` is refused at load time if it is not `https://`, unless the host
  is a loopback address (`127.0.0.1`, `localhost`) — the one case where the
  request never leaves the machine, which is also what makes a file-sourced
  base URL testable against a local double. The exception does not extend to
  any other address, including one on a private network. `SPEC_KIT_JIRA_BASE_URL`
  is not checked this way.
- **The environment variable is not validated the way the file is.** A base
  URL that has worked for months as an exported `SPEC_KIT_JIRA_BASE_URL` can be
  refused the moment it is moved into `config.yml`, because only the file form
  is checked for scheme and shape at load time. This is deliberate, not an
  inconsistency to file a bug against: an environment variable an operator
  typed themselves gets the operator's own scrutiny, a committed file does
  not.

## Reading a YAML file, fail-closed

All four configuration surfaces — `config.yml`, `config.local.yml`,
`personal.yml`, and the host's `.specify/extensions.yml` — go through the same
restricted YAML reader. The Bash port ships no `yq` (runtime dependencies are
`curl`, `jq`, `git` only), so it parses exactly the dialect the config command
writes and the self-documenting template teaches.

**A `reconcile` run reads each source at most once.** Every caller of the
reader that asks for the same path again in the same run — `config_load`'s
own team/local merge, the gate phase's persisted-binding read, and the
apply phase's hook-health check all separately need `config.local.yml` — is
served the first parse's result rather than re-opening the file. The
consequence: the resolved configuration is a **per-process snapshot**. If
something else edits `config.local.yml` (or any of the other three surfaces)
partway through a `reconcile` run, that edit is not observed until the
*next* run — the same way an already-resolved environment variable
wouldn't be. A malformed source is never cached, so a still-broken file
keeps failing (and reporting) on every read that reaches it.

```mermaid
flowchart TD
    Line["Next line"] --> Kind{"What is it?"}
    Kind -->|"comment or blank"| Skip["Skip"]
    Kind -->|"key: value mapping"| Ok["Accept"]
    Kind -->|"- sequence item"| Ok
    Kind -->|"anything else"| Refuse

    Ok --> Dup{"Key already seen<br/>at this level?"}
    Dup -->|"yes"| Refuse["FAIL CLOSED — exit 4<br/>name the file, the line, and the content<br/>suggest quoting a key containing a colon<br/>suggest re-running /speckit.jira.config"]
    Dup -->|"no"| Line

    Refuse -.->|"inside a lifecycle hook"| Warn["The same three lines + one WARNING<br/>the host command still completes normally"]
```

Supported: 2-space block indentation, `key: value` mappings, `- ` sequences,
plain / single- / double-quoted scalars, `true` / `false` / `null`, `#`
comments, blank lines. Out of scope by design: flow collections and anchors.

Failing closed rather than silently dropping the rest of the file is the point:
a partially-read config would mirror into the wrong project with the wrong
mapping, and nobody would find out until the tickets existed.

## Writing configuration, fail-closed

The writer escapes `"` and `\` inside every quoted scalar it emits (`\"` and
`\\`), so a Jira label or value containing either round-trips through
`config.local.yml` unchanged. Only a string value containing a line break
refuses the write — at exit `4`, naming the offending path — because this
restricted YAML dialect has no way to represent one.
