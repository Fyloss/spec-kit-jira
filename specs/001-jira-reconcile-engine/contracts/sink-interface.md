# Contract: Engine ↔ Jira-Sink Interface

**Feature**: 001-jira-reconcile-engine | **Constitution**: VIII (Neutral Engine / Jira Sink)

The engine carries **zero Jira knowledge**; all Jira knowledge lives behind this fixed interface. The engine and the sink communicate **only** by passing the schema-validated [neutral interchange document](./neutral-interchange.schema.json). This document is the fixed contract both ports implement identically; the conformance corpus asserts they do (NFR-1).

## Boundary rules (grep-enforced, Constitution VIII)

1. No `engine/` script sources/dot-sources (Bash `source`/`.`) or imports (`Import-Module`/dot-source, PowerShell) any file under `sink/`. — CI grep #1.
2. No `engine/` script contains any Atlassian-specific identifier: issue-key regex (`[A-Z]+-\d+`), `atlassian.net`, `createmeta`, ADF node names, Jira field ids, or Atlassian default type/status names. — CI grep #2. The grep script builds the vendor token from split literals so it does not trip itself.
3. The neutral document is validated against its schema **before any write**; a validation failure blocks the write and surfaces as an error.

## Operations the sink exposes to the engine

The engine calls these; the sink implements them. Every operation is available on **both** ports with identical observable behaviour, and every write-capable operation has a `--dry-run` twin (Constitution XI, FR-033). Inputs are neutral (logical names, the neutral document); outputs are neutral (resolved facts, decisions, summary fragments) — the sink never returns raw Jira JSON to the engine.

| Operation | Input (neutral) | Output (neutral) | Notes |
|-----------|-----------------|------------------|-------|
| `discover_binding(project_key)` | project key | Project Binding facts by **logical name** (style, issue types, statuses+categories, priorities, fields, estimation field, flagged field) | Style detected first (research §1); per-style path (research §2/§3). Used by the config command. |
| `resolve_identity(project_key, spec_ref)` | project key, spec ref | `{ ticket_ref?, origin?, claimed_by_other? }` | Reads the entity-property identity marker (research §5). `claimed_by_other` drives FR-051 refusal. |
| `read_ticket_state(ticket_ref)` | ticket ref | `{ status_classification, flagged, human_links[], managed_section_hash, origin }` | Read-only; classification is by the persisted per-project map (research §4). Used by drift/idempotency. |
| `fetch_mentioned(issue_key)` | issue key | `{ content, acceptance_criteria, priority_logical, labels, status, flagged, links, confluence_pages[title,url], parent_context, siblings[] }` | Read-only fetch (FR-050). Confluence page content is NOT fetched. |
| `plan_writes(neutral_doc, decisions)` | validated neutral doc + engine decisions | ordered **action set** (create/update/transition/comment/link/label) with resolved ids | The `--dry-run` report is exactly this action set (FR-033). No Jira mutation occurs here. |
| `apply_writes(action_set)` | the planned action set | per-action result + summary fragments | Each action runs the pre-write **privacy guard** (BLOCK tier, research §14) and the credential-safe transport (research §7). Fail-closed per spec (Constitution III). |
| `render_description(neutral_content, origin)` | neutral content blocks + origin | ADF document (sink-internal) + managed-section splice result | ADF construction lives here (research §6); managed-section rules per origin (FR-038/FR-040). |
| `write_identity(ticket_ref, spec_ref, origin)` | ticket ref, spec ref, origin | ok/failed | Entity-property marker, per-project scope (FR-044). |

## Decisions the engine makes (sink never makes these)

- Title ladder (FR-013), description synthesis (FR-014), Gherkin/Design extraction (FR-015/FR-016).
- Drift classification behaviour and idempotency (managed-section diff) — **pure functions**, no Jira calls (FR-030–FR-035).
- Routing a spec to a project (FR-041) from the config's routing rules.
- README managed-block byte-splice logic (FR-025–FR-029) — the engine owns the byte manipulation; the sink is not involved (the README is not a Jira artifact).

## Invariants asserted by the conformance corpus

- For identical inputs, both ports emit an identical **action set** (order, ids, kinds), identical exit codes, and identical run summaries (NFR-1).
- The neutral document written to disk (when materialised) is byte-identical across ports (Constitution VI, research §11).
- Schema validation failure ⇒ zero writes + an error (Constitution VIII).
