# spec-kit-jira — agent instructions

Two native ports (Bash for macOS/Linux, PowerShell 7+ for Windows) proven
equivalent by a shared conformance corpus. Architecture and module map:
`docs/README.md`. Where the project is heading — and which capabilities are
shipped versus merely envisioned — `docs/VISION.md`.

**The vision document authorises nothing.** It is the backlog Principle XV
(YAGNI) refers to. An item listed there is not a licence to build it: it needs
a spec, functional requirements, and a Constitution Check first. Read it to
avoid re-proposing what already ships, never to justify writing code.

## Windows portability — non-negotiable

Read `docs/10-windows-portability.md` before touching either port. The short
version:

- **Never put `$'\r\n'` inside a glob pattern** (`[[ == ]]`, `${x#…}`,
  `${x//…/…}`) — the MSYS bash matcher lets it match a bare LF. Count CRLF
  pairs with a CR-by-CR walk (`_ms_count_crlf`).
- Never call `jq` directly in the bash port — its Windows build emits CRLF on
  multi-line output. Go through `scripts/bash/lib/output.sh`.
- Paths handed to `curl` must be spelled with `cygpath -m`.
- Never spell a path back to the operator through `Split-Path` / `Join-Path` —
  the provider renormalises every separator to the host's own, in both
  directions. A path that reaches a message or a written file is cut out of the
  caller's own bytes.
- A Windows-only divergence is diagnosed by **measurement on the real runner**
  (push to `ci/windows-probe`, ~11 min, results arrive as annotations — see the
  doc), never by emulation, and a platform fix is unproven without a green run
  there. Failing test first: for Windows-only defects the conformance corpus on
  the probe is that failing test.

## Process budget — non-negotiable

Read `docs/11-process-budget.md` before adding a loop to the reconcile path.
The short version — one inseparable rule, not two:

- **No loop on the reconcile path spawns an external process per item.**
  Batch it into a bounded number of calls for the whole set instead.
- **In the same breath**: the batched payload that produces must not travel
  through a single command-line argument that can grow with input — route it
  through a temp file. Linux caps a single argument at 128 KiB
  (`MAX_ARG_STRLEN`), independent of the much larger `ARG_MAX`; macOS has no
  such cap, so the defect is invisible on the maintainer's own machine and
  has been reintroduced twice by applying the first half without the second.

## Running the suites

- `tests/run-bash.sh` — full bash suite (~190s / 3m10s, `bats`+`jq` only, no
  PowerShell or GNU `parallel` required). Use `tests/run-bash.sh --since <ref>`
  for a change-scoped inner loop (≤60s on a single-module diff).
- `bats -r tests/bash` still works directly if you need raw `bats` output —
  the `-r` is load-bearing, without it bats silently runs nothing — but it is
  serial and ~15 min; prefer `tests/run-bash.sh` for everyday use.
- `bash tests/conformance/ci-conformance.sh` — cross-port byte equivalence.
- `shellcheck` and `actionlint` must stay clean.
