# Contract — Jira Cloud endpoint delta (sink layer)

Extends `specs/001-jira-reconcile-engine/contracts/jira-cloud-endpoints.md`.
All calls go through the existing transport (`jira_request` /
`Invoke-JiraRequest`): same auth delivery, retry, and exit-code mapping.

## New reads

| Call | Purpose | Notes |
|------|---------|-------|
| `GET /rest/api/3/project/search?startAt=N&maxResults=50` | Accessible-projects list for the FR-004(c) closed question | Paginated (`isLast`/`total`); extracted fields per page: `values[].key`, `values[].name`, `values[].style`, `values[].simplified`. Returns only projects the credentials can browse — no elevated permission assumed. Empty total ⇒ fail-closed "no visible project" error. |
| `GET /rest/api/3/issue/{key}?fields=project` | Mentioned-ticket validation at feature-creation time (FR-013/FR-014) | Read-only; the ticket's `fields.project.key` feeds the cross-team check. Fail-closed codes apply (never silent fallback for a *mentioned* key). |

## Changed interpretation (no new call)

`GET /rest/api/3/project/{key}` (existing first discovery read): the
`style`/`simplified` mapping becomes three-valued — `team_managed`,
`company_managed`, or **ambiguous** (both signals absent, or contradictory).
Ambiguous is surfaced to the command layer as `style: null` in the binding;
the sink never substitutes a default (FR-001).

## New write

| Call | Purpose | Guards |
|------|---------|--------|
| `POST /rest/api/3/issue` | Automatic ticket creation in the effective team's project when no ticket is mentioned (FR-013) | Body: `fields.project.key` = team's project, `fields.issuetype.id` = the binding's resolved story-type id (never a literal type name — Constitution VII), `fields.summary` = feature description. The story-type id is read from the run context `SPEC_KIT_JIRA_PLAN_CONTEXT` (canonical JSON, key `story_type_id`) — the same out-of-band channel the reconcile command already consumes (001 convention); the wired flow fills it from the discovery binding. An absent or empty `story_type_id` at create time takes the FR-016 non-blocking fallback (`{active:false}` + one warning). PASS-1 privacy guard scans the body before the POST (exit 9, zero writes on BLOCK). Failure ⇒ non-blocking fallback (FR-016), never a hard stop. Created ticket is identity-stamped like any bridge-created artifact. |

No delete, no transition, no label call is added by this feature.
