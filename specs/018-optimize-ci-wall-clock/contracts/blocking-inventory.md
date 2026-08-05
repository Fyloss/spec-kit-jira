# Contract: the blocking inventory

Branch protection's required-check list is configured **outside this
repository** and cannot be read from it. A job this repository adds is therefore
not automatically required, and a job it renames silently stops being required.
That asymmetry is the whole reason 009 deferred in-OS sharding, and it is why
this inventory is a contract rather than a convention.

## The frozen set

Nine job **definitions**, eleven **check runs**. Branch protection matches
check-run names, so both columns are frozen.

| Workflow | Job definition | Check-run name |
| --- | --- | --- |
| ci.yml | `unit` | `Unit suites (ubuntu-latest)` |
| ci.yml | `unit` | `Unit suites (macos-latest)` |
| ci.yml | `unit` | `Unit suites (windows-latest)` |
| ci.yml | `lint` | `Lint (shellcheck, PSScriptAnalyzer)` |
| ci.yml | `static-checks` | `Static checks (manifest, messages, registry writes)` |
| gates.yml | `changes` | `Detect Bash-relevant changes` |
| gates.yml | `coverage-bash` | `Bash coverage >= 80% (kcov primary, traceability fallback)` |
| gates.yml | `coverage-pwsh` | `PowerShell coverage >= 80% (Pester)` |
| gates.yml | `module-parity` | `Twin ports mirror module-for-module` |
| gates.yml | `version-string` | `Version literal single-sourced (SC-006, FR-021/022)` |
| boundary.yml | `engine-sink-boundary` | `engine/ carries zero Jira knowledge` |

## Guarantees

| # | Guarantee | Rationale |
| --- | --- | --- |
| B1 | The set of job definitions and the set of rendered check-run names are byte-identical before and after this feature — including parenthesised suffixes and the `>=` spelling. | FR-016, SC-006 |
| B2 | No job is added to, or removed from, a workflow triggered by `push` or `pull_request`. | FR-002 |
| B3 | No workflow outside this table acquires an **unscoped `pull_request`** trigger or a **`push` on the default branch**. Exactly two exemptions exist, both recorded below and both asserted by name: `live.yml` and `windows-conformance.yml`. The nightly stays non-blocking **by trigger**, not by convention. | FR-012 |
| B4 | Work moved off the blocking gate (the xtrace-traced suite) lands in a workflow whose triggers are `schedule` + `workflow_dispatch` only. | FR-012, SC-011 |
| B5 | A guard test asserts B1–B4 mechanically against the workflow files, so a rename is a red test rather than a silently-optional gate. | SC-006 |

## Why B3 is scoped rather than absolute

Two workflows outside the table carry a trigger the absolute form would forbid,
and both are correct as they stand:

| Workflow | Triggers | Why it is not blocking |
| --- | --- | --- |
| `live.yml` | `push: [main]`, `schedule`, `pull_request: types: [labeled]` | Constitution XII **requires** exactly these three: the live suite runs on the default branch, on a schedule, and on a maintainer-applied label. Its `pull_request` trigger is label-gated, so it never runs unbidden on a pull request, and a fork PR carries none of the secrets it needs. |
| `windows-conformance.yml` | `push: [ci/windows-probe]`, `workflow_dispatch` | A throwaway branch that no pull request targets. The probe is an instrument, not a gate. |

A guard asserting the absolute form would be **red on a tree that is correct**,
which is how a guard gets disabled. B3 therefore forbids the two trigger shapes
that actually create a gate — an unscoped `pull_request`, and a `push` on the
default branch — and names the two exemptions explicitly, so acquiring a third
is a red test rather than a silent addition to the blocking inventory.

## Why the check-run name matters more than the job id

`coverage-bash` is the job id; `Bash coverage >= 80% (kcov primary, traceability
fallback)` is what branch protection matches. Changing the `name:` field while
keeping the id is exactly the mistake this contract exists to catch — the CI
stays green, the workflow file looks unchanged in review, and the gate quietly
stops blocking anything.
