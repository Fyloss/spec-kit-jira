# Contract: Version Resolution and Publication

**Feature**: 026 | **Satisfies**: FR-007, FR-008, FR-009, FR-010, FR-011, FR-012, FR-019, FR-020, FR-021,
FR-022, FR-023, FR-024

Governs how the version is read, how a release is cut, what is attached to it, and what the documentation is
allowed to say.

## §1 Version resolution

**C1.1** — The version is read from the `extension.version` field of `extension.yml` and from nowhere else.

**C1.2** — There is **one** parsing expression, shared by the builder and the release workflow — the same form
the existing *Version literal single-sourced* CI job already uses. It matches the indented `version:` key,
which is what distinguishes it from the top-level `schema_version` and from `requires.speckit_version`.

**C1.3** — An absent or empty version field fails, loudly, before anything else runs.

**C1.4** — No file added or modified by this feature may contain the version literal. The builder computes it;
the workflow computes it; `README.md` and `INSTALL.md` avoid it entirely by naming a version-free address
(§3). The existing gate, which scans the whole tree and exempts only `extension.yml` and `CHANGELOG.md`, must
stay green — and `packaging/` is deliberately *not* exempted from that scan, so the code most tempted to
hard-code a version is the code most closely watched.

## §2 Publication

**C2.1** — Publication is triggered by a version tag. It is never triggered by an ordinary push, and it is
never a manual assembly step (SC-008).

**C2.2** — Before any upload, the version the tag names and the version the manifest states are compared. A
mismatch fails and names **both** values. This is the one place a human states a version outside the manifest,
so it is the one place the cross-check belongs.

**C2.3** — The gates of `artifact-shape.md` and `surface-derivation.md` run against the built archive before
any upload. A failing gate blocks publication; there is no override path.

**C2.4** — Two assets are attached to the release, carrying identical bytes:

| asset name | resolves at | purpose |
| --- | --- | --- |
| `spec-kit-jira.zip` | `…/releases/latest/download/spec-kit-jira.zip` | the documented, version-free address |
| `spec-kit-jira-<version>.zip` | `…/releases/download/v<version>/spec-kit-jira-<version>.zip` | the immutable pinned address |

**C2.5** — Publishing over an existing release's assets fails loudly rather than replacing them silently
(FR-012, Principle II).

**C2.6** — The workflow is fail-closed throughout: an unreadable manifest, a failed build, a failed gate, or a
failed upload leaves the release without a partially-correct asset.

**C2.7** — The version cross-check, the asset naming and the overwrite refusal are implemented in
`packaging/publish-artifact.sh`, not in the workflow. The workflow supplies the tag, the archive path and the
credential, and treats a non-zero exit as blocking. This is what makes C2.2, C2.4 and C2.5 reachable by a test
that does not require cutting a release — written into `release.yml` they would be exercisable only by tagging,
and Constitution XIII requires the failing test first.

> **OPEN — who creates the release.** C2.1 triggers publication on a version tag, but `…/releases/latest/download/…`
> (FR-010) resolves against a **Release object**, not a tag, and C2.5's refusal presumes one already exists. If
> the maintainer creates the release by hand, SC-008's "zero manual steps" is false; if the workflow creates it
> when absent, C2.5 must refuse on the *asset* rather than on the release. Settle before T043.

## §3 What the documentation may say

**C3.1** — `README.md` and `INSTALL.md` contain **no** repository source-archive address, in any branch or tag
form. The pattern that must never reappear is `archive/refs/`.

**C3.2** — The primary, paste-able install command names the version-free address:

```
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip
```

*Provenance*: measured in research R2 — the host follows the redirect this address relies on.

**C3.3** — The pinned form is documented too, with a **placeholder** rather than a literal:
`…/releases/download/v<X.Y.Z>/spec-kit-jira-<X.Y.Z>.zip`. This is what keeps C1.4 satisfiable. A command a
reader cannot paste is how the current defect went unnoticed, so the pasteable one is primary and the
placeholder one is secondary — not the other way round.

**C3.4** — The documentation states that a URL outside a configured catalog prompts for confirmation of an
untrusted source, and shows what to answer (FR-024). *Provenance*: measured in research R8 — with no stdin the
install prints `Aborted.` and does nothing, which in a script reads as a silent no-op.

**C3.5** — The `--dev` route remains documented, explicitly labelled as the route for **developing the
extension**, not for using it.

**C3.6** — A check fails if `archive/refs/` reappears in any consumer-facing document, naming file and line.
It runs on every pull request, alongside the version-literal gate.

## §4 What the end-to-end proof must cover

**C4.1** — The matrix is two-dimensional: {macOS, Linux, Windows} × {floor host, current host}.

**C4.2** — The floor is read from `requires.speckit_version` in the manifest, never written into the workflow,
so the tested floor cannot drift from the declared one.

**C4.3** — The floor dimension is not optional and may not be reduced to the current host "because it passes".
Measured in research R3: the defect FR-016 fixes is invisible on any host above 0.14.3. A matrix pinned to the
newest `specify` is green against a population that is not the one at risk.

**C4.4** — Each job asserts, in order: the install command exits 0; the installed tree equals the surface; the
bridge answers `--help` with exit 0, invoked exactly as the command documents instruct; and all seven declared
lifecycle events are registered with `enabled: true`.

**C4.5** — The artifact is served over HTTP by a server the job starts, on a port the operating system assigns
and the job records. `file://` is not available — measured in research R7, the host rejects it as an invalid
URL — and a fixed well-known port is forbidden by Constitution XIII, which requires state to be identified by
a recorded identifier rather than by a machine-wide assumption.

**C4.6** — The confirmation prompt of C3.4 is answered on stdin. There is no `--yes` option; the full option
set of `specify extension add` is `--dev`, `--from`, `--force`, `--priority`.

**C4.7** — Each job asserts only its own outcomes and shares no state with the existing suites, so its signal
stays readable against a Windows baseline that is independently red.
