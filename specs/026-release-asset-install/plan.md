# Implementation Plan: An Installable Artifact, Built From the One List That Already Says What Ships

**Branch**: `fix/release-zip-size` | **Date**: 2026-08-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/026-release-asset-install/spec.md`

## Summary

The documented install command has never worked: it points at the repository's source archive, which carries
1 638 zip entries against a pre-extraction ceiling of 512. The installable surface is 87 files in 17
directories — 105 zip entries — so the answer is to publish an archive of that surface and point the
documentation at it.

The design has one organising idea: **nothing may state what ships except `.extensionignore`.** The builder
does not carry an inclusion list; it asks git which tracked files that file excludes, using git's own ignore
engine (`core.excludesFile`), and archives the remainder. The gates do not compare against a written inventory;
they compare the archive against that same derivation and against a real `--dev` install. A second list is the
failure mode this feature exists to prevent, so the design removes the place one could live.

Phase 0 measurement settled four unknowns and turned up three things the specification did not know:

- Both zip layouts install correctly; we ship the wrapped one. Redirects are followed, so the documented URL
  can be version-free — which is what keeps `README.md` clear of the version literal the existing gate forbids.
- **A zip install on the declared floor host lands the bridge at `0644`**, and our own prerequisite gate then
  rejects the `bash <script>` workaround. Reproduced end to end on `specify` 0.13.0 with a passing control on
  0.14.4. Packaging alone would therefore have shipped an installable extension that cannot run.
- **`--dev` copies this repository's `.git`** — 6 165 files, 38 MB — into every consuming repository. A
  pre-existing defect, visible only once the two routes were compared.
- The install **blocks on an interactive trust prompt** for any URL outside a configured catalog, and rejects
  `file://` addresses outright.

## Technical Context

**Language/Version**: Bash 3.2+ (packaging tooling, macOS floor), PowerShell 7+ (shipped port, unmodified by
this feature except two message literals), GitHub Actions workflow YAML.

**Primary Dependencies**: `git` (already required everywhere; used as the ignore-semantics engine), `zip` or
Python's `zipfile` for archive creation, `gh` for release asset upload (GitHub-hosted, already used by the
project's automation), `uv`/`uvx` in CI to obtain pinned `specify` versions. No new runtime dependency reaches
a consumer.

**Storage**: N/A — the artifact is a build output, not persisted state.

**Testing**: `bats` for the builder and the gates (`tests/bash/packaging/`), a three-OS GitHub Actions matrix
for the end-to-end install, Pester for the two PowerShell message-literal tests touched by FR-016.

**Target Platform**: the *artifact* must install on macOS, Linux and Windows; the *builder* runs on the Linux
release runner only (see research R10).

**Project Type**: CLI extension distributed as a spec-kit extension archive.

**Performance Goals**: not a performance feature. The one budget that matters is CI wall clock: the cheap gates
must stay under a minute so they can run on every pull request; the three-OS end-to-end install is the
expensive one and is triggered narrowly (see *CI triggering* below).

**Constraints**: the archive must satisfy every host pre-extraction bound with the project's own tighter
ceiling of 256 entries; the documentation must contain no version literal (existing *Version literal
single-sourced* gate); `.extensionignore` must remain the only statement of what ships.

**Scale/Scope**: 87 shipped files / 105 zip entries / 1.64 MiB uncompressed today. Nineteen existing files
change for FR-016 — seven of them tests, which change first — plus one new test file pinning the three
consumer documents nothing pins today (`contracts/bridge-invocation.md` §4, corrected from an earlier count of
fourteen). The rest of the work is new development-only material.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after Phase 1 design — see the post-design row at the end.*

| # | Principle | Gate at plan level |
| --- | --- | --- |
| I | Filesystem is the source of truth | PASS. The archive is derived from tracked files and `.extensionignore`; the gates measure the archive and a real install. Nothing declares content. |
| II | Zero-churn idempotency | PASS. The builder is deterministic — fixed member order, normalised timestamps and modes — so building twice from one commit yields identical bytes, and FR-012 refuses to overwrite a published asset. |
| III | Fail-closed on writes | PASS. Publication is the write; every gate fails closed (`set -euo pipefail`, explicit failure on an unreadable manifest or absent artifact) and blocks it. |
| IV | Credential security | PASS, and improved: the artifact excludes `tests/` and `specs/`, so no fixture or recording can carry a secret into a consumer tree. Publication uses the workflow's ambient release token; nothing is added to the tree. |
| V | Config / binding / secrets separation | PASS. Unaffected — the templates shipped are unchanged. |
| VI | Three-OS portability | PASS. One artifact carries both ports (FR-003); FR-017 installs and runs it on all three; FR-016's fix is verified on both ports. The builder itself is single-port by justified design (research R10). |
| VII | No hard-coded Jira workflow assumptions | PASS. Unaffected. |
| VIII | Engine / sink separation | PASS. Explicitly out of scope; the engine is packaged, not modified. |
| IX | Privacy guard | PASS. Unaffected, and indirectly served by excluding this project's specs from consumer trees. |
| X | Self-healing mirror | PASS. Unaffected. |
| XI | Dry-run and auditability | PASS. The builder writes an archive to a path and runs its gates without publishing; every gate names the offending entries, the measured count and the ceiling. |
| XII | Quality and catalog publication | PASS, and this is the principle the feature serves: it already requires installation to be documented via `specify extension add`, and that command currently fails. SemVer and the single-sourced version are preserved (FR-007). |
| XIII | TDD, 80% coverage | PASS with a caveat recorded below. Every gate gets its failing case first (three deliberately wrong artifacts, a version mismatch, a reintroduced source URL). FR-016 is a bug fix and ships its regression test first. The end-to-end test creates its own consumer repository and binds an OS-assigned port, identifying both by what it recorded — never by pattern or fixed port. **Caveat**: the new code is CI tooling, not shipped script, so it is outside the kcov statement-coverage gate's scope (`scripts/bash`); it is covered by bats scenarios instead. Recorded here rather than silently assumed. |
| XIV | KISS | PASS. No new abstraction, no new runtime dependency, no builder framework. Ignore semantics are delegated to git rather than reimplemented — the simplest thing that cannot drift. |
| XV | YAGNI | PASS. No signing, no checksums, no registry publication, no multi-channel release scheme. The one thing built beyond the literal ask — FR-016 — is required for the user's own acceptance condition ("the bridge answers `--help`") to hold on a supported host, and is proven necessary by measurement, not anticipated. |
| XVI | Human readable | PASS. Failure messages name paths, counts and ceilings; the documentation change exists entirely to stop misleading a first-time reader; `packaging/` is named for what it is rather than hidden under `tests/`. |

**No Constitution Check violations. The Complexity Tracking table below is therefore empty, as required.**

## Project Structure

### Documentation (this feature)

```text
specs/026-release-asset-install/
├── plan.md              # This file
├── research.md          # Phase 0 output — the four measured unknowns and three discoveries
├── data-model.md        # Phase 1 output — the entities and their invariants
├── quickstart.md        # Phase 1 output — how to validate the feature end to end
├── contracts/           # Phase 1 output — builder CLI, gate CLI, workflow, documented URL
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
packaging/                              # NEW — development-only, added to .extensionignore
├── build-artifact.sh                   # derive the surface, write the archive, print a manifest of it
├── verify-artifact.sh                  # the three content gates + the host-bound assertions
├── publish-artifact.sh                 # version cross-check, asset naming, overwrite refusal — the decisions
└── resolve-version.sh                  # read extension.version from extension.yml, one parser

.extensionignore                        # MODIFIED — add `.git/` (FR-002a) and `packaging/`

scripts/bash/lib/prereq.sh              # MODIFIED — drop the `-x` clause (FR-016), keep both `-f` clauses
scripts/bash/commands/reconcile.sh      # MODIFIED — remediation message literal
scripts/bash/hooks/register_hooks.sh    # MODIFIED — HOOK_INSTALL_COMMAND remediation literal
scripts/powershell/lib/Prereq.psm1      # MODIFIED — message literal only; no logic (it never checked the bit)
scripts/powershell/commands/Reconcile.psm1  # MODIFIED — message literal
scripts/powershell/hooks/RegisterHooks.psm1 # MODIFIED — $script:HookInstallCommand, byte-identical to its twin

commands/speckit.jira.config.md         # MODIFIED — instruct `bash <path>`; also the `incomplete` remedy row
commands/speckit.jira.feature.md        # MODIFIED — instruct `bash <path>` on macOS/Linux
commands/speckit.jira.reconcile.md      # MODIFIED — idem

templates/readme-block.template         # MODIFIED — instruct `bash <path>`. SHIPPED: it writes this text
                                        #   into the consuming repository's own README

README.md                               # MODIFIED — release-asset URL; no source archive, no version literal;
                                        #   and the `bash <path>` invocation form (lines 109, 213)
INSTALL.md                              # MODIFIED — idem, plus the trust-prompt note (FR-024)

tests/bash/packaging/                   # NEW
├── test_surface_derivation.bats        # the derived set equals the installed set
├── test_artifact_gates.bats            # three wrong artifacts, each rejected with named entries
├── test_version_resolution.bats        # manifest is the only source; tag mismatch fails
└── test_docs_no_source_archive.bats    # FR-023 reintroduction check
tests/bash/helpers/consumer_fixture.bash # NEW — throwaway consumer repo + loopback server on an OS-assigned port
tests/bash/ci/test_agent_doc_invocation.bats        # MODIFIED — the seven files pinning the invocation form
tests/bash/ci/test_agent_fallback_block.bats        #   and the exec-bit premise; all change BEFORE the fix
tests/bash/ci/test_message_command_literals.bats
tests/bash/ci/test_consumer_docs_invocation.bats    # NEW — pins the form in README/INSTALL/the template,
                                                    #   which nothing pins today
tests/bash/ci/test_workflow_release.bats            # NEW — release.yml gates before upload, holds no logic
tests/bash/conformance/test_us4_bridge_runnable.bats
tests/powershell/ci/AgentDocInvocation.Tests.ps1
tests/powershell/ci/AgentFallbackBlock.Tests.ps1
tests/powershell/ci/MessageCommandLiterals.Tests.ps1

.github/workflows/release.yml           # NEW — tag-triggered: build, gate, cross-check version, upload 2 assets
.github/workflows/install-e2e.yml       # NEW — three-OS install from the built artifact, floor + current host
.github/workflows/gates.yml             # MODIFIED — add the cheap artifact gates to the per-PR set
```

**Structure Decision**: the repository already separates *shipped* (`scripts/`, `commands/`, `templates/`,
manifest, consumer docs) from *development* (`tests/`, `specs/`, `docs/`, `.github/`, `.specify/`) by way of
`.extensionignore`. This feature adds one directory on the development side, `packaging/`, and declares it in
that same file — the only place such a declaration is allowed to exist. No shipped directory gains a file.

## The four design decisions worth stating

### 1. Git decides what ships, because git wrote the syntax

`.extensionignore` is gitignore syntax. Reimplementing that syntax — anchoring, directory-only patterns,
negation, order precedence — in the builder would be a second *implementation* of the exclusion rules even
though it is not a second *list*, and it would drift in exactly the silent, asymmetric way the specification
warns about. So the builder asks git:

```
git ls-files | git -c core.excludesFile=.extensionignore check-ignore --no-index --stdin
```

Measured in Phase 0: the resulting set matches a real install's tree exactly, modulo `.extensionignore` itself.
The builder subtracts that one file, which the host excludes unconditionally.

### 2. The completeness gate compares against an install, not against a list

FR-014 requires the expected contents to be *measured*. The gate therefore performs a `--dev` install into a
temporary consumer repository and diffs its `.specify/extensions/jira/` tree against the archive's contents.
That comparison is only meaningful once `.git/` is excluded (FR-002a) — which is why the exclusion-list
correction is a prerequisite of the gate rather than an incidental tidy-up. After it, the two trees are
identical and the diff is the assertion.

### 3. The end-to-end test must run on the floor host, or it proves nothing

The defect in research R3 is invisible on any host newer than 0.14.3, and a naive matrix would pin the newest
`specify` and go green while every supported older host fails. The matrix is therefore two-dimensional:
{macOS, Linux, Windows} × {floor version, current version}. The floor is read from
`requires.speckit_version` in the manifest rather than written into the workflow, so it cannot fall out of step
with what the extension claims to support.

### 4. The publication decisions live in a script, not in the workflow

Three of this feature's rules are *decisions*: the tag-versus-manifest cross-check (FR-009), the two asset
names derived from one archive (FR-008), and the refusal to overwrite (FR-012). Written into `release.yml`
they would be reachable only by cutting a tag, so their failing tests could never run — and Constitution XIII
requires the failing test first. They therefore live in `packaging/publish-artifact.sh`, which bats drives
directly with `gh` stubbed on `PATH`. `release.yml` supplies the tag, the archive path and the credential and
calls it; the workflow contributes no logic of its own, so there is nothing in it left untested
(`contracts/publication.md` C2.7).

## CI triggering — what runs when

| check | trigger | cost |
| --- | --- | --- |
| surface derivation, entry/size ceilings, completeness, purity, version resolution | every pull request, in `gates.yml` | seconds; no network |
| documentation has no source-archive URL and no version literal | every pull request | seconds |
| three-OS × two-host end-to-end install | pushes touching `packaging/`, `.extensionignore`, the manifest, the shipped surface or the release workflow; the release path; and manual dispatch | minutes, and Windows runs here are slow and occasionally flaky |
| build, gate, cross-check, publish two assets | version tag | minutes |

This split is what keeps the per-PR loop fast while still making the expensive proof unavoidable on any change
that could invalidate it. It follows the project's measured experience that runners here are roughly an order
of magnitude slower than local, and that a Windows retry costs about an hour and rarely teaches anything.

## Risks and how the plan answers them

| Risk | Answer |
| --- | --- |
| The wrapped layout behaves differently on Windows than on macOS, where it was proven | The flat layout is proven equally correct and is a one-line change in the builder; the three-OS test is what would reveal it, before any release. |
| `main` is already red on `windows-latest`, so a new Windows job inherits an unclear baseline | The end-to-end job asserts only its own outcomes (install succeeded, `--help` exited 0, seven hooks registered) and shares no state with the existing suites, so its signal is independent of that baseline. |
| FR-016 touches the invocation form in three command documents, which agents read as instructions | The literals are already pinned by two existing tests (`test_agent_fallback_block.bats` and its Pester mirror); those tests change first, in the same task, and are what turns the edit green. |
| Removing the `-x` clause hides a genuinely broken install | It does not: both `-f` clauses stay, so a *missing* entry point is still reported with its own cause. Only "present but not executable" stops being fatal — and it stops being fatal precisely because it is survivable. |
| The remediation message tells a URL consumer to run `--dev` | The literal is rewritten in the same change, for both ports, to name the route the reader actually has. |

## Constitution Check — post-design re-evaluation

Re-run after Phase 1 produced `data-model.md`, the four contracts, and `quickstart.md`. The design introduced
three things the pre-design check could not have seen; each is checked here rather than assumed to inherit the
earlier PASS.

| what the design introduced | principle at risk | verdict |
| --- | --- | --- |
| A new top-level directory, `packaging/`, and a new `.extensionignore` entry for it | XV (YAGNI), XVI (readable) | PASS. Every file in it traces to a functional requirement, and it is named for what it is rather than smuggled under `tests/` to inherit an exclusion. |
| A shipped-behaviour change (FR-016) inside a packaging feature | XV, and the project's bug-fix rule | PASS. Not anticipation: measured to be necessary for the user's own acceptance condition on a declared-supported host, with a passing control. `bridge-invocation.md` §4 enumerates all nine files, and §5 puts the two literal tests before the fix. |
| A single-port builder in a twin-port project | VI (portability), XIV (KISS) | PASS, and recorded explicitly in research R10 because "twin ports" is the reflex answer. VI governs what the *extension* must run on — satisfied by one artifact carrying both ports and a three-OS install test. The release tooling is no more twin-ported than `tests/run-bash.sh` or the coverage runner. A mirrored builder would be a second implementation of the derivation, which is the drift this feature exists to prevent. |

One caveat is carried forward rather than resolved, and is repeated here so `/speckit-tasks` does not lose it:
the new code is CI tooling outside `scripts/bash`, so it falls outside the kcov statement-coverage gate's
scope. It is covered by bats scenarios instead. This is a scope fact, not a coverage exemption — the shipped
files FR-016 touches remain inside the gate.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified.

No violations. No entries.
