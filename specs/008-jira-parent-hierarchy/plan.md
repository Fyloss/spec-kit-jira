# Implementation Plan: A Specification Mirrors as a Jira Hierarchy

**Branch**: `feat/create-epics` | **Date**: 2026-07-31 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-jira-parent-hierarchy/spec.md`

## Summary

The sink drops the parent. The neutral document has carried `epic.{title,description}` since 001,
`interchange_validate` requires it, and `plan_writes` never reads it — so a three-story
specification issues three `POST /rest/api/3/issue` calls and nothing else. This plan makes the
parent real: one artifact per specification, created before its children, carrying the
specification as prose, recognised on every later run by a durable identifier of its own.

Four repairs sit underneath it, and the order matters because each one unblocks the next.
Discovery must stop reading create metadata for one arbitrary issue type and read it for every
type the bridge writes to; the persisted binding must stop flattening issue types to
`{name: id}` and keep the hierarchy level and sub-task flag Jira already supplies; type
resolution must move off the literal `.issue_types.Story` lookup; and only then can the parent's
type be derived and the parent be planned, guarded, created, stamped and recorded.

Two findings from Phase 0 shape the design and one of them changes the spec's scope.

**R1 is load-bearing and was signed off on 2026-07-31 with two conditions.** Hierarchy level alone
cannot name the child type.
Jira's base level (`hierarchyLevel: 0`) holds several non-sub-task types in every real project —
Story, Task and Bug by default — and in this repository's own company-managed mock fixture it
holds two, `Story` (10102) and `Defect` (10103). Applying FR-006's ambiguity refusal at the child
level would refuse on essentially every project, including the existing
`us8-reconcile-company-managed` conformance scenario. Applying it only at the parent level leaves
FR-001 with no mechanism at all. R1 resolves this by following the precedent `_disc_style` already
sets: derive when the signal is unambiguous, and when it is not, let the layer above ask. The
answer is persisted in the **gitignored local binding with its provenance**, exactly as `style`
and `style_source` already are — not in the committable team config. That keeps the committed
format untouched, at the cost of one new closed question in the configuration ceremony.

Two conditions came with the sign-off and are now recorded in the artifacts rather than carried in
conversation. First, `style` is an objective property of a project and the child type is a team
preference, so a gitignored answer can diverge between developers on the same repository and
produce different issue types in the same Jira project. The committable switch is therefore
**required before rollout to a second team** — a dated trigger, not an open-ended "later" — and it
is purely additive, so deferring it risks backlog inconsistency, never breakage. Second, the stray
`projects[].issue_types` map is settled deliberately in R11: deleted rather than reserved, because
it maps names to identifiers while the future switch declares a name, and because it exists only
in a test fixture, so no consumer's committed file changes. See [research.md](./research.md) R1,
R2 and R11.

**R4 removes a whole class of assumption.** The bridge does not need to know how Jira attaches a
child to a parent. The child type's own create metadata says whether `parent` is offered, and the
same metadata answers FR-021 and FR-022. One fetch per written type serves the parent link, the
mandatory-field detection and the estimation candidates at once.

The rest is generalisation rather than new structure. The parent's identifier reuses
`story_marker.sh` (a second marker key in the same grammar, the same byte-preserving splice, the
same `creating` window); its identity reuses `identity.sh` and `recognition.sh`; its description
reuses `adf.sh`; its payload reuses the privacy guard; its refusals reuse `_reconcile_fault`,
which already gives Constitution III both halves for free.

## Technical Context

**Language/Version**: Bash >= 4 (macOS/Linux, gate in `lib/prereq.sh`) and PowerShell 7+
(Windows, gate in `lib/Prereq.psm1`). Two native implementations, no compiled artifact, no build
step, no download at runtime.

**Primary Dependencies**: `jq`, `curl`, `git` at runtime for the Bash port; PowerShell built-ins
only for the PowerShell port. This feature adds none. `kcov` and `bats` (Bash) and `Pester`
(PowerShell) stay development-time only.

**Storage**: Files only. The durable state this feature adds is one comment line per
specification in the repository's own `spec.md`, one entity property per parent ticket, and two
new per-type facts in the gitignored `config.local.yml` binding (hierarchy level, required
fields). No database, no cache.

**Testing**: `bats` (Bash), `Pester` (PowerShell), the language-agnostic conformance suite under
`tests/conformance/scenarios/` driven by `run-scenario.sh` against `mock-jira/mock-server.ps1`,
and the live suite for the Constitution II double-run assertion. Coverage by kcov (Bash, primary
gate) and Pester CodeCoverage (PowerShell), 80% statement minimum, near-100% on parent
recognition and on every fail-closed path.

**Target Platform**: macOS, Linux, Windows — the three-OS GitHub Actions matrix.

**Project Type**: Script-native Spec Kit extension.

**Performance Goals**: One extra `GET /rest/api/3/issue/{key}` per run once a parent is recorded
(the parent's recognition read), and one extra
`GET /rest/api/3/issue/createmeta/{key}/issuetypes/{typeId}` per written type at configuration
time only — two instead of one, never per reconcile. A twelve-story specification therefore
issues thirteen reads per lifecycle command instead of twelve. No batching: it would reintroduce
the index dependency R2 of spec 005 rejected.

**Constraints**: Byte-identical stdout, exit codes, Jira call sequences and resulting `spec.md`
bytes across both ports. Zero Jira writes on any run whose parent recognition is inconclusive. No
child created before its parent exists and is verified. No parent created before its identifier is
recorded. No credential, site host or accountId in any new diagnostic.

**Scale/Scope**: Two new modules per port (`spec_marker` in the engine, `hierarchy` in the sink),
seven changed modules per port, one changed engine parser, the mock double extended with parent
links and per-type create metadata, five new conformance fixtures. Roughly 700 changed lines per
port. To that add the work the reshaping imposes on state that already exists and which is easy to
cost at zero: five committed fixture bindings migrated to the list shape (T014a/T014b) and every
pre-existing reconcile scenario rebaselined for the parent call pair (T080a). Existing flat mirrors
in a consumer's Jira are not migrated; the spec puts that Out of Scope and the CHANGELOG must say
so plainly.

**NEEDS CLARIFICATION — carried into Phase 0 and resolved there**: how the child issue type is
named when its hierarchy level holds several candidates (resolved by R1/R2, and flagged above
because the resolution adds a closed question to the configuration ceremony).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — result recorded below
the table.*

| # | Principle | Gate at plan level | Status |
| --- | --- | --- | --- |
| I | Filesystem Is the Source of Truth | The parent is derived from `spec.md` and never the reverse. No delete is issued anywhere in this feature. A parent whose marker names another specification is reported and blocked, never adopted — adoption stays the opt-in, label-gated flow. The one file the bridge writes is `spec.md`, and it writes one comment line into it byte-preservingly, the discipline `story_marker.sh` already enforces. | PASS |
| II | Zero-Churn Idempotency | The parent's identity keys on a bridge-assigned identifier plus an entity property — never its summary. FR-011 removes the only description element that could not be made churn-free: a user-story list would have to be written after the children exist, forcing a second parent write on every first run. The zero-write assertion list gains `parent` as a write kind (R7). The live double-run assertion is a required task, since the principle says mocks are not sufficient. | PASS |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | Every new refusal — no parent level, ambiguous level, unresolvable child type, unsatisfiable mandatory field, retired config key, inconclusive parent read — returns through `_reconcile_fault`, which already returns the mapped code on a direct invocation and downgrades to one WARNING with success under `SPEC_KIT_JIRA_HOOK_CONTEXT`. FR-032 is therefore satisfied by the existing path with no new branch (R9). | PASS |
| IV | Credential Security | No new credential surface. The parent's payload goes through `privacy_guard_scan` before any write like every other payload (R8). The values this feature adds to the tracked tree are a 16-hex identifier and an issue key — neither is a token, an authentication email, a site URL, nor an accountId. New fixtures carry invented type names and field ids only. | PASS |
| V | Separation of Team Config / Local Binding / Secrets | Nothing is added to the committable layer; three keys are removed from it and a fourth, fixture-only stray is deleted (R11). The hierarchy level, the required-field schema and the operator's disambiguation answer are machine-owned instance facts and live in the gitignored `config.local.yml`, beside `style` / `style_source`, which set the precedent (R2). The deleted `projects[].issue_types` map is the counter-example that proves the boundary: it put resolved identifiers in the committable layer, and its committed value already disagreed with the binding's. No configuration moves inside the extension folder. | PASS |
| VI | Portability | Both ports change in the same commit. Removing `epic_strategy` crosses the engine, both sinks, the config layer and the conformance scenarios, so it is its own task set, not a one-liner (T-series in tasks). The parent identifier is generated through the existing `SPEC_KIT_JIRA_ID_SOURCE` seam, which is what keeps the two ports byte-identical under the conformance gate. | PASS |
| VII | No Hard-Coded Assumptions About the Jira Workflow | The principle this feature exists to restore. `.issue_types.Story` disappears. Both levels resolve from the project's reported hierarchy; where the hierarchy is ambiguous the bridge refuses or asks, and never guesses a name. Even the parent-link mechanism is read from the child type's create metadata rather than assumed (R4). Three non-default fixtures are merge-gating: Latin-with-diacritics, non-Latin script (CJK + Cyrillic), and SAFe. A type name is opaque text the bridge never parses, translates, normalises or matches, so no list of supported languages exists — the third fixture is there so the suite cannot be misread as covering two of them (FR-003b). | PASS |
| VIII | Neutral Engine / Jira Sink | The parent is a neutral concept in the engine: a title, description blocks, an opaque identifier, a marker. Hierarchy levels, type ids, the `parent` field, create metadata and ADF stay in the sink. `spec_marker.sh` takes pre-formatted marker text as a parameter exactly as `story_marker.sh` does, so the engine still contains no Jira vocabulary. The neutral document remains the only object crossing the boundary and is still validated before any write. | PASS |
| IX | Two-Tier Privacy Guard | Untouched in behaviour. The parent carries more of the specification than a story does, so the guard sees more text — which is the intent. The allowlist applies unchanged. | PASS |
| X | Self-Healing Automatic Mirror | Hook registration, health reporting and the permanence of an operator-disabled hook are untouched. The configuration ceremony gains one closed question (R2); it does not gain a write it did not already perform. | PASS |
| XI | Universal Dry-Run and Auditability | `--dry-run` derives the same types, predicts the parent creation or reuse, every `parent` reference, and every refusal — including the mandatory-field refusal, which must be predicted rather than discovered mid-write. The summary gains a `parent` line. No destructive operation is added; note that removing `epic_strategy` deletes one of the mapping-shape changes the guarded re-mode is documented as following, a documentation consequence only. | PASS |
| XII | Quality and Catalog Publication | CHANGELOG entry, version bump, three-OS matrix, lint and coverage stay blocking. The live suite carries the double-run over the parent. Dogfooding against the single consumer project is the acceptance signal, and is also where the Constitution II live proof is obtained. | PASS |
| XIII | TDD With a Minimum 80% Coverage | Every one of the four repairs gets its failing test first, per the repository's bug-fix policy: the literal type lookup, the hierarchy dropped at persistence, the single-type create metadata, and the dropped epic. The stale-binding refusal of FR-003a gets one too — it is the state every existing installation is in on its first run after the change, so it is tested rather than release-noted. Parent recognition and every fail-closed path are critical paths targeting near-100%. New fixtures include one non-default hierarchy and one parent type with a mandatory custom field, both required by the spec. Tests identify state by identifiers they recorded, never by machine-wide scan. | PASS |
| XIV | KISS | No new abstraction tier. Two new modules per port — `spec_marker` in the engine and `hierarchy` in the sink, each justified by the boundary its job sits on (see Structure Decision); everything else is an extension of a structure that already exists: the marker grammar gains a key, the identity marker gains a discriminator, recognition gains a role, the plan context gains two ids, the action set gains a `parent` field. FR-011 removes a feature rather than engineering a way to keep it correct. | PASS |
| XV | YAGNI | Four unconsumed config surfaces go: three retired keys, whose absence FR-031 enforces rather than assumes, and the fixture-only `projects[].issue_types` map, deleted rather than reserved (R11, FR-030a). No key is added to the committable layer: the parent's type is derived, and the child's disambiguation is an operator answer in the machine-owned binding, the shape `style_source: operator` already has. Both deferred keys stay in Out of Scope with their triggers written down — the parent-type key conditionally on FR-006 firing, the child-type switch on a date, before rollout to a second team. | PASS |
| XVI | Human Readable | Every new refusal names the project, the level, the candidates, the issue type, the field or the key, and carries a copy-pasteable remedy; they are catalogued in one contract rather than scattered as strings. `binding-shape-stale` is the sharpest case: it says the binding is a version behind rather than reusing "not bound yet", because the wrong message reads as a bug to an operator who has already run the ceremony (FR-003a). The parent reads as prose under named sections. One consequence recorded in the spec: the constitution's own example of a business-language key is `epic_strategy: per_feature`, which this feature deletes — a separate patch-level amendment, not a dilution. | PASS |

**Initial gate**: PASS — no violations. Complexity Tracking is empty.

**Post-Phase-1 re-check**: PASS. The one item raised for sign-off was granted on 2026-07-31 with
two conditions, both now folded into the artifacts. Four points re-examined after the design
artifacts existed:

- *Principle XV and the configuration ceremony (R1/R2, signed off).* The spec says the child issue
  type is not configurable in this feature. Phase 0 established that it is also not derivable,
  because the base hierarchy level is ambiguous in nearly every real project. The design resolves
  this without adding a committable key, by asking once at configuration time and persisting the
  answer with its provenance in the gitignored binding — the `style` precedent exactly. In
  practice the question fires for nearly every project, so the operator does end up choosing the
  story type; what stays Out of Scope is the *committable, team-wide* switch, and it now carries a
  dated trigger rather than an open-ended one (see the next point).
- *Principle XV and the divergence the local answer permits (condition 1).* `style` yields the
  same answer for every developer; the child type does not, because `Story` and `Defect` are each
  legitimate. A gitignored answer can therefore diverge across a team and produce mixed issue
  types in one project. Nothing breaks — identity keys on the marker, not the type — but the
  backlog degrades invisibly. The committable key is consequently required before rollout to a
  second team, is purely additive, and costs no migration. Recorded in the spec's Out of Scope
  with that trigger, and in research R2.
- *Principle VIII and the parent's placement in `spec.md`.* The parent marker sits after the H1,
  which is also where the implicit-story marker goes when a specification has no `User Story`
  headings. R3 proves the two cannot collide: `story_marker_parse_line` returns `kind: "none"` for
  any body that is not `story=<16 hex>`, so `_smk_section_has_marker` does not see a `spec=` line
  and still assigns the implicit story its own marker. A regression test pins this.
- *Principle II and ordering.* The parent must be created before its children (FR-012), so the
  action set is no longer a flat list — it has a head. R7 records why the parent is a distinct
  planning step rather than element zero of the same array: its creation response supplies the key
  that every subsequent child action needs, which a pre-computed array cannot express.

**R5 is confirmed as the first implementation task**, and it grew one requirement from the
sign-off. Reconcile must detect a binding carrying no hierarchy metadata and refuse with its *own*
message — the binding predates parent support, re-run `/speckit.jira.config` — rather than reusing
the "project has not been bound yet" text or, worse, falling through to a resolution that yields
an empty issue type and fails obscurely inside the write planner much later. Every existing
installation is in that state on its first run after the change, the maintainer's machine
included, so it ships with tests in both ports and a conformance scenario (quickstart Step 3b,
FR-003a). An earlier draft of R5 proposed reusing the existing message; that is corrected in
research.md.

Complexity Tracking remains empty.

## Project Structure

### Documentation (this feature)

```text
specs/008-jira-parent-hierarchy/
├── plan.md                          # This file
├── research.md                      # Phase 0 — eleven decisions; R1, R2 and R4 are load-bearing
├── data-model.md                    # Phase 1 — entities, changed structures, state transitions
├── quickstart.md                    # Phase 1 — thirteen validation steps, ending at the live gate
├── contracts/
│   ├── parent-marker.md             # Grammar extension, placement, read rules, write rules
│   └── hierarchy-resolution.md      # Derivation, refusals, required fields, diagnostics, exit codes
├── checklists/
│   └── requirements.md              # Spec quality checklist (complete)
└── tasks.md                         # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
scripts/bash/
├── engine/
│   ├── parse.sh                     # CHANGED — read the spec marker; extract success criteria
│   │                                #           and out-of-scope into epic.description
│   ├── spec_marker.sh               # NEW — the parent identifier: assign, mark, record, splice
│   ├── story_marker.sh              # CHANGED — shared grammar primitives exposed to spec_marker
│   └── interchange.sh               # CHANGED — drop epic.strategy; carry the parent marker
├── sink/jira/
│   ├── discovery.sh                 # CHANGED — createmeta per written type; keep hierarchy_level
│   │                                #           and subtask; record required fields
│   ├── identity.sh                  # CHANGED — the marker gains a parent discriminator
│   ├── recognition.sh               # CHANGED — recognise the parent before any story
│   ├── plan_apply.sh                # CHANGED — plan the parent; emit `parent` on every child;
│   │                                #           create the parent first and stamp it
│   └── hierarchy.sh                 # NEW — derive parent/child types; the mandatory-field gate
├── lib/
│   └── config.sh                    # CHANGED — retire three keys; persist levels + required fields
└── commands/
    ├── config.sh                    # CHANGED — the disambiguation answer and its provenance
    └── reconcile.sh                 # CHANGED — sequence derive → gate → recognise parent →
                                     #           plan → create parent → create children

scripts/powershell/                  # the same ten files, mirrored
├── engine/{Parse,SpecMarker,StoryMarker,Interchange}.psm1
├── sink/jira/{Discovery,Identity,Recognition,PlanApply,Hierarchy}.psm1
└── {lib/Config,commands/Config,commands/Reconcile}.psm1

tests/bash/
├── engine/test_spec_marker.bats               # NEW — grammar, placement, no collision with story
├── sink/test_hierarchy.bats                   # NEW — derivation, both refusals, required fields
├── sink/test_recognition_parent.bats          # NEW — parent decision table, fail-closed matrix
├── sink/test_plan_apply_parent.bats           # NEW — parent-first ordering, `parent` on children
├── commands/test_reconcile_hierarchy.bats     # NEW — the regression: one parent, three children
├── commands/test_reconcile_stale_binding.bats # NEW — a pre-feature binding refuses legibly
├── lib/test_config_binding_shape.bats         # NEW — the binding keeps level + subtask (R5)
└── lib/test_config_retired_keys.bats          # NEW — retired-key refusal, hook downgrade
tests/powershell/                              # mirrors the eight suites above

tests/conformance/
├── scenarios/us1-hierarchy-french.json            # NEW — non-default type names, no code change
├── scenarios/us1-hierarchy-safe.json              # NEW — Capability/Feature/Story
├── scenarios/us1-hierarchy-no-parent-level.json   # NEW — refusal, zero writes
├── scenarios/us1-hierarchy-ambiguous.json         # NEW — refusal naming every candidate
├── scenarios/us2-parent-first-run.json            # NEW — one parent, three children, links
├── scenarios/us2-parent-second-run.json           # NEW — zero writes, spec.md byte-identical
├── scenarios/us3-mandatory-field-refusal.json     # NEW — dry-run and real run agree
├── scenarios/us1-binding-shape-stale.json         # NEW — a pre-feature binding, refused legibly
├── scenarios/us4-retired-key-refusal.json         # NEW — exit 4 direct, WARNING under hook
├── fixtures/repo-with-french-project/             # NEW — Récit at level 0
├── fixtures/repo-with-nonlatin-project/           # NEW — ストーリー at level 0 (CJK + Cyrillic)
├── fixtures/repo-with-safe-project/               # NEW — Capability/Feature/Story
├── fixtures/repo-with-mandatory-field/            # NEW — parent type with a required custom field
└── mock-jira/                                     # CHANGED — parent links, per-type createmeta
    ├── mock-server.ps1
    └── fixtures/createmeta-issuetypes-{french,nonlatin,safe}.json  # NEW

# CHANGED, and easy to miss — the five committed bindings still in the old map shape
tests/conformance/fixtures/{repo-with-mirrored-spec,repo-with-reconcile-binding,
  repo-with-two-styles,repo-with-unicode-binding,repo-with-reconcile-legacy}/
  .specify/jira/config.local.yml     # CHANGED — reshaped to the list form (tasks T014a/T014b)
tests/conformance/scenarios/*.json   # CHANGED — every reconcile scenario gains the parent
                                     #           call pair and fields.parent (task T080a)

tests/live/
└── test_live_zero_churn.bats        # CHANGED — the double run now covers the parent
```

**Structure Decision**: the script-native layout is kept exactly as it is, and the two new modules
sit on the side of the boundary their job belongs to. `spec_marker.sh` is identifier assignment
and Markdown splicing, so it is `engine/` and contains no Jira vocabulary — it takes the marker
key as a parameter the way `managed_section.sh` takes its delimiters. `hierarchy.sh` reads
hierarchy levels, issue-type ids and create metadata, all Atlassian identifiers, so it is
`sink/jira/`. Only `commands/reconcile.sh` sources both, the shape 004 established and 005
followed.

The mock double is again the piece of test infrastructure that must grow. It serves create
metadata for one issue type per project style today and has no notion of a parent link; neither
the hierarchy derivation nor the mandatory-field gate nor the parent-first ordering is testable
until it does both.

## Scope boundaries worth stating

Five things a reader might expect here and will not find:

1. **No migration.** Tickets created flat carry no parent and no parent marker. Their
   specifications are re-mirrored from a clean state. The spec puts this Out of Scope; the
   CHANGELOG must say so in plain words, because it is the one user-visible cost.
2. **No user-story list on the parent.** FR-011 forbids it, and the reason is idempotency rather
   than taste: the parent exists before its children do, so any list of them costs a second write
   on the first run. Jira's own child view is the list.
3. **No sub-tasks and no `tasks.md`.** The hierarchy this feature builds is exactly two levels
   deep. Sub-task types are excluded from both derivations.
4. **No values for mandatory fields.** The gate detects and refuses. Supplying values, proposing
   defaults and asking for them during the ceremony are a separate feature, and no key for them is
   added here.
5. **No committable Story-versus-Task switch — but it is scheduled, not open-ended.** The child
   type is answered per developer in the gitignored binding. Because that answer is a team
   preference rather than an objective fact, developers can diverge and mix issue types in one
   project. The committable key must therefore ship **before rollout to a second team**; it is
   purely additive and costs no migration. This is the one deferral in the feature that carries a
   date, and `/speckit-tasks` should not fold it into this task set.

## Complexity Tracking

> No Constitution Check violations. This section is intentionally empty.
