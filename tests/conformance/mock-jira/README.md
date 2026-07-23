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
- **Fault injection** keyed by project/issue key in the config `faults` map:
  `{ "status": 401 }`, `{ "status": 404 }`,
  `{ "status": 429, "retryAfter": <s> }` (returned on every request → exhausts
  bounded retry), `{ "network": true }` (connection dropped, no response).
  A top-level `"fault"` applies globally when no per-key fault matches.
- **Call log**: every request is appended as `METHOD target` (query included),
  LF-terminated, so callers assert the exact Jira API call sequence (NFR-1).

## Drivers

- Bash: `source lib.sh` → `mock_start <config.json>` / `mock_calls` / `mock_stop`
  (sets `MOCK_BASE_URL`, `MOCK_CALLLOG`).
- PowerShell: `Import-Module Mock.psm1` → `Start-JiraMock` / `Get-JiraMockCallLog`
  / `Stop-JiraMock` (returns `BaseUrl`, `CallLog`).

Each `mock_start` / `Start-JiraMock` binds a fresh ephemeral port and writes the
chosen port to a ready file; drivers block until it appears. Start one instance
per test for isolation.
