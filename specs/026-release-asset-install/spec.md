# Feature Specification: An Installable Artifact, Built From the One List That Already Says What Ships

**Feature Branch**: `fix/release-zip-size`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description: "The documented install path is broken. README.md and INSTALL.md instruct
`specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip`.
That URL is the GitHub source archive of the whole repository. The `specify` CLI validates every downloaded
archive BEFORE extraction against a hard-coded ceiling of 512 entries (an anti-zip-bomb guard, not configurable
by environment variable). The current archive has 1638 entries and the install fails with
`Validation Error: ZIP archive contains too many entries (1638 > 512)`. Most of that volume is development
material — `tests/`, `specs/`, `docs/`, `.specify/`, `.claude/`, `.github/`. `.extensionignore` already excludes
them, but it is applied to the *copy*, therefore *after* extraction: it cannot stop the archive being rejected.
Tags have the same problem. I want an install-from-URL path that works: a release asset built from the
installable surface alone, published on every version, and verified by CI." — with eight explicit requirements
(three-OS install success; contents identical to what `--dev` copies; `.extensionignore` as the single source of
truth for exclusions; an archive layout proven by a real install rather than by reading upstream source; the
version single-sourced from `extension.yml`; fail-closed CI gates on entry count, completeness and purity; a
three-OS end-to-end install test from a pristine consumer repository; and documentation that never again names a
source-archive URL), an out-of-scope list (the upstream `specify` CLI, the 512 limit itself, the Jira reconcile
engine), and the standing constraint of the constitution and twin-port parity.

## Why this is a defect and not a wish

The two documents a new user reads first — `README.md` and `INSTALL.md` — contain a command that has never
worked. It does not fail late, in some corner of the reconcile path, on some unusual host. It fails immediately,
on every host, before a single byte is extracted, with a message about zip entry counts that says nothing about
this extension. From the reader's side the extension is simply not installable.

The arithmetic is not close, and it is not drifting toward the limit — it started far past it:

| | entries |
| --- | ---: |
| Tracked files in the repository | 1 202 |
| Directories implied by those files | 435 |
| The archive root | 1 |
| **Source archive total** | **1 638** |
| The ceiling the `specify` CLI enforces before extraction | **512** |

And the surface that a consumer actually needs is a small fraction of it:

| | entries |
| --- | ---: |
| Files outside `.extensionignore` (the installable surface) | 87 |
| Directories those files imply | 17 |
| **Installable total** | **~104** |

So the repository ships sixteen times the material a consumer needs, and the guard rejects it on that basis
alone. There is no version of "trim a bit" that fixes this and no tag that escapes it: `refs/tags/vX.Y.Z.zip` is
the same whole repository under a different name.

The reason `.extensionignore` does not already solve this is worth stating plainly, because it looks like it
should. That file is honoured by the install-time **copy** — the ignore callable of a recursive directory copy.
The copy happens after extraction. The guard runs before extraction. `.extensionignore` is on the wrong side of
the failure. It is a correct, well-reasoned document that cannot possibly be consulted at the moment it would
need to be.

That leaves exactly one shape of answer: publish an archive that already contains only the installable surface.
The `--dev` install proves the surface is well defined — it has been copying precisely that set for several
releases. What is missing is an artifact that carries the same set to someone who does not have a clone.

### The trap this feature must not fall into

The obvious implementation is to write a list of what to include. That list would be the second definition of
the installable surface, and the two would diverge — not loudly, but on the day someone adds a directory and
updates only one of them. The failure would be silent and asymmetric: `--dev` installs would be right and URL
installs would be subtly wrong, or the reverse, and nothing would report it. **`.extensionignore` is the single
source of truth for what ships, and this feature must not create a rival.** Every requirement below is written
so that the archive is *derived from* that file, and every gate is written so that it compares the archive
against *what the reference copy path actually produces*, never against a hand-maintained inventory.

### A second trap, discovered while specifying

Two files in the installable surface are committed executable: `scripts/bash/spec-kit-jira.sh` — the bridge
entry point every command document invokes by bare path — and `scripts/bash/sink/jira/prefetch.sh`. The `--dev`
install route copies file modes and preserves them. **Extraction from a zip does not.** A file extracted from an
archive lands non-executable regardless of what the archive recorded, unless the host explicitly restores it,
and the host only began doing so for extension installs in a version *newer than the floor this extension
declares it supports* (`requires.speckit_version: ">=0.13.0"`).

The consequence is that the naive version of this feature succeeds at its stated goal and still leaves the user
with a broken installation: the archive downloads, passes the guard, extracts, registers its hooks — and the
first command fails with `permission denied`. Worse, the extension's own prerequisite check treats a
non-executable entry point as a hard failure, so it also rejects the one workaround (`bash <script>`) that would
otherwise have worked, reporting "the extension install is incomplete".

"The bridge answers `--help`" — the user's own acceptance condition for the end-to-end test — therefore cannot
be met on a supported host by packaging alone. This specification treats bridge runnability after a zip install
as part of the deliverable rather than as a follow-up, because an install path that produces an unrunnable
bridge is not the working install path that was asked for.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A consumer installs from the documented URL, and it works (Priority: P1)

Someone who has never seen this repository copies the install command out of `README.md`, pastes it into their
own spec-kit project, and gets a working Jira bridge. They never clone anything, never learn what
`.extensionignore` is, and never read a stack trace about zip entries.

**Why this priority**: This is the whole feature. Everything else exists to make this repeatable and to keep it
true. Without it there is no supported way to install the extension at all, on any operating system.

**Independent Test**: From a pristine, freshly initialised spec-kit repository with no prior knowledge of this
extension, run the documented install command against a published artifact, then run the bridge's `--help` and
inspect the registered lifecycle hooks. Delivers a usable extension end to end.

**Acceptance Scenarios**:

1. **Given** a pristine consumer repository on macOS, **When** the operator runs the documented install command
   pointing at the published artifact, **Then** the install completes successfully and the extension's files
   appear under the consuming repository's extension directory.
2. **Given** the same on Linux, **Then** the install completes successfully.
3. **Given** the same on Windows, **Then** the install completes successfully.
4. **Given** a successful install on any of the three operating systems, **When** the operator invokes the
   bridge's `--help` exactly as the installed command documents spell it, **Then** it exits successfully and
   prints its usage.
5. **Given** a successful install, **When** the lifecycle hook registry of the consuming repository is read,
   **Then** every lifecycle event the manifest declares is registered and enabled.
6. **Given** a successful install on a host running the **lowest** spec-kit version this extension declares it
   supports, **Then** scenarios 4 and 5 still hold.
7. **Given** the artifact is downloaded, **When** the host's pre-extraction validation runs, **Then** it passes:
   the archive's entry count is far below the ceiling.

---

### User Story 2 - The maintainer cuts a version and the artifact publishes itself (Priority: P2)

The maintainer bumps the version in the manifest, updates the changelog, and tags the release. The artifact is
built, checked, and attached to the release without anyone assembling a zip by hand — and the version it carries
is the manifest's, because nothing else is allowed to state it.

**Why this priority**: A correct artifact that is published manually is an artifact that will eventually be
stale, or built from a dirty tree, or forgotten. Automation is what makes User Story 1 true for *every* version
rather than for one.

**Independent Test**: Trigger the publication path for a version and confirm an artifact is attached to the
corresponding release, that its embedded manifest version matches, and that its name derives from that same
version.

**Acceptance Scenarios**:

1. **Given** a release is cut for a version, **When** the publication path runs, **Then** an artifact built from
   the installable surface is attached to that release.
2. **Given** the artifact, **When** its embedded manifest is read, **Then** the version it states equals the
   version the release is named for.
3. **Given** a release whose declared version disagrees with the manifest's version, **When** the publication
   path runs, **Then** it refuses to publish and reports which two values disagreed.
4. **Given** a published release, **When** an install is attempted through the stable, version-free download
   address, **Then** it resolves to that release's artifact.

---

### User Story 3 - A wrong artifact never reaches a user (Priority: P2)

Before anything is published, the artifact is proved to be the installable surface — no more, no less — and
proved to be small enough to survive the host's guard with room to spare. Any of those proofs failing stops the
publication.

**Why this priority**: The failure this feature exists to fix was invisible until a user hit it. The gates are
what keep it from becoming invisible again — a new development directory, a renamed script, a `.extensionignore`
edit that quietly drops a shipped file. Same priority as publication itself: publishing without the proofs
recreates the original problem on a slower clock.

**Independent Test**: Construct three deliberately wrong artifacts — one too large, one missing a file the
surface contains, one containing a development file — and confirm each is rejected with a message naming the
offending entries.

**Acceptance Scenarios**:

1. **Given** an artifact whose entry count exceeds the project's own ceiling, **When** the gates run, **Then**
   publication fails and the count and ceiling are reported.
2. **Given** an artifact missing a file that the reference copy path would have installed, **When** the gates
   run, **Then** publication fails and the missing paths are listed.
3. **Given** an artifact containing a file the exclusion list excludes, **When** the gates run, **Then**
   publication fails and the offending paths are listed.
4. **Given** an artifact that is correct, **When** the gates run, **Then** they pass and publication proceeds.
5. **Given** a change to the exclusion list, **When** the gates run, **Then** the expected contents follow that
   change with no other file in the repository edited.

---

### User Story 4 - The documentation stops lying (Priority: P3)

Every install command in the consumer-facing documentation points at the release artifact. The source-archive
URL is gone and cannot come back unnoticed. The `--dev` route stays documented, clearly labelled as the path for
developing the extension rather than for using it.

**Why this priority**: Lowest of the four only because it is worthless before the artifact exists — a document
pointing at an artifact nobody publishes is no better than the current one. Once the artifact exists this is the
part users actually touch.

**Independent Test**: Read the consumer-facing documents and confirm no source-archive address appears; run the
check that enforces it and confirm it fails when such an address is reintroduced.

**Acceptance Scenarios**:

1. **Given** the consumer-facing documents, **When** they are searched for a repository source-archive address,
   **Then** none is found.
2. **Given** a change that reintroduces such an address in any consumer-facing document, **When** the checks
   run, **Then** they fail and name the file and line.
3. **Given** a reader of the installation document, **When** they look for how to work on the extension itself,
   **Then** the development install route is documented and identified as such.
4. **Given** the consumer-facing documents, **When** they are searched for a version literal, **Then** none is
   found — the documented address is version-free, and the pinning form is shown with a placeholder.

---

### Edge Cases

- **A file in the installable surface is committed executable.** Extraction does not restore execute
  permissions, so the bridge entry point arrives non-executable on a zip install. Covered by FR-016.
- **The extension's own prerequisite check rejects a non-executable entry point**, converting a survivable
  state into a hard failure and removing the operator's only workaround. Covered by FR-016.
- **The end-to-end test runs on a host newer than the declared floor.** Newer hosts restore execute permissions,
  so the test would pass while real users on a supported older host still fail. The test must exercise the floor,
  or it proves nothing about the population it claims to cover. Covered by FR-018.
- **The archive wraps its contents in a single root directory, or does not.** Settled by measurement during
  planning: **both** layouts install correctly, to the same 87-file tree. See `research.md` R1.
- **The stable download address is a redirect.** Settled by measurement: the host follows it. See `research.md`
  R2. This is what lets the documentation name a version-free address and stay free of version literals.
- **A URL outside a configured catalog triggers an interactive trust prompt.** Covered by FR-024 and FR-025.
- **The development route leaks this repository's `.git` into the consumer's tree.** A pre-existing defect that
  only became visible once the two routes were compared. Covered by FR-002a.
- **The exclusion list gains or loses a pattern.** The artifact's contents must follow, and the gates' notion of
  "correct contents" must follow with them, without any other file being edited.
- **A new file is added to a shipped directory.** It appears in the artifact automatically; no inventory is
  updated.
- **The same version is published twice.** The second attempt must not silently produce a differing artifact
  under an existing name.
- **The version in the manifest and the version the release is cut for disagree.** Publication refuses.
- **The artifact grows past the project's own ceiling while still being under the host's.** Publication refuses
  anyway — the project's ceiling is the alarm, not the wall.
- **The tree contains files that are neither shipped nor excluded by name** because the exclusion list works by
  directory. Nothing may be inferred from a file's absence from the exclusion list alone; membership of the
  surface is decided by the same evaluation the copy path performs.

## Requirements *(mandatory)*

### Functional Requirements

#### Composition of the artifact

- **FR-001**: The project MUST produce a distributable archive whose file set is exactly the **installable
  surface** — the manifest, the command documents, both script ports, the templates, and the consumer-facing
  documentation. The installable surface is defined as the repository's tracked files minus everything the
  exclusion list excludes, minus the exclusion list itself; it is 87 files across 17 directories today. Note
  that this is *not* literally "what `--dev` copies today": measurement during planning found `--dev` also
  copying the repository's `.git` directory (see FR-002a) and creating installer-generated staging after the
  copy. The archive carries the surface, and FR-002a makes the two routes agree.
- **FR-002a**: The exclusion list MUST be corrected to exclude the repository's own `.git` directory, so that
  the development install route and the archive route deliver byte-identical trees. This is a pre-existing
  defect of the development route, not a new requirement: measured during planning, `--dev` installs 6 165
  extra files and 38 MB of this project's git history into every consuming repository.
- **FR-002**: The archive's contents MUST be derived by evaluating `.extensionignore` against the repository.
  `.extensionignore` MUST remain the single source of truth for exclusions: no second exclusion list, and no
  hand-maintained inclusion list, may exist anywhere in the tree. A reviewer MUST be able to change what ships
  by editing `.extensionignore` alone.
- **FR-003**: The archive MUST carry both native ports in full — the Bash port for macOS and Linux and the
  PowerShell port for Windows — so that a single published artifact serves all three operating systems.
- **FR-004**: The archive MUST contain no development-only material: no test suites, no specifications, no
  architecture documentation, no CI definitions, no agent instruction files, no coverage or editor
  configuration.
- **FR-005**: The archive MUST extract into the directory layout the host's install expects. Whether that layout
  tolerates a single wrapping root directory or requires the manifest at the archive root MUST be determined by
  performing a real installation from a real archive and observing the result, and the answer MUST be recorded
  in the feature's design notes with the evidence. Reading the host's source code is not an acceptable substitute
  for that determination.
- **FR-006**: The archive MUST NOT contain the `.extensionignore` file itself, nor any file the host's install
  excludes unconditionally.

#### Version, single-sourced

- **FR-007**: The artifact's version MUST be read from the `extension.version` field of `extension.yml`, which
  remains the single source of truth. No other file may state the version literal, and the existing CI job that
  enforces this — *Version literal single-sourced*, which confines the literal to the manifest and the changelog
  — MUST remain green. (Requirement identifiers in this section are local to feature 026; the pre-existing
  constraint that job enforces is numbered FR-021/FR-022 in its own feature and is not the FR-021/FR-022 below.)
- **FR-008**: The artifact's file name and the release it is attached to MUST both be derived from that version
  rather than supplied independently.
- **FR-009**: If the version a release is cut for disagrees with the version in the manifest, publication MUST
  fail before anything is uploaded, naming both values.

#### Publication

- **FR-010**: Every published version MUST carry the artifact, and the consumer-facing documentation MUST be
  able to name a **version-free** download address that resolves to the newest published artifact, so that the
  documentation never contains a version literal (FR-007). A version-pinned address MUST also exist for each
  release, for operators who need to pin.
- **FR-011**: Publication MUST be automatic on the project's release action rather than a manual step, and it
  MUST be reproducible: building the artifact twice from the same commit yields the same file set.
- **FR-012**: Publication MUST NOT overwrite an already-published artifact for an existing version without
  failing loudly.

#### Gates — fail-closed, before publication

- **FR-013**: A gate MUST fail if the archive's entry count exceeds a project ceiling set well below the host's
  512, and the ceiling MUST be stated in one place with its rationale. The gate reports the measured count and
  the ceiling.
- **FR-014**: A gate MUST fail if any file that the reference copy path would install is absent from the
  archive, listing every missing path. The expected set MUST be obtained by exercising that copy path, never
  from a written inventory.
- **FR-015**: A gate MUST fail if the archive contains any file the exclusion list excludes, listing every
  offending path.
- **FR-016**: After an install performed by extracting the archive, the bridge MUST be runnable on all three
  operating systems **without depending on the executable bit having survived extraction**. The extension's own
  prerequisite check MUST NOT reject an intact but non-executable entry point, and the invocation form the
  command documents instruct MUST work in that state. Both ports MUST agree on this behaviour.
- **FR-017**: An end-to-end test MUST, on each of macOS, Linux and Windows: create a pristine consuming spec-kit
  repository, install the extension from the built artifact through the documented URL-install route, invoke the
  bridge's `--help` and require success, and read the consuming repository's lifecycle hook registry and require
  every event the manifest declares to be registered and enabled.
- **FR-018**: The end-to-end test MUST exercise the lowest spec-kit host version this extension declares it
  supports, not only the newest available, so that it covers the hosts that do not restore file permissions on
  extraction.
- **FR-019**: All gates MUST be fail-closed: an unexpected error, a missing artifact, or an unreadable manifest
  fails the gate rather than passing it, and a failing gate blocks publication.

#### Documentation

- **FR-020**: `README.md` and `INSTALL.md` MUST NOT contain any repository source-archive address, in any
  branch or tag form.
- **FR-021**: Every install command in the consumer-facing documentation MUST point at the published release
  artifact.
- **FR-022**: The development install route MUST remain documented, explicitly identified as the path for
  working on the extension rather than for consuming it.
- **FR-023**: A check MUST fail if a source-archive address reappears in any consumer-facing document, naming
  the file and line.
- **FR-024**: The installation documentation MUST state that installing from a URL not listed in a configured
  catalog prompts the operator to confirm an untrusted source, and MUST show what to answer. Measured during
  planning: the host refuses to proceed without an interactive `y`, so a reader who scripts the documented
  command without knowing this gets a silent `Aborted.` and no extension.
- **FR-025**: The end-to-end test MUST drive that confirmation non-interactively, and MUST serve the artifact
  over HTTP from a server it starts itself on a port the operating system assigns, recording that port for its
  own assertions. A `file://` address is not an option — measured during planning, the host rejects it as an
  invalid URL — and a fixed, well-known port would violate the constitution's test-isolation rule.

### Key Entities

- **Installable surface** — the set of repository files a consuming repository receives. Defined by evaluating
  `.extensionignore` against the tree; it currently comprises 87 files across 17 directories. It is the same set
  for both install routes, by construction rather than by coincidence.
- **Exclusion list** (`.extensionignore`) — the single source of truth for what is development-only. Consumed by
  the host's copy route today and, after this feature, by the artifact builder and by the gates as well.
- **Release artifact** — an archive of the installable surface, named from the manifest version, attached to a
  release, reachable both at a version-free address and at a version-pinned one.
- **Reference copy** — the file set produced by the development install route. Used as the *measured* expected
  contents in the completeness and purity gates, so that no written inventory can drift from reality.
- **Consumer fixture** — a pristine spec-kit repository created by the end-to-end test, with no prior knowledge
  of this extension, on which the install is performed.
- **Host floor version** — the lowest `specify` version the manifest declares support for. The population most
  exposed to the extraction-permission defect, and therefore the version the end-to-end test must cover.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Reinforced. The artifact is derived from the tree and from `.extensionignore`; the gates measure the artifact and the reference copy rather than trusting a declared inventory (FR-002, FR-014). No new authority is introduced. |
| II | Zero-Churn Idempotency | FR-011 requires a reproducible build — the same commit yields the same file set — and FR-012 forbids silently replacing a published artifact. Re-running publication for an unchanged version changes nothing. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-019 makes every gate fail-closed, and publication is a write. Hook behaviour is untouched: this feature changes how the extension arrives, not what it does once installed. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | Unaffected in substance, and improved in blast radius: the artifact carries only the installable surface, so no fixture, test recording, or development file can carry a secret into a consumer's tree. Publication uses the platform's own release credential, never a token in the tree. |
| V | Separation of Team Config / Local Binding / Secrets | Unaffected. The artifact contains no configuration instance — the templates it ships are the same ones the development route ships today. |
| VI | macOS / Linux / Windows Portability | Central. FR-003 requires both ports in one artifact; FR-017 requires the end-to-end install test on all three operating systems; FR-016 requires bridge runnability on all three after extraction, with both ports agreeing. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected. Nothing in this feature reads or writes Jira. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Unaffected — explicitly out of scope. The reconcile engine and the Jira sink are packaged, not modified. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected, and indirectly served: excluding `specs/` and `tests/` from the artifact keeps this project's own specification content out of consumers' trees. |
| X | Self-Healing Automatic Mirror | Unaffected. |
| XI | Universal Dry-Run and Auditability | The artifact builder MUST be inspectable without publishing — the gates run against a locally built artifact, and their reports name the offending entries rather than merely failing (FR-013 through FR-015). |
| XII | Quality and Catalog Publication | Directly served. This principle already requires installation to be documented via `specify extension add`; this feature makes that documented command work. Versioning stays SemVer and single-sourced (FR-007); the changelog obligation is unchanged; the three-OS suite obligation is extended by FR-017. |
| XIII | TDD With a Minimum 80% Coverage | Every gate and the packaging behaviour are specified with their failing cases first (US3's three deliberately wrong artifacts; FR-023's reintroduction case; FR-009's mismatch case). FR-016 fixes a defect and therefore ships with a regression test written before the fix. Tests identify state by paths they themselves created — the consumer fixture of FR-017 is created by the test, never a shared or well-known location. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The simplest solution that satisfies FR-002 is to derive the archive from the exclusion list already in the tree; no new manifest, no new configuration format, no new dependency is required by this specification. Any dependency introduced by the plan must be justified there. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Nothing here is speculative: every element traces to the broken install command. Deliberately excluded: signing or checksumming the artifact, publishing to a package registry, a `latest`-channel scheme beyond the single version-free address FR-010 needs, and any change to the 512 ceiling or the host CLI. |
| XVI | Human Readable — Readable by a Human Above All | The gates' failure messages must name the offending paths, the measured count, and the ceiling — never a bare non-zero exit (FR-013 to FR-015, FR-019). The documentation requirements (FR-020 to FR-022) exist entirely so that a first-time reader is not misled. |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On each of macOS, Linux and Windows, installing from the documented address into a pristine
  consuming repository succeeds, the bridge's `--help` exits successfully, and 100% of the lifecycle events the
  manifest declares are registered and enabled — including on the lowest declared-supported host version.
- **SC-002**: The published archive's entry count is at most half the host's ceiling, and is reported on every
  build. Against today's surface (~104 entries) that leaves at least 60% headroom below the project ceiling.
- **SC-003**: The difference between the archive's file set and the reference copy's file set is empty in both
  directions — zero missing files, zero extra files — measured, not asserted.
- **SC-004**: Changing what ships requires editing exactly one file. A reviewer can add or remove an exclusion
  pattern and observe the archive's contents change accordingly, with no other file in the repository modified.
- **SC-005**: Each of the four blocking conditions — too many entries, a missing surface file, a development
  file present, a version mismatch — is demonstrated to block publication by a test that fails before its gate
  exists and passes after.
- **SC-006**: The consumer-facing documents contain zero repository source-archive addresses and zero version
  literals, enforced by a check that fails on reintroduction.
- **SC-007**: The existing single-source-of-truth version gate remains green: the version literal appears only
  in the manifest and the changelog.
- **SC-008**: The time from cutting a release to having an installable published artifact is zero manual steps.

## Assumptions

- **The release trigger is the project's existing versioning action.** Publication is assumed to hang off the
  act of releasing a version (a version tag or the creation of a release), not off every push. Nothing in this
  specification requires an artifact per commit.
- **The version-free address is a redirect to the newest release's artifact**, and the artifact is therefore
  published under a name stable across releases *in addition to* a version-pinned name (FR-010). Whether the
  host follows that redirect is unknown here and is one of the things FR-005's real installation must settle; if
  it does not, the documented address becomes the version-pinned form and FR-010's documentation constraint is
  satisfied by a placeholder rather than a literal.
- **The project ceiling is 256 entries.** Half the host's limit, roughly two and a half times today's surface —
  low enough to fire long before a real failure, high enough not to trip on ordinary growth. The plan may revise
  the number; it may not remove the ceiling.
- **The end-to-end install test does not run on every pull request.** Three operating systems against real
  network downloads is expensive on this project's runners, and Windows runs here are slow and occasionally
  flaky. It is assumed to run on changes that can affect the artifact, on the release path, and on manual
  request — while the cheap gates (entry count, completeness, purity) run on every pull request.
- **`CHANGELOG.md` ships.** It is outside `.extensionignore` today and therefore part of the surface the
  development route already installs; this feature preserves that rather than deciding it afresh.
- **The consuming fixture repository is created by the test itself** and is disposable; no shared or
  pre-existing repository is used.
- **The upstream host's behaviour is discovered by measurement.** Two facts this specification depends on —
  the accepted archive layout and redirect-following — are properties of software this project does not own and
  may not modify. They are settled by performing real installs (FR-005), and the results are recorded so the
  next reader does not re-derive them.

## Out of Scope

- Modifying the upstream `specify` CLI in any way.
- Bypassing, raising, or otherwise defeating the 512-entry pre-extraction limit.
- Any change to the Jira reconcile engine, the sink, or the mapping behaviour.
- Signing, checksumming, or notarising the artifact.
- Publishing to any package registry or to the spec-kit community catalog.
- Reducing the repository's own file count, reorganising the source tree, or splitting the repository.
- Changing the set of files that ships. This feature changes how that set is delivered, not what it contains —
  with the single exception that the exclusion list may be corrected if the gates prove it currently
  mis-classifies a file.
