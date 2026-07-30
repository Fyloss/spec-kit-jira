# Quickstart: Validating Idempotent Reconcile

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md)
**Contracts**: [story marker](./contracts/story-marker.md), [recognition](./contracts/recognition-contract.md)

This guide proves the feature end to end. Unlike 004, `--dry-run` alone is not enough
here: recognition is defined by what a **second** run does after a first one wrote to
Jira, so the acceptance checks run against the mocked Jira double. Only Step 10 needs a
real instance — and Constitution II requires it.

---

## Prerequisites

| Requirement | Check |
| --- | --- |
| Bash >= 4 (macOS ships 3.2 — install a newer one) | `bash --version` |
| `jq` | `jq --version` |
| `bats` | `bats --version` |
| PowerShell 7+ (also runs the mock) and Pester | `pwsh --version` |
| `kcov` (coverage gate only) | `kcov --version` |

The mock double must first gain the capabilities recognition needs — it is currently
write-only. See "Mock capabilities" at the end; the conformance steps below fail without
them, and that work is part of this feature.

```sh
cd /Users/sebastienthibaud/DevTemp/spec-kit-jira
source tests/conformance/mock-jira/lib.sh
```

---

## Step 1 — Reproduce the defect (before any fix)

Constitution XIII and the repository's bug-fix policy require the failing test first.

```sh
mock_start tests/conformance/mock-jira/configs/<recognition-config>.json
export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
export JIRA_CONFIG_DIR="tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
SPEC="tests/conformance/fixtures/repo-with-reconcile-binding/specs/billing-001-invoices/spec.md"

./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --json > /dev/null
./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --json | jq '.counts'
grep -c 'POST /rest/api/3/issue$' "${MOCK_CALLLOG}"
mock_stop
```

**Expected before the fix** — the reported defect:

```json
{ "created": 1, "updated": 0, "skipped": 0, "warnings": 0, "errors": 0 }
```

with the call log showing **2** creation POSTs for one user story. The second run
mirrored the specification as if Jira were empty.

**Expected after the fix**: the second run reports `created: 0, updated: 0`, and the call
log shows **1** creation POST in total.

---

## Step 2 — The marker is written, and it is what binds (US1.4, FR-003, FR-008)

After a first run, the specification carries one marker per story and the ticket carries
the matching identity property.

```sh
grep -n 'speckit-jira' "${SPEC}"
jq -r '.value' <<< "$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/PROJ-1/properties/spec-kit-jira")"
```

**Expected**: a line matching `<!-- speckit-jira story=[0-9a-f]{16} ticket=[A-Z][A-Z0-9_]+-[1-9][0-9]* -->`
immediately after the story heading, and a property whose `story` equals that identifier
and whose `repo` / `spec_slug` name this repository and specification.

---

## Step 3 — An unchanged re-run writes nothing at all (US2, FR-013, SC-001)

```sh
cp "${SPEC}" /tmp/spec-before.md
: > "${MOCK_CALLLOG}"
./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --json | jq '.counts'
grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}"
cmp "${SPEC}" /tmp/spec-before.md && echo "spec.md byte-identical"
```

**Expected**: `created: 0, updated: 0, recognised: 1, skipped: 1`; **zero** POST or PUT
lines in the call log — only the recognition GET; and `spec.md` byte-identical (FR-009,
SC-006). Repeat the run ten times for SC-002; the counts and the file never move.

---

## Step 4 — A partial change writes exactly one ticket (US2, FR-015, SC-004)

Edit one story's prose in a multi-story fixture, then:

```sh
: > "${MOCK_CALLLOG}"
./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --json | jq '.counts'
grep -E '^PUT /rest/api/3/issue/' "${MOCK_CALLLOG}"
```

**Expected**: `updated: 1`, `skipped: N-1`, and exactly one PUT, naming the changed
story's ticket.

---

## Step 5 — Reordering and retitling never swap tickets (US1.5, FR-006, SC-005)

Move the last user story above the first, and retitle another, keeping their marker lines
with them. Then re-run.

**Expected**: `created: 0`; each ticket still holds the content of the story whose marker
names it. This is the check that positional identity would fail — assert the ticket→title
pairing, not just the count.

---

## Step 6 — Rename and fresh clone (US3, FR-017, FR-018, SC-003, SC-008)

```sh
git -C "$(mktemp -d)" clone --quiet . fresh && cd fresh   # a clone that never ran the bridge
mv specs/<feature> specs/<feature>-renamed                 # or rename in place
./scripts/bash/spec-kit-jira.sh reconcile specs/<feature>-renamed/spec.md --json | jq '.counts'
```

**Expected**: `created: 0` in both cases. Recognition read the committed markers; nothing
machine-local was involved.

---

## Step 7 — Every failure fails closed, never duplicates (FR-004, FR-012, SC-007)

Drive each case through the mock's fault map (`{"status": 401}`, `{"status": 404}`,
`{"status": 429, "retryAfter": 1}`, `{"network": true}`) and the filesystem.

| Injected fault | Expected exit | Expected creations |
| --- | --- | --- |
| `401` on the recognition GET | `3` | 0 |
| `429` exhausted on the recognition GET | `2` | 0 |
| network drop on the recognition GET | `2` | 0 |
| `404` on the recognition GET | `0` | 1 — the ticket is gone, re-mirrored, and the summary says so |
| `spec.md` read-only (`chmod a-w`) | `4` | 0 — no ticket may be created before its identifier is recorded |
| marker with `story=` but no `ticket=` | `0` | 1 — never attempted, so the story is created normally |
| marker with `story=` and `creating` | `0` | 0 for that story, one `key-unrecorded` warning |
| privacy guard BLOCK after identifiers were assigned | `9` | 0 — and the next run creates every story, none left `creating` |
| marker naming a ticket whose property names another spec | `0` | 0 for that story, one `claimed-by-other` warning |
| marker naming a ticket in a project the spec no longer routes to | `0` | 1 in the routed project, one `re-routed` notice, former ticket untouched |

The exact wording of each warning is fixed in the
[diagnostics catalogue](./contracts/recognition-contract.md#diagnostics-catalogue);
assert on it, and assert that no message contains the mock's host or any credential.

---

## Step 8 — The host command never fails (FR-022, SC-010)

```sh
SPEC_KIT_JIRA_HOOK_CONTEXT=after_plan \
  ./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --json; echo "exit=$?"
```

**Expected**: `exit=0` under every fault of Step 7, with one WARNING line on stderr.

---

## Step 9 — Drift and Flagged engage; nothing transitions (US4, FR-020, R9)

Set the mock's issue to a status beyond the phase the lifecycle event implies, and to
flagged, then run with `SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify`.

**Expected**: a named drift warning identifying the ticket; the content write suppressed
where the drift rule says so; the Flagged marker surfaced and never written; and **zero**
`POST /rest/api/3/issue/{key}/transitions` lines in the call log — this release evaluates
the rules but never moves a ticket's status.

---

## Step 10 — Dry-run equality and port parity (FR-016, SC-009; Constitution VI, XI)

```sh
./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --dry-run --json | jq -S '.actions' > /tmp/pred.json
cp "${SPEC}" /tmp/spec-dry.md
./scripts/bash/spec-kit-jira.sh reconcile "${SPEC}" --json      | jq -S '.actions' > /tmp/real.json
diff /tmp/pred.json /tmp/real.json && echo "dry-run == real"
cmp "${SPEC}" /tmp/spec-dry.md && echo "dry run left spec.md untouched"

tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-recognition-second-run.json
```

The conformance runner executes each scenario against both ports and compares stdout,
exit codes, the Jira call sequence, and the resulting `spec.md` bytes. With
`SPEC_KIT_JIRA_ID_SOURCE` pinned to the scenario's fixed sequence (research R4), the
identifiers are deterministic and the comparison is exact.

Coverage gate:

```sh
tests/coverage/run.sh   # kcov, Bash; >= 80% statement, near-100% on recognition
pwsh -c "Invoke-Pester -CI"
```

---

## Step 11 — Live verification (Constitution II and XII — not optional)

Two things can only be proven against a real Jira Cloud instance:

1. **The double-run assertion.** Reconcile a real specification twice; the second run
   must issue zero writes of every kind. Constitution II is explicit that mocks are not
   sufficient here — three live-only bugs in the original extension are the reason.
2. **The R2 assumption.** Confirm that a `spec-kit-jira` entity property set through the
   REST API is *not* JQL-searchable without an app descriptor:

   ```sh
   curl -s -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
     --get "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/search/jql" \
     --data-urlencode 'jql=issue.property[spec-kit-jira].story = "<identifier>"' | jq '.errorMessages // (.issues|length)'
   ```

   An error, or zero issues for a ticket known to carry the property, confirms the
   research decision. If it unexpectedly *works*, the design still stands — the recorded
   key is chosen for immediate consistency, not only for searchability (research R2) —
   but record the finding in `research.md`.

Then dogfood: run the extension against this repository's own specifications on a real
project, twice, and confirm the backlog does not grow.

---

## Mock capabilities this feature must add

The double is currently write-only and stateless, so it cannot express "the ticket exists
now". Recognition needs it to become minimally stateful:

| Capability | Why |
| --- | --- |
| `POST /rest/api/3/issue` returns a **distinct, sequential** key per call | A fixed key makes duplicate creation invisible — the defect could not be asserted |
| `GET /rest/api/3/issue/{key}` returns the created fields | Steps 3, 4, 9 |
| `?properties=spec-kit-jira` returned with the issue | The marker verification decision table |
| `PUT /rest/api/3/issue/{key}/properties/{key}` stores the marker | Step 2 |
| `PUT /rest/api/3/issue/{key}` updates stored fields | Step 4's churn comparison across runs |
| Per-issue seeded status, `statusCategory`, Flagged, and issue links | Step 9 |

State lives for the lifetime of one mock process, so a scenario's two runs share it and a
new scenario starts clean.
