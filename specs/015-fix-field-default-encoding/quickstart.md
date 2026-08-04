# Quickstart — Proving 015 Works

**Feature**: 015 | **Date**: 2026-08-04 | **Phase**: 1

How to prove this feature, suite by suite, from the repository root. Shapes and
rules referenced below live in [`contracts/field-default-encoding.md`](contracts/field-default-encoding.md)
and [`data-model.md`](data-model.md); they are not repeated here.

## Prerequisites

- `bash` ≥ 4, `bats`, `jq` — the Bash suite needs nothing else.
- `pwsh` 7+ and Pester — for the PowerShell suite.
- No Jira credentials. Every step below runs against the mock.

---

## Step 0 — Watch the defect fail first

Before any code changes, the regression test of FR-017 must be red. Write it,
then:

```bash
bats -r tests/bash/sink/test_plan_apply_defaults.bats
```

Expected: the new case fails, showing the select-list field carried as a bare
string in the payload. **If it passes, it is not testing the defect.**

---

## Step 1 — The Bash inner loop

```bash
tests/run-bash.sh --since HEAD
```

Change-scoped, ≤60s on a single-module diff. Use this while iterating.

Full suite before pushing (~3m10s):

```bash
tests/run-bash.sh
```

Green means: the encoding rules, the two-map invariants, the confirmed-count rule,
and the configuration-time refusal all hold on the Bash port.

---

## Step 2 — The PowerShell port

```bash
pwsh -NoProfile -Command "Invoke-Pester tests/powershell -Output Detailed"
```

The twin cases must assert the same values as the Bash ones. Pester's discovery
order differs between hosts, so a case that depends on another case's state will
be green here and red on the Linux runner — each case sets up its own tree.

---

## Step 3 — Cross-port byte equivalence

```bash
bash tests/conformance/ci-conformance.sh
```

This is the only proof FR-016 accepts. Success is **silent**: exit 0 and zero
lines containing `conformance divergence`. Temp paths in the output are harness
noise, not findings.

The three scenarios this feature adds are listed in the contract, §8.

---

## Step 4 — Lint

```bash
shellcheck $(git ls-files '*.sh')
actionlint
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/powershell -Recurse -Settings PSScriptAnalyzerSettings.psd1"
```

All three must be clean; they are blocking gates.

---

## Step 5 — Coverage

The 80% statement gate applies per port. The jq program literals inside
`plan_resolve_field_defaults` are already `kcov-excl` bracketed — keep the new
encoding rules inside those brackets so the exclusion stays accurate rather than
generous.

---

## Manual end-to-end check (optional, needs a real Jira project)

Only meaningful against a project whose written issue types require a
single-select field.

1. `/speckit.jira.config` — record a default for the select field and for a
   free-text field.
2. Inspect `.specify/jira/config.yml`: both values must be plain scalars. If
   either is a mapping, §1 of the contract is broken — the encoding has leaked
   into the committable layer.
3. Run the reconcile with `--dry-run` and read the provenance notes: the values
   shown, and the `--field-default` promotion command, must repeat exactly what
   step 1 recorded.
4. Run it for real. Exit 0, tickets created, markers resolved.
5. Read the summary's `counts.created` and compare with what Jira holds. They
   must agree.
6. Hand-edit one recorded value to something outside its allowed list and re-run
   `/speckit.jira.config`. It must refuse, name the field by its Jira label, list
   the accepted values, and leave `config.yml` untouched.

Anonymise anything from this run before it reaches a spec, an issue, or a commit
message — project keys, field labels, option values, and ticket keys included.

---

## What "done" looks like

| Gate | Command | Signal |
| --- | --- | --- |
| Regression test red first | `bats -r tests/bash/sink/test_plan_apply_defaults.bats` | fails before the fix |
| Bash suite | `tests/run-bash.sh` | green |
| PowerShell suite | `Invoke-Pester tests/powershell` | green |
| Cross-port equivalence | `bash tests/conformance/ci-conformance.sh` | exit 0, silent |
| Lint | `shellcheck`, `actionlint`, `Invoke-ScriptAnalyzer` | clean |
| Three-OS matrix | CI | green on macOS, Linux, Windows |
