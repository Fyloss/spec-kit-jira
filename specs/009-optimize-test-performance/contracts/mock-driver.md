# Contract: Mock driver (`tests/conformance/mock-jira/lib.sh`)

The **35** Bash test files depend ONLY on these public symbols. This contract is
**preserved unchanged**; only the backend behind it changes (real pwsh server →
`curl` shim for the Bash port). Any change that breaks a signature below breaks
tests and is rejected.

> **Widened by the 008 merge.** `lib.sh` exposes six public functions: the three
> specified below plus `mock_died`, `mock_write_config`, and `mock_issue_field`.
> All six are now specified (research.md **OQ-1** is resolved by Decision 6) —
> see "Surface added by 008" at the end of this file.

## Public functions

### `mock_start [config.json]`
- **Starts** a mock backend for the current run.
- **Sets** (exported): `MOCK_BASE_URL`, `MOCK_CALLLOG`, `MOCK_TMPDIR`.
- **Backend selection**: Bash port → install the `curl` shim (no process, no
  port). PowerShell port → spawn `mock-server.ps1` (unchanged).
- **Config**: same `configs/*.json` schema for both backends (see data-model.md).
- **Isolation**: all state lives under a fresh `MOCK_TMPDIR` recorded here.
- **Failure**: returns non-zero with a named diagnostic if the backend cannot
  start; never leaves a half-started state.

### `mock_stop`
- **Tears down** exactly what `mock_start` created (the recorded `MOCK_TMPDIR`,
  and the recorded `MOCK_PID` for the pwsh backend). Idempotent.

### `mock_calls`
- **Prints** the LF-separated `METHOD target` log of every request received,
  **byte-identical** in format across both backends (NFR-1).

## Invariants (verified by `tests/bash/ci/test_mock_shim_contract.bats`)

1. `GET /rest/api/3/project/COMP` under `default.json` → 200, body `.style == "company"`-consistent fixture; `TEAM` → team fixture.
2. Faults from `faults.json`: `AUTH` → 401, `MISSING` → 404, `RATE` → 429 with
   `Retry-After`, `NET` → network failure (transport sees a dropped connection).
3. `POST /rest/api/3/issue` → 201 with the created-issue fixture.
4. Every request appears once, in order, in `mock_calls` output.
5. The shim and the pwsh server produce the same response for the same
   (config, request) pair — enforced continuously by the conformance diff.

## Surface added by 008

| Function | Bash call sites | Required shim behaviour |
| --- | --- | --- |
| `mock_died` | internal readiness helper | Always reports "alive" for the shim backend: there is no process to die. Must not be made to scan for one. |
| `mock_write_config <json>` | **0** in `tests/bash` | Backend-agnostic as written (writes a temp file, prints the path). No shim work required; confirm at T005 rather than assume. |
| `mock_issue_field <key> <jq-path>` | **9** (`tests/bash/sink/test_hierarchy.bats`, `tests/bash/commands/test_reconcile_hierarchy.bats`) | Served from the shim's **issue store** (research.md Decision 6, `contracts/curl-shim.md` § Session state): `GET /rest/api/3/issue/{key}` returns the issue as the preceding POST left it, so `.fields.parent.key` resolves to the parent actually linked. |

## Invariants added for the 008 surface

6. After `POST /rest/api/3/issue` with a `parent`, `mock_issue_field <key> .fields.parent.key` returns that parent's key — on **both** backends.
7. Two `mock_start` instances running concurrently never observe each other's issues (per-instance store under the recorded `MOCK_TMPDIR`).
