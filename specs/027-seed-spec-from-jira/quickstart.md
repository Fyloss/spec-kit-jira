# Quickstart — Validating 027 end to end

**Feature**: 027 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Runnable scenarios that prove the feature works. Contract details are referenced,
not repeated — see [`contracts/`](./contracts/).

---

## Prerequisites

```sh
bash --version          # ≥ 4.0; macOS ships 3.2, which does not qualify
pwsh --version          # ≥ 7.0
jq --version
bats --version
```

No new dependency is introduced by this feature.

---

## Inner loop (change-scoped, ≤ 60 s)

```sh
tests/run-bash.sh --since HEAD~1
```

Full bash suite (~190 s / 3 m 10 s):

```sh
tests/run-bash.sh
```

> `bats -r tests/bash` works but is serial and ~15 minutes. The `-r` is
> load-bearing — without it bats silently runs nothing.

Cross-port byte equivalence:

```sh
bash tests/conformance/ci-conformance.sh
```

> Conformance success is **silent**: no pass banner. Look for exit 0 and zero
> `conformance divergence` lines. Temp paths in the output are harness noise.

Linters, both blocking:

```sh
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
actionlint
```

---

## Scenario 1 — Adoption under an existing parent (P1 slice, US1 + US3)

The shippable slice: no irreversible write anywhere in it.

```sh
# Mock double: PROJ-1 (specification role), PROJ-11/12/13 (story role)
export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:$MOCK_PORT"

scripts/bash/spec-kit-jira.sh feature \
  --parent PROJ-1 \
  --story PROJ-11 \
  --story "http://127.0.0.1:$MOCK_PORT/browse/PROJ-12" \
  --story "http://127.0.0.1:$MOCK_PORT/jira/software/projects/PROJ/boards/7?selectedIssue=PROJ-13" \
  "add payment webhooks"
```

**Expect** — exactly one `POST /rest/api/3/issue/bulkfetch`, zero mutations, a
seed record at `.specify/jira/state/<dir>.seed.json` with three ordered story
designators, and seed material naming all four issues.

The three URL forms in one invocation are deliberate: they are the three shapes
[`designator-grammar.md` §3](./contracts/designator-grammar.md) requires a
conformance scenario for.

Then, after the agent drafts `spec.md` with pinning markers:

```sh
scripts/bash/spec-kit-jira.sh seed          # renders plan, exits 0, mutates nothing
scripts/bash/spec-kit-jira.sh seed --confirm
```

**Expect** — three adoptions with `origin: human`, N−3 story creates under
`PROJ-1`, zero parent creates, seed record deleted, pinning markers replaced by
`story=<id> ticket=KEY`.

**Then prove the promise:**

```sh
scripts/bash/spec-kit-jira.sh reconcile --json | jq '.counts'
```

Run it twice. The second must be `created: 0, updated: 0, skipped: N` — FR-040.

---

## Scenario 2 — The one-way read (FR-009, FR-010, SC-009)

The load-bearing guarantee, and the easiest to regress.

1. Seed and bind as in Scenario 1.
2. `git hash-object spec.md` → record it.
3. In the mock, **edit every named issue's description and summary**.
4. Run `plan`, `tasks`, and a full `reconcile`.
5. `git hash-object spec.md` → **must be identical**.

A single changed byte fails FR-010. This is the regression test that gets written
first.

---

## Scenario 3 — Decline, edit, resume (FR-049, FR-050, FR-062, FR-064)

```sh
scripts/bash/spec-kit-jira.sh seed          # decline: do not pass --confirm
```

**Expect** — seed record present with `bindings: []`, pinning markers present,
**zero** identity markers on either side.

Now edit `spec.md` by hand: rewrite a narrative, add a scenario, and add a whole
new unpinned user story. Then:

```sh
scripts/bash/spec-kit-jira.sh seed
```

**Expect** — resumes at the gate; `spec.md` untouched; the plan shows **one more
create** than before, plus a delta line naming it; `REF-EXISTS` does not fire.

Now break the pinning — delete a pinned user story — and resume again.

**Expect** — `REF-DRAFT-EDIT`, naming the vanished marker and its line, exit 4,
and the seed record **unchanged** so the operator can restore and retry.

---

## Scenario 4 — The re-parenting disclosure (FR-051, US7 AC6)

Give the mock two story-role issues already parented under `PROJ-99`, then seed
them under a different designated parent.

**Expect**, in the rendered plan:

- A re-parenting line **visually distinct** from every adopt and create line.
- `PROJ-99` named by **key, summary, and status**.
- "loses 2 children" — the count stated even when it is one.
- Zero mutations until `--confirm`.

Declining here is the case C4 exists for: the remediation line must tell the
operator to detach in Jira and re-invoke, and the resume must recompute the plan
without that line.

---

## Scenario 5 — The ordinary run is untouched (FR-048, US5, SC-004)

```sh
bash tests/conformance/ci-conformance.sh
```

The **existing** feature-naming scenarios run unmodified. Byte-identical stdout,
identical exit codes, identical recorded request sequence. This is the scenario
that protects every current consumer, and it must be green before any other work
is called done.

Also assert the negative path directly: with the mock unreachable and **no**
designators, the run still emits `{active:false}` plus one warning and exits 0.
With designators, the same unreachable mock must exit 2 — see
[`seed-cli-contract.md` §3](./contracts/seed-cli-contract.md).

---

## Scenario 6 — Budgets (FR-043, FR-044, FR-045)

Use the 024 counting stand-ins (`PATH`-interposed shims), in runs **separate**
from any timing run.

| Assertion | Expected |
| --- | --- |
| 100 designators | 1 `bulkfetch` |
| 101 designators | 2 `bulkfetch` |
| Spawn count at 10 vs 100 designators | does not grow per issue |
| Request body | reaches `jira_request` via a temp file, never argv |
| Run naming nothing | 0 additional requests |
| **Resume** of a declined run, 100 designators | 1 `bulkfetch` — the same as the first run |
| Any read on the resume path | no `comment` field in the field union |

The argv assertion matters most on Linux: a single argument is capped at 128 KiB
(`MAX_ARG_STRLEN`) independently of `ARG_MAX`, and macOS has no such cap — so
this defect is invisible on a maintainer's own machine and has been reintroduced
twice.

---

## Scenario 7 — Windows

```sh
git push origin HEAD:ci/windows-probe     # ~11 min; results arrive as annotations
```

Constitution VI: a Windows-only divergence is diagnosed by measurement on the
real runner, never by emulating MSYS locally, and a platform fix is unproven
without a green run there.

**Triage first.** The probe baseline on `main` has been red independently of any
feature. Compare against the baseline before attributing a red run to this work,
and stop after one retry — a flake costs about an hour and proves nothing.

Highest-risk surfaces here: URL reduction (glob patterns — no `$'\r\n'` may
appear in one), the rendered plan and provenance report (multi-line output must
go through `lib/output.sh`, never a bare `jq`), and the temp file handed to
`curl` (spelled with `cygpath -m`).

---

## Before calling it done

- [ ] `tests/run-bash.sh` green
- [ ] Pester suite green
- [ ] `ci-conformance.sh` exit 0, zero divergence lines
- [ ] `shellcheck` and `actionlint` clean
- [ ] Three-OS matrix green
- [ ] `speckit.jira.seed` **declared in `extension.yml`** and reachable from an agent — the `mention` lesson
- [ ] Scenario 2 passes: no byte of `spec.md` moves after a Jira-side edit
- [ ] Dogfooded against a real instance, on a company-managed **and** a team-managed project
- [ ] CHANGELOG entry; version bumped in `extension.yml` only
