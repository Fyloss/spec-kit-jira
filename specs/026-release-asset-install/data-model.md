# Data Model — 026 Release Asset Install

This feature has no persistent state and no schema. What it does have is a small set of **derived sets and
identifiers** whose relationships are the whole design: if any two of them are allowed to be stated
independently, they drift, and the feature has failed. This document names them, says where each one comes
from, and records the invariant that binds it to the others.

---

## Installable surface

**What it is**: the set of repository files a consuming repository receives.

**Where it comes from — the only place**: derived, never declared.

```
surface = tracked_files − excluded(tracked_files) − { .extensionignore }

where  tracked_files  = git ls-files
       excluded(S)    = git -c core.excludesFile=.extensionignore \
                            check-ignore --no-index --stdin  < S
```

**Current value**: 87 files across 17 directories.

| top-level | files |
| --- | ---: |
| `scripts/` (both ports) | 76 |
| `commands/` | 3 |
| `templates/` | 3 |
| `extension.yml`, `README.md`, `INSTALL.md`, `CHANGELOG.md`, `LICENSE` | 5 |

**Invariants**:

- **S1** — The surface is a pure function of the working tree and `.extensionignore`. No other file may
  influence it. *Verified by*: changing a pattern in `.extensionignore` changes the surface and nothing else
  in the repository is edited (SC-004).
- **S2** — The surface equals the tree a `--dev` install produces, once FR-002a's `.git/` exclusion is in
  place. *Verified by*: performing that install into a temporary consumer repository and diffing.
- **S3** — `.extensionignore` itself is never a member. The host excludes it unconditionally; the builder
  subtracts it explicitly so the two agree for the same reason rather than by luck.

---

## Exclusion list — `.extensionignore`

**What it is**: the single source of truth for what is development-only. Gitignore syntax, evaluated by git.

**Consumers** (three, after this feature): the host's `--dev` copy route, the archive builder, and the gates.
All three read the same file through the same engine.

**Changes this feature makes** (two entries, both justified in the file's own comment style):

| entry | why |
| --- | --- |
| `.git/` | The `--dev` route copies it — 6 165 files, 38 MB of this project's history — into every consuming repository. Pre-existing defect; see research R5. |
| `packaging/` | The artifact builder and its gates. Development tooling a consumer cannot use and must not receive (Principle XV). |

**Invariant**:

- **E1** — No other file in the repository may enumerate shipped or excluded paths. *Verified by*: a review
  rule and by the absence, by construction, of any inclusion list in `packaging/`. This is the invariant the
  entire feature is organised around.

---

## Release artifact

**What it is**: a zip archive of the installable surface.

| property | value | source |
| --- | --- | --- |
| layout | every member under a single `spec-kit-jira/` root | research R1 (both layouts measured; wrapped chosen) |
| entries | surface files + their directories + the root = 105 today | derived |
| compression | deflate (stored for incompressible members) | the host accepts only these two methods |
| member order | sorted, deterministic | required by II (zero-churn) |
| timestamps / modes | normalised to fixed values | required by II; modes are discarded on extraction anyway (research R3) |

**Two names, one archive** — both attached to each release:

| name | address | purpose |
| --- | --- | --- |
| `spec-kit-jira.zip` | `…/releases/latest/download/spec-kit-jira.zip` | the documented, version-free address. Resolves by redirect to the newest release (research R2). |
| `spec-kit-jira-<version>.zip` | `…/releases/download/v<version>/spec-kit-jira-<version>.zip` | the immutable pinned address, for operators who need to pin. |

**Invariants**:

- **A1** — Contents equal the surface, exactly, in both directions: nothing missing, nothing extra.
- **A2** — Every host pre-extraction bound is satisfied with margin, and the project's own tighter ceiling
  holds: **≤ 256 entries** (against the host's 512), ≤ 50 MiB uncompressed, no member > 10 MiB, no member path
  containing a Windows-invalid character or reserved device name.
- **A3** — Building twice from the same commit produces byte-identical archives.
- **A4** — The two names carry the same bytes.

---

## Version

**What it is**: the extension's SemVer version.

**Where it comes from — the only place**: the `extension.version` field of `extension.yml`.

**Read by**: the builder (to name the pinned asset), the release workflow (to name the release), the existing
*Version literal single-sourced* CI job (to prove nothing else states it). One parsing expression, shared —
the same `sed` form that job already uses — so there is one reading behaviour, not two.

**Invariants**:

- **V1** — The literal appears in `extension.yml` and `CHANGELOG.md` and nowhere else in the tree. The
  builder, the workflow, `README.md` and `INSTALL.md` all compute or avoid it. *Verified by*: the existing gate,
  which must remain green.
- **V2** — The version a release is cut for equals the manifest's version. *Verified by*: a cross-check that
  runs before any upload and names both values on mismatch (FR-009).
- **V3** — A published version's assets are never silently replaced (FR-012).

---

## Reference copy

**What it is**: the tree produced by `specify extension add --dev <repo>` into a throwaway consumer repository.
Used by the completeness and purity gates as the *measured* expectation.

**Why it exists as an entity**: FR-014 forbids a written inventory. The reference copy is what replaces it —
the gate's notion of "correct" is obtained by running the other install route, so the two routes cannot
disagree without the gate saying so.

**Known contaminants, both handled**:

| contaminant | count | handling |
| --- | ---: | --- |
| `.git/` copied from this repository | 6 165 files | removed at the source by FR-002a — the exclusion list gains `.git/` |
| `.specify-dev/agent-commands/…` generated by the installer *after* the copy | 3 files | not part of the surface and never in the archive; the gate compares against the surface derivation, and the reference copy corroborates it |

---

## Consumer fixture

**What it is**: a pristine spec-kit repository the end-to-end test creates for itself.

**Lifecycle**: created by `specify init --here` in a directory the test made, installed into, asserted on,
discarded. Never a shared or pre-existing location.

**Constitutional constraint (XIII)**: the test identifies everything it observes by an identifier it recorded —
the directory path it generated, the port the operating system assigned to the server it started, the process
id of that server. Never a name pattern, never a fixed well-known port. A fixed port would make the test
correct only when it runs alone.

**Assertions made against it**:

1. the install command exits successfully;
2. `.specify/extensions/jira/` contains exactly the surface;
3. the bridge answers `--help` with exit 0, invoked exactly as the command documents instruct;
4. `.specify/extensions.yml` registers all seven declared lifecycle events with `enabled: true`.

---

## Host floor version

**What it is**: the lowest `specify` version the manifest declares support for — `>=0.13.0` today.

**Where it comes from**: `requires.speckit_version` in `extension.yml`. Read by the end-to-end workflow rather
than written into it, so the tested floor cannot drift from the declared one.

**Why it is an entity and not a constant**: it is the whole reason the end-to-end test means anything. Measured
in research R3, a zip install leaves the bridge at `0644` on 0.13.0 and at `0755` on 0.14.4 — so a matrix
pinned to "current" is green on a population that is not the one at risk.

---

## How they fit together

```
.extensionignore ──┐
                   ├─(git ignore engine)─→ installable surface ─→ release artifact ─→ two named assets
git ls-files ──────┘                              │                      │
                                                  │                      ├→ gates: A1 completeness & purity
                                                  │                      ├→ gates: A2 host bounds + 256 ceiling
                                                  │                      └→ gates: A3 reproducibility
                                                  └─(--dev install)→ reference copy ─→ corroborates A1

extension.yml ──→ version ──→ pinned asset name, release name, V2 cross-check
              └─→ floor version ──→ e2e host matrix dimension
```

Read the diagram for the property that matters: every arrow originates at a file already in the tree. There is
no box labelled "the list of things we ship".
