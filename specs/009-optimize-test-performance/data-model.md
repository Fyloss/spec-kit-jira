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

### Public driver surface (widened by 008)

`tests/conformance/mock-jira/lib.sh` exposes **six** functions, not the four this
plan was originally written against. Any shim backend must honour all of them:

| Function | Since | Shim impact |
| --- | --- | --- |
| `mock_start` / `mock_stop` / `mock_calls` / `mock_died` | pre-008 | Covered by Decisions 1–2. |
| `mock_write_config <json>` | 008 | Writes an ad hoc config to a temp file and prints the path. **0 call sites in `tests/bash`** (driven from `Mock.psm1`), so no shim work is required today. |
| `mock_issue_field <key> <jq-path>` | 008 | `curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/${key}" \| jq -r`. **9 call sites** in `tests/bash/sink/test_hierarchy.bats` and `tests/bash/commands/test_reconcile_hierarchy.bats`. Reads back a field of an issue created by an earlier POST **in the same session** — see research.md **OQ-1**. |

## Entity: Test-runner invocation (NEW)

`tests/run-bash.sh` — inputs and outputs:

| Aspect | Value |
| --- | --- |
| Input (optional) | A path/glob of test files or dirs (default: `tests/bash`). |
| Input (optional) | `--since <ref>` — change-scoped local mode (FR-017): run only the files affected by the diff. Local only; fail-open to the full suite when the affected set is undeterminable. |
| Concurrency | `xargs -P <cores>` sharding, one `bats` per file; serial fallback if concurrency unavailable. |
| Never | Depends on GNU `parallel`; reports success while executing 0 tests; is invoked with `--since` from any CI workflow. |
| Exit code | 0 iff every shard passed and the executed-file count > 0; non-zero otherwise with a named message. |
| Output | Aggregated pass/fail summary + executed-test count. |

## Entity: CI cache keys (NEW behavior)

| Cache | Key inputs | Fallback on miss |
| --- | --- | --- |
| Pester module | OS + pinned Pester version | `Install-Module` as today. |
| `specify-cli` (uv tool) | OS + pinned spec-kit ref | `uv tool install …` as today. |

**Invariant**: a cache hit can never serve content that changes a gate verdict;
any doubt → fresh install (still correct, slower).

## Entity: Shim issue store (NEW — run-scoped, mutable)

Settled by research.md **Decision 6**. This section previously claimed the shim
was stateless; 008's `mock_issue_field` made that false, because it asserts on a
field of an issue a *previous* POST created in the same session, which no static
fixture holds.

| Aspect | Value |
| --- | --- |
| Location | A JSON file under the recorded `MOCK_TMPDIR` (never a fixed path). |
| Shape | `{ "<ISSUE-KEY>": { "fields": { … , "parent": {"key": "…"} }, "properties": {…} } }` — mirroring the pwsh mock's `$script:Issues`. |
| Seeded | From the existing `fixtures/*.json` at `mock_start`. |
| Mutated | `POST /rest/api/3/issue` inserts the created key + fields; `PUT` updates them. |
| Read | `GET /rest/api/3/issue/{key}` — the path `mock_issue_field` drives. |
| Destroyed | By `mock_stop`, with the rest of `MOCK_TMPDIR`. |

**Isolation**: per-instance by construction, so concurrent tests never share a
store — the identity-by-recorded-value rule (Constitution XIII) and
green-under-parallel (FR-007/SC-009) both hold.

**Parity**: the pwsh mock holds equivalent state; the conformance diff
cross-checks the two backends on every run.

## State transitions

Only the shim issue store above is mutable within a run. Everything else — the
call log and the scratch dir — is append-only or inert, and all three are created
by `mock_start` and destroyed by `mock_stop` within a single lifecycle.
