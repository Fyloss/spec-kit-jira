# Mocked Jira Cloud double (T008)

A single-threaded loopback HTTP server that both ports' REST transports target
via base URL. It is **pwsh-only** (`mock-server.ps1`) — PowerShell is present on
every CI runner, so a single implementation serves the Bash and PowerShell
suites alike and avoids a Python dependency. It runs over a raw `TcpListener`
(not `HttpListener`) so it needs no admin rights or urlacl reservation on
Windows.

## What it serves

- **Discovery** for both project styles (non-default metadata, Constitution VII):
  `GET /rest/api/3/project/{key}`, `.../project/{key}/statuses`,
  `.../issue/createmeta/{key}/issuetypes[/{id}]`, `.../priority`, `.../field`.
  Style is chosen from the `projects` map in the config (`company` → `classic`
  fixtures, `team` → `next-gen` fixtures); unknown keys default to company.
- **Writes**: `POST /rest/api/3/issue` → `201` with `issue-created.json`.
- **Identity markers**: `GET /rest/api/3/issue/{key}/properties/spec-kit-jira`
  returns the marker configured under `identity.{key}`, or `404` (= unclaimed).
  `PUT` of the same URL returns `204`.
- **Label search** (003): with an `issues` corpus configured,
  `GET /rest/api/3/search/jql` becomes a real, JQL-aware handler. It honours the
  two terms the adoption sink ever emits — `project = "<KEY>"` and
  `labels IN ("<a>", "<b>", …)` — matches labels **case-sensitively**, orders by
  issue key ascending, and paginates with a `nextPageToken` cursor that is
  **omitted on the last page**. `maxResults` is honoured and can be capped
  further with the top-level `pageSize`, which is how a handful of issues
  exercises real multi-page pagination. Without an `issues` corpus the endpoint
  keeps serving the fixed `search-siblings` fixture that `fetch_mentioned` uses.
- **Per-issue context** (003): with an `issues` corpus configured,
  `GET /rest/api/3/issue/{key}?fields=…` serves that issue's
  `labels` / `parent` / `project`, and a key absent from the corpus is a `404`
  (fail-closed) — this is the read a `--bind` pin resolves through.
- **Fault injection** keyed by project/issue key in the config `faults` map:
  `{ "status": 401 }`, `{ "status": 404 }`,
  `{ "status": 429, "retryAfter": <s> }` (returned on every request → exhausts
  bounded retry), `{ "network": true }` (connection dropped, no response).
  A top-level `"fault"` applies globally when no per-key fault matches.
- **Call log**: every request is appended as `METHOD target` (query included),
  LF-terminated, so callers assert the exact Jira API call sequence (NFR-1).

## Config shape

```jsonc
{
  "projects": { "ADO": "company", "BILL": "team" },
  "faults":   { "AUTH": { "status": 401 } },
  "pageSize": 2,                       // cap project/search AND search/jql pages
  "identity": {                        // per-issue identity markers (US10, 003)
    "ADO-3": { "origin": "human", "repo": "acme/app", "spec_slug": "004-billing-export" }
  },
  "issues": {                          // the 003 candidate corpus
    "ADO-1": { "labels": ["speckit-adopt:003-label-based-adoption"] },
    "ADO-2": { "labels": ["speckit-adopt:003-label-based-adoption:us1"],
               "parent": "ADO-1" },    // omit `parent` for a parentless issue
    "BILL-4": { "labels": ["speckit-adopt:005-audit-trail"],
                "project": "BILL" }    // defaults to the key's own prefix
  }
}
```

## Drivers

- Bash: `source lib.sh` → `mock_start <config.json>` (or `mock_start_json '<json>'`
  to seed inline) / `mock_calls` / `mock_stop` (sets `MOCK_BASE_URL`,
  `MOCK_CALLLOG`).
- PowerShell: `Import-Module Mock.psm1` → `Start-JiraMock -ConfigPath` (or
  `-ConfigJson`) / `Get-JiraMockCallLog` / `Stop-JiraMock` (returns `BaseUrl`,
  `CallLog`).

Both drivers pass the config object through verbatim, so a scenario and a unit
suite seed **identical** corpora.

Each `mock_start` / `Start-JiraMock` binds a fresh ephemeral port and writes the
chosen port to a ready file; drivers block until it appears. Start one instance
per test for isolation.
