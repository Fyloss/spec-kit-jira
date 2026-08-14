# Phase 0 Research — 026 Release Asset Install

**Date**: 2026-08-14
**Host used for measurement**: macOS (darwin 25.5.0), `specify` 0.14.4.dev0 as the *current* host and
`specify` 0.13.0 — the floor declared by `requires.speckit_version: ">=0.13.0"` — fetched into an ephemeral
environment with `uvx --from git+https://github.com/github/spec-kit.git@v0.13.0`, so the maintainer's own
installation was never modified.

Every decision below that concerns the host's behaviour was settled by **performing the operation and observing
the result**, per FR-005. Where a decision rests on reading a file rather than running something, that is said
explicitly.

---

## R1 — Does the archive need the manifest at its root, or is a single wrapping directory tolerated?

**Decision**: A single wrapping root directory is tolerated. **We ship the wrapped layout**, with everything
under `spec-kit-jira/`.

**Evidence**: Two candidate archives were built from the same 87-file surface — `flat.zip` (manifest at the zip
root, 104 entries) and `rooted.zip` (everything under `spec-kit-jira/`, 105 entries) — served over local HTTP,
and installed into two pristine consumer repositories created by `specify init --here`.

| archive | install result | installed file count | tree matches the surface |
| --- | --- | ---: | --- |
| `flat.zip` | `✓ Extension installed successfully!` | 87 | exact |
| `rooted.zip` | `✓ Extension installed successfully!` | 87 | exact |

Both produce an identical `.specify/extensions/jira/` tree, an identical `.specify/extensions.yml` hook
registry (all seven lifecycle events, `enabled: true`), and identical `.claude/skills/speckit-jira-*` entries.

**Rationale for choosing the wrapped layout**: it is the shape the host has always had to handle, because
GitHub's own source archives — the form the broken documentation pointed at — are always wrapped. It is
therefore the better-trodden code path upstream. It also means a human who downloads the artifact and unzips it
by hand gets one directory rather than 87 loose entries in their working directory. The cost is one extra zip
entry.

**Alternatives considered**: the flat layout, which is proven to work equally well and is one entry cheaper.
Kept as the recorded fallback: if the three-OS test finds a Windows-only divergence, switching is a one-line
change to the builder, and no other requirement depends on the choice.

---

## R2 — Does the host follow HTTP redirects, and may the documented URL be version-free?

**Decision**: Yes, redirects are followed. The documented address is
`https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip`.

**Evidence**: a local server was made to answer `/latest/download/spec-kit-jira.zip` with `302 Found` and a
`Location` pointing elsewhere. Installing from the redirecting address succeeded and produced the full 87-file
tree.

**Why this matters more than it looks**: it is what resolves the collision between two requirements that
otherwise cannot both hold. The user asked for documentation pointing at "the versioned release asset"; the
existing *Version literal single-sourced* CI job forbids the version literal from appearing in any file except
`extension.yml` and `CHANGELOG.md` — and `README.md` and `INSTALL.md` are not excluded from that scan. A
version-pinned URL in the documentation would turn that gate red. GitHub's `/releases/latest/download/<name>`
form is a redirect to the newest release's asset of that name, so the documentation can name a stable address
that carries no version at all.

**Consequence for publication**: each release must attach the asset under a **stable, version-free name**
(`spec-kit-jira.zip`) for that address to resolve, *and* under a version-pinned name
(`spec-kit-jira-<version>.zip`) so that operators can pin. Two assets, one archive.

**Alternatives considered**: (a) documenting the version-pinned URL and excluding `README.md`/`INSTALL.md` from
the version gate — rejected, it weakens an existing constitutional gate to solve a documentation problem;
(b) a placeholder such as `<version>` in the documented command — rejected as the *primary* form, because a
command a reader cannot paste is how the current defect went unnoticed. The placeholder form is still shown, as
the secondary "to pin a version" line.

---

## R3 — Does the executable bit survive a zip install, and on which hosts?

**Decision**: It does not, on the hosts this extension declares it supports. The fix is to stop depending on
it: invoke the Bash port through the interpreter and drop the `-x` clause from the prerequisite gate.

**Evidence, in three parts.**

*The mechanism*, measured directly in Python: an archive member written from a `0755` file records
`0o100755` in its external attributes, and `ZipFile.extractall` restores it as **`0644`**. The permission is
stored and then discarded on extraction. This is a property of the extraction call, not of our archive.

*The population*, measured by installing the same archive on two hosts:

| host | route | `scripts/bash/spec-kit-jira.sh` mode |
| --- | --- | ---: |
| `specify` 0.14.4.dev0 | zip / `--from` | `755` (host reports "Updated execute permissions on 36 script(s)") |
| `specify` 0.14.4.dev0 | `--dev` | `755` |
| **`specify` 0.13.0 — the declared floor** | **zip / `--from`** | **`644`** |

*The consequence*, measured on the floor host after that install:

| invocation | exit | output |
| --- | ---: | --- |
| `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help` — the form all three command documents instruct | `126` | `permission denied` |
| `bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help` — the natural workaround | `5` | `spec-kit-jira: the bridge entry point … was not found or is not executable — the extension install is incomplete. Restore it with: specify extension add --dev …` |
| the same archive, same command, on `specify` 0.14.4.dev0 (control) | `0` | prints usage |

So the second row is our own gate (`scripts/bash/lib/prereq.sh:58`) rejecting an install that is entirely
intact, and the remediation it prints tells a URL-installing consumer to use `--dev`, which is precisely the
route they do not have. The control row proves the archive itself is fine and the variable is the host.

**Blast radius of the fix** (measured by search, 9 files):

- `scripts/bash/lib/prereq.sh` — delete the `-x` clause at lines 56–61, keep both `-f` clauses.
- `scripts/powershell/lib/Prereq.psm1` — **no code change needed**: the twin never checked the bit (its
  doc-comment at line 39 says so explicitly, because NTFS carries no such bit). Removing the Bash check
  therefore *increases* port parity rather than threatening it. The shared message literal at line 94 changes.
- `commands/speckit.jira.config.md`, `commands/speckit.jira.feature.md`, `commands/speckit.jira.reconcile.md`
  — the instructed invocation becomes `bash <path>` on macOS/Linux.
- `scripts/bash/commands/reconcile.sh`, `scripts/powershell/commands/Reconcile.psm1` — message literals.
- `tests/bash/ci/test_agent_fallback_block.bats`, `tests/powershell/ci/AgentFallbackBlock.Tests.ps1` — the
  tests that pin those literals.

**Alternatives considered**: (a) raise `requires.speckit_version` to `>=0.14.3` — rejected: it fixes nothing
for anyone actually running today, silently drops support for hosts that otherwise work, and leaves every
already-installed tree broken; (b) have the config ceremony `chmod +x` on first run — rejected: the ceremony is
itself invoked through the bridge, so it cannot run; (c) ship the entry point as a wrapper the host marks
executable — rejected, no such mechanism exists and it would be speculative machinery (Principle XV).

---

## R4 — How is the archive's content derived from `.extensionignore` without a second list?

**Decision**: Ask git. `git ls-files` enumerates the candidates and git's own ignore engine, pointed at
`.extensionignore` through `core.excludesFile`, decides which are excluded:

```
git ls-files                                       # tracked files, the candidate set
  | git -c core.excludesFile=.extensionignore \
        check-ignore --no-index --stdin            # the ones .extensionignore excludes
```

The archive is the candidates minus that result, minus `.extensionignore` itself.

**Evidence**: the derived set was compared against the tree an actual install produced. It matched **exactly**,
with the single expected difference of `.extensionignore` itself (88 derived vs 87 installed), which the host
excludes unconditionally and which FR-006 already requires us to drop.

**Rationale**: `.extensionignore` is written in gitignore syntax, and gitignore syntax has more corners than it
looks — negation, anchoring, directory-only patterns, precedence by order. Reimplementing it in shell or
PowerShell would be a second *implementation* of the exclusion semantics even if it were not a second *list*,
and it would drift. Delegating to git means the builder cannot disagree with the file. Git is already a hard
requirement of every path in this project, so this adds no dependency (Principle XIV).

**Alternatives considered**: (a) build the archive by running `--dev` into a temporary directory and zipping
the result — attractive because it makes divergence impossible by construction, but rejected because that copy
carries `.git` (see R5) and installer-generated staging, so it would need its own post-filter, which is the
second list this feature exists to avoid; (b) hand-written `find` prune expressions — rejected, that *is* the
second list.

---

## R5 — What does `--dev` actually copy today? (the reference, and a defect found while measuring it)

**Decision**: The `--dev` route currently copies the repository's `.git` directory into the consumer's tree.
`.extensionignore` must gain a `.git/` entry (spec FR-002a).

**Evidence**: a `--dev` install into a pristine consumer repository produced:

| | files | size |
| --- | ---: | ---: |
| `.specify/extensions/jira/` total | 6 255 | 40 MB |
| of which `.specify/extensions/jira/.git/` | 6 165 | 38 MB |
| of which installer-generated `.specify-dev/agent-commands/…` | 3 | — |
| **the actual surface** | **87** | **1.8 MB** |

`.extensionignore` lists `.github/`, `.gitignore` and `.gitattributes` — but not `.git/`. The zip route is
unaffected (`.git` is not in `git ls-files`), so this is a pre-existing `--dev` defect that only became visible
because this feature compares the two routes. Fixing it is what makes "the two routes agree" a checkable claim
rather than an aspiration, and the spec's Out of Scope section already reserved the right to correct the
exclusion list when a gate proves it mis-classifies a file.

The three `.specify-dev/agent-commands/…` files are **generated by the installer after the copy**, not present
in this repository (confirmed: no `.specify-dev` exists here, and `git status` is unchanged by the install).
They must therefore never be in the archive, and the completeness gate must compare against the surface rather
than against a post-install listing.

---

## R6 — What exactly does the host validate before extraction?

**Decision**: The project's own ceiling is **256 entries**, and the gate also asserts the three other bounds
that could plausibly be reached.

**Evidence**: read from `specify_cli/_download_security.py` in the installed 0.14.4 host — this one is read
rather than measured, because the constants are declarative — and the candidate archive measured against them:

| host limit | value | our archive | headroom |
| --- | ---: | ---: | ---: |
| `MAX_ZIP_ENTRIES` | 512 | **105** | 79% |
| `MAX_ZIP_TOTAL_BYTES` (uncompressed) | 50 MiB | 1.64 MiB | 97% |
| `MAX_ZIP_MEMBER_BYTES` | 10 MiB | 145 KiB (`scripts/powershell/commands/Reconcile.psm1`) | 98% |
| `MAX_DOWNLOAD_BYTES` | 50 MiB | 0.5 MiB compressed | 99% |
| `MAX_ZIP_PATH_BYTES` | 4096 | 48 | — |
| `MAX_ZIP_COMPONENT_BYTES` | 255 | 25 | — |

The host also rejects Windows-invalid filename characters (`<>:"|?*`) and reserved device names anywhere in a
member path, and accepts only stored and deflated members. Our tree satisfies all of these today; the gate
asserts the entry count, the uncompressed total, and the largest member, because those are the three that grow
with the project. The path-length and character rules are asserted too, cheaply, since a Windows-hostile
filename would otherwise be discovered only by a Windows consumer.

**Rationale for 256**: half the host's ceiling and roughly two and a half times today's 105 entries. It fires
on a doubling of the shipped surface — which would be a deliberate architectural change worth a conversation —
long before anything a user would experience.

---

## R7 — Can the artifact be installed from a local file during testing?

**Decision**: No. The end-to-end test must serve the artifact over HTTP from a server it starts itself.

**Evidence**: `specify extension add jira --from file:///…/flat.zip` fails with
`Error: Invalid URL: file:///…`. Loopback HTTP works, including through a redirect (R2).

**Consequence for test design**: the server binds a port **assigned by the operating system**, and the test
reads back the assigned port for its own URL. Constitution XIII forbids identifying state by a fixed
well-known port: a hard-coded port would make the test correct only when it runs alone. The server's process
identifier is likewise recorded at launch and used for teardown.

---

## R8 — Is the install non-interactive?

**Decision**: No, and both the documentation and the test must account for it.

**Evidence**: installing from an address that is not in a configured catalog prints an `⚠ Untrusted Source`
panel and blocks on `Continue with installation? [y/N]:`. With no stdin the install prints `Aborted.` and
exits without installing — which, in a script, looks like a silent no-op. Feeding `y` on stdin completes the
install.

There is no `--yes` option on `specify extension add` (its full option set is `--dev`, `--from`, `--force`,
`--priority`). So the confirmation is answered on stdin, and the documentation says so (FR-024).

---

## R9 — How is the artifact published, and how is the version cross-checked?

**Decision**: A workflow triggered by a version tag builds the archive, runs the gates, and attaches both asset
names to the release. The version is read from `extension.yml` and compared to the tag; a mismatch fails before
any upload.

**Rationale**: this is the only trigger that satisfies "published on every version" without publishing on every
commit, and the tag is the one place a human states a version outside the manifest — so it is exactly where the
cross-check belongs. Reading the version uses the same `sed` expression the existing *Version literal
single-sourced* job already uses, so there is one parsing behaviour, not two.

**Note on the existing gate**: the builder and the workflow must not contain the version literal — they compute
it. This is checked for free, because that job scans the whole tree and excludes `.github/`; the *builder
script*, however, will not live under `.github/`, so it must genuinely never hard-code a version.

**Alternatives considered**: publishing on every push to the default branch — rejected, it produces artifacts
nobody asked for and makes "the latest asset" ambiguous; publishing by hand — rejected by SC-008.

---

## R10 — Where does the builder live, and in which language?

**Decision**: One script under `scripts/` is wrong — that directory is shipped. The builder is development-only
and lives beside the other development tooling, written in Bash, and driven from CI.

**Rationale**: anything under `scripts/`, `commands/` or `templates/` is part of the installable surface and
would ship to consumers, which Principle XV forbids for a tool they cannot use. The builder therefore belongs
on the excluded side of the line — but not under `tests/`, because it is not a test, and calling it one to
inherit an existing exclusion would cost a reader more than the one line it saves (Principle XVI). It gets its
own top-level `packaging/` directory and one new `.extensionignore` entry, which is precisely what that file is
for. Its bats tests live under `tests/bash/packaging/`, following the existing convention.

Deliberately **not** `.github/scripts/`: the *Version literal single-sourced* job excludes `.github/` from its
repository-wide scan, so a version accidentally hard-coded there would go unreported. Under `packaging/` the
builder stays inside that scan, and FR-007 gets enforced on the very code most tempted to violate it.

**On port parity**: the builder is *tooling about* the two ports, not one of them. Principle VI requires the
shipped extension to work on all three operating systems — which is why the artifact carries both ports and why
FR-017 tests on all three — but it does not require the release tooling itself to be twin-ported, any more than
`tests/run-bash.sh` or the coverage runner are. The builder runs on the release runner only. This is recorded
here rather than argued in review because "twin ports" is otherwise the reflex answer.

**Alternatives considered**: a PowerShell twin of the builder — rejected as speculative genericity (Principle
XIV/XV): it would double the surface with no second consumer, and a divergence between the two builders would
reintroduce exactly the drift this feature exists to prevent.

---

## Summary of what changed in the specification because of this research

| Finding | Spec change |
| --- | --- |
| `--dev` copies `.git` (6 165 files, 38 MB) | FR-001 reworded, FR-002a added |
| Untrusted-source prompt blocks non-interactive installs | FR-024 added |
| `file://` rejected; fixed ports forbidden by Principle XIII | FR-025 added |
| Both zip layouts work; redirects are followed | Two edge cases moved from "unknown" to "settled", pointing here |
