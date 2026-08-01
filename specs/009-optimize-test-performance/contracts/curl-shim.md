# Contract: `curl` shim (`tests/conformance/mock-jira/curl-shim.sh`)

A scripted replacement for the `curl` binary, placed first on `PATH` by
`mock_start` for the Bash port. It must satisfy exactly the subset of `curl`'s
CLI that `jira_request()` (`scripts/bash/sink/jira/client.sh`) uses — no more.
`jira_request()` is NOT modified; it must not be able to tell the shim from real
`curl` except that responses come from fixtures.

## Invocation shape it must accept

`jira_request` calls (line 139 of client.sh, post-008):

```
printf '%s\n' "${cfg}" | curl --silent --config - \
  --output "${respfile}" --dump-header "${hdrfile}" \
  --write-out '%{http_code}' 2>/dev/null
```

Where the config on **stdin** contains:
```
header = "Authorization: Basic ..."      # MUST be ignored & never logged
url = "<base>/rest/api/3/..."
request = "<METHOD>"
header = "Content-Type: application/json"
header = "Accept: application/json"
data = "@<bodyfile>"                      # present only on writes
```

## Required behavior

| Input | Shim MUST do |
| --- | --- |
| Read config from stdin (`--config -`) | Parse `url`, `request`, and (if present) `data = "@file"`. |
| `--output FILE` | Write the response body to FILE (empty on faults/no-body). |
| `--dump-header FILE` | Write response headers to FILE, including `Retry-After:` on a 429. |
| `--write-out '%{http_code}'` | Print the numeric HTTP status to stdout (what `jira_request` captures). |
| Success (2xx/201) | Serve the matching fixture body; exit 0. |
| 401/403/404/5xx | Empty body, correct status; exit 0 (curl itself succeeded). |
| 429 fault | Status 429 + `Retry-After` header on **every** call (exhausts bounded retry). |
| Network fault | **Exit non-zero** and write no status — reproduces a dropped connection (`curl_rc != 0`). |
| Any request | Append `METHOD target` (path incl. query) to `${MOCK_CALLLOG}`. |

## Routing

Path → fixture, driven by the active `configs/*.json` and the existing
`fixtures/*.json`, reproducing the mock README contract:
`GET project/{key}`, `.../statuses`, `.../issue/createmeta/{key}/issuetypes[/{id}]`,
`.../priority`, `.../field`, `POST /issue`. Style (`company`/`team`) and fault
selection come from the config keyed by the project/issue key in the path.

## Session state (research.md Decision 6)

The shim is **not** a purely static router: 008's `mock_issue_field` reads back
fields of issues created earlier in the same session. The shim therefore keeps an
**issue store**.

| Aspect | Requirement |
| --- | --- |
| Location | A JSON file under the recorded `MOCK_TMPDIR` — never a fixed path, never outside it. |
| Seeding | Populated from the existing `fixtures/*.json` at `mock_start`. |
| Mutation | `POST /rest/api/3/issue` records the created key and its `fields` (including `parent`); `PUT` updates them. |
| Read | `GET /rest/api/3/issue/{key}` serves the stored issue, so `mock_issue_field <key> .fields.parent.key` returns what the preceding POST actually set. |
| Lifecycle | Created by `mock_start`, destroyed with `MOCK_TMPDIR` by `mock_stop`. |
| Isolation | Per-instance by construction; two concurrent tests can never observe each other's issues (Constitution XIII, FR-007/SC-009). |
| Parity | The pwsh mock holds the same state in `$script:Issues`; the conformance diff cross-checks the two on every run. |

## Security (Constitution IV / NFR-3)

- The `Authorization` header MUST be ignored and MUST NEVER be written to the
  call log, the header dump, or any diagnostic.
- The shim adds no credential to any file. The existing
  "token never appears under `set -x`" test must still pass with the shim active.

## Out of scope for the shim

Any `curl` flag `jira_request` does not use. The shim is deliberately minimal
(YAGNI); unrecognized-but-harmless flags may be ignored, unknown *required*
behavior must fail loudly rather than silently mis-serve.
