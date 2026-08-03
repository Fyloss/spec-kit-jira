# Quickstart — validating feature 014

**Feature**: `specs/014-fix-install-exec-bit` | **Date**: 2026-08-03

How to prove the feature works, end to end, in the order that fails fastest. Contract references:
[`contracts/bridge-invocation.md`](./contracts/bridge-invocation.md).

## Prerequisites

- `bash` ≥ 4 on `PATH`, plus `curl`, `jq`, `git` — the bridge's own runtime gate.
- `bats` and `shellcheck` for the Bash suite.
- PowerShell 7+ with Pester for the twin, and `actionlint` for the workflows.
- The `specify` CLI for the install-harness tests. Without it those tests **skip** rather than fail;
  a green run that skipped them has not validated User Story 1.

## Step 0 — Reproduce the defect before fixing anything

This is the gate. If it passes on `main`, the reproduction is wrong.

```sh
cd "$(mktemp -d)" && git init -q .
specify init --here --integration claude --force --ignore-agent-tools
specify extension add --dev <path-to-spec-kit-jira>
chmod a-x .specify/extensions/jira/scripts/bash/spec-kit-jira.sh   # what the archive route does
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help
```

**Expected on `main`**: the run is refused with *"the bridge entry point … was not found or is not
executable — the extension install is incomplete"*, exit code 5. That is defect (2) from research
R1 — our own gate closing the only workaround.

**Expected after the fix**: `usage: spec-kit-jira …`, exit code 0.

## Step 1 — The automated reproduction

```sh
tests/run-bash.sh --since main          # change-scoped, ≤60s on this diff
bats -r tests/bash/conformance/test_us4_bridge_runnable.bats   # the reproduction itself
```

The new conformance case installs through the harness, clears the mode, and requires success —
research R7 explains why it strips the mode rather than driving a real archive install.

## Step 2 — Equivalence between the two modes (FR-009, C7)

The point of the feature is that the mode stops meaning anything. Prove it by comparison, not by
inspection:

```sh
# same repository, same command, two modes — the two captures must be identical
chmod 755 .specify/extensions/jira/scripts/bash/spec-kit-jira.sh
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help > /tmp/exec.out 2>&1; echo "$?" >> /tmp/exec.out
chmod 644 .specify/extensions/jira/scripts/bash/spec-kit-jira.sh
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help > /tmp/noexec.out 2>&1; echo "$?" >> /tmp/noexec.out
diff /tmp/exec.out /tmp/noexec.out && echo "identical"
```

## Step 3 — Diagnostics stay honest (FR-004, C4, C5)

```sh
mv .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1{,.bak}
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help
```

**Expected**: the PowerShell entry point is named as its own degraded cause, the message says *"was
not found"* with no permission clause, and the remedy it names is the real install command. Restore
the file afterwards.

## Step 4 — No permission instruction survives (FR-005, SC-002)

```sh
grep -rniE 'chmod|not executable|executable bit' \
  commands/ scripts/ templates/ README.md INSTALL.md
```

**Expected**: exactly one hit — `README.md`'s `chmod 600 .specify/jira/.env`, which is the
credential-secrecy control FR-005 exempts by name. Anything else is a leftover.

## Step 5 — Cross-port byte equivalence (FR-006)

```sh
bash tests/conformance/ci-conformance.sh
```

**Expected**: exit 0 and **zero** lines containing "conformance divergence". There is no success
banner — silence is the pass. Temporary paths in the output are harness noise, not divergences.

## Step 6 — Lint and the full suites

```sh
shellcheck $(git ls-files '*.sh')
actionlint
tests/run-bash.sh                       # ~3m10s
pwsh -c 'Invoke-Pester tests/powershell' # twin
```

## Step 7 — Dogfood on the route that actually broke (Constitution XII)

The only step that exercises the real defect end to end rather than a construction of it:

```sh
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
ls -l .specify/extensions/jira/scripts/bash/spec-kit-jira.sh    # expect 0644 — the mode is dropped
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help
```

Run it on a host **below** the version that restores modes. If the listing shows `0755`, the host is
too new to reproduce the defect and this step has proved nothing — say so rather than recording a
pass.

## Step 8 — The managed README block (research R9)

On a configured consumer repository, after upgrading:

```sh
/speckit.jira.config      # first run rewrites the managed block with the corrected invocation
/speckit.jira.config      # second run must write NOTHING
```

**Expected**: one content change on the first run, zero writes on the second. A second write is
churn and fails Principle II.

## Done when

- Step 0 fails on `main` and passes after the change.
- Steps 1–6 are green, with the harness tests **run** rather than skipped.
- Step 7 is either green or explicitly recorded as not reproducible on the available host.
- Step 8 shows one write then none.
