# Contract: Surface Derivation

**Feature**: 026 | **Satisfies**: FR-001, FR-002, FR-002a, FR-006, FR-014, FR-015

Governs how anything in this repository decides which files are shipped to a consuming repository. Binds the
artifact builder (`packaging/build-artifact.sh`), the content gates (`packaging/verify-artifact.sh`), and any
future consumer of that question.

## §1 The single statement

**C1.1** — `.extensionignore` is the only file in the repository that may state what is shipped or excluded.
No other file may contain a path list, a glob list, a `find … -prune` expression, or any other enumeration
serving that purpose.

**C1.2** — This holds "by construction", not "by convention": a reviewer must be able to change what ships by
editing `.extensionignore` and nothing else, and the change must be visible in the artifact. A second list that
happens to agree today does not satisfy C1.1.

**C1.3** — `.extensionignore` gains exactly two entries in this feature: `.git/` (FR-002a) and `packaging/`.
Each carries the explanatory comment the file's existing style requires — that file is read by humans deciding
what a consumer receives, and an uncommented pattern there is a future mistake.

## §2 The derivation

**C2.1** — The surface is computed as:

```
git ls-files                                            # candidates
  | git -c core.excludesFile=.extensionignore \
        check-ignore --no-index --stdin                 # the excluded subset
```

keeping the candidates that the second command does not report, then removing `.extensionignore` itself.

**C2.2** — The exclusion semantics are **delegated to git**, never reimplemented. No shell or PowerShell code
may interpret gitignore syntax — anchoring, `!` negation, directory-only patterns, order precedence. The reason
is not elegance: a reimplementation is a second *implementation* of C1.1's single statement, and it drifts in
the same silent, asymmetric way a second list would.

**C2.3** — Untracked files are never in the surface. `git ls-files` is the candidate set, so a file that exists
only in a working tree cannot reach a consumer. This also means `.git/` never enters the archive by this
route — the `.git/` exclusion of C1.3 exists for the `--dev` copy route, which does not go through git.

**C2.4** — The derivation runs from the repository root and is independent of the caller's working directory.

## §3 What the derivation must equal

**C3.1** — The derived surface MUST equal the tree that `specify extension add --dev` installs into a consuming
repository, member for member. *Measured in Phase 0*: it does, exactly, once `.extensionignore` excludes
`.git/` — 87 files, 17 directories.

**C3.2** — The derived surface MUST equal the archive's contents, member for member, after stripping the
archive's single root directory. Both directions are asserted: a missing file and an extra file are distinct
failures with distinct messages.

**C3.3** — The expected set in C3.1 is obtained **by performing that install**, never from a file checked into
the repository. A gate that compares the archive against a committed inventory does not satisfy FR-014,
whatever its contents.

## §4 Failure reporting

**C4.1** — A completeness failure names every missing path, one per line, under a heading that says the archive
is missing files the reference install produced.

**C4.2** — A purity failure names every extra path, one per line, under a heading that says the archive
contains files the exclusion list excludes.

**C4.3** — Neither failure may report only a count, and neither may report only the first offender. A gate that
must be run repeatedly to enumerate its own findings fails Principle XVI.

**C4.4** — Every gate is fail-closed: an unreadable `.extensionignore`, an absent archive, a `git` invocation
that errors, or an empty derived surface fails the gate. An empty surface in particular must never be read as
"nothing is missing".
