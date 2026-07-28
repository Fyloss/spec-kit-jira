# Contract — Jira Cloud endpoints delta for adoption

**Feature**: 003-label-based-adoption

Delta to
[`001/contracts/jira-cloud-endpoints.md`](../../001-jira-reconcile-engine/contracts/jira-cloud-endpoints.md).
Base: `https://<site>/rest/api/3` — the site is a coordinate resolved at runtime
and never persisted or printed (Constitution IV).

Adoption touches **three** endpoints in total: one new read, one existing read,
and one existing write. Nothing else.

## 1. New read — candidate discovery by label

| Purpose | Method + Path | Used by |
|---------|---------------|---------|
| Label search, per routed project | `GET /search/jql?jql=<encoded>&fields=labels,parent,project&maxResults=100[&nextPageToken=<token>]` | `adopt_search_candidates` (sink) |

**JQL shape** — assembled from derived label values only, never from free text:

```text
project = "<PROJECT_KEY>" AND labels IN ("<label1>", "<label2>", ...)
```

**Rules**

- **One query per distinct routed project**, carrying the union of the label
  values implied by the spec folders that route there. The routed project comes
  from the existing `routing_resolve`; a candidate in any other project is not
  adopted by that spec (FR-004).
- **Bounded by the folders in scope** — the bridge searches for the exact label
  values the targets imply and never enumerates a backlog (NFR-6). This is also
  why a label naming a non-existent spec folder is undiscoverable rather than
  reported (spec Out of Scope).
- **Paginated to exhaustion** on the `nextPageToken` cursor; the loop stops only
  when the response omits the token. A truncated candidate list would silently
  turn a two-candidate ambiguity (which must be refused, FR-010) into a
  one-candidate binding, so exhaustive pagination is a correctness requirement,
  not a performance one (NFR-6, research §2).
- `/search/jql` is the supported Jira Cloud search endpoint; the offset-paginated
  `GET /search` was removed in the 2025 search-API migration. `fetch_mentioned`
  still uses the old form for a best-effort sibling read and is out of scope
  here (research §1).
- `maxResults` is a request, not a guarantee — the server may return fewer. Only
  the absence of `nextPageToken` ends the loop.

**Response fields consumed**: `issues[].key`, `issues[].fields.labels`,
`issues[].fields.parent.key` (absent ⇒ `null`), `issues[].fields.project.key`.
Nothing else is read, so adoption asserts nothing about issue types, statuses,
transitions, or custom fields, and works over both project styles without a
style branch (Principle VII, NFR-5).

## 2. Existing read — the claim check

| Purpose | Method + Path | Used by |
|---------|---------------|---------|
| Ticket identity | `GET /issue/{key}/properties/spec-kit-jira` | existing `identity_read` |

One read per candidate **and** per `--bind` pinned key — the claim check applies
identically to discovered and pinned candidates (FR-020). Behaviour is unchanged
from feature 001: a `404` means "unclaimed" and returns success; any other
transport failure propagates its mapped exit code.

The marker's `origin` and `spec_slug` drive four of the eight refusal classes:
`already-claimed`, `spec-owns-bridge-ticket`, and the `already-adopted` skip
(FR-011, FR-027).

## 3. Existing write — the only write adoption performs

| Action | Method + Path | Rule |
|--------|---------------|------|
| Identity stamp | `PUT /issue/{key}/properties/spec-kit-jira` | Body `{"origin":"human","repo":…,"spec_slug":…}`. One per adopted ticket. |

**Rules**

- This is the **complete** write surface of the feature. Adoption issues no
  `POST /issue`, no `PUT /issue/{key}`, no `POST /issue/{key}/transitions`, no
  `POST /issue/{key}/comment`, no `POST /issueLink`, and no label mutation
  (FR-007). The conformance corpus asserts the exact call sequence, so an
  accidental extra call is a failing test.
- Executed through the existing `apply_writes`, which scans every payload with
  the BLOCK-tier privacy guard **before** the first write and returns exit 9
  with zero writes on a match — adoption is not exempt (FR-028) — and which
  aborts the remaining writes on any transport result at or above exit 2
  (FR-008, research §7).
- The body is built by the existing `identity_marker`, so the adopt and mention
  paths cannot drift in what they stamp.
- Origin is the literal `human` (the wire value `bridge-created` names the other
  origin; the spec's `bridge_created` names the concept — research §4).

## Cross-cutting rules (unchanged)

- **Rate limiting**: bounded retry with exponential backoff honouring
  `Retry-After` on 429; exhaustion aborts the whole run before any write with
  the documented exit code (FR-008).
- **Fault mapping**: 401/403 → exit 3; 404 / network / 429-exhausted → exit 2;
  monotonic escalation, highest applicable code wins (FR-013, FR-030).
- **No coordinate persisted or printed**: site URL, accountId, and email are
  coordinates. Adoption writes nothing into the repository tree at all (FR-028)
  and prints issue keys, project keys, and spec folder names only (FR-025).

## Mock-server delta (`tests/conformance/mock-jira/mock-server.ps1`)

The route `^/rest/api/3/(search|search/jql)$` currently returns the fixed
`search-siblings` fixture regardless of the JQL — sufficient for
`fetch_mentioned`, insufficient here. It gains a **JQL-aware handler** driven by
a per-scenario issues map, so a scenario can express:

- zero, one, and several candidates for a label (FR-009, FR-010),
- candidates carrying another spec's marker, or this spec's with either origin
  (FR-011, FR-027) — served by the existing `Get-IdentityMarker` path with
  scenario data, no new mock code,
- parent relationships for the hierarchy checks (FR-014, FR-015),
- candidates in a non-routed project (FR-005),
- multi-page results, to prove pagination reaches every candidate (NFR-6),
- both project styles (NFR-5).

The existing per-key fault-injection map already covers the
"unreliable read during discovery aborts before any write" scenario (FR-008)
with no new capability.
