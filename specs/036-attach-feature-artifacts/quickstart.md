# Quickstart — validating artifact publication

**Feature**: `036-attach-feature-artifacts`

How to prove this feature works, in the order the proofs get cheaper to
expensive. Every command runs from the repository root.

---

## Prerequisites

- `bash` ≥ 4, `curl`, `jq`, `git` — the port's declared prerequisites.
- `bats` for the Bash suite; PowerShell 7+ for the Pester suite and for the
  mock server (which is pwsh-only and serves both ports).
- For §5 only: credentials for a real Jira Cloud site.

Nothing is built or downloaded.

---

## 1. The inner loop (seconds)

Scope the Bash suite to what the change touches:

```bash
tests/run-bash.sh --since main
```

**Read the `mode:` line before drawing any conclusion.** This runner fails open
to a full run — 16 minutes, not 60 seconds — whenever the affected set is
undeterminable, and a change to `scripts/bash/lib/*` is exactly such a case.
This feature touches `lib/run_state.sh`, so expect the full run and size your
patience accordingly rather than assuming the scoping is broken.

---

## 2. Unit level — the decisions, without a network

```bash
bats -r tests/bash/engine/test_artifact_set.bats
bats -r tests/bash/sink/test_artifact_publication.bats
pwsh -c "Invoke-Pester tests/powershell/Engine/ArtifactSet.Tests.ps1"
```

The `-r` is load-bearing: without it `bats` silently runs nothing and reports
success.

What these must prove, per port:

| Proof | Expectation |
|-------|-------------|
| Enumeration | Nested files found at any depth; an ignored file absent from the set. |
| Sort order | The set is sorted by `path`, byte-wise, identically on both ports. |
| Flattening | `contracts/api.md` → `contracts__api.md`; a top-level file keeps its exact name. |
| Collision | `contracts/api.md` + `checklists/api.md` … both withheld, one warning naming both. |
| Classification | absent → published; hash differs → revised; hash matches → unchanged, **no write**. |
| Withholding order | name-collision before oversized before site-disabled, deterministically. |

---

## 3. Zero-churn — the assertion the feature exists under

```bash
bats -r tests/bash/commands/test_reconcile_artifacts_idempotent.bats
```

Run the mirror twice over an unchanged feature directory against the mock, then
assert on the recorded call log:

```bash
grep -cE 'POST .*/attachments|POST .*/comment|PUT .*/properties/spec-kit-jira-artifacts' "$MOCK_CALLLOG"
# second run must print: 0
```

Assert on the call log, not on the summary text — the summary is what the code
*says* it did; the log is what it did.

The regression this feature is most likely to reintroduce is the short-circuit
one. Its test is explicit and must be written before the schema bump, and
observed to fail against schema 2:

```bash
bats -r tests/bash/lib/test_run_state_artifacts.bats
```

Publish, modify **only** `research.md`, run again, assert the run did **not**
short-circuit and that `research.md` was published.

---

## 4. Cross-port equivalence (minutes)

```bash
bash tests/conformance/ci-conformance.sh
```

**Never run this concurrently with the Bash suite** — they share fixtures, and
the collision invents an `Only in …: state` divergence in an unrelated scenario
that costs an hour to chase.

Success is silent: exit 0 and zero lines containing `conformance divergence`.
There is no pass banner, and the temporary paths it prints are harness noise.

What the new scenarios must assert:

| # | Assertion |
|---|-----------|
| 1 | The ADF comment body is byte-identical between ports, key order included. |
| 2 | The multipart part list — order and part filenames — is identical between ports. |
| 3 | Exactly one attachment POST and one comment POST per publishing run, on both ports. |
| 4 | The run summary's `artifacts[]` array is byte-identical between ports. |
| 5 | A `403` on the upload leaves the run's exit code unchanged, on both ports. |

A reconcile conformance fixture needs `resolved_ids` and **no** `base_url`;
getting either wrong looks exactly like a silent exit-0 no-op.

---

## 5. Against a real site — the only proof that counts here (Principle XII)

The mocks in §2–§4 are ours. They cannot falsify anything in
`research.md` §R15, which is where this feature's real risk lives. Before
release, confirm each on a real Jira Cloud site and record the result:

```bash
# a feature directory with a nested artifact, a binary, and a revision
.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh reconcile --dry-run
.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh reconcile
```

Then, in the browser, on the specification ticket:

1. Every artifact is listed in the attachment panel and downloads intact —
   the binary byte-for-byte identical to the file on disk.
2. Exactly one new comment, listing every published artifact, none withheld.
3. Re-run: no new attachment, no new comment, nothing in the activity stream.
4. Revise `spec.md`, re-run: a second `spec.md` attachment appears, the first is
   still there and still downloads, and the comment says `revised`.
5. With a token lacking "Create attachments": the reconcile still succeeds, its
   exit code is unchanged, and one warning names the missing capability and the
   remedy.

Item 5 is the one worth setting up deliberately. It is the regression that would
hit every existing consumer on upgrade, and no mock will surface it.

---

## 6. Windows (hours, not minutes)

The `form =` directive in a `curl` config on stdin, through MSYS, is a host
quirk — the constitution requires it be measured on a real runner, never
emulated:

```bash
git push origin HEAD:ci/windows-probe
```

Budget **~2 hours**, not the 11 minutes an older note claims. Results come back
as check-run annotations, not job logs. One retry maximum on a flake, then hand
the result back rather than burning another hour.

Freeze the branch while checks run: pushing mid-CI restarts everything, and a
doc-only commit has discarded 22 of 24 checks and an hour of Windows work
before.

---

## 7. Gates before merge

```bash
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
actionlint
```

Both must be clean. `shellcheck` is scoped to `scripts/bash` on purpose — a
whole-tree scan is about 1 900 lines of host-script noise that is not ours.
