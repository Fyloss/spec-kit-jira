# Phase 1 Data Model: Jira Reconcile Engine

**Feature**: 001-jira-reconcile-engine | **Date**: 2026-07-23

This model is the conceptual data layer behind the reconcile engine and the Jira sink. It derives directly from the spec's **Key Entities** and the functional requirements. Concrete serialisations live in `contracts/` (JSON Schemas for the neutral document, both config layers, and the run summary). Nothing here carries Jira-specific identifiers into the **engine** side — the neutral interchange document is the only object crossing the engine↔sink interface (Constitution VIII).

## Layering

| Layer | Owns | Never contains |
|-------|------|----------------|
| **Engine (neutral)** | Spec Artifact Set, Neutral Interchange Document, Drift Decision, Idempotency Decision, Managed Section (logic) | Any Jira id, ADF node, endpoint, issue-key regex |
| **Sink (Jira)** | Project Binding, Ticket Identity Marker (write/read), ADF rendering, REST transport | Reconcile *decisions* (drift/idempotency logic) |
| **Config** | Team Config, Local Binding, Privacy Allowlist | Any credential |
| **Cross-cutting** | Run Summary, Version Source | — |

---

## 1. Team Config — `config.yml` (committable, credential-free)

The single shared, PR-reviewable configuration at `.specify/jira/config.yml` (repo root, **never** in the extension folder). Business-language keys (Constitution XVI). Schema: `contracts/config.schema.json`.

| Field | Type | Rules | FR |
|-------|------|-------|----|
| `version_compat` | string (semver range) | Extension version the config was authored against (advisory) | FR-021 |
| `projects[]` | list | One entry per mapped Jira project | FR-041, FR-043 |
| `projects[].key` | string | Jira project key (public within org — allowed) | FR-019 |
| `projects[].style` | enum `company_managed`\|`team_managed` | Detected, persisted by logical value | FR-004 |
| `projects[].epic_strategy` | enum `per_repo`\|`per_feature` | Chosen explicitly | FR-008 |
| `projects[].task_strategy` | enum `subtask`\|`linked_story` | Chosen explicitly | FR-009 |
| `projects[].link_type` | string | Required iff `task_strategy = linked_story`; logical name | FR-009 |
| `projects[].hierarchy[]` | list of logical level names | Rejected at config time if it exceeds the style's limit (team-managed: Epic/Sub-task only) | FR-007 |
| `projects[].issue_types{}` | map logical→id | Resolved via API; **no literal Atlassian default** in scripts | FR-010 |
| `projects[].phase_status_map{}` | map phase→status (many-to-one) | Two consecutive phases on one status ⇒ no transition | FR-011 |
| `projects[].status_classification{}` | map status→`mapped`\|`post-scope`\|`halted`\|`unknown` | Exactly one category per status, per project | FR-011, FR-034 |
| `projects[].priority_map{}` | map `P1\|P2\|P3`→priority logical name | | FR-017 |
| `projects[].estimation_field` | logical descriptor | Operator-confirmed discovered field (team-managed: not global Story Points) | FR-006, FR-018 |
| `routing[]` | list | Ordered rules mapping `specs/<pattern>`→project | FR-041 |
| `routing[].match` | object `{folder_prefix?, spec_label?}` | | FR-041 |
| `routing[].project` | string (project key) | | FR-041 |
| `routing_default` | string (project key) | Fallback when no rule matches | FR-041 |
| `generation{}` | object | Content-generation options (Design section on/off, etc.) — each tied to an FR | FR-013–FR-018, XV |
| `privacy.allowlist[]` | list of domains/hosts | Neither block nor warn | FR-053 |

**Validation**: schema **rejects any credential-shaped value** in any field (ATATT prefix, `*.atlassian.net` real host, email/token shapes) (FR-023). A team-managed project with a `hierarchy` level above Epic is rejected at config time with the limitation named (FR-007).

---

## 2. Local Binding — `config.local.yml` (gitignored)

Personal overrides and instance-specific resolved ids the team chooses not to commit. Schema: `contracts/config.local.schema.json`. Same credential-rejection rule (FR-023). **Never** contains the token (secrets resolve only via NFR-3). Never destroyed by reinstall/upgrade (FR-020).

| Field | Type | Notes |
|-------|------|-------|
| `site_alias` | string | Non-secret alias only; the real site URL is a *coordinate*, never stored here |
| `resolved_ids{}` | map | Instance-specific id resolutions cached locally |
| `overrides{}` | object | Per-user overrides of team config fields |

---

## 3. Project Binding (sink-owned, per project)

The discovered, resolved metadata for one project — the sink's authoritative view. Persisted into `config.yml`/`config.local.yml` split per the team's choice; assembled fresh from the API on `/speckit.jira.config`.

| Field | Type | Source |
|-------|------|--------|
| `style` | `company_managed`\|`team_managed` | `GET project.{style,simplified}` (research §1) |
| `issue_types[]` | `{logical_name, id, subtask:bool}` | createmeta / project-scoped (research §2/§3) |
| `statuses[]` | `{name, id, status_category, classification}` | project statuses + operator (research §4) |
| `transitions` | per-issue, discovered at reconcile | `GET issue/{key}/transitions` |
| `priorities[]` | `{logical_name, id}` | `GET priority` |
| `fields[]` | `{logical_name, id, schema_type}` | `GET field` / project createmeta |
| `estimation_field` | `{logical_name, id}` | discovery heuristic + operator (research §3) |
| `flagged_field` | `{id}` | discovered, not assumed (research §15) |

**Invariant**: every reference is by logical name, resolved to an id through the API — no literal Atlassian default type/status/field id in any script (FR-010, Constitution VII). Bindings are per-project so two teams never collide (FR-044).

---

## 4. Spec Artifact Set (engine-owned, disk source of truth)

The `spec.md` (+ optional `plan.md`, `tasks.md`) of one `specs/NNN-feature/` folder — the reference the reconcile derives from (Constitution I).

| Derived value | Rule | FR |
|---------------|------|----|
| `title` | Ladder: explicit `Title:` → H1 → user-story section title → first non-empty paragraph → folder slug; **never** `## Summary` | FR-013 |
| `description` | Structured, non-empty, synthesised from need statement + context; works with no `## Summary` | FR-014 |
| `acceptance_criteria[]` | Parsed Given/When/Then | FR-015 |
| `design[]` | Figma links + UX/UI guidance | FR-016 |
| `priority` | P1/P2/P3 from the spec | FR-017 |
| `estimation` | Declared estimation, if any (create-only) | FR-018 |
| `user_stories[]` | Each becomes its own Story under the Epic | FR-008 |
| `tasks[]` | From `tasks.md`; become Sub-tasks or linked Stories per strategy | FR-009 |

---

## 5. Neutral Interchange Document (engine→sink, schema-validated)

The **only** object crossing the interface (Constitution VIII). Built by the engine, validated against `contracts/neutral-interchange.schema.json` **before any write**. Carries zero Jira identifiers — logical names only; the sink resolves them to ids.

```text
NeutralDoc
├── spec_ref            { repo, spec_slug, folder }
├── routing             { project_key }               # resolved by engine from routing rules
├── epic                { strategy, title, description }
├── stories[]           { local_id, title, description(ADF-neutral blocks),
│                         acceptance_criteria[], design[], priority_logical,
│                         estimation?, tasks[] }
├── tasks[]             { local_id, title, relation: subtask|linked_story, link_type_logical? }
└── content_blocks      # neutral, Jira-agnostic block tree the sink renders to ADF
```

**Invariant**: every field is a logical/neutral value; `priority_logical`, `link_type_logical`, status references are names, never ids or ADF nodes. Schema validation failure blocks the write and surfaces as an error (Constitution VIII).

---

## 6. Ticket Identity Marker (sink-owned)

Binds a Jira ticket to a spec. Stored as an **issue entity property** (research §5), scoped per project.

| Field | Type | Rule |
|-------|------|------|
| `repo` | string | Repository identifier |
| `spec_slug` | string | `NNN-feature` |
| `project_key` | string | Per-project scope (FR-044) |
| `origin` | enum `bridge_created`\|`human` | Discriminates managed-section behaviour (FR-040) |

**Invariants**: identity never keyed on a mutable title/summary (Constitution II); resolves through spec-folder rename (Edge Cases); a mentioned ticket already carrying another spec's identity ⇒ zero writes + actionable refusal (FR-051).

---

## 7. Managed Section (engine logic, sink renders)

The delimited, bridge-owned region of a Jira description — or the whole description for bridge-created tickets.

| Case (by `origin`) | Behaviour | FR |
|--------------------|-----------|----|
| `human` | Write only inside the delimited panel ("Synced from spec-kit — do not edit below this line"); preserve every human line verbatim above it, permanently, incl. after later edits | FR-038 |
| `bridge_created` | Whole description is the managed section; no delimiters | FR-040 |

**Invariant**: the description idempotency diff is computed on the managed section alone (FR-039). The discriminator is the recorded origin, never a content heuristic.

---

## 8. Managed README Block (engine logic for byte-splice)

The version-marked, bridge-owned region of the consuming `README.md`.

| Aspect | Rule | FR |
|--------|------|----|
| Markers | `<!-- spec-kit-jira:start v<version> -->` … `<!-- spec-kit-jira:end -->`, version from the single source | FR-024 |
| Update | Replace only bytes strictly between markers; every byte outside preserved verbatim (CRLF-safe) | FR-025 |
| Line endings | Adopt host's dominant convention; new README uses LF; never mixed-ending | FR-025 |
| Absent block | Append once at a documented position without reformatting | FR-026 |
| Absent README | Create one containing only the block | FR-026 |
| Malformed markers | Zero writes + located error with line numbers | FR-027 |
| Idempotent | Unchanged version + content ⇒ zero rewrites, zero-change report | FR-028 |
| Ownership | Block regenerated (bridge-owned); hand-edited block replaced, summary states so | FR-029 |

---

## 9. Drift Decision & Idempotency Decision (engine-owned)

Pure functions of (disk-inferred phase, ticket status classification, managed-section diff). No Jira calls.

| Input status classification | Drift behaviour | FR |
|-----------------------------|-----------------|----|
| `post-scope` | Never backward drift; a disk phase regression aborts the *transition* by default (content-only may still reconcile); `--on-drift=proceed` or explicit confirmation required to pull back | FR-034, FR-035 |
| `unknown` | Named drift + suggestion to classify | FR-034 |
| `halted` | Stop all writes to the ticket; surface orphaned spec with two remediations (archive spec / reopen ticket) | FR-034 |
| `mapped`, ticket advanced Jira-side | Named drift warning; never silent overwrite | FR-031 |

**Idempotency invariant**: a re-run on an unchanged corpus produces **zero writes of every kind** (create/update/transition/comment/link/label) (FR-030, Constitution II). Flagged tickets withhold transitions by default; human links are never modified (FR-036, FR-037).

---

## 10. Run Summary (cross-cutting)

Structured report; prose by default, `--json` opt-in. Schema: `contracts/run-summary.schema.json`.

| Section | Content | FR |
|---------|---------|----|
| Counts | created / updated / skipped / warnings / errors | NFR-5 |
| Three effects (config run) | discovery / hooks / README — reported **separately** | FR-054 |
| Drift | named warnings per ticket + field | FR-031 |
| Flags | Flagged tickets surfaced | FR-036 |
| Blockers | open blocking links named (info, non-gating) | FR-037 |
| Hook health | present / missing / disabled + one-command repair hint | FR-047 |
| Mutations | every mentioned-ticket mutation logged | FR-049 |

---

## 11. Version Source (cross-cutting)

The **single** source of truth: `.specify/extensions/jira/VERSION`. Every consumer (config command, README block markers, run summary, upgrade check) reads it from there. **No** `.specify/jira/VERSION` file and **no** other hand-maintained version string anywhere in the consuming repo (FR-021, FR-022, SC-006). *(Implementation note: the pre-existing `.gitignore` line for `.specify/jira/VERSION.local` is removed, since it implies a forbidden marker.)*

---

## Entity relationships (summary)

```text
Spec Artifact Set ──parse──▶ Neutral Interchange Document ──validate──▶ [interface] ──▶ Jira Sink
      (engine)                       (engine)                                            │
                                                                                         ▼
Team Config ◀──routing──┐                                            Project Binding (per project)
Local Binding           ├── resolve project & mapping                        │
Privacy Allowlist       ┘                                                     ▼
                                                             Ticket ◀──Ticket Identity Marker (entity property)
                                                                │
                                                                ├── Managed Section (description)
                                                                └── ADF-rendered content
All runs ──▶ Run Summary        Version Source ──▶ README block markers, upgrade check, summary
```
