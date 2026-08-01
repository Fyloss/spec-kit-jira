# Contract: Mock driver (`tests/conformance/mock-jira/lib.sh`)

The 29 Bash test files depend ONLY on these public symbols. This contract is
**preserved unchanged**; only the backend behind it changes (real pwsh server →
`curl` shim for the Bash port). Any change that breaks a signature below breaks
tests and is rejected.

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
