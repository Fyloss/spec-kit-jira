# Quickstart — Validating routing that follows the developer's team

Runnable checks proving the feature end to end. Contract clauses are cited as
`C<n>.<m>` and refer to [contracts/routing-resolution.md](./contracts/routing-resolution.md).

## Prerequisites

- `bats` and `jq` for the bash port; PowerShell 7+ and `Pester` for the twin.
- Run from the repository root.
- **Never run the bash suite and the conformance corpus concurrently** — they
  share fixtures and invent divergences in unrelated scenarios.

---

## 1. The fixture that shows the defect

A repository shared by two teams, with a committed default that suits neither.

```yaml
# .specify/jira/config.yml
projects:
  - key: ALPHA
    style: company_managed
  - key: BETA
    style: company_managed
routing:
  # Rank 1 tests the RAW folder name, numbering included — unlike rank 2, which
  # tests it with the leading `NNN-` removed. A rule spelled 'billing-' would
  # never match the host-numbered folder `003-billing-refund`.
  - match:
      folder_prefix: '003-billing-'
    project: ALPHA
routing_default: ALPHA
teams:
  - id: alpha
    project: ALPHA
    folder_prefix: "alpha-"
    branch_pattern: "alpha-<ID>/<FEATURE_NAME>"
  - id: beta
    project: BETA
    folder_prefix: "beta-"
    branch_pattern: "beta-<ID>/<FEATURE_NAME>"
```

```yaml
# .specify/jira/personal.yml  (gitignored)
team: beta
```

Then a specification folder matching nothing: `specs/007-legacy-cleanup/`, with
no story markers.

**Before this feature**: resolves to `ALPHA` — the other team's project.
**After**: resolves to `BETA` (C2.1 rank 3).

---

## 2. Rank order

Four checks, each isolating one rank. Same repository as §1 unless stated.

| # | Folder | `personal.yml` | Expected | Clause |
| --- | --- | --- | --- | --- |
| 2a | `specs/003-billing-refund/` | `team: beta` | `ALPHA` — the committed rule wins | C2.5 |
| 2b | `specs/004-alpha-102-export/` | `team: beta` | `ALPHA` — the team route wins | C2.5 |
| 2c | `specs/007-legacy-cleanup/` | `team: beta` | `BETA` — rank 3 | C2.1 |
| 2d | `specs/007-legacy-cleanup/` | absent | `ALPHA` — falls to rank 4 | C2.3, C4.4 |

2a and 2b are the ones that matter most: they prove a personal selection cannot
hijack a specification the committed configuration already places.

---

## 3. The boundness precondition (FR-004)

The check that stops per-developer routing from ping-ponging.

Take `specs/007-legacy-cleanup/spec.md` from §1 and add one bound marker:

```markdown
<!-- speckit-jira story=a1b2c3 ticket=ALPHA-88 -->
```

| # | Spec state | `personal.yml` | Expected | Clause |
| --- | --- | --- | --- | --- |
| 3a | no marker | `team: beta` | `BETA` | C3.1 |
| 3b | marker above | `team: beta` | `ALPHA` — rank 3 skipped | C3.1, C3.5 |
| 3c | `<!-- speckit-jira story=a1b2c3 creating -->` | `team: beta` | `BETA` — in flight is not bound | C3.3 |
| 3d | `<!-- speckit-jira story=a1b2c3 -->` | `team: beta` | `BETA` — assigned is not bound | C3.3 |

**The one to run twice**: 3b with `team: beta`, then 3b with `team: alpha`. Both
must give `ALPHA`. That is C3.5, and it is the whole point of FR-004 — two
operators, one answer.

---

## 4. `routing_default` becomes optional

```bash
# C5.1 — absent validates
printf 'projects:\n  - key: ALPHA\n    style: company_managed\n' \
  > "${WORK}/config.yml"
bash -c 'source scripts/bash/lib/config.sh; config_load "$1"' _ "${WORK}"
# expect: exit 0

# C5.2 — present but malformed still refuses, with today's message
printf 'projects:\n  - key: ALPHA\n    style: company_managed\nrouting_default: lower\n' \
  > "${WORK}/config.yml"
bash -c 'source scripts/bash/lib/config.sh; config_load "$1"' _ "${WORK}"
# expect: exit 4, "routing_default must be a valid project key"
```

Wrap the `source` in `bash -c` as shown — sourcing a port script at the top level
of the tool's shell corrupts its own `BASH_SOURCE` paths.

---

## 5. The legacy invariant (FR-009, C1.4)

The check that proves nothing broke for existing users. A repository declaring
`routing_default`, **no** `teams:`, and **no** `personal.yml`:

```bash
bash tests/conformance/ci-conformance.sh
```

Every pre-existing routing scenario must resolve exactly as before. Conformance
success is silent — expect exit 0 and zero lines containing
`conformance divergence`. There is no pass banner, and the temp paths it prints
are harness noise.

---

## 6. The refusal (C6)

Strip `routing_default` from the §1 configuration, remove `teams:`, remove
`personal.yml`, and reconcile `specs/007-legacy-cleanup/`.

Expected: exit 4, zero writes, and one message naming all four findings — no rule
matched, no team prefix matched, no team selected (and which of the two reasons),
no `routing_default` declared. It must **not** say "add routing_default to
config.yml" as the sole remedy (C6.5).

Then re-run with `personal.yml` present but selecting no team. The message must
change, naming that specific state rather than "no personal file" (C6.3).

---

## 7. Full suites

```bash
tests/run-bash.sh --since main      # change-scoped, ≤60s on a single-module diff
tests/run-bash.sh                   # full bash suite, ~190s
bash tests/conformance/ci-conformance.sh
shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')
```

Windows divergences are diagnosed by measurement on the real runner
(`ci/windows-probe`, ~11 min, results arrive as annotations), never by emulation.
The boundness scan of C7.3 is the clause most likely to need it.
