# Quickstart Results — 015

**Date**: 2026-08-04

## Automated gates (this session)

| Gate | Command | Result |
| --- | --- | --- |
| Regression test red first | new FR-017 case in `test_ticket.bats` | confirmed red against pre-fix code, green after |
| Bash suite | `tests/run-bash.sh` | green (all files pass) |
| PowerShell suite | `Invoke-Pester tests/powershell` | green (all files pass) |
| Cross-port equivalence | `bash tests/conformance/ci-conformance.sh` | exit 0, zero `conformance divergence` lines |
| Lint | `shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')`, `actionlint`, `Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse -Settings PSScriptAnalyzerSettings.psd1` | all three clean |

Four new conformance scenarios were added and pass byte-identically on both
ports: `us1-field-defaults-option-encoded`, `us2-field-defaults-option-question`,
`us3-created-count-refused`, `us4-recorded-value-outside-allowed`.

## Manual end-to-end check against a real Jira instance — NOT PERFORMED

Principle XII names this dogfood record a release gate, and it is the only
proof of SC-001 against a real Jira instance rather than the mock. **This
session has no Jira credentials and no real project to run it against.**

Before this feature ships, run the six steps in
[quickstart.md](quickstart.md) §"Manual end-to-end check" against a real
company-managed (or team-managed) project whose specification-role and
story-role issue types each require a single-select field, and replace this
section with the outcome — anonymising every project key, field label,
option value, and ticket key before it reaches this file, a commit, or an
issue (per the project's no-consumer-data convention).

The mock-based conformance scenarios above exercise the same code paths
(encoding, the confirmation question, the confirmed-created count, and the
configuration-time refusal) against a fixture shaped identically to the
reported defect, and are strong evidence the fix is correct — they are not a
substitute for the real-instance run this gate asks for.
