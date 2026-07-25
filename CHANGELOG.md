# Changelog

All notable changes to the spec-kit-jira extension are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Added

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

## [0.1.0] - 2026-07-23

### Added

- Initial twin-port skeleton (Bash + PowerShell 7+), engine/sink separation,
  test tree, lint configuration, and CI shell.
