# Data Model — Reliable Automatic Jira Discovery & Team-Based Feature Prefix

Entities extend the 001 model (`specs/001-jira-reconcile-engine/data-model` via
its contracts). On-disk formats are YAML read through the existing
reader/writer pair; every persisted document round-trips byte-identically on
both ports.

## 1. Project style resolution (extends *Project binding*)

Lives in the machine-owned local binding, per project, inside
`config.local.yml` → `resolved_ids.<PROJECT_KEY>`.

| Field | Type | Rules |
|-------|------|-------|
| `style` | `company_managed \| team_managed` | Never defaulted. Written only when traceable (FR-001). |
| `style_source` | `api \| operator` | `api` = unambiguous discovery signal; `operator` = closed-question answer passed via `--style` (FR-003). |

**State transitions**:

```text
discovery payload ──unambiguous──▶ style persisted (style_source: api)
        │
        └─ambiguous/contradictory─▶ interactive: closed question ─▶ persisted (style_source: operator)
                                    unattended: EXIT_CONFIG 4, zero writes
```

A committed `config.yml` `style` (now **optional**) counts as an operator
declaration; a conflict with an unambiguous API signal re-enters the
ambiguous branch (never silently resolved).

## 2. Project binding source (unchanged entity, constrained sources)

The bound project key in a connected run comes from exactly one of:
command argument → committed config (`projects[].key`, where the literal
placeholder `PROJ` counts as **unset**, FR-005) → operator choice over the
discovered accessible-projects list. Git state is never a source (FR-004).
An unresolvable key fails closed with no substitution (FR-006).

## 3. Accessible project (new, transient — never persisted)

Output element of `discovery_list_projects` (sink):

| Field | Type | Source |
|-------|------|--------|
| `key` | projectKey | `GET /project/search` `values[].key` |
| `name` | string | `values[].name` |
| `style` | enum or `null` | mapped by the same §1 rules from `values[].style` / `values[].simplified` |

Empty list ⇒ fail-closed error (no empty closed question).

## 4. Team convention catalogue (new, committed — `config.yml` `teams:`)

Contract: [`contracts/teams-catalogue.schema.json`](./contracts/teams-catalogue.schema.json)

| Field | Type | Rules |
|-------|------|-------|
| `id` | string | `^[a-z][a-z0-9]*$`, unique across the catalogue. |
| `project` | projectKey | The team's Jira project (routes auto-created tickets; FR-013). |
| `folder_prefix` | string | `^[a-z0-9][a-z0-9-]*-$`, unique; folder-safe by construction (FR-018). |
| `branch_pattern` | string | Contains `<ID>` and `<FEATURE_NAME>` exactly once each; other characters restricted to `[a-z0-9/_-]` (FR-010). `/` creates git hierarchy only. |

Credential-shaped values are refused without echoing (FR-018). The section is
optional — its absence changes nothing (FR-017).

**Implicit team route**: when resolving a spec folder to a project, a folder
whose flat name carries a catalogue team's `folder_prefix` (after the numbering
component) routes to that team's `project` when no explicit `routing` rule
matches, before `routing_default`. Explicit rules always win (US3 scenario 6,
SC-006).

## 5. Personal team selection (new, gitignored — `.specify/jira/personal.yml`)

Contract: [`contracts/personal-config.schema.json`](./contracts/personal-config.schema.json)

| Field | Type | Rules |
|-------|------|-------|
| `team` | string | Must match a catalogue `id`; unknown ⇒ located error listing valid ids (FR-011). |
| `override` | object, optional | `branch_pattern` / `folder_prefix`, same validation as a catalogue entry; use reported in every feature output (FR-012). |

Human-owned: no script ever writes it. Optional: absent file ⇒ `{active:false}`
pass-through. Gitignore coverage is enforced by the config ceremony's new
gitignore effect (FR-019).

## 6. Ticket reference (extends 001's identity model)

| Field | Type | Rules |
|-------|------|-------|
| `key` | issue key | Mentioned (validated read) or created (guarded write) — resolved **before** naming (FR-013). |
| `number` | string | `key` stripped of `^[A-Z][A-Z0-9_]+-` (feeds `<ID>`). |
| `action` | `attached \| created \| would-attach \| would-create` | The `would-*` pair is the `--dry-run` prediction. The non-blocking fallback (FR-016) and the no-team-selected path carry no ticket at all — they emit `{active:false}` (plus one warning for the fallback). |
| `team` | catalogue id | Effective team; differs from the personal selection only after the closed confirmation (FR-014). |

**Effective-team transitions**:

```text
personal team (default)
  ├─ mentioned ticket in same team's project ──────────────▶ personal team
  ├─ mentioned ticket in another catalogue team's project ─▶ closed question
  │      ├─ confirmed ─▶ that team (this feature only; personal file untouched)
  │      └─ refused ───▶ creation stops (no contradictory branch)
  └─ mentioned ticket in a non-catalogue project ──────────▶ closed proceed/stop confirmation
```

## 7. Feature naming result (new, transient — `feature` command output)

Contract: [`contracts/feature-cli-contract.md`](./contracts/feature-cli-contract.md)

| Field | Rules |
|-------|-------|
| `branch_name` | Effective team's `branch_pattern` expanded (FR-015). |
| `short_name` | `folder_prefix + descriptive short name`, prefix never duplicated; always a flat single-level folder component placed after the numbering component by the host (`NNN-ijt-invoice-export`). |
| `override_used` | boolean — audit trail for FR-012. |
| `warnings[]` | e.g. the FR-016 unreachable-Jira fallback warning. |

## 8. Run summary extensions (config command)

Contract: [`contracts/config-cli-contract.md`](./contracts/config-cli-contract.md)

- Per-project style resolution (`style`, `style_source`) in the discovery
  effect (FR-003).
- New `gitignore` effect (`created|written|unchanged` — FR-019).
- Degraded runs: `provisional` proposals array (each marked
  `provisional: true`), one warning, re-run guidance; `resolved_ids` untouched
  (FR-008/FR-009).
