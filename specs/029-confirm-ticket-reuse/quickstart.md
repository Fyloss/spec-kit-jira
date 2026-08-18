# Quickstart — Validating 029 end to end

**Feature**: 029 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

Runnable scenarios that prove the feature works. Contract details are referenced,
not repeated — see [`contracts/`](./contracts/).

---

## Prerequisites

```sh
bash --version          # ≥ 4.0; macOS ships 3.2, which does not qualify
pwsh --version          # ≥ 7.0
jq --version
bats --version
```

No new dependency is introduced by this feature.

---

## Inner loop

```sh
tests/run-bash.sh --since HEAD~1     # change-scoped, ≤ 60 s
tests/run-bash.sh                    # full bash suite, ~190 s
bash tests/conformance/ci-conformance.sh
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
actionlint
```

> Conformance success is **silent**: no pass banner. Look for exit 0 and zero
> `conformance divergence` lines; temp paths in the output are harness noise.
> Never run the bash suite and conformance concurrently — they share fixtures.

---

## Scenario 1 — The question, and the omission that makes it stick (P1, US1)

The shippable core.

```sh
export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:$MOCK_PORT"

scripts/bash/spec-kit-jira.sh feature IJT-2241 "migrate to node 22" --json
```

**Expect** — a returned proposal, not an abstract question: a `Detected:` line
naming IJT-2241 by key, summary, type and status, an `Attach …?` line stating the
role it would be attached in using the project's own configured type names (never
`specification`/`story`), and exactly two offered answers — `--reuse yes` attaches
as proposed, `--reuse no` creates new instead. Exit `0`; zero Jira mutations; zero
local writes. An issue whose type maps to neither declared role (a `Bug`, say) is
proposed in the story role and marked unmapped rather than refused; only an issue
carrying the *other* role's declared type refuses, at the question.

**Then assert the load-bearing property** — the result carries **no** `branch_name`
and **no** `short_name`. This is the test that proves the question cannot be
skipped: without a name the caller cannot create the branch or the spec folder
([feature-question-contract.md §3](./contracts/feature-question-contract.md)).
Everything else in this feature assumes a caller that follows instructions; this
assertion is the one that holds when it does not.

---

## Scenario 2 — Both answers (P1, US2 + US3)

```sh
# "create new" — the regression guarantee
scripts/bash/spec-kit-jira.sh feature IJT-2241 "migrate to node 22" --reuse no --json

# "reuse" with no explicit designator — auto-accepts the proposal (US3 AC1). This
# is the ORDINARY case whenever the routed project declares a hierarchy: the role
# the question already derived (IJT-2241 -> story, say) is reused with no further
# round-trip, byte-identical to typing --story IJT-2241 directly.
scripts/bash/spec-kit-jira.sh feature IJT-2241 "migrate to node 22" --reuse yes --json

# explicit designators — the override that skips the question entirely
scripts/bash/spec-kit-jira.sh feature --parent IJT-2200 --story IJT-2241 "migrate to node 22" --json
```

**Expect**, in order: output byte-identical to the current release for the same
input; a seeded-not-bound state identical to the one explicit designators produce,
with no question involved; the same state again, reached via explicit designators
directly. The which-issues follow-up question — repeatable indefinitely, zero
writes, zero accumulated state — is the EXCEPTION, reached only when the routed
project declares **no** hierarchy at all (FR-029/FR-035), not the ordinary case:

```sh
scripts/bash/spec-kit-jira.sh feature IJT-2241 "migrate to node 22" --reuse yes --json
# repeated three times, against a project with no declared hierarchy
```

The three results of that repeated call must be byte-identical to each other and
the state directory must stay empty — FR-030.

---

## Scenario 3 — A pasted link is a mention (US1 AC3, FR-032)

```sh
scripts/bash/spec-kit-jira.sh feature "http://127.0.0.1:$MOCK_PORT/browse/IJT-2241" "migrate to node 22" --json
scripts/bash/spec-kit-jira.sh feature "http://127.0.0.1:$MOCK_PORT/jira/software/projects/IJT/boards/7?selectedIssue=IJT-2241" "migrate to node 22" --json
```

**Expect** — both byte-identical to Scenario 1's bare-key result.

**Also assert the negative**, because it is the boundary that protects everyone
else: a leading positional that is an ordinary word produces **no** question and a
result byte-identical to the current release. `ticket https://…` is that case — the
leading positional is `ticket` ([mention-grammar.md §1](./contracts/mention-grammar.md)).

---

## Scenario 4 — Nothing named is nothing changed (P3, US5, SC-004)

```sh
bash tests/conformance/ci-conformance.sh
```

The **existing** `us3-feature-*.json` scenarios run unmodified: byte-identical
stdout, identical exit codes, identical recorded request sequence. They are the
evidence that this feature changed nothing for the installed base — do not edit
them to carry the new flag.

This is the scenario that must be green before any other work is called done.

---

## Scenario 5 — The four silent exits (US6, FR-026 to FR-028)

The riskiest surface, because it is the one the plan reorders.

| Repository state | With a mention | With no mention |
| --- | --- | --- |
| no `config.yml` | names `config.yml`, states the config command | **byte-identical to today** |
| unreadable `config.yml` | same | **byte-identical to today** |
| empty `teams:` catalogue | same | **byte-identical to today** |
| catalogue present, no selection | names `personal.yml`, states that the selection is the operator's own | **byte-identical to today** |

Every row needs both columns tested. The right-hand column is where a regression
would hit every repository that does not use this extension at all, and no Jira
double is required to test any of it.

---

## Scenario 6 — Unattended (US4, FR-013, FR-014)

```sh
scripts/bash/spec-kit-jira.sh feature IJT-2241 "migrate to node 22" --accept-defaults --json
```

**Expect** — no question, today's outcome, plus a statement that the question was
suppressed and `no` assumed.

**Assert the trap explicitly**: with `--accept-defaults` **absent** and no terminal
attached, the question still fires. A TTY probe would suppress it always and reduce
this feature to a no-op that passes review
([research.md §R3](./research.md)).

---

## Scenario 7 — Windows

```sh
git push origin HEAD:ci/windows-probe     # ~11 min; results arrive as annotations
```

Constitution VI: a Windows-only divergence is diagnosed by measurement on the real
runner, never by emulating MSYS locally.

**Triage first.** The probe baseline on `main` has been red independently of any
feature — compare against the baseline before attributing a red run to this work,
and stop after one retry.

Highest-risk surfaces here: the URL reduction (glob patterns — no `$'\r\n'` may
appear in one) and every new multi-line message (through `lib/output.sh`, never a
bare `jq`).

---

## Before calling it done

- [ ] `tests/run-bash.sh` green
- [ ] Pester suite green
- [ ] `ci-conformance.sh` exit 0, zero divergence lines, existing feature scenarios unedited
- [ ] `shellcheck` and `actionlint` clean
- [ ] Three-OS matrix green
- [ ] Scenario 1's omission assertion present — the feature is unenforced without it
- [ ] Scenario 5's right-hand column tested for all four exits
- [ ] `commands/speckit.jira.feature.md` states that the ticket goes in the leading positional
- [ ] Dogfooded against a real instance, replaying the reported scenario
- [ ] CHANGELOG entry; version bumped in `extension.yml` only
