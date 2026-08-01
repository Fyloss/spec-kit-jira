# Quickstart: Validating the Jira Hierarchy

Thirteen steps that prove this feature works, in the order they should be run. Steps 1–3 are the
Red half of Red-Green-Refactor and MUST fail before any implementation exists. Step 3b is the
first thing every existing installation will hit. Step 12 is the live gate Constitution II
demands, because mocks are explicitly not sufficient for idempotency.

Run everything from the repository root.

## Prerequisites

```bash
bash --version        # >= 4; macOS ships 3.2, which does not qualify
pwsh --version        # >= 7
jq --version
bats --version
```

Live steps additionally need credentials resolved by Principle IV — environment variables, the OS
secret manager, or a gitignored `.env`. No token ever enters the tree.

---

## Step 1 (RED) — The parent does not exist today

Prove the defect before fixing it, per the repository's bug-fix policy.

```bash
bats tests/bash/commands/test_reconcile_hierarchy.bats -f "creates one parent and three children"
```

**Expect**: FAIL. The current run emits exactly three `POST /rest/api/3/issue` calls, no parent
and no `parent` field on any child.

## Step 2 (RED) — The child type does not resolve on a non-default Jira

```bash
bats tests/bash/sink/test_hierarchy.bats -f "resolves the child type on a French project"
```

**Expect**: FAIL. `.issue_types.Story` finds no key named `Story` in a binding whose types are
`Récit`, `Tâche`, `Épopée`, so `story_type_id` reaches the plan context empty and `plan_writes`
refuses the creation.

## Step 3 (RED) — The binding discards the hierarchy

```bash
bats tests/bash/lib/test_config_binding_shape.bats -f "keeps hierarchy_level and subtask"
```

**Expect**: FAIL. `config_resolved_ids_for` reduces the discovered types to `{logical_name: id}`,
so the level and the sub-task flag are gone by the time anything durable exists. This is the
blocker underneath Steps 1 and 2 — fix it first.

## Step 3b (RED, then GREEN) — An existing binding is refused legibly

Every installation that exists today — the maintainer's own machine first — will meet the new code
with a binding written by the old `config_resolved_ids_for`, which has no `hierarchy_level`, no
`subtask`, no `child_type` and no `parent_type`. This is the single most likely first experience
of the change, so it is tested, not noted.

```bash
bats tests/bash/commands/test_reconcile_stale_binding.bats
pwsh -c "Invoke-Pester tests/powershell/commands/Reconcile.StaleBinding.Tests.ps1"
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-binding-shape-stale.json
```

**Expect** exit 4, zero write calls, and a message that says the binding **predates parent
support** and points at `/speckit.jira.config`.

**Assert the two wrong outcomes are absent** — both are what happens by accident:

- The message must **not** be the existing "project has not been bound yet" text. The project is
  bound; its binding is a version behind, and the wrong message reads as a bug to an operator who
  has already run the ceremony.
- The run must **not** reach `plan_writes`. If the stale shape falls through, `.child_type.id`
  yields an empty string and the failure surfaces much later as an incomplete-creation error —
  the obscure failure this feature exists to remove. Assert the refusal happens before the first
  `GET`.

---

## Step 4 — Derivation, both refusals

```bash
bats tests/bash/sink/test_hierarchy.bats
pwsh -c "Invoke-Pester tests/powershell/sink/Hierarchy.Tests.ps1"
```

**Expect**: GREEN, covering every row of §3 of
[contracts/hierarchy-resolution.md](./contracts/hierarchy-resolution.md) — default Scrum, the
company-managed fixture, SAFe, the Latin-diacritic project, the non-Latin-script project, the flat
project that refuses with `no-parent-level`, and the two-candidate project that refuses with
`parent-level-ambiguous` naming both candidates.

**Also assert**: no Atlassian default type name appears in the implementation.

```bash
grep -REn '"(Epic|Story|Task|Bug|Sub-task)"' scripts/ && echo "VIOLATION" || echo OK
```

The guard enumerates the **Atlassian defaults only**, and deliberately does not list `Récit`,
`エピック` or any other localised name. Enumerating localised names is unbounded — there is a name
per language per instance — and a guard that tried would suggest the bridge knows a set of
languages. It knows none. What proves script-independence is not this grep but the fixtures: the
same code, the same configuration, three projects whose type names share no alphabet (Step 11).

## Step 5 — The parent marker, and its non-collision with the story marker

```bash
bats tests/bash/engine/test_spec_marker.bats
```

**Expect**: GREEN. The load-bearing case is the last one: a specification with an H1, **no**
`## User Story` headings, and a `spec=` marker already present must still receive its own `story=`
marker. If that test passes for the wrong reason the implicit story is silently dropped on every
such specification.

Byte preservation, CRLF handling, atomicity and idempotence are inherited from the story marker's
suite and re-asserted here on the new key.

## Step 6 — The mandatory-field gate

```bash
bats tests/bash/sink/test_hierarchy.bats -f "mandatory"
```

**Expect**: GREEN, and specifically:

- Zero write calls issued.
- The message names **every** unsatisfiable field of **every** written type, not the first one.
- Fields are named by their Jira `name`, never by a `customfield_NNNNN` id.
- The failure is a named mandatory-field refusal, not a transport error.

## Step 7 — The first run builds the hierarchy

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us2-parent-first-run.json
```

**Expect** the call sequence, in this order:

```text
POST /rest/api/3/issue                         # the parent
PUT  /rest/api/3/issue/COMP-1/properties/spec-kit-jira   # role: parent
POST /rest/api/3/issue                         # story 1, fields.parent.key = COMP-1
PUT  /rest/api/3/issue/COMP-2/properties/spec-kit-jira   # role: story
POST /rest/api/3/issue                         # story 2, fields.parent.key = COMP-1
…
```

**And in the fixture's `spec.md`**: one `spec=<id> ticket=COMP-1` line after the H1, and one
`story=<id> ticket=COMP-N` line per user story. Every other byte unchanged.

## Step 8 — The second run writes nothing

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us2-parent-second-run.json
```

**Expect**: one `GET` per recorded ticket including the parent, and **zero** `POST`, `PUT` or
`DELETE`. The summary reports `created: 0`, `updated: 0`. `spec.md` is byte-identical — check the
bytes, not the diff:

```bash
git diff --stat tests/conformance/fixtures/repo-with-mirrored-spec   # must be empty
```

## Step 9 — Fail-closed: no orphan stories

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-hierarchy-no-parent-level.json
tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-hierarchy-ambiguous.json
tests/conformance/run-scenario.sh tests/conformance/scenarios/us3-mandatory-field-refusal.json
```

**Expect** for each: exit 4, **zero** write calls of any kind, a message naming the project and
the specific cause. Then confirm the other half of Constitution III:

```bash
SPEC_KIT_JIRA_HOOK_CONTEXT=after_specify \
  tests/conformance/run-scenario.sh tests/conformance/scenarios/us1-hierarchy-ambiguous.json
```

**Expect**: exit **0**, one `WARNING: … (exit 4). This spec-kit command completed normally.` line,
still zero writes.

Also assert the interrupted-run window: with `spec.md` carrying `spec=<id> creating`, the run
refuses and **no story is created either**.

## Step 10 — Dry-run predicts the real run exactly

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us6-dry-run.json
```

**Expect**: the dry-run report names the parent creation, the identifier the run assigned, and
every child's parent reference. Then run the same scenario for real against the same state and
diff the predicted action set against the performed one — they must be identical, including the
mandatory-field refusal case, which must be predicted rather than discovered mid-write.

## Step 11 — Both ports agree, byte for byte

```bash
tests/conformance/run-scenario.sh --port bash       tests/conformance/scenarios/us2-parent-first-run.json
tests/conformance/run-scenario.sh --port powershell tests/conformance/scenarios/us2-parent-first-run.json
```

**Expect**: identical stdout, identical exit codes, identical Jira call sequences, identical
resulting `spec.md` bytes. `SPEC_KIT_JIRA_ID_SOURCE` supplies the identifiers, which is the only
reason two random generators can agree.

Repeat for the Latin-diacritic, non-Latin and SAFe scenarios. The non-Latin one is the sharpest
portability case in the suite: both ports must emit the project's own type names in the same
encoding, on all three runners, Windows PowerShell included. A byte-diff here is an encoding
defect, not a hierarchy defect.

Then the retired-key refusal:

```bash
tests/conformance/run-scenario.sh tests/conformance/scenarios/us4-retired-key-refusal.json
```

**Expect**: exit 4 naming `epic_strategy`, the project index and the file. Then confirm the key
is gone everywhere it should be:

```bash
grep -rn "epic_strategy\|task_strategy\|link_type" scripts/ templates/ commands/ \
  | grep -v "retired"      # only the retirement rule may mention them

# And the fourth dead surface, deleted rather than retired (R11).
# Scoped to the COMMITTABLE layer: after T014a every gitignored-style binding
# (config.local.yml) legitimately carries issue_types — that is the whole point
# of the reshaping. Only a team config declaring it is a violation.
grep -rn "issue_types" tests/conformance/fixtures/*/.specify/jira/config.yml \
  && echo "VIOLATION" || echo OK
```

## Step 12 (LIVE GATE) — Idempotency against a real instance

Mocks are not sufficient; Constitution II says so explicitly, and three live-only bugs in the
original extension are why.

```bash
bats tests/live/test_live_zero_churn.bats
```

**Expect**, against a real Jira project:

1. First run: one parent, one child per user story, every child under the parent in Jira's own
   issue view.
2. Second run, unchanged specification: `0 created / 0 updated / 0 transitioned / 0 commented /
   0 linked / 0 labeled`, and no parent reference written.
3. The parent's description, read by a human in Jira, shows named sections and complete
   sentences — no markdown, no front-matter, no marker comments, and no list of user stories,
   because Jira is already showing the children.
4. Add one user story, run again: exactly one creation, beneath the existing parent, and the
   parent itself untouched.

Step 12 is the acceptance signal for the feature and the dogfooding record Constitution XII
requires before release.

---

## Coverage gate

```bash
tests/coverage/bash-coverage.sh     # kcov, >= 80% statements
pwsh -c "Invoke-Pester -CodeCoverage"
```

Parent recognition, the derivation refusals, the mandatory-field gate and every fail-closed path
are critical paths and target coverage close to 100%.
