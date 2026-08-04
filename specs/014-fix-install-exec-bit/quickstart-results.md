# Quickstart walk-through results — 014 A Fresh Install Runs Immediately

**Task**: T034 | **Date**: 2026-08-03 | **Host**: macOS (Darwin 25.5.0, arm64),
`specify` CLI `0.14.4.dev0`, bash `5.3.15(1)-release` (Homebrew), PowerShell `7.5.2`,
Bats `1.13.0`, ShellCheck `0.11.0`, actionlint `1.7.12`.

Every step of [quickstart.md](./quickstart.md) was walked against the fixed tree (commit
`f917944`, `extension.yml` version `0.10.1`). Results below, in order. Where a step could not be
exercised as specified, the reason is recorded rather than reported as a pass, per SC-001's own
wording.

## SC-001 matrix — `{--dev copytree, --from zip} × {declared floor, current}`

| Install route | Host version | Result |
| --- | --- | --- |
| `--dev` copytree | current (`specify 0.14.4.dev0`) | **PASS** — Step 0 below: install, `chmod a-x` the Bash entry point, `bash <path> --help` exits 0 |
| `--dev` copytree | declared floor | **Not reproducible on this host** — no `specify` build at the declared floor version is available here. Carried instead by the install-harness tests (`tests/bash/conformance/test_us4_bridge_runnable.bats`, `Us4.BridgeRunnable.Tests.ps1`), confirmed **run, not skipped**, in Steps 1 and 6 |
| `--from` zip | current (`specify 0.14.4.dev0`) | **Not reproducible** — `specify extension add --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip` refuses the archive outright: `Validation Error: ZIP archive contains too many entries (876 > 512)`. This is a `specify`-CLI-side safety limit on the raw GitHub source archive (which is not filtered by `.extensionignore` the way `--dev` copytree is) — it fires before extraction, so it never reaches the file-mode question at all. Unrelated to this feature; not something 014 can or should fix |
| `--from` zip | declared floor | **Not reproducible** — same entry-count block prevents reaching this cell regardless of host version. This is also the cell plan.md's own risk table flagged as unreproducible once a host restores modes from `>=0.14.3`, so a second, independent reason would have blocked it even without the entry-count limit |

## Step 0 — Reproduce the defect before fixing anything

Pre-fix failure was established by T001 before this commit landed (commit `f917944`'s description
names the exact symptom: *"was not found or is not executable"*, exit 5). This session runs the
**post-fix** expectation on the fixed tree:

```
$ specify extension add --dev <repo> --force   # lands entry point at 0644
$ chmod a-x .../spec-kit-jira.sh
$ bash .../spec-kit-jira.sh --help
usage: spec-kit-jira <config|reconcile|mention|feature> [options]
  ...
EXIT:0
```

**Result: PASS** — matches quickstart's "Expected after the fix".

## Step 1 — The automated reproduction

```
bats -r tests/bash/conformance/test_us4_bridge_runnable.bats tests/bash/lib/test_prereq.bats
```

| Result | Count |
| --- | --- |
| Tests run | 13 |
| Passed | 13 |
| `specify` present, harness tests **run** (not skipped) | yes |

**Result: PASS**

## Step 2 — Equivalence between the two modes (FR-009, C7)

`--help` captured at `0755` then at `0644` on the same installed tree:

```
diff /tmp/exec.out /tmp/noexec.out && echo "identical"
identical
```

**Result: PASS** — byte-identical stdout/stderr/exit code across both modes.

## Step 3 — Diagnostics stay honest (FR-004, C4, C5)

PowerShell entry point renamed away, Bash entry point invoked:

```
spec-kit-jira: the bridge entry point .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1
was not found — the extension install is incomplete. Restore it with:
specify extension add --dev <path-to-spec-kit-jira> --force
EXIT:5
```

Names the actual missing file, says "was not found" with no permission clause, remedy is real.

**Result: PASS**

## Step 4 — No permission instruction survives (FR-005, SC-002)

```
grep -rniE 'chmod|not executable|executable bit' commands/ scripts/ templates/ README.md INSTALL.md
templates/readme-block.template:88:   (`chmod 600`). That file's parser reads **only** `JIRA_API_TOKEN`.
README.md:184:chmod 600 .specify/jira/.env
```

Two hits, both the credentials-secrecy control FR-005 exempts by name — neither is an instruction to
make the bridge runnable. (T035 corrected quickstart.md's stated expectation from one hit to these
two; the automated sweep, `tests/bash/ci/test_message_command_literals.bats`, already exempted both
and was green before this correction — only the hand-run expectation was stale.)

**Result: PASS**

## Step 5 — Cross-port byte equivalence (FR-006)

```
bash tests/conformance/ci-conformance.sh
```

Exit 0. Zero lines containing "conformance divergence". The harness prints no success banner — the
temp paths it emits are noise, and exit 0 with no divergence line is the whole of the pass signal.

**Result: PASS**

## Step 6 — Lint and the full suites

| Check | Scope | Result |
| --- | --- | --- |
| `shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')` (CI's actual scope) | this feature's shipped Bash surface | clean |
| `shellcheck $(git ls-files '*.sh')` (quickstart's literal command) | whole repo | also flags `.specify/scripts/bash/check-prerequisites.sh` — pre-existing spec-kit scaffolding outside this feature's blast radius (last touched `b7a2852`, unrelated to 014) |
| `actionlint` | `.github/workflows/*.yml` | reports pre-existing style/info findings in `ci.yml` and `gates.yml`, last touched in PR #14 — unrelated to 014, not in this feature's file list |
| `tests/run-bash.sh` | full Bash suite | **PASSED** — 127 files, 1211 tests, 0 failures |
| `pwsh -c 'Invoke-Pester tests/powershell'` | full PowerShell suite | **924 passed, 0 failed, 0 skipped**, 388.73s, including `Us4.BridgeRunnable.Tests.ps1` run (not skipped) |

**Result: PASS** on this feature's actual blast radius (`scripts/bash/**`); the two flagged files are
pre-existing and out of scope for 014.

## Step 7 — Dogfood on the route that actually broke

Blocked before reaching the mode question: see the SC-001 matrix above (`--from zip` cells). The
`specify` CLI refuses this repository's GitHub archive with `Validation Error: ZIP archive contains
too many entries (876 > 512)` on `specify 0.14.4.dev0`. Recorded as **not reproducible**, per
quickstart's own instruction, rather than as a pass — with the added, more specific reason (an
entry-count safety limit, not mode restoration) than the risk plan.md anticipated.

**Result: not reproducible on the available host/CLI**

## Step 8 — The managed README block (research R9)

A live dogfood against a configured consumer repository with real Jira Cloud credentials was not
performed — same limitation 003's quickstart-results §10 recorded (no Jira Cloud project/credentials
available in this environment). Evidence instead:

- The invocation change already lands in the shipped surface: `templates/readme-block.template:64`,
  `README.md:109`, `README.md:206`, `INSTALL.md:154` all carry the `bash ` prefix (confirmed by grep).
- The splice mechanism's idempotency (unchanged content/version writes nothing, changed content
  replaces the block once) is covered by `tests/bash/engine/test_readme_idempotent.bats` and
  `tests/powershell/engine/ReadmeIdempotent.Tests.ps1`, both green in Step 6's full-suite runs.
- T033 (tasks.md) records this step as already walked by hand in an earlier session.

**Result: evidence-based pass; live dogfood not performed (credentials unavailable)**

## Done when — checklist against quickstart.md

| Criterion | Status |
| --- | --- |
| Step 0 fails on `main`, passes after the change | passes after the change (pre-fix failure established by T001/commit `f917944`) |
| Steps 1–6 green, harness tests run not skipped | green, harness tests run |
| Step 7 green or explicitly recorded as not reproducible | recorded not reproducible, reason specific to this host's `specify` CLI |
| Step 8 shows one write then none | evidence-based (automated idempotency tests + shipped diff), no live dogfood |
