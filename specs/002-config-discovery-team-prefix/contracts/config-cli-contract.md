# Contract — `config` command deltas (both ports)

Extends `specs/001-jira-reconcile-engine/contracts/cli-contract.md` and
`run-summary.schema.json`. Behaviour, exit codes, and every persisted byte are
identical across the Bash and PowerShell ports (FR-020).

## Invocation

```text
spec-kit-jira config [PROJECT_KEY] [--style KEY=VALUE]... [--json] [--dry-run] [--repair-hooks] [--verbose]
```

- `PROJECT_KEY` (new, optional positional): the key to (re)bind. Validated by
  the first discovery read (`GET /project/{key}`); an unresolvable key
  propagates the transport's fail-closed exit code with **no substitution**
  (FR-006).
- `--style KEY=VALUE` (new, repeatable): the operator's closed-question answer
  for one project. `VALUE ∈ {company_managed, team_managed}`; anything else is
  usage error (exit 1). Consumed only when discovery is ambiguous for `KEY`
  (or conflicts with a committed declaration); provenance becomes `operator`.

## Style resolution (FR-001/FR-002/FR-003)

Per configured project, in order:

1. Unambiguous API signal (`style`/`simplified` agree) ⇒ persist with
   `style_source: "api"`.
2. Ambiguous (absent or contradictory signals, or committed `style`
   conflicting with an unambiguous signal) **and** `--style` given for the
   key ⇒ persist the given value with `style_source: "operator"`.
3. Ambiguous without `--style` ⇒ **exit 4 (`EXIT_CONFIG`), zero writes**,
   stderr names the project key and the missing/contradictory signal, and
   states the two valid `--style` values (the agent's closed question is
   asked from this error surface in interactive mode).

The template no longer pre-fills `style:`; `projects[].style` is optional in
the config schema.

## Project-key resolution in a connected run (FR-004/FR-005)

Sources, exclusively: positional argument → committed `projects[].key`
(the literal `PROJ` placeholder counts as **unset**) → operator choice over
`discovery_list_projects` output (interactive; the agent persists the choice
into `config.yml` and re-invokes). Unattended with no usable key ⇒ exit 4.
Zero accessible projects ⇒ fail-closed error, no empty question. Git state is
never read in a connected run.

## Degraded mode (FR-008/FR-009)

Entered **only** when, before any Jira call, `SPEC_KIT_JIRA_BASE_URL` is unset
or the token resolves through none of the three rungs. Defined-but-failing
parameters keep the existing fail-closed exits (2/3) and never degrade.

Degraded run: exit 0; **zero writes** (`config.local.yml` untouched, all other
effects report `skipped`); one warning naming the missing variables; branch
scan proposes distinct `<prefix>-<number>/…` prefixes as provisional team
candidates; prose and `--json` both carry the re-run guidance.

## Connected-run mismatch surfacing (FR-009)

When the committed config declares a `teams:` catalogue, a connected run
performs the paginated `GET /project/search` read and emits, per catalogue team
whose `project` is not among the accessible projects, one warning:

```text
WARNING: team '<id>': project <KEY> matches no accessible Jira project — a provisional, branch-derived value may have been accepted into the catalogue; verify or fix config.yml
```

Each warning increments `counts.warnings`. The run still binds normally
(warn, never block). Without a `teams:` catalogue no extra read is performed.

## Run-summary extensions (`run-summary.schema.json` delta)

```jsonc
{
  "effects": {
    "discovery": {
      "status": "…",
      "detail": "…",
      "projects": {                       // NEW — per-project style audit (FR-003)
        "<KEY>": { "style": "team_managed", "style_source": "api|operator" }
      }
    },
    "hooks": { … },                       // now also registers before_specify → speckit.jira.feature
    "readme": { … },
    "gitignore": {                        // NEW effect (FR-019)
      "status": "created|written|unchanged|skipped",
      "detail": "personal.yml gitignore coverage"
    }
  },
  "provisional": [                        // NEW — present ONLY in degraded runs (FR-008)
    { "team_prefix": "ijt", "provisional": true }
  ],
  "rerun_guidance": "…"                   // NEW — present ONLY in degraded runs
}
```

## Persisted local binding (`config.local.schema.json` delta)

`resolved_ids.<KEY>` gains `style` and `style_source` (enum values above),
written through the canonical serialiser — an unchanged project re-run stays
byte-identical on both ports (SC-004).

## Exit codes (unchanged set, new mappings)

`0` success (including degraded report-only run) · `1` usage (bad `--style`
value) · `2` fail-closed read (unknown key, network) · `3` auth ·
`4` config refusal (ambiguous style unattended; no usable key unattended;
schema/validation refusals) · `5` prerequisite · `9` privacy BLOCK.

## Agent command definition (`commands/speckit.jira.config.md`) — FR-007

The rewritten definition MUST state, in normative wording testable by grep:
in a connected run the project key and project style are **never** inferred
from git state (branch names, prefixes, folders, remotes); every
branch-derived output belongs to the degraded mode only and is provisional;
the interactive closed questions are exactly: style (two values), project key
(the discovered list), and nothing else new.
