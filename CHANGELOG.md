# Changelog

All notable changes to the spec-kit-jira extension are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-07-27

Label-based adoption of pre-existing Jira tickets (003).

### Added

- New `adopt` command: binds tickets that already exist in Jira to the spec
  folders they belong to. Strictly two-phase — a read-only discovery that
  prints the plan and writes nothing, then an apply phase that runs only after
  an explicit confirmation. The **only** write it ever emits is the identity
  marker: no create, delete, transition, comment, link, relabel, description or
  summary write (FR-006, FR-007).
- Two committable config keys under a new `adoption:` section, self-documented
  in `templates/config.yml.template`: `adoption.enabled` (default `false` — the
  feature is opt-in and enabling it is a PR-reviewable team decision) and
  `adoption.label_prefix` (default `speckit-adopt:`). While adoption is
  disabled a labelled ticket is never even read (FR-001, FR-002, SC-009).
- Three label forms, all of which must **name** a spec: `<prefix><folder>`,
  `<prefix><folder>:us<N>`, and the short `<prefix><NNN>` accepted only while
  exactly one spec folder in scope carries that numbering component. A label
  carrying the prefix alone adopts nothing — the bridge never guesses which
  spec a ticket belongs to (FR-003).
- Fail-closed classification with eight named refusal classes —
  `no-candidate`, `several-candidates`, `already-claimed`,
  `spec-owns-bridge-ticket`, `wrong-project`, `unbound-parent`, `wrong-parent`,
  `ambiguous-short-number`. Each refuses **that binding** with zero writes while
  the unambiguous bindings in the same run still apply, and each message names
  the spec folder, every ticket involved, and a copy-pasteable remediation
  (FR-009…FR-015, SC-005).
- No similarity, order, recency or issue-type tie-break exists in any code
  path: two candidates whose titles match the spec exactly are still refused
  (FR-012).
- Three new flags: `--bind <folder>[:us<N>]=<KEY>` to pin a target to a specific
  ticket (validated exactly like a discovered candidate, and the documented
  answer to every refusal), `--spec <folder>` to scope a run to a subset of spec
  folders (the rest contribute no label to any query, so their tickets are never
  read), and `--yes` to pre-confirm the apply phase (FR-020…FR-022, FR-026).
- Adopted tickets are recorded as human-authored, permanently: the first
  `reconcile` afterwards **adds** its managed panel below the existing prose
  with every pre-existing byte intact and reports, per adopted ticket, what it
  added; the reconcile after that writes nothing (FR-016, FR-018, SC-002,
  SC-006).
- Re-running `adopt` over an already-adopted backlog performs zero writes of
  every kind and exits 0, so an interrupted adoption completes on re-run with
  exactly one stamp per ticket (FR-019, FR-027, SC-004, SC-007).

### Changed

- The mocked Jira double gained a real JQL-aware `GET /search/jql` handler with
  `nextPageToken` cursor pagination, a per-issue context read, and in-run
  persistence of written entity properties, so the conformance corpus can prove
  idempotency rather than assume it. The scenario harness gained multi-command
  `steps`, which is how `adopt → reconcile → reconcile` is captured and diffed
  as one sequence.
- `run-summary.schema.json` accepts `adopt` as a command and documents the
  `adoption` block and the `adopted` report (003 delta).

### Fixed

- **Cross-port URI encoding.** The PowerShell port's `ConvertTo-JiraUriComponent`
  used JavaScript's `encodeURIComponent` unreserved set, which leaves `!*'()`
  intact, where `jq`'s `@uri` escapes them. Any query carrying a parenthesis —
  such as the adoption JQL's `labels IN (…)` — produced a different request URL
  on each port. The unreserved set is now RFC 3986's `A-Za-z0-9-_.~`, matching
  `jq` exactly (NFR-1).
- **PowerShell `--verbose` handling.** `pwsh -File <entry> … --verbose` bound
  that token to the engine's `-Verbose` common parameter, which streamed every
  module load to stdout (corrupting a `--json` summary) *and* consumed the token
  so the extension's own parser never saw it. The engine stream is now silenced
  and the flag handed back to the arguments it was taken from (NFR-1).

## [0.2.0] - 2026-07-27

Reliable automatic Jira discovery & team-based feature prefix (002).

### Added

- Three-valued project-style detection: style comes exclusively from an
  unambiguous API signal (`style_source: api`) or an explicit operator answer
  via the repeatable `--style KEY=VALUE` flag (`style_source: operator`);
  ambiguity fails closed with exit 4 and zero writes — the silent
  `company_managed` default is gone.
- Jira-first project-key sourcing: argument → committed config (the literal
  `PROJ` placeholder counts as unset) → closed question over the paginated
  `GET /project/search` accessible-projects list. Git state is never a source
  in a connected run; undefined connection parameters trigger a loud,
  provisional, write-free degraded mode, and the next connected run surfaces
  catalogue/project mismatches as warnings.
- Team naming conventions: committed `teams:` catalogue, human-owned
  gitignored `.specify/jira/personal.yml` selection, and the new twin-ported
  `feature` command (`speckit.jira.feature`, registered as a non-blocking
  `before_specify` hook) that resolves the ticket first (validate or
  guarded-create), then emits `branch_name` per team pattern and a flat
  deduped `short_name`. No selection ⇒ byte-for-byte previous behaviour.
- Config ceremony gitignore effect: idempotent `.gitignore` coverage of
  `config.local.yml`, `.env`, and `personal.yml`, reported as its own effect.
- Implicit team→project routing fallback: a team-prefixed spec folder routes
  to the team's project when no explicit routing rule matches.
- Bash statement-coverage gate: `tests/coverage/bash-coverage.sh` plus a
  `bash-coverage` CI job on Linux, the twin of Pester's CodeCoverage
  (Constitution XIII). It measures the mocked unit suites the way that
  constitution requires, using two collectors: kcov owns the denominator and
  drives the conformance corpus, while the bats suite is traced on a dedicated
  descriptor — kcov cannot run bats, because it instruments bats-core's own
  DEBUG-trap tracing and the two never terminate. `--mode bats` reports traced
  hit counts on hosts where kcov cannot run the port at all, macOS included.

### Fixed

- The default (prose) run summary now states how each project's style was
  resolved — `    <KEY>: <style> (<style_source>)`, nested under the discovery
  effect and ordered by project key. It was previously visible only under
  `--json`, so the FR-003 audit trail was missing from the default output.
- The literal `\{}` defaults in `feature.sh` and `lib/config.sh` no longer
  kill the bash entry point under `errexit` when `SPEC_KIT_JIRA_PLAN_CONTEXT`
  is unset, and no longer pollute `config_personal_load` stderr; the
  redundant `mktemp` capture around `ticket_create` is gone.
- `feature` command prose output (non-`--json`) no longer renders run-summary
  nulls on bash or raw JSON on PowerShell — both ports now share a dedicated
  twin prose renderer (`_feat_render_prose` / `ConvertTo-JiraFeatureProse`).
- PowerShell discovery no longer fabricates a phantom project from a
  `values`-less page, bypassing the zero-results fail-closed; style-switch
  comparisons are case-sensitive and `simplified` follows `tostring`
  semantics like bash.
- Routing: an empty-string `folder_prefix`/`spec_label` rule condition now
  counts as undeclared, so the shipped template's catch-all rule no longer
  shadows the implicit team route; a `teams` entry without `folder_prefix`
  no longer aborts bash `routing_resolve`.
- The bash `.gitignore` idempotency probe now strips CR, so a CRLF checkout
  no longer causes endless duplicate appends (FR-019); PowerShell repo-root
  derivation no longer throws on a single-component `JIRA_CONFIG_DIR`.
- The prose run summary now renders the `gitignore` effect and the degraded
  run's provisional teams plus rerun guidance; degraded effects gain
  `gitignore: skipped`.
- Hook health now covers the `before_specify` feature hook
  (present/missing/disabled), so a deleted entry is reported instead of
  silently re-added; PowerShell command comparisons in the hook merge are
  case-sensitive like bash.
- `quickstart.md` now documents `trash` instead of `rm -f` for cleanup, per
  the project's file-deletion policy.

## [0.1.0] - 2026-07-25

First public release.

### Added

- Initial twin-port skeleton (Bash + PowerShell 7+), engine/sink separation,
  test tree, lint configuration, and CI shell.
- Deterministic, model-independent `config` install ceremony: byte-identical
  re-run, dual-style (company-managed + team-managed) metadata discovery, and the
  three reported effects — discovery, `after_*` hook registration, and the managed
  README block (US1, US2, US4, US5, US9).
- `reconcile` command: title ladder, never-empty structured description, Gherkin
  panel, distinct Design section, priority by logical name, estimation on create
  only, rendered to ADF and written idempotently through the pre-write privacy
  guard (US3).
- Privacy guard — BLOCK tier (known coordinate / ATATT prefix / real
  `*.atlassian.net` host → exit 9, zero writes) and WARN tier + allowlist
  (`.extensionignore` + `config.privacy.allowlist`, no false positives) (US11, US12).
- Idempotency, status-category drift, fail-closed reads, `--dry-run` twin,
  Flagged withholding, and human-link preservation (US6); origin-discriminated
  managed-panel splice that never overwrites human-authored content (US7).
- Multi-project / multi-team routing with per-project identity scope (US8);
  self-healing `after_*` hooks with `--repair-hooks` and per-run hook health (US9).
- `mention` command: read-only fetch of an existing ticket (content, acceptance
  criteria, priority, labels, status, flag, links, Confluence title+url, parent
  context, siblings), identity stamping, and claimed-by-other refusal (US10).

### Changed

- The SOURCE repository now follows the official Spec Kit extension layout:
  `extension.yml` (official manifest schema with the nested `extension:` block),
  `commands/`, `scripts/`, and `templates/` live at the repository root, and
  `specify extension add` creates `.specify/extensions/jira/` in the consuming
  repository automatically; development-only material (`tests/`, `specs/`,
  `.specify/`, `.github/`, lint configs) is excluded from installation by
  `.extensionignore`. The installed (consumer-side) layout is unchanged.

### Fixed

- Privacy guard fail-open defects: the allowlist now exempts individual matches
  only (the payload is never rewritten, so an overlapping entry can never disable
  detection of unrelated tokens, hosts, or coordinates), `*.atlassian.net` hosts
  are matched case-insensitively, and the PowerShell port de-duplicates known
  coordinates and allowlist entries ordinally like `jq unique` — case variants
  are kept distinct (FR-052, FR-053).
- Cross-port parity: PowerShell enum, label, and config-key comparisons are now
  case-sensitive like the Bash port, so routing and validation decisions no
  longer diverge between ports (NFR-1).
- Flagged/impediment field discovery is locale-independent: the English name is
  only a first-chance match; a localized site resolves the field by shape, so
  flagged-withholding lifecycle safety stays active (FR-036).
- A `config.local.yml` override touching one project no longer drops the other
  projects from the merged configuration (`projects` merges per entry, by key).
- `reconcile` guards every pipeline step: a malformed spec or an invalid
  `SPEC_KIT_JIRA_LIFECYCLE` value now exits with the documented configuration
  code and an actionable error instead of a raw interpreter failure (FR-032).
- `.env` token parsing follows dotenv conventions (`export ` prefix, surrounding
  quotes, CRLF), so a conventional file no longer yields a corrupted token and
  an unexplained authentication failure.
- An inline Given/When/Then triple whose Given clause contains the word "when"
  now splits at the explicit clause boundaries and survives intact (FR-015).
- The `--json` run summary now conforms to `run-summary.schema.json`: hook
  health is reported under `hook_health` as `{present, missing, disabled,
  repair_hint?}`, and the contract documents the `actions`, `warnings`, and
  `notes` fields the summary carries (FR-033, FR-047).

[Unreleased]: https://github.com/Fyloss/spec-kit-jira/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Fyloss/spec-kit-jira/releases/tag/v0.1.0
