# Quickstart — Validating Discovery Reliability & Team-Based Prefixes

Runnable scenarios proving the feature end-to-end. Each maps to a user story;
formats and rules referenced from [data-model.md](./data-model.md) and
[contracts/](./contracts/).

## Prerequisites

- Bash ≥ 4 (macOS: Homebrew bash — the OS-shipped 3.2 does not qualify) or
  PowerShell 7+.
- `curl`, `jq`, `git` on PATH.
- Dev suites: bats-core, Pester; the conformance harness's mock Jira server
  (`tests/conformance/mock-jira`) — no real credentials needed for any
  scenario below.

## Scenario 1 — Team-managed style is detected, never defaulted (US1)

```bash
# Unit (regression written BEFORE the fix — must fail on the old code):
bats tests/bash/sink/test_discovery.bats     # ambiguous payload ⇒ style null, not company_managed
pwsh -c 'Invoke-Pester tests/powershell/sink/Discovery.Tests.ps1'

# Conformance (mock project payload says team-managed):
tests/conformance/run.sh us2-team-managed-discovery
```

**Expected**: binding and `config.local.yml` carry `style: team_managed`,
`style_source: api`; both ports byte-identical.

## Scenario 2 — Ambiguous style: closed question or fail-closed (US1)

```bash
# Unattended: fixture payload with no style/simplified signal
tests/conformance/run.sh us1-style-ambiguous-refusal
# ⇒ exit 4, stderr names the project and the missing signal, zero writes

# Operator answer path:
spec-kit-jira config --style PROJ1=team_managed --json
# ⇒ persisted style_source: "operator"; summary audits it (FR-003)
```

## Scenario 3 — Connected run: key from the discovered list, never from git (US2)

```bash
git checkout -b wex-99/red-herring   # arbitrary branch prefix
spec-kit-jira config --json          # config.yml key still the PROJ placeholder
```

**Expected**: exit 4 unattended (placeholder = unset, FR-005) — the error
lists the closed-question path; the summary contains no value derived from
`wex`. Supplying an unknown key argument fails closed with no substitution
(FR-006): `spec-kit-jira config NOPE` ⇒ transport fail-closed exit.

## Scenario 4 — Degraded run is loud, provisional, and write-free (US2)

```bash
unset SPEC_KIT_JIRA_BASE_URL
spec-kit-jira config --json > degraded.json
```

**Expected**: exit 0; one warning naming the missing variables; every
proposal marked `provisional: true`; `rerun_guidance` present;
`config.local.yml` byte-identical to before the run. Then define the
connection env vars and re-run: authoritative discovery replaces the
proposals and surfaces mismatches (FR-009). With *wrong* (defined)
credentials instead, the run fails with the auth exit code — no degraded
fallback.

## Scenario 5 — Team selected: ticket-first naming (US3)

```bash
# Committed catalogue: teams ijt + wex (fixture repo-with-teams)
printf 'team: ijt\n' > .specify/jira/personal.yml

spec-kit-jira feature IJT-42 --json "invoice export"
# ⇒ {"branch_name":"ijt-42/invoice-export","short_name":"ijt-invoice-export",
#    "ticket":{"key":"IJT-42","action":"attached"},...}

spec-kit-jira feature --json "invoice export"
# ⇒ ticket action "created" in IJT (mock records POST /issue), number feeds <ID>
```

Cross-team mention: `spec-kit-jira feature WEX-7 --json "…"` ⇒
`confirmation_required` naming `wex`; re-invoking with `--use-team wex`
yields `wex-7/…` and the `wex` folder prefix; `personal.yml` unchanged.

## Scenario 6 — No selection ⇒ zero behaviour change (US3)

```bash
trash .specify/jira/personal.yml   # recoverable deletion (File Deletion Policy)
spec-kit-jira feature --json "invoice export"
# ⇒ {"active":false} — no prompt, no warning, no Jira call (mock log empty)
```

An unknown team in `personal.yml` stops with a located error listing the
valid ids. Jira unreachable at creation time ⇒ `{active:false}` plus one
warning — feature creation proceeds with default naming (FR-016).

## Scenario 7 — Gitignore coverage and byte-identical re-runs

```bash
spec-kit-jira config --json   # gitignore effect: created/written on first run
spec-kit-jira config --json   # ⇒ every effect "unchanged"
git check-ignore .specify/jira/personal.yml   # exit 0 (FR-019)
cmp before.local.yml .specify/jira/config.local.yml   # byte-identical (SC-004)
```

## Full gates (must be green before merge)

```bash
shellcheck scripts/bash/**/*.sh
bats -r tests/bash
pwsh -c 'Invoke-Pester tests/powershell -CI'
tests/conformance/run.sh --all        # every scenario byte-identical across ports
# coverage ≥ 80% (kcov / Pester CodeCoverage) — CI gate
```
