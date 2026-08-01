# spec-kit-jira — project instructions

Two native ports (Bash for macOS/Linux, PowerShell 7+ for Windows) proven
equivalent by a shared conformance corpus. Architecture and module map:
`docs/README.md`.

## Windows portability — non-negotiable

Read `docs/10-windows-portability.md` before touching either port. The short
version:

- **Never put `$'\r\n'` inside a glob pattern** (`[[ == ]]`, `${x#…}`,
  `${x//…/…}`) — the MSYS bash matcher lets it match a bare LF. Count CRLF
  pairs with a CR-by-CR walk (`_ms_count_crlf`).
- Never call `jq` directly in the bash port — its Windows build emits CRLF on
  multi-line output. Go through `scripts/bash/lib/output.sh`.
- Paths handed to `curl` must be spelled with `cygpath -m`.
- A Windows-only divergence is diagnosed by **measurement on the real runner**
  (push to `ci/windows-probe`, ~11 min, results arrive as annotations — see the
  doc), never by emulation, and a platform fix is unproven without a green run
  there. Failing test first: for Windows-only defects the conformance corpus on
  the probe is that failing test.

## Running the suites

- `bats -r tests/bash` — full bash suite (~15 min; the `-r` is load-bearing,
  without it bats silently runs nothing).
- `bash tests/conformance/ci-conformance.sh` — cross-port byte equivalence.
- `shellcheck` and `actionlint` must stay clean.
