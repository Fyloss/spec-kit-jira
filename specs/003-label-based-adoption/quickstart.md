# Quickstart: Validating Label-Based Adoption

**Feature**: 003-label-based-adoption | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

This is a **validation guide**, not an implementation guide. It lists the
runnable scenarios that prove the feature works end to end, and what each one
must show. Entities and field rules live in [data-model.md](./data-model.md);
flags, phases, exit codes, and message contents live in
[contracts/adopt-cli-contract.md](./contracts/adopt-cli-contract.md); endpoints
live in [contracts/jira-endpoints-delta.md](./contracts/jira-endpoints-delta.md).

## Prerequisites

| Requirement | Check |
|-------------|-------|
| Bash ≥ 4 (macOS's shipped 3.2 does **not** qualify) | `bash --version` |
| `curl`, `jq`, `git` | `command -v curl jq git` |
| PowerShell 7+ (for the twin port and the mock server) | `pwsh -v` |
| bats-core ≥ 1.13, Pester | `bats --version`, `pwsh -c 'Get-Module -ListAvailable Pester'` |

No credentials are needed for anything below except the final dogfood run — the
mock Jira server serves every automated scenario.

## Setup

```bash
cd /path/to/spec-kit-jira
git checkout 003-label-based-adoption
```

Enable adoption in a scratch fixture's committable config (never in a real repo
while testing):

```yaml
# .specify/jira/config.yml
adoption:
  enabled: true
  label_prefix: "speckit-adopt:"
```

## Scenario 1 — Adopt a labelled hierarchy (US1, P1)

**Setup**: a fixture repo with three spec folders; a mock corpus holding an Epic
and two Stories, each carrying one spec-naming label.

```bash
# Phase 1 only — must print the plan and write nothing
spec-kit-jira adopt --dry-run
# Real run
spec-kit-jira adopt --yes --json
```

**Expected**

- The dry-run prints three bindings with reason `label match` and performs
  **zero** writes.
- The real run's call log contains **exactly three** `PUT
  /rest/api/3/issue/*/properties/spec-kit-jira` calls and **no** `POST /issue`,
  `PUT /issue/{key}`, transition, comment, link, or label call (FR-007, SC-001).
- Each stamp body carries `"origin":"human"`.
- Exit code `0`.

**Also verify**

- Declining the confirmation (no `--yes`, answer `n`) ⇒ zero writes, summary
  says *adoption cancelled*, exit `0` (US1 AS-3).
- `adoption.enabled: false` ⇒ exit `4`, the message names the configuration key,
  and the call log contains **zero** reads against candidate tickets (US1 AS-4,
  SC-009).
- A ticket carrying the bare prefix, or a label naming a folder absent from
  disk, is never adopted and never guessed at (US1 AS-5).

## Scenario 2 — Fail-closed on ambiguity (US2, P1)

**Setup**: one fixture per refusal class plus one valid binding.

```bash
spec-kit-jira adopt --json
```

**Expected** — for each of the eight classes in
[data-model.md §8](./data-model.md#8-refusal-classes):

- The valid binding still applies; each refused binding leaves **zero** writes
  (FR-013).
- Each message names the spec folder, every issue key involved, and a
  copy-pasteable remediation (SC-005).
- `several-candidates` lists **every** candidate, not a truncated pair — run it
  against a multi-page mock result to prove pagination reaches them all (NFR-6).
- Two candidates whose titles closely match the spec's title still refuse: the
  tie is not broken by similarity, order, recency, or issue type (US2 AS-5,
  FR-012).
- Run exits `4`.

**Fault injection** — with a 401, a 404, a network drop, and an exhausted 429
each injected during discovery: the whole run aborts **before any write**, the
call log contains zero `PUT .../properties/...` entries, and the exit code is
`3`, `2`, `2`, `2` respectively (US2 AS-6, FR-008).

## Scenario 3 — Adopt without destroying human content (US3, P1)

**Setup**: an adopted ticket with a hand-written description.

```bash
# capture the description BEFORE
spec-kit-jira adopt --yes
spec-kit-jira reconcile specs/003-*/spec.md      # first reconcile after adoption
spec-kit-jira reconcile specs/003-*/spec.md      # the one immediately after
```

**Expected**

- After the first reconcile, every pre-existing byte of the human description is
  present unchanged **outside** the managed panel, and the panel was **added**
  below it — never a rewrite (SC-002, FR-018).
- The first reconcile performs zero creations, zero deletions, and zero
  transitions on adopted tickets (SC-006).
- The second reconcile performs **zero writes of every kind** (SC-006).
- Re-running `adopt` on the adopted corpus performs zero writes of every kind
  and exits `0` (FR-019, SC-004).

This scenario is the promise that makes adoption acceptable to the Product
Owner. A single modified byte outside the managed panel is a failing test, not a
tolerance.

## Scenario 4 — Explicit binding override (US4, P2)

**Setup**: one spec with two candidates, one spec with none.

```bash
spec-kit-jira adopt \
  --bind 004-ambiguous=PROJ-51 \
  --bind 005-unlabelled=PROJ-77 \
  --yes --json
```

**Expected**

- Both bind; the summary records reason `explicit-binding` for each.
- `005-unlabelled` binds with **no label added** to the ticket (FR-020, Out of
  Scope: the bridge reads labels, it never applies them).
- A pin to a claimed ticket, or to a ticket in a project the spec does not route
  to, is refused with the same message and exit code as the equivalent
  discovered candidate (US4 AS-3).
- A pin naming a folder absent from disk stops the run as a usage error, exit
  `1`, zero writes (FR-021).
- A pin that overrides a discovered candidate shows **both** keys in the plan
  (FR-022).

## Scenario 5 — Dry-run twin and audit trail (US5, P2)

```bash
spec-kit-jira adopt --dry-run --json > dry.json
spec-kit-jira adopt --yes     --json > real.json
```

**Expected**

- The two action sets are identical, and the dry-run's call log holds zero
  writes (SC-003, FR-023).
- Both summaries validate against
  [`run-summary.schema.json`](../001-jira-reconcile-engine/contracts/run-summary.schema.json)
  plus [`adoption-plan.schema.json`](./contracts/adoption-plan.schema.json).
- The default (no `--json`) output is prose (Principle XVI).
- Grep both outputs and the `--verbose` output for the test token and the mock
  host: **no match** at any verbosity (FR-025, NFR-3).

## Scenario 6 — Partial and resumable adoption (US6, P3)

```bash
# scope a two-spec subset of a five-spec repo
spec-kit-jira adopt --spec 003-a --spec 004-b --yes --json
```

**Expected**

- Only the two scoped folders are discovered and bound; the other three are
  reported *out of scope*, and the call log contains **zero** reads or writes
  against their tickets (US6 AS-1).
- Interrupting a run after the first stamp and re-running it: the already-stamped
  ticket is reported `already-adopted` and skipped, the remaining bindings apply,
  and the total is exactly **one** stamp per ticket across both runs (SC-007).
- `--spec` naming a folder absent from disk ⇒ usage error, exit `1`, zero writes
  (US6 AS-3).

## Cross-port parity (NFR-1, SC-008)

Run every scenario above against both ports and diff the captures:

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-adopt-hierarchy.json bash  out/bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-adopt-hierarchy.json powershell out/pwsh
diff -r out/bash out/pwsh
```

**Expected**: byte-identical plans, byte-identical `--json` summaries,
byte-identical call logs, identical exit codes, identical post-run trees. Any
difference is a failing test, not a documented quirk.

## Unit and coverage gates

```bash
bats -r tests/bash                                    # Bash port
pwsh -c 'Invoke-Pester -Path tests/powershell'        # PowerShell port
```

**Expected**: green on macOS, Linux, and Windows; statement coverage at or above
80% (kcov on Linux, Pester CodeCoverage everywhere), with the ambiguity refusal,
zero-write, human-preservation, confirmation-gate, and privacy-guard paths close
to 100% (Principle XIII).

## Boundary gate (Principle VIII)

```bash
grep -rnE '[A-Z]{2,}-[0-9]+|atlas""sian|createmeta|customfield_[0-9]+' scripts/bash/engine scripts/powershell/engine
```

**Expected**: no match. The engine adoption module must carry no issue-key-shaped
literal **even in a comment** — the CI grep scans comments too (research §8).

## Dogfood before release (Principle XII)

Against a real Jira instance with real credentials, on a throwaway project:
label three tickets, run `adopt --dry-run`, confirm the plan, run `adopt --yes`,
then run `reconcile` twice. Record that the hand-written descriptions survived
byte-for-byte and the second reconcile wrote nothing. A release without this
record is invalid.
