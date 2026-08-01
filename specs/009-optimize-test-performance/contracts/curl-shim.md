# Contract: `curl` shim (`tests/conformance/mock-jira/curl-shim.sh`)

A scripted replacement for the `curl` binary, placed first on `PATH` by
`mock_start` for the Bash port. It must satisfy exactly the subset of `curl`'s
CLI that `jira_request()` (`scripts/bash/sink/jira/client.sh`) uses — no more.
`jira_request()` is NOT modified; it must not be able to tell the shim from real
`curl` except that responses come from fixtures.

## Invocation shape it must accept

`jira_request` calls (line 96 of client.sh):

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

## Security (Constitution IV / NFR-3)

- The `Authorization` header MUST be ignored and MUST NEVER be written to the
  call log, the header dump, or any diagnostic.
- The shim adds no credential to any file. The existing
  "token never appears under `set -x`" test must still pass with the shim active.

## Out of scope for the shim

Any `curl` flag `jira_request` does not use. The shim is deliberately minimal
(YAGNI); unrecognized-but-harmless flags may be ignored, unknown *required*
behavior must fail loudly rather than silently mis-serve.
