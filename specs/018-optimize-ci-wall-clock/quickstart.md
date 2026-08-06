# Quickstart — validating 018 (CI wall-clock)

Runnable checks that prove this feature works end to end. Each names the
criterion it discharges. Details live in `contracts/` and `research.md`; this
file is the run guide.

**Prerequisites**: `bats`, `jq`, `curl`, `git`, a Bash ≥ 4 (macOS ships 3.2 —
install one). `pwsh` for the PowerShell legs. `gh` authenticated for the CI
checks. kcov runs on Linux only.

---

## V1 — The corpus is complete on every host (SC-005, FR-001)

```bash
ls tests/conformance/scenarios/*.json | wc -l          # the corpus size
bash tests/conformance/ci-conformance.sh               # exit 0, no divergence lines
```

**Expected**: the runner prints a verdict count equal to the corpus size. A
shortfall is an error, never a silent pass (R5/R6).

**On CI**: read the same count from each of the three `unit` legs. The three
counts and the corpus size are one number.

> Conformance success is silent — there is no pass banner. Exit 0 with zero
> "conformance divergence" lines is the pass.

---

## V2 — Determinism at the new concurrency (SC-007, FR-007)

```bash
bash tests/conformance/ci-conformance.sh   # run 1, captures kept
bash tests/conformance/ci-conformance.sh   # run 2
```

**Expected**: byte-identical captures per scenario and an identical verdict set.
This is the tripwire for the class of defect 009 hit at exactly this point (a
PID-keyed cursor that collided only under higher subprocess churn). A difference
here blocks adoption of the wider concurrency — it is not a flake to re-roll.

Repeat on `windows-latest` through the probe before the wider form gates.

---

## V3 — The blocking inventory is untouched (SC-006, FR-016)

```bash
bats tests/bash/ci/                # includes the inventory guard
```

**Expected**: the nine job definitions and eleven check-run names match
`contracts/blocking-inventory.md` byte for byte, and no workflow outside that
table carries a `push`/`pull_request` trigger.

---

## V4 — No test was removed (SC-008, FR-010)

```bash
ls tests/conformance/scenarios/*.json | wc -l                    # >= 84
grep -rhc '^@test' tests/bash --include='*.bats' | paste -sd+ - | bc   # >= 1427
ls tests/bash/**/*.bats | wc -l                                  # >= 149
```

Pester side: `Invoke-Pester -Path tests/powershell -PassThru` reports **≥ 1128**
tests across **≥ 125** files.

---

## V5 — The Bash suite inside its budget (SC-002, FR-009)

```bash
time tests/run-bash.sh              # full suite
tests/run-bash.sh --since main      # change-scoped inner loop, <= 60s
```

**Local expectation**: green, with every discovered file executed. **The budget
is a CI figure, not a local one** — this project's runners are 6–8× slower than
a developer machine, so never size the budget from the local wall clock. Read
the real number from the `unit` job's step timing.

Measure the machine before trusting a local timing:

```bash
uptime            # a high load average makes every number below meaningless
```

---

## V6 — The coverage gate is green, meaningful, and inside its budget (SC-004)

Linux only:

```bash
./tests/coverage/bash-coverage.sh --mode conformance --threshold 80 \
    --report-dir coverage/bash
```

**Expected**: a published percentage ≥ 80, a per-file table, and a duration
leaving ≥ 20% headroom under the declared budget. Then prove the two failure
modes are distinguishable:

- a run that exceeds the budget **fails** and does not reach the fallback (C5);
- a run that cannot measure (rc=2) **does** reach it (C6).

Shard equivalence (C4): the merged N-shard percentage equals the serial
percentage over the same scenarios.

---

## V7 — Parity detection is unimpaired (SC-010, FR-006)

Inject a one-line divergence into a scratch copy of a port module, run one
scenario against both ports, confirm the diff fails and the report names the
first differing byte in hex with both sizes. Discard the scratch copy.

Then confirm the *pre-existing* red is unchanged: on `windows-latest`,
`us2-field-defaults-option-question` and `us2-field-defaults-question` still
fail, and nothing else does. This feature neither fixes nor hides them.

---

## V8 — The Windows facts came from Windows (FR-018, SC-001)

```bash
git push --force origin HEAD:ci/windows-probe
gh run list --branch ci/windows-probe --limit 2
```

Results arrive as **annotations**, not job logs (a non-admin token reads logs as
403):

```bash
gh api repos/:owner/:repo/actions/runs/<run-id>/jobs --jq '.jobs[].id'
gh api repos/:owner/:repo/check-runs/<job-id>/annotations \
  --jq '.[] | "\(.annotation_level) :: \(.title) :: \(.message)"'
```

**Expected**: the notice carries W1/W2/W3/W4 (`contracts/windows-probe.md`), and W2
reports a **verdict count** alongside its duration. One retry maximum on an
inconclusive run.

---

## V9 — The merge decision inside 20 minutes (SC-003, SC-012)

```bash
gh run list --workflow=ci.yml --limit 5 --json databaseId,createdAt,updatedAt
gh api repos/:owner/:repo/actions/runs/<run-id>/jobs \
  --jq '.jobs[] | "\(.name) [\(.conclusion)] \(.started_at) -> \(.completed_at)"'
```

**Expected**: the last of the eleven check runs concludes ≤ 20 minutes after the
push, no `unit` leg exceeds 18 minutes, and total runner-minutes are below the
baseline run `30947466217`.

Compare against a `main` run before blaming the branch: `windows-latest` has
been red on `main` since 015, so a red Windows leg is the baseline, not
necessarily a regression.

---

## V10 — The coverage-gap evidence still exists, non-blocking (SC-011, FR-012)

Trigger the nightly by hand and confirm it publishes the xtrace-traced
distinct-frame count, and that its workflow carries `schedule` +
`workflow_dispatch` triggers only.
