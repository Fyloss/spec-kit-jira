# Quickstart Walkthrough Results — 2026-07-26 (T076)

Every scenario of [quickstart.md](./quickstart.md) executed end-to-end against
the mock Jira server (`tests/conformance/mock-jira`), on macOS with Bash 5 and
PowerShell 7. Conformance scenarios were run through
`tests/conformance/run-scenario.sh` against **both ports** and diffed on
stdout, exit code, Jira call sequence, and the written repository tree.

| # | Scenario | Evidence | Result |
|---|----------|----------|--------|
| 1 | Team-managed style detected, never defaulted (US1) | `tests/bash/sink/test_discovery_ambiguous.bats`, `Discovery.Ambiguous.Tests.ps1`, conformance `us2-team-managed-discovery` | ✅ PASS — `style: team_managed`, `style_source: api` persisted; byte-identical across ports |
| 2 | Ambiguous style: closed question or fail-closed (US1) | conformance `us1-style-ambiguous-refusal` (exit 4, zero writes, stderr names project + missing signal) and `us1-style-operator-answer` (`style_source: "operator"` audited) | ✅ PASS |
| 3 | Connected run: key from the discovered list, never git (US2) | conformance `us2-placeholder-key-refusal` (placeholder `PROJ` = unset ⇒ exit 4 unattended, no branch-derived value in the summary), `us2-list-projects`; `config NOPE` fail-closed covered by `test_config_key_sources.bats` / `Config.KeySources.Tests.ps1` | ✅ PASS |
| 4 | Degraded run loud, provisional, write-free (US2) | conformance `us2-degraded-mode` (exit 0, one warning, `provisional: true` proposals, `rerun_guidance`, zero writes, zero mock calls); defined-but-wrong credentials ⇒ auth/network codes per `test_config_degraded.bats` | ✅ PASS |
| 5 | Team selected: ticket-first naming (US3) | conformance `us3-feature-attach` (`IJT-42` ⇒ `ijt-42/invoice-export` + `ijt-invoice-export`, attached), `us3-feature-create` (mock records `POST /issue`, created number feeds `<ID>`), `us3-feature-cross-team` (`WEX-7` ⇒ `confirmation_required`; `--use-team wex` ⇒ `wex-7/…`, personal.yml unchanged) | ✅ PASS |
| 6 | No selection ⇒ zero behaviour change (US3) | conformance `us3-feature-no-team` (`{active:false}`, empty mock call log) and `us3-feature-fallback` (unreachable Jira ⇒ `{active:false}` + exactly one warning, exit 0) | ✅ PASS — the fallback scenario exposed an errexit leak in the Bash create path (raw curl exit 52 through the real dispatcher); fixed in `ticket.sh`/`feature.sh` with the `|| rc=$?` guard, re-run byte-identical |
| 7 | Gitignore coverage and byte-identical re-runs | conformance `us3-gitignore-effect` (first run `created`, second run all effects `unchanged`, `git check-ignore .specify/jira/personal.yml` exits 0) and `us1-config-idempotent` (SC-004 byte-identical re-run) | ✅ PASS |

## Full gates (same session)

- `shellcheck` over `scripts/bash/**`: clean.
- `Invoke-ScriptAnalyzer` over `scripts/powershell` (project settings): clean.
- `bats -r tests/bash tests/conformance`: 429 tests, 0 failures.
- `Invoke-Pester tests/powershell`: 314 tests, 0 failures.
- Conformance corpus (28 scenarios × both ports): 0 divergences.
- Engine boundary gates (no sink import, no Atlassian identifier): clean.
