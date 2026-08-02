# Quickstart — proving recorded field defaults work

How to validate this feature end to end, in the order the suites should be run during development.
Nothing here is implementation; it is the shortest path from a clean checkout to knowing whether the
feature is real.

## Prerequisites

- Bash ≥ 4 (macOS ships 3.2 — install a qualifying Bash), plus `jq`, `curl`, `git`, `bats`.
- PowerShell 7+ and Pester for the Windows port's suites.
- `shellcheck` and `actionlint` for the lint gate.
- No Jira credentials are needed for anything below; the conformance harness runs against the mock.

## The inner loop, in order

```sh
# 1. The Bash units for the modules being changed — seconds, not minutes.
tests/run-bash.sh --since main

# 2. The full Bash suite once the change settles (~3m10s).
tests/run-bash.sh

# 3. The PowerShell twin.
pwsh -c 'Invoke-Pester tests/powershell -Output Detailed'

# 4. Cross-port byte equivalence — the gate that catches a port drifting.
bash tests/conformance/ci-conformance.sh

# 5. Lint.
shellcheck $(git ls-files '*.sh') && actionlint
```

Windows-only behaviour is never validated on macOS or Linux. If the managed-region write or a message
diverges on Windows, push to `ci/windows-probe` and read the annotations (see
`docs/10-windows-portability.md`); an emulation that passes locally proves nothing.

---

## Scenario 1 — the defect, still failing (write this first)

The existing fixture `tests/conformance/fixtures/repo-with-mandatory-field` describes a project whose
parent type `Deliverable` requires `Business Owner` and `Program Increment`. The existing scenario
`us3-mandatory-field-refusal.json` asserts the refusal.

**Before any implementation**, add its green counterpart and watch it fail: the same fixture with the
two fields recorded in `config.yml`, expecting a completed mirror instead of a refusal. That failing
scenario is the feature's red test, and it is what proves the refusal was the defect rather than the
design.

Expected before implementation: refusal, zero writes, exit non-zero.
Expected after: parent and stories created, both custom fields present in the create payloads, exit 0.

---

## Scenario 2 — recording the answers (User Story 1)

Fixture: `tests/conformance/fixtures/repo-with-field-defaults`, a project with two required custom
fields on the specification type, one of them enumerating allowed values.

```sh
# Non-interactive recording — the scripted path FR-006 requires.
… config CONSUMER \
    --field-default 'CONSUMER=Epic=Business Owner=Platform Team' \
    --field-default 'CONSUMER=Epic=Program Increment=PI-2026-Q3' \
    --json
```

Verify:

- `config.yml` now carries the managed region, and **every comment outside it is untouched** — diff the
  file, not just the region.
- Re-running the identical command leaves `config.yml` byte-for-byte unchanged (FR-007).
- `config.local.yml` carries `defaultable_fields` with `allowed_values` for the enumerated field.
- A value outside the allowed list is refused, listing the accepted values, with zero file writes.
- An empty value is refused (FR-008).
- Naming an issue type the project does not offer is refused, listing the types it does (FR-026).
- Recording for a discovered type the bridge does not write succeeds and is reported as not yet
  consumed (FR-027).
- In degraded mode (unset the base URL) nothing is asked and nothing is written (FR-009).

---

## Scenario 3 — the consolidated question (User Story 2)

With Scenario 2's defaults recorded, run a reconcile that has creations pending.

Verify:

- One `confirmation-pending` object, listing each field once with its recorded value, and **zero Jira
  writes** on that pass.
- Re-invoking with `--accept-defaults` creates the tickets carrying the recorded values.
- Re-invoking with `--field-value 'CONSUMER=Epic=Program Increment=PI-2026-Q2'` creates them carrying
  the overridden value, and `config.yml` is **not modified** (FR-021) — assert on the file's bytes.
- A run where everything is already mirrored asks nothing (FR-013).
- With `ask: false` in the config, the first pass writes directly and the summary still attributes each
  value to its source (FR-014, FR-022).
- The summary names the overridden field and prints the `config --field-default …` line that would make
  it permanent.

---

## Scenario 4 — the surviving refusal (User Story 3)

With no defaults recorded and `--accept-defaults` given (the non-interactive case), run the reconcile
against the mandatory-field fixture.

Verify:

- Zero writes, the pre-existing exit code, and a message naming both fields by their Jira labels.
- The message carries a copy-pasteable `config --field-default …` line that, when run, makes Scenario 1
  pass.
- A field marked non-defaultable is reported with its reason and the refusal path is unchanged (FR-010).

---

## Scenario 5 — invisibility (FR-028, SC-010)

Model this on the existing `sc009-core-untouched.json`.

Run the whole corpus against fixtures that record **no** default and assert every byte of every output
matches the pre-feature release. This is the scenario that proves a solo developer on a three-type
project is unaffected, and it is the one most worth running on all three operating systems.

---

## Scenario 6 — dry run agreement (FR-023)

For each of Scenarios 1, 3, and 4, run `--dry-run` then the real run against the same state and assert
the predicted field values and the sent field values are identical, including their attributed sources.

---

## Definition of done for this feature

- [ ] Scenario 1's counterpart went red before any implementation and is green after.
- [ ] All six scenarios pass on macOS, Linux, and Windows.
- [ ] `config.yml` comments survive a ceremony run; a second run changes no byte.
- [ ] No default reaches an update payload — asserted, not assumed.
- [ ] A defaulted value is inside the body the privacy guard scans — asserted, not assumed — and a
      value the guard blocks produces zero Jira writes (FR-024).
- [ ] `--accept-defaults` on a *first* invocation, with no preceding planning pass, writes directly:
      the continuous-integration shape works without an agent (FR-015, contract §3.10).
- [ ] Coverage ≥ 80% statements on both ports; the critical paths (satisfiability, resolution
      precedence, the refusal) near 100%.
- [ ] `shellcheck` and `actionlint` clean; the engine/sink boundary greps green.
- [ ] Dogfooded against a real Jira project whose written types carry mandatory custom fields.
