# Contract: Jira Cloud REST v3 Endpoints (sink-internal)

**Feature**: 001-jira-reconcile-engine | **Scope**: sink layer only (never referenced from `engine/`)

This is the sink's map of Jira Cloud REST API v3 endpoints per project style. It is **sink-internal**: no `engine/` script may reference any endpoint, host, or identifier here (Constitution VIII). All metadata is discovered at runtime and resolved by logical name (Constitution VII) — no literal Atlassian default type/status/field id is compiled into any script. Endpoint shapes are version-sensitive; the two items flagged in research §"Open items" are verified live during implementation.

Base: `https://<site>/rest/api/3` (site resolved at runtime, never persisted as a coordinate). Auth: `Authorization: Basic base64(email:token)` passed through the argv-safe mechanism of research §7 (Bash `curl --config` on stdin; PowerShell in-process header). The token is never in argv/logs/traces (NFR-3).

## 0. Style detection (first call, both styles) — research §1

| Purpose | Method + Path | Read |
|---------|---------------|------|
| Project style | `GET /project/{projectIdOrKey}` | `.style` (`classic`\|`next-gen`) cross-checked with `.simplified` (bool). Missing ⇒ default company-managed, do not fail closed. |

## 1. Company-managed (`classic`) discovery — FR-005, research §2

| Purpose | Method + Path | Notes |
|---------|---------------|-------|
| Issue types (per project) | `GET /issue/createmeta/{projectIdOrKey}/issuetypes` | Current createmeta sub-resource (all-projects createmeta is deprecated). |
| Fields per issue type | `GET /issue/createmeta/{projectIdOrKey}/issuetypes/{issueTypeId}` | Required/allowed fields. |
| Statuses per issue type | `GET /project/{projectIdOrKey}/statuses` | Includes `statusCategory` (seeds the four-category classification, research §4). |
| Priorities | `GET /priority` | Site-level. |
| Fields catalogue | `GET /field` | Resolve logical names → ids (incl. Flagged, estimation candidates). |

## 2. Team-managed (`next-gen`) discovery — FR-006, research §3

| Purpose | Method + Path | Notes |
|---------|---------------|-------|
| Issue types (project-owned) | `GET /issue/createmeta/{projectIdOrKey}/issuetypes` | Treated as project-owned objects; hierarchy limited to Epic (parent) / Sub-task (child). |
| Fields (project-scoped) | `GET /issue/createmeta/{projectIdOrKey}/issuetypes/{issueTypeId}` + `GET /field` | Estimation field located by the documented heuristic over the project's own fields, operator-confirmed (never the global Story Points custom field). |
| Statuses | `GET /project/{projectIdOrKey}/statuses` | Read per issue type; `statusCategory` seeds classification. |
| Workflows | read per issue type via the statuses/transitions available to that type | Team-managed workflows are per issue type. |

## 3. Reconcile-time reads (both styles)

| Purpose | Method + Path | Used by |
|---------|---------------|---------|
| Ticket identity | `GET /issue/{key}/properties/{propertyKey}` | `resolve_identity` (research §5). |
| Ticket state | `GET /issue/{key}?fields=status,priority,issuelinks,<flagged>,<estimation>` | `read_ticket_state` (drift/idempotency). |
| Transitions (contextual) | `GET /issue/{key}/transitions` | Discovered per issue; never assumed. |
| Mentioned-ticket fetch | `GET /issue/{key}` (+ remote links for Confluence titles/URLs, parent, JQL for siblings) | `fetch_mentioned` (FR-050). Confluence page *content* is not fetched. |

## 4. Writes (both styles) — each preceded by the privacy guard + fail-closed transport

| Action | Method + Path | Rule |
|--------|---------------|------|
| Create issue | `POST /issue` | Estimation written on create only (FR-018); identity property written after create. |
| Update issue | `PUT /issue/{key}` | Estimation never re-sent (FR-018); description write respects the managed section (FR-038/FR-040). |
| Transition | `POST /issue/{key}/transitions` | Withheld if Flagged (FR-036); category-aware drift gates it (FR-034/FR-035). |
| Comment | `POST /issue/{key}/comment` | Counted in idempotency (FR-030). |
| Link | `POST /issueLink` | Human links never modified/removed (FR-037). |
| Label / entity property | `PUT /issue/{key}` (labels) · `PUT /issue/{key}/properties/{propertyKey}` (identity) | Identity marker per-project scoped (FR-044). |

## Cross-cutting rules

- **Rate limiting**: bounded retry with exponential backoff honouring `Retry-After` on 429; exhaustion ⇒ zero writes for that spec + the documented exit code (research §8, Constitution III).
- **Fault mapping**: 401/403 → auth exit; 404 / network / 429-exhausted → per-spec fail-closed exit; monotonic escalation (see `cli-contract.md`).
- **No coordinate persisted**: site URL, accountId, and email are coordinates — never written to any tracked file (Constitution IV); the privacy guard BLOCK tier scans for them before every write.
