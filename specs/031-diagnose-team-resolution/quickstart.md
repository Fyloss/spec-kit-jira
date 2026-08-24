# Quickstart — validating the pass-through diagnosis

Every scenario below is runnable against a scratch repository and needs no Jira
credentials: the whole feature is on the path that makes zero Jira requests.

## Prerequisites

- `bats` and `jq` (macOS/Linux), PowerShell 7+ for the second port
- A scratch directory outside this repository

## Setup — a project the way a consumer has one

```bash
ROOT="$(mktemp -d)/workspace"
mkdir -p "${ROOT}/.specify/jira" "${ROOT}/sub/module"
cd "${ROOT}"
```

`.specify/` at `${ROOT}` is the marker the resolution walks up to find
(contract §1). `sub/module` stands in for a nested checkout — the shape that
produced the original report.

## Scenario 1 — the defect, before and after (FR-007, C1.1)

Write a valid catalogue and a selection, then run from the nested directory:

```bash
# .specify/jira/config.yml — one team, id ijt, folder_prefix "ijt-"
# .specify/jira/personal.yml — team: ijt
cd "${ROOT}/sub/module"
<entry-point> feature --json "invoice export"
```

**Before**: `{"active":false}` — the relative path found nothing.
**After**: named by the `ijt` convention, identical to the same command run
from `${ROOT}`. Run it from both and diff the two outputs; they must match.

## Scenario 2 — a broken catalogue speaks (FR-001, FR-002, C2.1)

Introduce a syntax error into `config.yml`, then:

```bash
<entry-point> feature --json "invoice export"
```

**Expect**: a report naming the absolute path and the loader's located reason,
the host's default naming as the fallback, exit 0, and an empty mock call log.
**Expect not**: the word "invalid" alone, and no line quoting a value.

## Scenario 3 — silence is preserved (FR-004, FR-005, C2.2, C2.4)

Remove `config.yml` entirely, then remove `personal.yml`, running the command
after each:

```bash
<entry-point> feature --json "invoice export"
```

**Expect**: `{"active":false}` and nothing else, in both cases. This is the
regression that matters most — it is what two shipped conformance scenarios
already assert, and this feature is wrong if either moves.

## Scenario 4 — no project at all (FR-008, C1.4)

```bash
cd "$(mktemp -d)"   # no .specify/ anywhere above
<entry-point> feature --json "invoice export"
```

**Expect**: a report that no project was located, naming the directory walked
from; exit 0; no fallback to a relative path.

## Scenario 5 — asking why (FR-010, C4.1, C4.2)

Re-run any silent scenario above with `--verbose`.

**Expect**: the resolution state named explicitly, plus the absolute path
consulted. Then re-run without it and confirm the output is byte-identical to
scenario 3 — the diagnosis must be reachable without being unavoidable.

## The suites

```bash
tests/run-bash.sh --since main          # change-scoped, the inner loop
bash tests/conformance/ci-conformance.sh # cross-port byte equivalence
```

Conformance is where scenarios 1, 3 and 4 belong (contract §5.2): path
resolution and absolute-path spelling are the two hosts' divergence surface, and
a per-port unit test cannot see a divergence between ports.

Success is silent — exit 0 and no "conformance divergence" line. There is no
pass banner.

## What this feature never needs to validate

No Jira instance, no credentials, no network. If a scenario here appears to
require any of them, it has drifted out of scope: the feature's defining
property is that every path it touches makes zero requests (contract §3.2).
