# Phase 0 Research: The Process Budget Outlives the Feature That Measured It

Four questions had to be answered by reading the existing harness rather than assumed. Two of
them changed the design materially; one of them invalidated the obvious approach outright.

---

## R1 — Does the existing counter see Jira requests, and does that break a whole-run assertion?

**Finding: yes to both, and worse than expected.**

`tests/bash/helpers/spawn_count.bash` shims **`jq`, `sed`, `awk` and `curl`**, so every Jira
request already contributes at least one counted process. That alone would make a naive
"double the items, assert the total is unchanged" test fail for a legitimate reason — a creating
run issues one request per story, so requests and items rise together.

The obvious fix — count `jq`+`sed`+`awk` and exclude `curl` — **does not work**, and this is the
finding that changed the design. `tests/conformance/mock-jira/lib.sh:54` copies `curl-shim.sh`
over `${bindir}/curl` and prepends `bindir` to `PATH`; that shim is a Bash script containing
**52 `jq` invocations**. The mock serves each request by running `jq` many times. Those calls are
indistinguishable, to a PATH-interposed counter, from the port's own. A whole-run `jq` count
therefore measures the port *and the test double it is talking to*, and grows with request count
no matter which tools are excluded.

**Decision**: hold the request count constant instead of trying to subtract it. Assert non-growth
on a specification whose stories are **already bound and unchanged**, reconciled with `--force`
so the state short-circuit does not skip the run entirely (`reconcile.sh:594` confirms `--force`
bypasses the unchanged-state read). Prefetch chunks recorded keys at **100 per bulkfetch**
(`prefetch.sh:39,54-55`), so doubling from 10 to 20 stories leaves the request count at exactly
one bulkfetch — and therefore leaves the mock's own internal `jq` usage flat as well. Any growth
that remains is the port's local per-item work, which is what the budget is about.

**The test asserts this invariant rather than trusting it.** It compares the request count of the
two runs and fails if they differ, so a future change that makes requests grow reports itself as
a broken premise instead of silently corrupting the measurement.

**Alternatives rejected**:

- *Exclude `curl` from the count* — defeated by the mock's internal `jq`, as above.
- *Teach the mock to call a non-counted `jq`* — would work, but modifies shared conformance
  infrastructure to serve one test, and any future mock change could silently reintroduce the
  leak. Principle XIV: the constant-request scenario needs no infrastructure change at all.
- *Subtract a measured mock baseline* — a magic number that drifts with every mock change, and
  FR-012 exists specifically to keep magic numbers out of these assertions.

---

## R2 — Can a whole reconcile run be driven from a Bats test at all?

**Finding: yes, and the pattern is already in the tree.**

`tests/bash/commands/test_reconcile_large_spec.bats` sources `reconcile.sh`, starts the mock,
generates a specification of *N* stories programmatically (`_write_large_spec`), and calls
`cmd_reconcile` in-process. That is exactly the shape US2 needs — a whole run, an item count that
is a parameter, and a mock that makes it deterministic.

**Decision**: reuse that structure rather than inventing a driver. The generator is extended to
emit stories that carry the marker comments that make them *already bound*, which is what R1's
constant-request scenario requires.

**Note carried into the plan**: the counter distorts wall clock by ~61% (documented in the helper
itself), so this test asserts counts only and never a duration. That is already what FR-007
requires; the harness independently confirms why.

---

## R3 — How is an oversized argument detected without depending on the host's own limit?

**Finding: the existing E2BIG test cannot detect the defect on the maintainer's own machine.**

`test_reconcile_large_spec.bats` says so in its own header: macOS has no per-argument cap, so the
test "passes on macOS whether or not the defect is present." It detects the *symptom* — `exec`
failing — which only happens on Linux. The maintainer develops on macOS. That is why the defect
was reintroduced three times and each time caught only by CI, late.

**Decision**: detect the **cause**, not the symptom. A shim in front of `jq` measures the byte
length of each element of `$@` and fails when any single element exceeds the Linux per-argument
limit (`MAX_ARG_STRLEN`, 128 KiB). This runs identically on macOS, Linux and Windows, and turns a
platform-specific crash into a portable assertion — which is what FR-013 and US3's third
acceptance scenario ask for.

This reuses the shim mechanism already proven by `spawn_count.bash` (same PATH interposition, same
`exec` pass-through), so it adds a variant rather than a second mechanism.

**Alternatives rejected**:

- *Keep relying on Linux CI* — that is the status quo whose cost this feature exists to remove.
- *Lower the threshold on macOS to force a failure* — would assert a limit the platform does not
  have, and would fire on values that are perfectly safe there.
- *Static analysis for `--argjson` usage* — cannot distinguish a large value from a small one, so
  it would forbid a construct that is correct for bounded inputs.

---

## R4 — Where does the durable rule live, and what is the precedent for making it discoverable?

**Finding: the repository already solved this problem once, for a different rule.**

`AGENTS.md` carries a "Windows portability — non-negotiable" section: a short summary of the
hazards, then a pointer to `docs/10-windows-portability.md` for the full text. `AGENTS.md` is
reached from `CLAUDE.md` via `@AGENTS.md`, so it loads into every session automatically. `docs/`
runs `01-` through `10-`, and is already excluded from what installs into a consuming repository
by `.extensionignore` — the audience is contributors, not operators.

**Decision**: mirror that precedent exactly. `docs/11-process-budget.md` holds the authoritative
rule; `AGENTS.md` gains a short section in the same shape as the Windows one. Feature 024's
`contracts/spawn-budget.md` keeps its measurements and derivation as the historical record, and
gains a header line pointing at the durable document as the current authority (FR-005 — its
record is not rewritten, only its claim to authority moves).

---

## R5 — Does whole-run C1.2 actually hold today, on an already-bound, unchanged, doubled scenario? (added during implementation, T004b)

**Finding: no — on two separate, undocumented axes.**

T004b requires measuring the premise before T011 depends on it. Built the scenario research R1/R2 describe
(already-bound, unchanged, `task_mirror: checklist`, `--force`) at 10×3 and 20×6 stories×tasks, via two
uncounted bootstrap `cmd_reconcile` passes (create + backfill the provenance label, exactly
`test_reconcile_zero_churn.bats`'s own pattern) followed by one counted `--force` pass, against
`repo-with-reconcile-binding`'s resolved config:

| Scenario | Stories | Tasks/story | Spawns | Requests | Writes |
| --- | --- | --- | --- | --- | --- |
| A | 10 | 3 | 2381 | 1 | 0 |
| B | 20 | 6 | 5091 | 1 | 0 |
| A0 | 10 | 0 | 1826 | 1 | 0 |
| B0 | 20 | 0 | 3276 | 1 | 0 |

The premise D2 needs (equal requests, zero writes) holds exactly as designed. **The budget (C1.2) does not.**
Spawn count grows with story count even at zero tasks per story (A0→B0), and grows further with task count
held-story-count-fixed. Two independent, undocumented-by-024 sources, isolated directly (calling each
function alone, matching `test_plan_apply_spawn_budget.bats`'s existing style):

- `plan_writes`' UPDATE-branch per-story payload construction (`plan_apply.sh:397-522`) — already named as
  accepted debt by 024 T030 ("~60-80 `jq` calls per UPDATE-branch story... unchanged"), but never previously
  measured at whole-run scope. This is the function T015 was written to target.
- `tasks_parse_document` (`engine/tasks_parse.sh`) — **not previously known**. Isolated measurement: 10 tasks
  → 64 spawns, 100 tasks → 604 spawns (~6/task, linear). 024's contract and 025's plan both assumed
  parse-side work was fully vectorised; this is a second, independent per-item source neither documented.

**Decision: US2 (Phase 4, T011-T017) is blocked, not built.** A single-function subtraction (isolate and
subtract `plan_writes`' contribution from the whole-run total) was drafted and rejected: `tasks_parse_document`
is a second, independent non-constant source inside the same whole-run measurement, so a one-term subtraction
would silently under-count and the assertion would still be wrong in a way indistinguishable from correct.
A two-(or more-)term subtraction was rejected on Principle XIV (KISS) and on trustworthiness grounds: a
regression-guard test whose own passing logic is this intricate is exactly the shape of assertion nobody
would notice going quietly wrong.

Config-line growth (the third C1.2 axis, FR-016) was checked as a possible substitute growth axis and found
genuinely constant today (1101 spawns at 5 stories regardless of 2 vs 200 extra routing-config lines,
confirming T038's config.sh fix holds) — but SC-002 names stories and tasks explicitly, not configuration
lines, so this does not substitute for the blocked scenario; it is recorded because it is positive evidence
the harness itself is trustworthy for what it does measure.

**What would unblock US2**: a scoped, mechanical fix to `tasks_parse_document` mirroring T038's technique
(the same class of fix, on a much smaller function), and a real (not deferred) fix to `plan_writes`' per-story
payload construction (024 T030 — "a substantially larger, higher-risk rewrite" by its own account). Both are
production changes under `scripts/`, which this feature's own scope forbids (SC-007). Chartering either is a
decision for the maintainer, not something this feature can do inside its own boundary.

---

## Consolidated decisions

| # | Decision | Rationale | Rejected |
| --- | --- | --- | --- |
| D1 | Whole-run assertion uses an already-bound, unchanged, `--force`d specification, doubled 10→20 | Holds requests constant, so neither `curl` nor the mock's internal `jq` pollutes the count | Excluding `curl`; patching the mock; subtracting a baseline |
| D2 | The assertion also asserts that the two runs issued the same number of requests | Makes the premise self-verifying instead of assumed | Trusting the scenario's shape |
| D3 | Reuse `test_reconcile_large_spec.bats`' in-process driver shape | Proven, already in the tree, item count is already a parameter | A new scenario runner |
| D4 | Oversized-argument detection measures argument length in a shim, not `exec` failure | Portable verdict on every host; the maintainer's macOS currently gets no signal at all | Relying on Linux CI; platform-specific thresholds; static analysis |
| D5 | `docs/11-process-budget.md` + an `AGENTS.md` section, mirroring the Windows-portability precedent | The repository's own proven pattern for a non-negotiable rule | A skill (fires only when invoked); leaving it in `specs/` |
| D6 | Counts only, never durations, in every assertion this feature adds | The counter itself distorts wall clock ~61%; and host speed varies 3.4× between the two known machines | A time-based budget |
| D7 | US2 (Phase 4) is blocked, not built: whole-run C1.2 does not hold today, on two independent non-constant sources (`plan_writes`, `tasks_parse_document`) | Measured directly (T004b/R5); fixing either is a production change under `scripts/`, forbidden by this feature's own SC-007 | A single-function subtraction (still wrong, misses the second source); a hardcoded tolerance (forbidden by FR-012); building it anyway and shipping it red |
