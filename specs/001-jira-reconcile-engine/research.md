# Phase 0 Research: Jira Reconcile Engine

**Feature**: 001-jira-reconcile-engine | **Date**: 2026-07-23

This document resolves every technical unknown implied by the Technical Context. The spec is highly constrained, so most "unknowns" are best-practice/endpoint decisions rather than open questions. Each entry records the Decision, its Rationale, and the Alternatives considered. Jira Cloud REST API details are version-sensitive; because all metadata is discovered at runtime (Constitution VII), the exact endpoint choices below are sink-internal and verifiable against a live instance in the implementation phase.

---

## 1. Project-style detection (US2 / FR-004)

**Decision**: The first discovery call is `GET /rest/api/3/project/{projectIdOrKey}`. Read the `style` attribute: `"classic"` → company-managed, `"next-gen"` → team-managed. Cross-check with the boolean `simplified` (`true` → team-managed). Do **not** fail closed if `style` is missing; fall back to `simplified`, and if both are absent default to company-managed (the scheme-based path is the more capable superset and its discovery calls degrade gracefully).

**Rationale**: The spec mandates reading the style attribute *first* and following the style-appropriate path (`classic`/`next-gen`). `style` is the documented, human-meaningful attribute; `simplified` is the machine boolean that has existed longest, so cross-checking both is robust across API revisions.

**Alternatives considered**: Inferring style from the presence of scheme endpoints (rejected — indirect, brittle, and violates "detect style first"). Asking the operator (rejected — the value is API-readable, so US1 forbids a question here).

---

## 2. Company-managed metadata discovery (FR-005)

**Decision**: Discover through site-level, scheme-based endpoints:
- Issue types + required fields per type: `GET /rest/api/3/issue/createmeta/{projectIdOrKey}/issuetypes` then `.../issuetypes/{issueTypeId}` (the current, non-deprecated createmeta shape).
- Statuses per issue type: `GET /rest/api/3/project/{projectIdOrKey}/statuses`.
- Transitions: discovered per issue at reconcile via `GET /rest/api/3/issue/{key}/transitions` (transitions are workflow-and-status-contextual, not global).
- Priorities: `GET /rest/api/3/priority`.
- Fields: `GET /rest/api/3/field`.

**Rationale**: Company-managed projects share site-level schemes, so scheme endpoints return the authoritative set. The classic `GET /rest/api/3/issue/createmeta` (all-projects) is deprecated in favour of the per-project `issuetypes` sub-resource; the plan targets the current shape.

**Alternatives considered**: The deprecated all-projects `createmeta` (rejected — deprecated, over-fetches). Hard-coding the default Atlassian scheme (rejected — Constitution VII forbids literal defaults).

---

## 3. Team-managed metadata discovery + estimation-field heuristic (FR-006)

**Decision**: For `next-gen` projects, discover from project-scoped endpoints, treating issue types and fields as project-owned objects (not the site-level objects of the same name). Read workflows per issue type. Treat the hierarchy as limited to **Epic (parent)** and **Sub-task (child)** only.

For the **estimation field**, run a documented discovery heuristic over the project's own fields (from the project-scoped field/createmeta response), never a literal field name compiled into a script:
1. Collect the project's own numeric estimation-capable fields (schema type `number`, and the time-tracking `timeoriginalestimate` where relevant).
2. Rank candidates by a documented signal set: field appears in the project's own createmeta (not merely site-global), schema custom type is the team-managed estimation type (`...:gh-sprint-...`/story-point-estimate family), and the display name matches a *candidate* pattern (the conventional "Story point estimate" MAY be proposed as a candidate but MUST NOT be assumed).
3. Present the ranked candidates to the operator via US1's closed enumerated question and persist the operator's confirmed choice. Never silently pick the global "Story Points" custom field.

**Rationale**: Team-managed projects expose project-scoped, project-owned fields; the team-managed estimation field is distinct from the global Story Points custom field and its id varies per project. A rank-then-confirm heuristic keeps the script free of any literal field name (Constitution VII, FR-006) while still guiding the operator to the right field.

**Alternatives considered**: Matching the literal name "Story point estimate" (rejected — FR-006 forbids a compiled literal; names are localisable/renamable). Using the global Story Points custom field id (rejected — it is the wrong field for team-managed, the predecessor's bug). Auto-selecting the top candidate without confirmation (rejected — US1 requires a closed question for any operator decision).

---

## 4. Status classification into four categories (FR-011 / FR-034)

**Decision**: Classify every project status using Jira's `statusCategory` as the objective signal, refined by operator confirmation where ambiguous:
- Jira `statusCategory.key = "done"` → candidate `post-scope` (work past the last mapped phase) unless the operator maps it to a phase (then `mapped`).
- `statusCategory.key = "indeterminate"` / `"new"` mapped to a spec phase by the operator → `mapped`.
- A status the operator designates as a stop state (cancelled/rejected/won't-do) → `halted`.
- Any status not classified by the operator → `unknown`.

The phase→status mapping is many-to-one (two consecutive phases resolving to one status produce no transition, FR-011). Classification is persisted per project.

**Rationale**: `statusCategory` (`new`/`indeterminate`/`done`) is the only workflow-agnostic, discoverable signal Jira exposes, so it seeds the classification; but "done" is not always "post-scope" and stop states are not discoverable as such, so the operator confirms via US1. This keeps drift evaluation category-aware (FR-034) without hard-coding status names (Constitution VII).

**Alternatives considered**: Classifying by status name (rejected — names vary, Constitution VII). Treating every `done` status identically (rejected — conflates post-scope completion with halted/cancelled, which FR-034 distinguishes with different behaviours).

---

## 5. Ticket identity marker (FR-044 / Constitution II)

**Decision**: Bind a Jira ticket to a spec using an **issue entity property** (`PUT /rest/api/3/issue/{key}/properties/{propertyKey}`, key e.g. `spec-kit-jira`), whose JSON value records: repository identifier, spec slug (`NNN-feature`), project key, and ticket origin (`bridge-created` vs `human`). Scope the property per project so two teams' projects can never collide (FR-044). A mirrored, human-visible label (e.g. `speckit:001-feature`) MAY be written for discoverability but is **never** the identity source of truth.

**Rationale**: Entity properties are server-side, not shown in the editable summary/labels UI, and survive spec-folder renames (identity resolves from the stored marker, not the path — Edge Cases). Constitution II forbids identity keyed on any operator-editable display name; a label alone is editable, an entity property is the stable key.

**Alternatives considered**: Labels as the identity key (rejected — user-editable, Constitution II). Storing identity only on the spec side (rejected — cannot survive a folder rename nor detect a ticket claimed by another spec, US10/FR-051). A hidden custom field (rejected — requires per-project field creation, violates KISS and "no schema assumptions").

---

## 6. Rich ticket content: ADF rendering (US3 / FR-013–FR-018)

**Decision**: Render descriptions as **Atlassian Document Format (ADF)** (required by REST API v3). Map neutral-document sections to ADF nodes:
- Title: deterministic ladder in the engine (explicit `Title:` → H1 → user-story section title → first non-empty paragraph → folder slug), never from `## Summary`.
- Description: a structured ADF document synthesised from the need statement + context; never empty.
- Acceptance criteria → ADF `panel` node containing Given/When/Then blocks.
- Figma links / UX-UI guidance → a distinct "Design" ADF `heading` + section.
- Priority: map spec P1/P2/P3 → project priority field by logical name.
- Estimation: written to the discovered estimation field **on create only**, never re-sent on update (FR-018).

The neutral→ADF conversion lives in the sink (`adf.sh`/`Adf.psm1`); the engine emits only neutral, Jira-agnostic content blocks.

**Rationale**: ADF is mandatory for v3 rich content; keeping ADF construction in the sink preserves the engine's zero-Jira-knowledge rule (Constitution VIII — ADF node names are Atlassian-specific identifiers). Panels and headings give a human reader the named sections Constitution XVI requires.

**Alternatives considered**: Wiki-markup/plain-text descriptions (rejected — v3 requires ADF for structured content; plain text loses panels/Gherkin formatting, Constitution XVI). Building ADF in the engine (rejected — leaks Atlassian identifiers into the neutral layer, fails the Principle VIII grep).

---

## 7. Credential resolution + argv exclusion (NFR-3 / Constitution IV)

**Decision**: Resolve the token in order **environment variable → OS secret manager → gitignored `.env`**:
- macOS Keychain via `security find-generic-password`; Linux libsecret via `secret-tool lookup`; Windows Credential Manager via PowerShell's `Get-StoredCredential`/`CredRead` (or the `Microsoft.PowerShell.SecretManagement` vault when present).
- **Bash argv exclusion**: pass the `Authorization` header to `curl` via `--config /dev/stdin` (or a `--config -` fed on stdin), so the header value never appears in the process argument list. Never use `-H "Authorization: ..."` on the command line.
- **PowerShell**: the token stays in-process (`Invoke-RestMethod -Headers`); no child process sees it.
- The token is never logged, echoed in errors, or visible under `set -x`/`-Verbose`; error paths scrub it.

**Rationale**: NFR-3 is eliminatory — any token in argv/log/error/trace is a failing test. `curl --config` on stdin is the established argv-safe mechanism; PowerShell's in-process header keeps it out of any argv entirely.

**Alternatives considered**: `-H` header on argv (rejected — visible in `ps`, NFR-3 violation). Env-var interpolation into a here-string that `set -x` would echo (rejected — appears in traces). Writing the header to a temp file on disk (rejected — a token touching the tree violates Constitution IV even transiently; stdin avoids disk).

---

## 8. Rate-limiting & fail-closed exit codes (FR-032 / Constitution III)

**Decision**: Bounded retry with exponential backoff honouring `Retry-After` on HTTP 429; on exhaustion, zero writes for the affected spec and a non-zero exit. Exit codes escalate **monotonically** (a more severe failure never maps to a lower code), e.g. `0` success · `1` generic/usage · `2` per-spec fail-closed (unreliable read: network/404/429-exhausted) · `3` auth failure (401/403) · `4` capability/config refusal (e.g. team-managed level-above-Epic) · a dedicated code for a **privacy BLOCK** (highest, distinct). The exact numeric table is fixed in `contracts/cli-contract.md` and asserted byte-identically across both ports.

**Rationale**: Constitution III mandates zero writes + a documented, monotonic exit code on unreliable reads; a single documented table shared by both ports is what the conformance corpus asserts (NFR-1).

**Alternatives considered**: Unbounded retry (rejected — can hang a hook; Constitution III wants fail-closed). Best-effort partial writes on 429 (rejected — Edge Cases require "fails that spec closed, never a partial write"). Ad-hoc per-port codes (rejected — breaks byte-identical parity, NFR-1).

---

## 9. Managed-section & README-block byte-exact editing (US5 / US7 / FR-025)

**Decision**: Both the Jira managed panel (US7) and the README managed block (US5) use explicit start/end markers and are edited by **byte-exact splice**: locate markers, replace only the bytes strictly between them, preserve every byte outside verbatim (including trailing whitespace and line endings). README block content adopts the host file's **dominant line-ending convention** (CRLF if the file is predominantly CRLF, else LF; a newly created README uses LF). Markers carry the version from the single source (FR-021). Malformed markers (start-without-end, nested, duplicated) → **zero writes** + a located error naming line numbers. Both ports MUST produce byte-identical block content for identical inputs on identical hosts.

**Rationale**: FR-025/FR-027 and SC-005 require byte-preservation outside the block, CRLF-safety, and located refusal on malformed markers. A splice-not-reparse approach is the only way to guarantee "every byte outside is unchanged". Dominant-line-ending detection prevents mixed-ending files.

**Alternatives considered**: Regex whole-file rewrite (rejected — risks reflowing untouched content, fails byte-preservation). Normalising all endings to LF (rejected — would rewrite CRLF bytes outside the block, SC-005 violation). Guessing boundaries on malformed markers (rejected — FR-027 forbids guessing).

---

## 10. `after_*` hook registration & health (US9 / Constitution X)

**Decision**: The config command registers hooks idempotently in `.specify/extensions.yml` under `hooks.after_specify|after_clarify|after_plan|after_tasks|after_implement|after_analyze`, each pointing at the reconcile command with `enabled: true` by default. Registration is set-not-append (re-running produces no duplicate entries). Every command execution checks hook health (present/absent/disabled) and reports it in the run summary; a missing hook is one-command repairable and is reinstalled automatically by the config command. A hook explicitly `enabled: false` is preserved forever across upgrade/reinstall/repair.

**Rationale**: Constitution X and FR-045–FR-048 require idempotent, self-healing, disable-respecting hooks. The `.specify/extensions.yml` `hooks.after_*` shape is the format the Spec Kit harness already reads (confirmed by the plan/tasks skills' own hook-scanning logic), so writing there wires the bridge into the lifecycle without touching core.

**Alternatives considered**: A separate hook config inside the extension folder (rejected — reinstall could strip it, Constitution V; the harness reads `.specify/extensions.yml`). Appending hook entries (rejected — creates duplicates on re-run, Constitution X). Re-enabling a disabled hook during repair (rejected — FR-048 forbids it forever).

---

## 11. Byte-identical output across ports (Constitution VI / NFR-1)

**Decision**: Any output written into the repository or crossing platforms — the neutral interchange document, run summaries, the README block, request JSON bodies — is produced through a **canonical serialiser**: stable key ordering, no insertion of trailing newlines that differ per port, UTF-8, and explicit line-ending control. PowerShell uses a canonical JSON converter that preserves insertion order and matches the Bash `jq` output byte-for-byte (including URL-encoding rules: `jq @uri` with `%20`→`+` normalisation on query strings). Divergence is a failing conformance test, not a documented quirk.

**Rationale**: Constitution VI requires byte-identical cross-platform output and NFR-1 makes any divergence a failing test. A shared canonical serialisation contract is the only way two independent runtimes converge to identical bytes.

**Alternatives considered**: Per-port native JSON (rejected — `ConvertTo-Json` and `jq` differ in spacing/escaping/order, breaking byte-parity). Normalising only at test time (rejected — the constitution requires the *written* bytes to match, not a normalised comparison).

---

## 12. Coverage tooling (Constitution XIII)

**Decision**: Statement coverage on the mocked unit suites only. **PowerShell**: Pester's built-in `CodeCoverage`. **Bash (PRIMARY)**: `kcov`. **Bash FALLBACK** (only on recorded kcov unviability on a CI platform): requirement→scenario traceability — every functional requirement exercised by at least one bats or conformance scenario, checked in CI. 80% is a blocking merge gate; critical paths (drift, idempotency, fail-closed, privacy guard, credential resolution) target near-100%.

**Rationale**: Constitution XIII names exactly these tools and the fallback; kcov is the sole justified dev-only dependency (Complexity Tracking). Computing on mocked suites keeps the gate runnable on fork PRs without credentials (Constitution XII).

**Alternatives considered**: bashcov/other Bash coverage (rejected — Constitution names kcov as PRIMARY). Coverage on live suites (rejected — fork PRs lack credentials; Constitution XII forbids a credential-dependent PR gate).

---

## 13. Engine/sink boundary enforcement (Constitution VIII)

**Decision**: Two CI greps enforce the boundary: (1) no `engine/` script contains a `source`/`.` (Bash) or `Import-Module`/dot-source (PowerShell) statement referencing the `sink/` directory; (2) no `engine/` script contains any Atlassian-specific identifier (issue-key regex, `atlassian.net`, `createmeta`, ADF node names, Jira field ids/type names). The vendor token used by the grep is built from split literals so the grep script itself does not trip the grep. The engine communicates with the sink solely by passing the schema-validated neutral interchange document across the interface documented in `contracts/sink-interface.md`.

**Rationale**: Constitution VIII's enforcement test is exactly these two greps; realising them in CI makes the boundary mechanical, not aspirational.

**Alternatives considered**: Convention-only separation (rejected — Constitution VIII demands a greppable CI check). A single combined module (rejected — couples engine to Jira, the core anti-pattern this feature fixes).

---

## 14. Privacy guard tiers (US11 P1 / US12 P3 / Constitution IX)

**Decision**: **BLOCK tier** (ships increment 1, before every write): exact match of a known site/project coordinate, the `ATATT` token prefix, or a real non-documentation `*.atlassian.net` host → zero writes + a dedicated exit code. **WARN tier** (P3): generic shapes (emails, UUIDs) warn but do not block. **Allowlist** (P3): domains/links in `.extensionignore` (gitignore syntax) or `config.privacy.allowlist` produce neither block nor warning; `.extensionignore` paths are excluded from both parsing and scanning. Precision wins over recall at BLOCK (no false positives on allowlisted Confluence links).

**Rationale**: Constitution IX and FR-052/FR-053 define the two tiers and the allowlist; the BLOCK tier is constitution-mandated on every write and cannot be deferred (US11 at P1), so the first live dogfooding from a public repo runs with the guard active.

**Alternatives considered**: Deferring BLOCK to P3 with WARN (rejected — US11/FR-052 forbid; leaves the first dogfooding unguarded). A recall-maximising BLOCK that also flags generic shapes (rejected — false positives get the guard disabled; Constitution IX puts generic shapes in WARN).

---

## 15. Flagged (impediment) & human issue links (FR-036 / FR-037)

**Decision**: Discover the Flagged field id at binding (it is a project-visible custom field, discovered not assumed). At reconcile, a ticket carrying the Flagged marker has its transitions **withheld by default**, the flag is surfaced in the summary, and the bridge never sets or removes it. Human-created issue links are never modified or removed; a transition advancing a ticket with open blocking links proceeds but the summary carries an info note naming the blockers.

**Rationale**: FR-036/FR-037 require flag-aware transition withholding and never touching human links. Discovering the Flagged field id (rather than assuming `customfield_10021`) honours Constitution VII.

**Alternatives considered**: Assuming the default Flagged field id (rejected — Constitution VII). Blocking the transition on open blockers (rejected — FR-037 says proceed with an info note; blockers inform, not gate).

---

## Open items carried into implementation

None block planning. Two are flagged for live verification during implementation (not clarifications):
- Exact current Jira Cloud createmeta sub-resource shape (§2) — API-version-sensitive; verify against the live instance in the sink layer.
- Windows Credential Manager access path (§7) — confirm `SecretManagement` vault vs native `CredRead` on the CI Windows runner.
