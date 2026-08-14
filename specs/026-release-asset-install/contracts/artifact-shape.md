# Contract: Artifact Shape and Bounds

**Feature**: 026 | **Satisfies**: FR-003, FR-004, FR-005, FR-011, FR-013, FR-019

Governs the bytes the builder writes. Everything here is checkable against a built archive without installing
it, which is what lets these gates run on every pull request.

## §1 Layout

**C1.1** — Every member is under a single root directory named `spec-kit-jira/`. Nothing sits at the archive
root except that directory.

**C1.2** — Below the root, paths mirror the repository exactly: `spec-kit-jira/extension.yml`,
`spec-kit-jira/scripts/bash/…`, `spec-kit-jira/commands/…`, and so on.

**C1.3** — *Provenance of the choice*: both the wrapped layout and a flat one (manifest at the archive root)
were built and installed in Phase 0, and **both work** — each produced the identical 87-file tree, the identical
seven-event hook registry, and the identical agent-command registration. The wrapped form is chosen because it
is the shape GitHub's own source archives take, so it is the better-trodden path in the host, and because a
human who unzips the artifact by hand gets one directory rather than 87 loose entries. The flat form is the
recorded fallback: switching is a one-line change and no other clause here depends on the choice.

**C1.4** — Directory entries are present for every directory implied by a member path. The host tolerates their
absence, but their presence is what makes the entry count an honest predictor of what the host will count.

## §2 Contents

**C2.1** — Contents equal the derivation of `surface-derivation.md` §2, exactly, in both directions.

**C2.2** — Both native ports are present in full: `scripts/bash/` and `scripts/powershell/`. A single published
artifact serves macOS, Linux and Windows; there is no per-platform artifact.

**C2.3** — No development material: no `tests/`, `specs/`, `docs/`, `.specify/`, `.github/`, `.claude/`,
`.tokensave/`, `packaging/`, `coverage/`, no editor or linter configuration, no `AGENTS.md`/`CLAUDE.md`, no
`.gitattributes`, and no `.git/`.

**C2.4** — `.extensionignore` is not a member.

## §3 Bounds

Every bound below is asserted by the gate, not assumed. The host's values are on the left; ours are what the
gate enforces.

| host bound | host value | gate enforces | today |
| --- | ---: | ---: | ---: |
| `MAX_ZIP_ENTRIES` | 512 | **≤ 256** | 105 |
| `MAX_ZIP_TOTAL_BYTES` (uncompressed) | 50 MiB | ≤ 25 MiB | 1.64 MiB |
| `MAX_ZIP_MEMBER_BYTES` | 10 MiB | ≤ 5 MiB | 145 KiB |
| `MAX_DOWNLOAD_BYTES` | 50 MiB | ≤ 25 MiB compressed | 0.5 MiB |
| `MAX_ZIP_PATH_BYTES` | 4096 | ≤ 1024 | 48 |
| `MAX_ZIP_COMPONENT_BYTES` | 255 | ≤ 128 | 25 |

**C3.1** — The entry ceiling is **256**: half the host's, and about two and a half times today's archive. It
fires on a doubling of the shipped surface — a deliberate architectural change worth a conversation — long
before anything a user would experience.

**C3.2** — The ceiling and each bound are stated in exactly one place in the codebase, with the rationale
beside them. A number repeated in a workflow and in a script is two numbers.

**C3.3** — No member path may contain a character the host rejects on Windows (`<`, `>`, `:`, `"`, `|`, `?`,
`*`) or a reserved device name in any component. A Windows-hostile filename would otherwise be discovered only
by a Windows consumer, after publication.

**C3.4** — Every member uses a compression method the host accepts: stored or deflated.

**C3.5** — A bound failure reports the measured value, the ceiling, and — where the bound is per-member — the
offending member. `too many entries` without the count fails Principle XVI.

## §4 Determinism

**C4.1** — Building twice from the same commit produces **byte-identical** archives (FR-011, Principle II).

**C4.2** — This requires: members emitted in sorted order; modification timestamps normalised to a fixed value
rather than taken from the filesystem; and permission bits normalised. Modes are discarded on extraction
anyway — measured in research R3 — so recording the real ones buys nothing and costs reproducibility.

**C4.3** — Determinism is asserted by a test that builds twice and compares digests, not by inspection.

## §5 Fail-closed

**C5.1** — The builder runs under `set -euo pipefail`. Any failing step aborts before an archive is written; a
partially written archive is removed rather than left on disk.

**C5.2** — The builder refuses to run against a repository with a derived surface of zero files.

**C5.3** — The gate treats "cannot determine" as failure in every case: unreadable archive, unparseable
manifest, `git` error, absent reference install.
