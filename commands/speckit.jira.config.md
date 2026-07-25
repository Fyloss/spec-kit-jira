---
name: "speckit.jira.config"
description: "Configure the Jira reconcile bridge: discover project metadata, register lifecycle hooks, and manage the README block — a deterministic, model-independent ceremony."
argument-hint: "Optional: a project key to (re)bind, e.g. PROJ"
---

# /speckit.jira.config

Run the single installation ceremony for the Jira reconcile bridge. The ceremony
is **fully deterministic and model-independent** (US1, FR-001): every step below
is exactly one of

- an **API read** (a `GET` against Jira, never a write), or
- a **config read** (reading `.specify/jira/config.yml` / `config.local.yml`), or
- a **closed, enumerated question** to the operator (a fixed list of choices — no
  free-form judgement, no inferred field or key).

No step is left to model judgement. Because the ceremony reads only and persists
through the canonical serialiser, running it twice against an unchanged project
produces a **byte-identical** `config.local.yml` on both ports (FR-003, SC-004).

The heavy lifting is performed by the deterministic entry point
`spec-kit-jira config`; this file is the exact, ordered algorithm the agent
follows to drive it. **Never invent a project key, an issue-type name, a status,
a field id, or a strategy** — each comes from an API read or a closed question.

## Preconditions (fail before touching Jira)

1. **Prerequisite gate** — the entry point checks `bash ≥ 4` (macOS ships 3.2 —
   name it explicitly), `curl`/`jq`/`git`, or `pwsh ≥ 7`. On failure it exits `5`
   **before any Jira interaction** (NFR-4). Do not proceed.
2. **Credentials** — resolve the token via env → OS secret manager → gitignored
   `.specify/jira/.env` (NFR-3). The token NEVER appears in argv, logs, or errors.

## Algorithm (ordered, each step is read / config-read / closed question)

1. **Config read** — read `.specify/jira/config.yml`. If absent, create it from
   `.specify/extensions/jira/templates/config.yml.template` and ask the operator
   the closed questions it documents (each key is an enumeration):
   - `style`: **{ company_managed | team_managed }** — *detected* by an API read
     at step 3; only confirmed here.
   - `epic_strategy`: **{ per_repo | per_feature }**.
   - `task_strategy`: **{ subtask | linked_story }**; if `linked_story`, ask
     `link_type` from the **discovered** link-type list (step 3) — never invented.
   - `priority_map`: for each of **P1 / P2 / P3**, pick a priority **from the
     discovered priority list** (step 3).
2. **Config read** — for each project, resolve its routing (`routing[]` /
   `routing_default`). A credential-shaped value in either YAML layer is refused
   with exit `4` (FR-023); the offending value is never echoed.
3. **API reads (discovery, US2)** — for each configured project the entry point
   runs the fixed, style-first read sequence (research §1–§3), **in this order**:
   1. `GET /project/{key}` → detect **style** (this is the first Jira call).
   2. `GET /issue/createmeta/{key}/issuetypes` → issue types + hierarchy levels.
   3. `GET /issue/createmeta/{key}/issuetypes/{firstType}` → the project's own
      field schema (estimation candidates + flagged field come from **here**,
      never the global `/field` catalogue — research §3).
   4. `GET /project/{key}/statuses` → statuses + `statusCategory`.
   5. `GET /priority` → priorities.
   6. `GET /field` → the logical-name → id catalogue.
4. **Closed question (estimation field)** — the entry point *ranks* the project's
   numeric fields and **proposes** the top candidate; the operator **confirms or
   picks another from the ranked list**. It is never silently assumed, and never
   the global Story Points field (research §3).
5. **Closed question (status classification)** — each discovered status is seeded
   objectively from its `statusCategory` (done → `post-scope`, else `unknown`) and
   the operator maps phases → statuses from the **discovered** status list. There
   is **no built-in "ideal" status/phase table** — the operator's workflow is
   authoritative (FR-012).
6. **Capability check (mapping validity, FR-007)** — a team-managed project
   supports only an Epic parent and Sub-task children. A configured level **above
   the discovered Epic tier** is refused at config time with exit `4`, naming the
   offending level and the project style. The Epic tier is the top non-subtask
   hierarchy level **from the binding**, never a compiled-in name.
7. **Persist (deterministic write)** — the resolved-id table (logical name → id
   for issue types, priorities, statuses) is written into the machine-owned
   `.specify/jira/config.local.yml` via the canonical serialiser, preserving the
   operator's `site_alias` / `overrides`. `config.yml` is **not** rewritten.

## The three effects (reported separately — FR-054)

A single run has three effects and the summary reports each **separately**:

- **discovery** — the resolved-id table written to `config.local.yml` (above).
- **hooks** — idempotent `after_*` lifecycle-hook registration (US9).
- **readme** — the version-marked managed README block (US5).

> **Increment note**: in the current increment only the **discovery** effect
> performs its write; the **hooks** and **readme** effects appear as distinct
> summary sections and are wired in later increments (US9 hook registration, US5
> README block). The summary structure is stable across increments.

## Flags

- `--json` — emit the machine-readable run summary (`run-summary.schema.json`).
- `--dry-run` — compute everything and report, but write nothing.
- `--repair-hooks` — one-command repair of missing `after_*` hooks (US9).
- `--verbose` — extra diagnostics (the token never appears, even here).
- `--help` — usage; exits `0`.

## Exit codes

`0` success · `1` usage · `2` fail-closed read · `3` auth · `4` config/capability
refusal · `5` prerequisite failure · `9` privacy BLOCK. Monotonically escalating
(Constitution III); identical on both ports.
