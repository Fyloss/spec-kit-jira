# Phase 0 Research: Retire the hook registry report

**Feature**: `034-retire-hook-report` | **Date**: 2026-08-30

This feature is a net deletion, so the research is not "how do we build it" but
"what exactly falls when the reader goes, and what must be caught on the way
down". Every finding below was taken by reading the tree at
`2be2889`, not from the specification's description of it.

---

## R1 — The seven-event set has one declaration, and it is NOT the module being deleted

**Question**: FR-009 says the build-time check asserting manifest ⟷ port event-set
equality must be "retired or re-pointed". Which, and at what?

**Finding**: `scripts/bash/hooks/register_hooks.sh:56` does not declare the set —
it consumes it:

```bash
HOOK_EVENTS=("${JIRA_HOOK_EVENT_NAMES[@]}")
```

`JIRA_HOOK_EVENT_NAMES` lives in `scripts/bash/lib/config.sh:1084`
(`$script:JiraHookEventNames`, `scripts/powershell/lib/Config.psm1:1876`). It has
a **second consumer that survives this feature**:
`_cfg_after_event_names_json` (`lib/config.sh:1091`) slices off `before_specify`
and feeds the remaining six into the `phase_status_map` schema enum — feature 023,
`contracts/role-lifecycle-config.md §2`. That is live, unrelated code.

**Decision**: **re-point, do not retire.** `tests/bash/ci/test_manifest_hooks.bats`'s
last test and its Pester mirror keep asserting manifest ⟷ port equality, sourcing
`lib/config.sh` and reading `JIRA_HOOK_EVENT_NAMES` instead of sourcing the deleted
module and reading `HOOK_EVENTS`. The assertion keeps its whole value: an event
added to the manifest and forgotten in the port would still ship a `phase_status_map`
enum that rejects it.

**Rationale**: retiring the check would satisfy FR-009's letter while dropping a
guard that protects a *different* feature's contract. The set's declaration site
is not going away; only one of its two readers is.

**Consequence for the code**: `lib/config.sh:1058-1084`'s comment block currently
justifies the set as "the `hooks.disabled` enum of config.local.schema.json" and
tells the reader that `hooks/register_hooks.sh` consumes it. Both halves become
false. The comment must be rewritten to name the 023 lifecycle enum as the reason
the set exists.

**Alternative rejected**: move the array into the manifest-parsing test itself as a
literal. Rejected — it would make the test tautological with `EXPECTED_EVENTS`
(line 33) and assert nothing about the port at all.

---

## R2 — Deleting the hooks effect deletes five values from the effect status vocabulary

**Question**: FR-002 removes the `effects.hooks` object. Does anything else in the
run-summary contract depend on it?

**Finding**: `specs/001-jira-reconcile-engine/contracts/run-summary.schema.json:151-163`
declares one shared `$defs/effect.status` enum of eleven values, and its own
description partitions them: *"The first six are WRITE outcomes … The last five are
the READ-ONLY verification vocabulary of the hooks effect"*. A grep across both
ports confirms the partition is exact — `healthy`, `incomplete`, `held_disabled`,
`duplicated` and `unreadable` are produced at exactly one site each
(`scripts/bash/commands/config.sh:970-976`, `scripts/powershell/commands/Config.psm1:1074-1080`),
and that site is the hooks effect. The three surviving effects (`discovery`,
`readme`, `gitignore`) use only the six write outcomes.

**Decision**: remove all five values from the enum along with the `hooks` property.
The surviving enum is the six write outcomes, and its description loses the
partition sentence that no longer has two sides.

**Rationale**: leaving five unreachable values is the same defect this feature
exists to remove, one layer down — a published vocabulary asserting outcomes
nothing can produce. FR-008 already forbids the softer option ("updated to remove
them rather than mark them optional") for the fields; the enum is the same
contract.

---

## R3 — Retiring the disable record also retires reconcile's dispatch hold

**Question**: US3 removes the record and the flag that cleared it. The record has a
third consumer the specification does not name in an FR. What happens to it?

**Finding**: `scripts/bash/commands/reconcile.sh:621-634` (mirror:
`Test-JiraReconcileHeld`, `scripts/powershell/commands/Reconcile.psm1:63-83`) reads
the record at dispatch, before the prerequisite check and before any network call,
and returns **0 silently** when the current lifecycle event is recorded:

```bash
# (0) DISPATCH GUARD — the operator's disable decision, honoured before any
# prerequisite check, any config read and any network call (FR-020). The exit
# is INERT: no Jira call, and no warning either.
```

There is no way to keep that guard: it reads a key FR-005 removes from the
accepted set, so after this feature a repository that still declares the key is
refused at load, and one that does not has nothing for the guard to read.

**Decision**: the dispatch hold is removed with the record — the function, its call
site, its `EXIT_CONFIG` branch, and the conformance scenario built on it.

**This is a real behaviour removal, and it is authorised.** Constitution 4.0.0
records it in as many words: *"the obligation that a hook the operator explicitly
disabled MUST be respected forever … is REMOVED with the rest. A reinstall may now
re-enable a hand-disabled hook, and this extension will neither prevent it nor
report it."* Spec US3's phrase "a withheld lifecycle event" is the same thing named
from the flag's side. FR-011 requires it to be documented rather than discovered.

**Consequence**: after this feature the only way to stop a hook firing is the host's
own `enabled: false` in `.specify/extensions.yml`, which a reinstall may overwrite.
That is the second of the two protections the amendment gives up.

---

## R4 — FR-005 costs one token and one block per port, and the located refusal already exists

**Question**: SC-004 demands the refusal be produced "entirely by the pre-existing
unknown-key path — zero lines of code are added to obtain it". Is that true of the
code as it stands?

**Finding**: `scripts/bash/lib/config.sh:1021-1034`:

```jq
(keys_unsorted[] | select(IN("site_alias","bound_site","resolved_ids","overrides","hooks")|not)
 | "unknown config.local key: \(.)"),
…
(if has("hooks") then … "unknown hooks key: \(.)" … else empty end),
```

Removing `,"hooks"` from the `IN(...)` list and deleting the `has("hooks")` block
leaves a file declaring `hooks:` producing `unknown config.local key: hooks`. That
string reaches the operator through `lib/config.sh:1561`:

```bash
… | _cfg_schema_errors "${_CFG_LOCAL_ERRORS_JQ}" | _cfg_report_errors "schema" "${local_f}" || return "${EXIT_CONFIG}"
```

`_cfg_report_errors` is handed `${local_f}` — the full path of the file. So the
refusal already names **both** the key and the file, and already exits 4.

The PowerShell mirror is the same shape: `scripts/powershell/lib/Config.psm1:1020`
tests membership of an `$allowed` list and emits the identical string; the `hooks`
validation block below it is deleted alongside.

**Decision**: FR-005 is implemented as a deletion from `$allowed` / the `IN(...)`
list plus the removal of the dedicated `hooks` validation block, in both ports. No
retired-key rule, no bespoke message, no migration — exactly as the spec's
Assumptions section requires.

**Verification owed**: SC-004 says *zero* lines added. A task must assert the
message text against a fixture, not merely the exit code, so a future refactor
that drops the file path from the report is caught.

---

## R5 — `SPEC_KIT_JIRA_EXTENSIONS_YML` is retired, not merely unused

**Question**: three sites read `${SPEC_KIT_JIRA_EXTENSIONS_YML:-…}` to locate the
registry. Does the override survive as a no-op?

**Finding**: the variable exists solely so tests can point the reader at a fixture
registry. Its only consumers are the two health call sites and the reader itself.

**Decision**: delete the variable, its defaulting expressions and every mention in
documentation and test harnesses. FR-001 forbids opening the file "in any command,
in any state"; an environment variable naming a path nothing opens is a claim about
a capability that no longer exists.

**Enforcement**: this makes the widened guard (R6) simpler and much stronger — after
this feature the token `SPEC_KIT_JIRA_EXTENSIONS_YML` should not appear in
`scripts/` at all.

---

## R6 — The widened guard is an absence check, and it must be proven red first

**Question**: FR-010 widens `tests/bash/ci/test_no_registry_write.bats` (and
`tests/powershell/ci/NoRegistryWrite.Tests.ps1`) from "never writes" to "never
reads". What shape, and how is it demonstrated red?

**Finding**: the existing guard is seven tests of increasing specificity, built
around `REGISTRY_TOKENS='extensions\.yml|SPEC_KIT_JIRA_EXTENSIONS_YML|ext_path'`
and a set of *write-verb* regexes (redirection, `mv|cp|rm|tee|truncate|install`,
`sed -i`, `mkdir`, `config_to_yaml`). All seven exist because a write can be
spelled many ways.

After this feature the extension does not name the registry **at all**, so the
guard collapses to something categorically simpler and stronger: the tokens must
not occur in the shipped port, in any line, comment or code, except in a comment
that explains the prohibition itself.

**Decision**: replace the seven write-verb tests with:

1. **Total absence** — `extensions\.yml` and `SPEC_KIT_JIRA_EXTENSIONS_YML` occur
   zero times in `scripts/` (both ports), outside an explicit allowlist of the
   prohibition's own explanatory comment.
2. **The deleted module has not returned** — no file named `register_hooks.sh` /
   `RegisterHooks.psm1`, and no symbol `register_hooks_*` / `Get-JiraHook*`.
3. **No read verb reaches a registry-shaped path** — retained from the old guard's
   spirit, generalised: `cat|<|read|jq …` against a path ending `extensions.yml`.
   Subsumed by (1) but kept, because (1)'s allowlist is the seam a future change
   would widen.

Test (1) subsumes every write test: a path that cannot be named cannot be written.

**Proving it red** (per FR-010 and the project's standing rule that a guard nobody
has seen fail is not known to work): run the new guard against the **pre-change**
port, retrieved with `git show HEAD:scripts/bash/…` into a temporary tree, with the
guard's `SCRIPTS` root pointed at that tree. It must fail on all three tests. This
is done and recorded *before* the deletion is applied, not after.

**Hazard to avoid** — the old guard's `offending()` helper greps `${SCRIPTS}`, a
path baked into `setup()`. A guard that silently reads nothing passes vacuously.
The red run is also the proof that the instrument reads the file at all.

**Portability note**: keep `grep -rnE 'a|b'`. BSD `grep` mishandles `\|`
alternation in a basic-regex pattern and silently fails to match on macOS.

---

## R7 — The managed README block changes, and that is one write per consumer, not churn

**Question**: `templates/readme-block.template:8-35` tells the reader the ceremony
"also verifies hook registration" and documents `--enable-hook`. FR-011 and SC-006
require both statements to go. Does rewriting the template violate Principle II?

**Finding**: the block is content-addressed — the ceremony writes it when the
rendered content differs from what is on disk and reports `unchanged` otherwise.

**Decision**: rewrite the template. Every consumer repository takes exactly one
`written` outcome on its next ceremony and `unchanged` on every run thereafter.
That is the intended behaviour of a versioned managed block, not churn.

**Consequence — and it is smaller than it first looks.** Conformance compares the
two ports *to each other*, not to a stored golden capture
(`tests/conformance/scenarios/README.md`), so a template rewrite cannot break a
scenario: both ports render the new text and stay byte-identical. `us6-zero-churn`
is unaffected for a second reason — its registry clause guards
`.specify/extensions.yml` being byte-identical after a run, a guarantee this
feature makes trivially true.

The real exposure is the **unit** tests that assert block text or scan the
consumer-facing docs:

| File | Why it is exposed |
| --- | --- |
| `tests/bash/ci/test_consumer_docs_invocation.bats` | scans consumer-facing docs for the commands they name |
| `tests/bash/ci/test_consumer_docs_naming_surface.bats` | same, for the naming surface |
| `tests/bash/engine/test_readme_idempotent.bats` + `ReadmeIdempotent.Tests.ps1` | assert the rendered block round-trips unchanged |
| `tests/bash/engine/test_readme_edgecases.bats` + `ReadmeEdgecases.Tests.ps1` | splice behaviour around the markers |

Only the first two are likely to hold the retired text; the idempotency and
edge-case tests assert *mechanism* and should pass unmodified. If one of them needs
editing, check that the edit is to a literal and not to the splice — 018 guards the
top edge of the managed region only, and human text below it has been destroyed
before.

---

## R8 — Version and release classification

**Finding**: `extension.yml:17` is `version: 0.23.0`. The three most recent
features on `main` (#57, #58, #59) were all breaking (`feat!:`, `feat(config)!:`,
`feat(routing)!:`) and each took a **minor** bump, which is correct SemVer for a
`0.x` line: below 1.0.0 the minor position carries breaking changes.

**Decision**: `0.24.0`, released as breaking. Constitution XII's "major version
bump" is satisfied by the leftmost position that can move in a `0.x` line; the
CHANGELOG entry carries the `BREAKING` marker and names, individually: the removed
`--enable-hook` flag, the removed `hooks.disabled` local-binding key, the removed
`effects.hooks` and `hook_health` summary fields, the five removed effect-status
values, and the removed silent dispatch hold.

**Note**: `extension.yml`'s own header states the version literal appears nowhere
else in the tree except `CHANGELOG.md`, and CI greps to prove it. The bump is two
files.

---

## R9 — Conformance disposition: one scenario retires, one is re-pointed

**Finding**: three of the 254 conformance scenarios touch this surface.

| Scenario | Depends on | Disposition |
| --- | --- | --- |
| `us9-hook-registration` | the ceremony's hooks effect and its status vocabulary | **Retire.** Its subject is deleted; there is no residual assertion to keep. |
| `us021b-disabled-event` | fixture `repo-with-disabled-event`, whose `config.local.yml` declares `hooks.disabled` | **Re-point.** Keep the fixture, keep the argv, change the expectation: the run is now refused with exit 4 and the located `unknown config.local key: hooks` message. |
| `us4-port-selection` | mentions the registry only in its description string | Reword the description; no behavioural change. |

**Decision on `us021b`**: re-pointing it is what makes SC-004 and FR-012 provable
in the same artifact. The refusal is byte-identical-across-ports behaviour on a
real fixture — which is precisely the class of claim a per-port unit test cannot
make, and this project has previously shipped a unit test where a conformance
scenario was required.

**Fixture hazard**: `repo-with-config`, `repo-with-spec` and
`repo-032-accept-site-replay` each carry a tracked `.specify/extensions.yml`. Those
stay. The registry existing in a fixture is not a violation — nothing opens it, and
their presence is what makes the guard's claim meaningful.

---

## R10 — The documentation surface FR-011 and SC-006 bind

**Finding**, enumerated by `git grep`:

| File | What is there now | What FR-011 / SC-006 require |
| --- | --- | --- |
| `INSTALL.md` (14 hook mentions) | a status table with `held_disabled` / `duplicated` / `unreadable`, a "how to disable a hook" section pointing at `--enable-hook`, and an upgrade section on leftover entries | Replace with: registration and its survival belong to the host; a repository whose hooks are absent will simply see nothing happen; a hand-disabled hook may be re-enabled by a reinstall without warning |
| `commands/speckit.jira-mirror.config.md` | a normative "hooks effect" section, the status table, the `--enable-hook` flag entry, and a front-matter `description:` promising to "verify lifecycle hooks" | Delete the section, the table and the flag; rewrite the description |
| `commands/speckit.jira-mirror.reconcile.md:400` | lists `--enable-hook` among flags tolerated on `reconcile` | Remove |
| `templates/readme-block.template` | see R7 | Rewrite |
| `README.md:170,183,599,610` | "reports hook registration"; the restricted-YAML-reader note naming `.specify/extensions.yml` | Rewrite; the YAML-reader note keeps its point but must stop citing a file we no longer read |
| `docs/03-lifecycle-hooks.md` | the module's own chapter | Rewrite around what remains: the manifest declares, the host registers, the bridge runs, one warning on failure |
| `docs/02-module-architecture.md`, `docs/05-reconcile-flow.md` | the module map and the flow both name the reader | Remove the module; remove the health step from the flow |
| `docs/04-config-ceremony.md`, `docs/01-system-context.md`, `docs/README.md` | incidental mentions | Sweep |

**Decision**: the sweep is scoped to shipped code and documentation. `specs/**` is
a historical record and is **not** rewritten — earlier specifications correctly
describe the world they were written in. `.specify/memory/constitution.md` already
carries the amendment. `CHANGELOG.md` gains an entry rather than losing its history.

**Rationale**: this project has previously shipped a feature whose tasks covered
the code's documentation but left a `README.md` stating the opposite of the
feature. SC-006's "zero occurrences … anywhere in shipped code or documentation" is
only checkable against an enumerated list, which is why the list is here rather
than left to the implementer's grep.

---

## Open questions

None. Every NEEDS CLARIFICATION raised while filling the Technical Context resolved
against the tree.
