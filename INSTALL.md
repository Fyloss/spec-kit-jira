# spec-kit-jira — Installation & Prerequisites

The reconcile bridge ships as **twin native ports** — Bash (macOS/Linux) and
PowerShell 7+ (Windows) — with identical observable behaviour (NFR-1). Install the
prerequisites for your platform, then run the one-command install ceremony.

## Prerequisites (NFR-4)

The prerequisite check runs **before any Jira interaction** and exits with code
`5`, naming the missing item, if any of these is absent:

| Requirement | Notes |
|-------------|-------|
| **Bash ≥ 4** (macOS/Linux port) | macOS ships Bash **3.2** — the check detects and names this case explicitly. Install a newer Bash (e.g. `brew install bash`). |
| **PowerShell 7+** (Windows port) | The sole Windows implementation. |
| `curl` | HTTP transport (the Authorization header is passed off-argv via `curl --config`, never on the command line). |
| `jq` | JSON handling and the canonical serializer. |
| `git` | Repository context and the managed README block. |

## Credentials (NFR-3 — eliminatory)

The API token is resolved in order: environment → OS secret manager → gitignored
`.specify/jira/.env`. The resolved token **never** appears in argv, logs, errors,
or traces at maximum verbosity (SC-007). Set:

```sh
export JIRA_EMAIL="you@example.com"
export JIRA_API_TOKEN="…"        # or store it in your OS secret manager / .env
```

The committable team config (`.specify/jira/config.yml`) is credential-free;
credential-shaped values in either YAML layer are rejected at config time (exit 4).

## Install & configure

1. Install the extension with the official Spec Kit command — it creates
   `.specify/extensions/jira/` in your repository automatically (and never
   writes into Spec Kit core's `.specify/scripts/` or `.specify/templates/`,
   FR-055/SC-009):

   ```sh
   specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
   # or, while developing the extension itself:
   specify extension add --dev /path/to/spec-kit-jira
   ```

2. Run the deterministic install ceremony:

   ```
   /speckit.jira.config
   ```

   In one run it performs — and reports as three separate effects — metadata
   discovery, idempotent `after_*` hook registration in `.specify/extensions.yml`,
   and creation/update of the managed README block (FR-054).
3. Mirror your specs: `spec.md` / `plan.md` / `tasks.md` reconcile into Jira
   automatically at each Spec Kit lifecycle step, or run `reconcile` manually.

## Verifying the install

- Re-run `/speckit.jira.config` on an unchanged project: the produced
  `config.local.yml` is **byte-identical** (determinism, SC-004).
- Re-run `reconcile` on an unchanged corpus: **zero writes** of every kind
  (zero-churn idempotency, SC-001).
- A forced reinstall preserves the team config and the registered hooks, with
  self-repair on the next run (SC-008).
