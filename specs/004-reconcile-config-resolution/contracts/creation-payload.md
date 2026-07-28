# Contract: Creation Payload

**Feature**: [../spec.md](../spec.md) | **Interface**: the payload every creation path of the sink emits

Two code paths create work items: the mirror path (`plan_writes` → `apply_writes`) and the feature ceremony's single-item path (`ticket_create`). They currently disagree — only one produces a valid creation. This contract is the shape both must produce, and the shared builder that makes the agreement structural rather than conventional.

---

## Mandatory base

Every creation, on every path, for every project style:

```json
{
  "fields": {
    "project":   { "key": "<resolved project key>" },
    "issuetype": { "id": "<issue type id resolved for THAT project>" },
    "summary":   "<title>"
  }
}
```

`project` is unconditional. No project style, configuration option or environment setting may omit it (FR-026).

`issuetype` must be an identifier the resolved project itself declares. An identifier resolved for one project is never used for another — team-managed projects own their issue types privately, so a shared identifier would name a type that does not exist there (FR-027).

**Producer**: `jira_create_fields_base <project> <summary> <issue-type-id>` in `sink/jira/ticket.sh`. Both paths call it; neither hand-builds the base. `_ticket_create_body` wraps it unchanged; `plan_writes` extends it with the optional attributes below.

---

## Optional attributes, mirror path only

Added on top of the base, each only when resolved for that project:

| Attribute | Condition | Requirement |
| --- | --- | --- |
| `description` | Always on create | Structured, never empty |
| `priority.id` | Only when the resolved project accepts a priority **and** the level maps to an identifier | Omitted otherwise — omission never fails the run (FR-011, FR-029) |
| `<estimation field id>` | Only on create, only when the project declares an estimation field | Never re-sent on update (FR-012) |

**Style independence**: whether an attribute is included follows what the resolved project reports it accepts, never a rule keyed on the project's style (FR-028). A project with no priority in its create metadata yields an empty priority map, and the existing "unresolved priority is omitted" path handles it with no style branch anywhere in the code.

---

## Update payload

Unchanged by this feature, and deliberately different from the create payload:

```json
{ "fields": { "summary": "…", "description": {…}, "priority": {…}? } }
```

No `project`, no `issuetype`, no estimation — an update targets an existing item by key, and the estimation is create-only.

---

## Assembly guard

Before any payload is returned for dispatch:

| Condition | Result |
| --- | --- |
| Project absent or empty | Assembly returns non-zero; zero writes for the run |
| Issue type absent or empty on a creation | Assembly returns non-zero; zero writes for the run |

The guard runs at assembly time, so an incomplete payload is refused **before dispatch** rather than sent and rejected by the destination service (FR-024). This is the fail-closed rule of Principle III applied to payload construction.

The privacy guard is unchanged and still runs as the mandatory gate immediately before every write; this guard sits earlier and does not replace it.

---

## Verification

Every assertion below is checkable on the planned action set with **no network contact**, because `--dry-run` emits exactly the payloads a real run would send:

| Assertion | Requirement |
| --- | --- |
| Every `POST …/issue` body has a non-empty `fields.project.key` | FR-022, SC-009 |
| That key equals the run summary's resolved project | FR-023 |
| Every `POST …/issue` body has a non-empty `fields.issuetype.id` | FR-024, SC-003 |
| The placeholder key appears in zero payloads | FR-005, SC-002 |
| Against a project whose metadata omits priority, zero payloads declare a priority | FR-029, SC-012 |
| With two projects of different styles bound, zero payloads carry the other project's identifiers | FR-027, SC-013 |
| Both creation paths produce the same base attribute set | FR-025, SC-010 |
| Both ports produce byte-identical payloads | FR-021, SC-007 |
