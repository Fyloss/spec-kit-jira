# Data Model: Optimize Automated Test Performance

**Feature**: 009-optimize-test-performance | **Date**: 2026-07-31

This is test infrastructure, so the "data model" is the set of schemas and
run-scoped state the new/changed components read and write. All fixture and
config schemas are **existing and unchanged** — the shim reuses them verbatim.

## Entity: Mock config (existing, unchanged)

`tests/conformance/mock-jira/configs/*.json` — selects routing and faults per run.

| Field | Type | Meaning |
| --- | --- | --- |
| `projects` | object `{KEY: "company"\|"team"}` | Project style → which discovery fixture set to serve. Unknown key defaults to `company`. |
| `faults` | object `{KEY: fault}` | Per-project-key fault. |
| `faults.KEY.status` | int (401/403/404/429/…) | HTTP status to return for requests naming that key. |
| `faults.KEY.retryAfter` | int (seconds) | Emitted as `Retry-After` header on a 429. |
| `faults.KEY.network` | bool | When true, simulate a dropped connection (shim exits non-zero; server closes socket). |
| `fault` | object | Global fault when no per-key fault matches. |
| `identity` | object `{ISSUE-KEY: {origin, repo, spec_slug}}` | Adoption/recognition state for mention scenarios. |
| `createmetaFields` | object `{KEY: variant}` | Which createmeta-fields fixture variant to serve. |

**Validation**: both mock backends (pwsh server, Bash shim) MUST interpret this
schema identically; the conformance diff enforces that.

## Entity: HTTP fixture (existing, unchanged)

`tests/conformance/mock-jira/fixtures/*.json` — canned Jira REST v3 response
bodies (project discovery, statuses, createmeta issuetypes/fields, priority,
field, created issue, remote links, siblings). Keyed by path + style per the
mock README contract.

## Entity: Curl-shim request record (NEW — run-scoped output)

The shim appends one line per request to the call log, matching the pwsh mock's
format exactly (so `mock_calls` assertions are backend-agnostic):

```
<METHOD> <target-with-query>
```

- Written LF-terminated to `${MOCK_CALLLOG}` (a path under the shim's per-run
  `mktemp` dir recorded by `mock_start`).
- `target` is the request path including query string, matching what the pwsh
  mock records (NFR-1 byte-identical call sequences).

## Entity: Mock driver run-state (contract preserved)

Set by `mock_start`, consumed by tests and `mock_stop`:

| Variable | Meaning | Backend behavior |
| --- | --- | --- |
| `MOCK_BASE_URL` | Base URL tests prepend to request paths | pwsh: real `http://127.0.0.1:<port>`. shim: a sentinel URL (the shim keys on the path, not the host). |
| `MOCK_CALLLOG` | Path to the call log | Same semantics both backends. |
| `MOCK_PID` (pwsh only) | Recorded server PID | Only meaningful for the real server; the shim has no process. |
| `MOCK_TMPDIR` | Per-run scratch dir (recorded identity) | Both backends; `mock_stop` removes exactly this. |

**Isolation rule (Constitution XIII)**: every path/PID above is recorded by the
instance that created it; nothing is discovered by name pattern or machine-wide
scan.

## Entity: Test-runner invocation (NEW)

`tests/run-bash.sh` — inputs and outputs:

| Aspect | Value |
| --- | --- |
| Input (optional) | A path/glob of test files or dirs (default: `tests/bash`). |
| Concurrency | `xargs -P <cores>` sharding, one `bats` per file; serial fallback if concurrency unavailable. |
| Never | Depends on GNU `parallel`; reports success while executing 0 tests. |
| Exit code | 0 iff every shard passed and the executed-file count > 0; non-zero otherwise with a named message. |
| Output | Aggregated pass/fail summary + executed-test count. |

## Entity: CI cache keys (NEW behavior)

| Cache | Key inputs | Fallback on miss |
| --- | --- | --- |
| Pester module | OS + pinned Pester version | `Install-Module` as today. |
| `specify-cli` (uv tool) | OS + pinned spec-kit ref | `uv tool install …` as today. |

**Invariant**: a cache hit can never serve content that changes a gate verdict;
any doubt → fresh install (still correct, slower).

## State transitions

None. All components are stateless per run except the run-scoped call log and
scratch dir, both created and destroyed within a single `mock_start`/`mock_stop`
lifecycle.
