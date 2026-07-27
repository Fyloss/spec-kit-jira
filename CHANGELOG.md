# Changelog

All notable changes to the spec-kit-jira extension are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Bash statement-coverage gate: `tests/coverage/bash-coverage.sh` plus a
  `bash-coverage` CI job on Linux, the twin of Pester's CodeCoverage
  (Constitution XIII).

### Fixed

- The default (prose) run summary now states how each project's style was
  resolved — `    <KEY>: <style> (<style_source>)`, nested under the discovery
  effect and ordered by project key. It was previously visible only under
  `--json`, so the FR-003 audit trail was missing from the default output.

## [0.2.0] - 2026-07-26

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

[Unreleased]: https://github.com/Fyloss/spec-kit-jira/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Fyloss/spec-kit-jira/releases/tag/v0.1.0
