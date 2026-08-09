# Contract — the recognition prefetch

Covers spec FR-015 … FR-018. The governing rule: **the prefetch may only ever remove requests. It may
never change an outcome.**

## 1. The endpoint

`POST {base}/rest/api/3/issue/bulkfetch`

```json
{
  "issueIdsOrKeys": ["PROJ-1", "PROJ-2", "..."],
  "fields": ["summary", "description", "priority", "status", "issuelinks", "parent", "labels", "subtasks"],
  "properties": ["spec-kit-jira"]
}
```

Confirmed against the published Jira Cloud OpenAPI document, retrieved 2026-08-07:

- **Up to 100 issues** per request. Chunk at 100.
- Addressed **by identifier**, not by query. No JQL, no search index — this is what makes it legitimate
  where feature 005 rejected `key IN (…)` search (research R2, and spec FR-016).
- `properties` accepts up to 5 keys; we send 1, so the identity marker still folds into the same request.
- `fields` defaults to `*navigable` here, **unlike** `GET /issue/{key}` whose default is all fields. The
  explicit list above is therefore mandatory, never omitted.
- Responses: `200`, `400`, `401`. Body: `{"issues": [IssueBean], "issueErrors": [{"id", "errorMessage"}]}`.
- Issues are returned in ascending `id` order — **never** in request order.

## 2. Interface

`sink/jira/prefetch.sh` / `sink/jira/Prefetch.psm1`:

| Function | Behaviour |
| --- | --- |
| `prefetch_load <key>…` | Chunks the keys, issues one request per chunk, populates the map. Returns 0 always. |
| `prefetch_get <key> <fields-csv>` | Prints the same canonical JSON `_recognition_read` prints — `{"gone":false,"marker":…,"fields":{…}}` — projected to `<fields-csv>`. Returns 1 on a miss, printing nothing. |
| `prefetch_reset` | Empties the map. Test support. |

`prefetch_load` is called from the command layer, where the full key list — parent, stories, and tasks —
is known in one place.

## 3. The two outcomes the endpoint cannot express

From the endpoint's own documentation:

> Issues which aren't found or that the user doesn't have permission to view won't be returned in this
> list [`issueErrors`].

A deleted ticket and an invisible ticket are therefore **indistinguishable** in a `bulkfetch` response —
both are simply absent. Today those are:

| Today | Status | Classification |
| --- | --- | --- |
| Ticket deleted | `404` | `{"gone":true}` → re-created as new, with a `recreated_from` note |
| Ticket not visible | `403` | auth (exit 3) → the whole specification fails closed |

Collapsing them would be a fail-closed regression in one direction and a duplicate-ticket regression in
the other.

**Resolution — the fall-through.** `_recognition_read` and `_recognition_read_parent` call `prefetch_get`
first. On a miss they execute **exactly today's `GET`**, unchanged, and today's status code produces
today's classification. Spec FR-017's "the ambiguous keys alone MUST be re-read individually" is
satisfied by *not removing* the existing path rather than by new logic.

In the healthy steady state every key is present, so the extra reads number zero. In an abnormal state
the cost returns to today's, which is the correct place for it.

## 4. Invariants

| # | Invariant |
| --- | --- |
| P1 | A key absent from the prefetch response is re-read individually. No classification is ever derived from absence. |
| P2 | A non-2xx from `bulkfetch` empties the map and the phase proceeds at today's semantics and today's cost. It does **not** consume the fail-closed budget — the authoritative read has not happened yet. |
| P3 | Every hit is projected down to the caller's own field list before it is returned, so the bytes handed downstream are identical to an unprefetched read. |
| P4 | Results are matched back to requested keys by comparing the returned `key`, case-insensitively. `bulkfetch` resolves moved and case-differing identifiers and returns in id order, so positional matching is forbidden. Anything unmatched is a miss. |
| P5 | Chunk boundaries are unobservable: the outcome for a key list of any length is identical to the outcome for the same keys read individually. |
| P6 | The prefetch issues zero requests when there are zero recorded keys — a first run performs no prefetch. |
| P7 | Every existing classification is preserved exactly: `bound`, `new`, `blocked`, `marker-mismatch`, `duplicate-claim`, `parent-key-unrecorded`, re-routed, and the inconclusive-read fail-closed. |

## 5. Field projection

The two readers request different sets:

| Reader | Fields |
| --- | --- |
| `_recognition_read` (story) | `summary,description,priority,status,issuelinks,parent,labels` + `subtasks` |
| `_recognition_read` (task) | `summary,description,priority,status,issuelinks,parent,labels` |
| `_recognition_read_parent` | `summary,description,labels` |

The prefetch requests the union. `prefetch_get` intersects the returned `.fields` object with the
caller's list before emitting, then passes it through `json_canonical`. A field the caller did not ask
for can therefore never reach a downstream comparison, and a field Jira omitted stays omitted.

## 6. How the invariants are proven

The decisive test is a **differential** one, and it is what the `_RECOGNITION_NO_PREFETCH` seam exists
for: run every recognition-touching conformance scenario twice — prefetch on, prefetch off — and diff
`stdout`, `stderr`, `exit`, and the post-run tree. They must be byte-identical. Only `calls.log` differs,
and it differs in exactly one direction: fewer requests.

Scenario coverage the corpus gains, each asserting identical classification with and without the
prefetch:

| Case | Assertion |
| --- | --- |
| All keys present | Read phase issues 1 request for ≤100 keys; every ticket classified `bound` |
| 101 keys | 2 requests; identical outcome |
| One key deleted (`404` on fall-through) | Classified `new` with `recreated_from`, exactly as today |
| One key not permitted (`403` on fall-through) | Whole specification fails closed, exit 3, zero writes |
| `bulkfetch` returns `400` | Every read falls through; run completes identically at today's cost |
| `bulkfetch` returns `401` | Every read falls through; the individual read produces today's auth failure |
| A returned key differing in case | Matched; not re-read |
| Zero recorded keys | Zero prefetch requests |
| A ticket created seconds earlier | Recognised — the immediate-consistency assertion that makes R2's substitution legitimate |

The conformance mock in `tests/conformance/mock-jira/` gains a `POST /rest/api/3/issue/bulkfetch` handler
that composes its response from the same fixtures it already serves per key, so the two ports see one
source of truth.
