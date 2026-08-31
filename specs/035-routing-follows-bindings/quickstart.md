# Quickstart — validating marker-derived routing

Runnable checks that prove the feature end to end. Details of behaviour live in
[`contracts/marker-routing.md`](contracts/marker-routing.md); the derived value
and the retired surfaces are described in [`data-model.md`](data-model.md).

## Prerequisites

- `bats` and `jq` on `PATH` for the Bash suites
- `pwsh` 7+ for the Pester suites
- No Jira credentials: every check below runs against the mock server the
  conformance harness starts for itself

## 1. The defect, reproduced

Builds the observed shape: a feature folder with no team-specific prefix, an
operator selecting team A, a committed default naming project B, and a
specification already bound to A.

```bash
bats -r tests/bash/commands/test_reconcile_marker_routing.bats
```

Expected before the fix: the run resolves B and plans a create.
Expected after: the run resolves A and plans updates only.

## 2. Both ports agree

```bash
bash tests/conformance/ci-conformance.sh
```

Success is silent — exit 0 and no line containing `conformance divergence`.
There is no pass banner, and the temporary paths it prints are harness noise.

Scenarios added by this feature, all prefixed `us035-`:

| Scenario | Proves |
| --- | --- |
| `us035-bound-beats-default` | C2.1 rank 3 ahead of `routing_default` |
| `us035-bound-same-for-every-operator` | C2.1 with a different team selected |
| `us035-bound-no-default-declared` | a bound spec placed where today refuses |
| `us035-refuse-markers-split` | C3.1 |
| `us035-refuse-routed-mismatch` | C3.2 |
| `us035-unbound-unchanged` | C2.5 |

## 3. Nothing else moved

```bash
tests/run-bash.sh
```

Budget ~16 min (2688 tests / 274 files, measured 2026-08-30 on an unloaded
machine). Re-measure before trusting that figure — the count grows fast.

For a change-scoped inner loop while iterating:

```bash
tests/run-bash.sh --since main
```

It fails open to the full run whenever the affected set is undeterminable —
which a change under `scripts/bash/lib/` always triggers. Check the `mode:` line
before concluding the inner loop is slow.

```bash
pwsh -NoProfile -Command "Invoke-Pester tests/powershell -Output Detailed"
```

Never run the bash suite and the conformance harness concurrently: they share
fixtures, and the collision invents a divergence in an unrelated scenario.

## 4. Lint

```bash
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
actionlint
```

## 5. Manual end-to-end, against the observed shape

For dogfooding on a real instance (Principle XII). Anonymised: `A` is the
operator's own team's project, `B` a second declared project.

1. In a repository declaring both projects, set `routing_default: B` in
   `.specify/jira/config.yml` and select team A in `.specify/jira/personal.yml`.
2. Create a feature folder whose name carries no team prefix and run
   `/speckit-specify`. The parent and stories are created in **A** and recorded
   in `spec.md`.
3. Run `/speckit-plan`. Its `after_plan` reconcile must now report **updates in
   A**, and must not plan a create for any bound story.
4. Re-run the same reconcile with no change. It must report zero writes of every
   kind.
5. Set `SPEC_KIT_JIRA_PROJECT_KEY=B` and reconcile with `--dry-run`. It must
   refuse, naming A as the recorded project, B as the routed one, and the
   override as where B came from — and must refuse identically without
   `--dry-run`.
