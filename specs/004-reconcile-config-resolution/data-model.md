# Phase 1 Data Model: Reconcile Resolves Its Own Routing and Plan Context From Config

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md)

No entity is invented by this feature. Every shape below already exists on disk or in memory; what changes is which of them the mirror actually reads, and one correction to how a single field is populated. Nothing here requires a migration of an existing repository.

---

## 1. Team config layer — `.specify/jira/config.yml` (committed)

Read-only for this feature. Validated by `_CFG_TEAM_ERRORS_JQ` in `lib/config.sh`.

| Field | Type | Role in this feature |
| --- | --- | --- |
| `projects[].key` | project key | The set of declared projects. A routing rule naming a key absent from this set is diagnostic `unknown-project`. |
| `projects[].style` | `company_managed` \| `team_managed` | Recorded and reported only. **Never** consulted to decide payload contents (FR-028). |
| `projects[].epic_strategy` | string | Source of the run's epic strategy (FR-006), replacing the built-in `per_repo` default. |
| `projects[].issue_types` | map logical name → id | Committed identifier layer. Loses to the machine layer (FR-009). |
| `projects[].priority_map` | map `P1`\|`P2`\|`P3` → logical priority name | Step one of the two-step priority resolution (FR-008). |
| `routing[].match.folder_prefix` | string | Tested against the spec folder's basename. |
| `routing[].match.spec_label` | string | Tested against the spec's declared labels. |
| `routing[].project` | project key | The rule's result. |
| `routing_default` | project key | Fallback when no rule matches (FR-003). |
| `teams[].folder_prefix` / `teams[].project` | string | The implicit team route `routing_resolve` already applies between rules and the default. |

**Validation rules applied**: an empty resolution, a syntactically invalid key, or a key equal to `JIRA_CONFIG_PLACEHOLDER_KEY` (`PROJ`) blocks every write for the run (FR-005).

---

## 2. Machine binding layer — `.specify/jira/config.local.yml` (gitignored)

Read-only for this feature. Written only by the `config` command. Validated by `_CFG_LOCAL_ERRORS_JQ`.

```yaml
resolved_ids:
  COMP:
    style: company_managed
    issue_types:  { Epic: "10001", Story: "10004" }
    priorities:   { Highest: "1", Medium: "3", Low: "4" }
    statuses:     { "To Do": "10000" }
overrides:
  routing_default: COMP
```

| Field | Role in this feature |
| --- | --- |
| `resolved_ids.<KEY>.issue_types` | Source of the Story issue-type id (FR-007). Already discovered per project via `createmeta/{key}/issuetypes`, so already correct for team-managed projects that own their types privately (FR-027). |
| `resolved_ids.<KEY>.priorities` | Step two of priority resolution (FR-008). **Changed population** — see §5. |
| `resolved_ids.<KEY>.style` | Reporting and hierarchy validation only. |
| `overrides.*` | Merged over the team layer by `config_load`; the machine layer wins (FR-009). |

**Absence rules**: the whole file missing is "never bound" — one notice, exit 0, unchanged from today. The file present but holding no `resolved_ids` entry for the resolved project is a distinct cause, `project-not-bound` (FR-010).

---

## 3. Routing decision (in memory)

Produced once per run by the command layer, before any network call.

| Field | Type | Source |
| --- | --- | --- |
| `project_key` | project key | `SPEC_KIT_JIRA_PROJECT_KEY` when explicitly set, else `routing_resolve(folder, labels, config)` |
| `epic_strategy` | string | `SPEC_KIT_JIRA_EPIC_STRATEGY` when set, else the resolved project's `epic_strategy` |
| `source` | `env` \| `rule` \| `team` \| `default` | Which mechanism produced the key — carried for diagnostics, not for behaviour |

**Inputs**: the spec folder's basename, the spec's declared labels (`[]` when the specification declares none — label-conditioned rules then simply do not match), and the merged config.

**Invariant**: exactly one project key per run, or the run writes nothing.

---

## 4. Creation context (in memory)

The existing plan-context object, now built from the binding instead of arriving empty.

```json
{
  "base_url": "…",
  "story_type_id": "10004",
  "priority_ids": { "P1": "1", "P2": "3", "P3": "4" },
  "estimation_field_id": "customfield_20011",
  "tickets": {},
  "ticket_origins": {},
  "ticket_descriptions": {}
}
```

| Field | Derivation |
| --- | --- |
| `story_type_id` | `resolved_ids.<KEY>.issue_types.Story` |
| `priority_ids.<level>` | `resolved_ids.<KEY>.priorities[ priority_map[<level>] ]` — omitted per level when either step yields nothing |
| `estimation_field_id` | The resolved project's own estimation field (FR-030); absent leaves the estimation unwritten |
| `base_url` | `SPEC_KIT_JIRA_BASE_URL`, unchanged — always wins |

**Precedence**: a non-empty `SPEC_KIT_JIRA_PLAN_CONTEXT` overrides the derived object wholesale (FR-013); `base_url` is re-applied over it, as today.

**Deliberately absent**: `project_key`. The payload's project comes from the neutral document, not from here — see research R2.

---

## 5. Discovered binding — the one corrected field

`discover_binding` output, `priorities` only. Everything else is unchanged.

| Before | After |
| --- | --- |
| Site-wide `GET /priority` list, stored per project | The project's own accepted set, derived from its create metadata against that catalogue |

Three cases, per research R4:

| Project's create metadata | Recorded `priorities` | Payload effect |
| --- | --- | --- |
| No `priority` field | `{}` | No priority declared; run completes normally (FR-029) |
| `priority` with `allowedValues` | Only those values | Only priorities the project offers |
| `priority` without `allowedValues` | The site-wide catalogue | Today's behaviour, preserved |

**No schema change**: `resolved_ids.<KEY>.priorities` already exists and already has this type. Only its contents become project-truthful.

---

## 6. Creation payload (outgoing)

The shape both creation paths must produce. Full contract in [contracts/creation-payload.md](./contracts/creation-payload.md).

| Attribute | Presence | Source |
| --- | --- | --- |
| `fields.project.key` | **Always** — no style, setting or configuration makes it optional (FR-026) | The neutral document's `routing.project_key` |
| `fields.issuetype.id` | Always on create | `story_type_id` |
| `fields.summary` | Always | The story's ladder title |
| `fields.description` | Always on create | Rendered structured description |
| `fields.priority.id` | Only when resolved for that project | `priority_ids[<level>]` |
| `<estimation field>` | Create only, never re-sent on update (FR-012) | `estimation_field_id` |

**Guard**: assembly returns non-zero before producing a payload lacking a project or an issue type; the run writes nothing (FR-024).

---

## Entity relationships

```text
spec file path ──┐
                 ├──> Routing decision ──> neutral document (routing.project_key)
team config ─────┘           │                        │
                             │                        └──> creation payload (fields.project)
                             v
machine binding ────> Creation context ─────────────────> creation payload (issuetype, priority, estimation)
```

The routing decision feeds both branches, which is why the payload's project and the summary's project cannot disagree.
