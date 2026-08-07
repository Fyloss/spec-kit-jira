# Phase 0 Research: A Ticket the Mirror Created Is the Mirror's to Replace

**Feature**: 019-fix-duplicate-acceptance-criteria | **Date**: 2026-08-06

Every finding below was measured against the working tree at `1916286`, not inferred. The reproduction
scripts are reproduced inline so a reviewer can re-run them.

---

## R1 — Where the defect actually is, and where it is not

**Decision**: The update path for a description that already carries the boundary is correct and is not
touched by this feature. The defect is confined to the `marker_count == 0` branch of
`_adf_resolve_managed` (`scripts/bash/sink/jira/adf.sh:256`).

**Rationale**: Measured. A description created by the current release, then re-rendered from an edited
specification:

```
CREATE  : AC sections = 1
UPDATE 1: status=ok  AC sections = 1   ("Hello Universe", no trace of "Hello World")
UPDATE 2: status=ok  AC sections = 1   byte-identical to UPDATE 1
TASK UPDATE: status=ok                 (task tier, same result)
```

The same content with the boundary stripped — a description written by a release predating 018 —
reproduces the report exactly:

```
UPDATE 1: status=migrated-warned  AC sections = 2
UPDATE 2: status=ok               AC sections = 2   (the stale copy is now permanent)
```

The second run reports `ok` because the stale copy has been re-attributed to the human prefix, where every
later run preserves it verbatim. This is why the duplicate never heals.

**Alternatives considered**: Rewriting the update path to diff against the current description — rejected:
there is nothing wrong with it, and the measurement says so.

---

## R2 — The evidence that identifies the mirror's own output

**Decision**: The ticket's **recorded origin**, read from the server-side identity entity property
(`scripts/bash/sink/jira/identity.sh`). Values are `"bridge"` (the mirror created the ticket) and
`"human"` (a human created it and handed it over via `mention`).

**Rationale**:

- It is authoritative rather than inferential. `identity_marker` takes `origin` as a required positional and
  every caller supplies one: `ticket.sh:160` writes `"bridge"` on creation, `mention.sh:103` writes
  `"human"` on adoption.
- It is not operator-editable. The marker lives in a Jira **entity property**, hidden from the editable UI —
  which is exactly what Constitution II demands of an identity signal, and why the label and the summary are
  both unusable for this purpose.
- It already survives updates. Each update path rebuilds the identity stamp from the *recorded* origin
  rather than assuming `"bridge"`: `plan_apply.sh:391` (story), `:548` (parent), and the task equivalent.
  So adopting a human's ticket does not silently flip it to `bridge` on the first write.
- **It is already in scope at every call site.** No new plumbing, no second discovery pass:

  | Tier | Origin available as | Render call site (bash) |
  | --- | --- | --- |
  | Story | `ctx.ticket_origins[<local_id>]` | `plan_apply.sh:365` |
  | Parent | `ctx.parent_origin` | `plan_apply.sh:520` |
  | Sub-task | `ctx.ticket_origins[<task_id>]` | `plan_apply.sh:733` |

  `reconcile.sh:348` populates the story origins, `:397` merges the task tier into the same map, and
  `:1020` supplies `parent_origin`.

**Alternatives considered**:

- *A structural fingerprint of the mirror's own shape* (a trailing run of nodes matching heading + info
  panel + design). Rejected: it guesses where a record already states the answer, it puts sink vocabulary
  into a decision the engine must own, and a human imitating the shape would be misclassified. Named out of
  scope in the spec.
- *The provenance label `speckit-<slug>`* — rejected: feature 017 applies it to adopted tickets too, so it
  does not discriminate, and labels are operator-editable (Constitution II).
- *The `ticket=` binding in `spec.md`* — rejected for the same reason: a `mention`-adopted ticket is bound
  identically to a created one.

---

## R3 — What happens when the origin is neither `bridge` nor `human`

**Decision**: Treat any value that is not exactly `bridge` or `human` as **undeterminable**: preserve the
whole existing description and reuse the existing `migrated-warned` status, which already produces a named
warning. Do **not** change `recognition.sh`'s `.origin // "bridge"` default.

**Rationale**: FR-004 requires the safe branch. It is not reachable through any shipping code path — every
marker carries an origin — so this is a defensive branch reached only by a hand-edited or corrupted entity
property. Implementing it at the decision point makes it unit-testable (pass an arbitrary string) at
near-zero cost. Changing recognition's default instead would ripple into the identity re-stamp, which would
then write a bogus origin back to the property, and would churn the recognition contract and its conformance
output for a case that does not occur.

**Alternatives considered**: Introducing an explicit `"unknown"` value through recognition — rejected on
blast radius, as above. Defaulting an unrecognised origin to `bridge` — rejected outright: it is the one
branch that can delete a human's description.

---

## R4 — Where the decision lives

**Decision**: A new **neutral engine** function owns the whole decision:
`managed_section_ownership_split <marker> <managed-json> <ownership>` (bash) /
`Split-JiraManagedSectionOwnership` (PowerShell), in `engine/managed_section.sh` and
`engine/ManagedSection.psm1`. `<ownership>` is one of `self` | `other` | `unknown` — pure neutral
vocabulary. The sink translates its own values (`bridge`→`self`, `human`→`other`, anything else→`unknown`)
and keeps the marker wording and the document format, as it does today.

**Rationale**: Constitution VIII and FR-020. The engine already takes its markers as parameters and knows
nothing about READMEs or Jira; taking ownership as a third opaque parameter is the same seam. Putting the
branch in `adf.sh` instead would leave the ownership rule in the sink, where the constitution says it may
not live, and would make it untestable without the tracker's document shape.

`managed_section_suffix_split` is **retained unchanged** — it remains the rule for `other`, which is
precisely the case it was written for (FR-003, "today's behaviour, unchanged").

**Alternatives considered**: Passing a pre-computed boolean from the sink — rejected: that is the decision,
so it would be the sink making it.

---

## R5 — The decision table

**Decision**:

| Existing description | Ownership | Prefix kept | Status | Warning |
| --- | --- | --- | --- | --- |
| no existing (creation) | — | — | `ok` | none |
| `marker_count > 1` | any | — (nothing written) | `malformed` | existing |
| `marker_count == 1` | any | nodes above the marker | `ok` | none |
| `marker_count == 0` | `self` | **empty** | `ok` | none |
| `marker_count == 0` | `other` | suffix split (today) | `ok` \| `migrated-warned` | existing |
| `marker_count == 0` | `unknown` | whole content | `migrated-warned` | existing |

**Rationale**: Only one row changes — `marker_count == 0` + `self`. Every other row is today's behaviour
verbatim, which is what makes the regression surface small and the diff reviewable. The status vocabulary is
unchanged, so `_plan_apply_managed_field` (`plan_apply.sh:220`) and its PowerShell twin need no edit and no
new warning text (FR-015).

Note the ordering: the marker count is decided **before** ownership. A ticket that already carries a
boundary is never touched by the new branch, so `self` cannot reach into a human prefix that the boundary
already protects.

---

## R6 — Blast radius

**Decision**: Six source files, three per port, plus tests.

| Port | File | Change |
| --- | --- | --- |
| bash | `engine/managed_section.sh` | new `managed_section_ownership_split` |
| bash | `sink/jira/adf.sh` | `_adf_resolve_managed` takes ownership; both `adf_render_managed_*` pass it through |
| bash | `sink/jira/plan_apply.sh` | 3 call sites read the origin already in `ctx` and translate it |
| pwsh | `engine/ManagedSection.psm1` | new `Split-JiraManagedSectionOwnership` + export |
| pwsh | `sink/jira/Adf.psm1` | `Resolve-JiraManagedAdfContent`, `ConvertTo-JiraManagedAdfDocument`, `ConvertTo-JiraManagedTaskAdfDocument` |
| pwsh | `sink/jira/PlanApply.psm1` | 3 call sites (lines 424, 586, 730) |

**One ordering hazard, PowerShell only**: at all three PowerShell call sites the origin is read *after* the
render call (`$ticketOrigins` at 448 vs the render at 424; `$parentOrigin` at 609 vs 586; `$taskOrigins` at
846 vs 730). Each lookup must be hoisted above its render. The bash port reads `ctx` inline and has no such
ordering.

**Rationale**: Measured by reading every call site, not estimated.

---

## R7 — Test surfaces, and the two that must change rather than grow

**Decision**: New coverage is additive except for two existing artefacts whose recorded expectation is the
behaviour being fixed:

- `tests/conformance/scenarios/us4-migration-ambiguous.json` — its fixture sets `"origin":"bridge"`, so its
  expectation flips from "content duplicated, one warning" to "content replaced, no warning". It is
  **rewritten**, and a **new** `us4-migration-ambiguous-human.json` carrying `"origin":"human"` is added so
  the FR-003 path keeps its conformance coverage.
- `tests/bash/sink/test_boundary_migration.bats` and its Pester twin — the sink-level assertions on the
  `marker_count == 0` path need an origin per case.

Unchanged and used as regression guards: `tests/bash/engine/test_managed_panel.bats`,
`tests/bash/engine/test_managed_migration.bats` (the suffix split itself does not change),
`tests/bash/sink/test_preserve_boundary.bats`,
`tests/bash/sink/test_adf_task.bats`, `tests/conformance/scenarios/us4-migration-clean.json`,
`sc008-deleted-managed-region-restored.json`.

New: `tests/bash/engine/test_managed_ownership.bats` (the decision table, all six rows, both ports through
the existing cross-port harness), plus the failing reproduction described in the quickstart.

**Two more existing artefacts change, beyond the two above** (found during implementation, not predicted
here — recorded per T051):

- `tests/bash/sink/test_adf.bats` and `tests/powershell/sink/Adf.Tests.ps1` — the pre-existing contract §3
  origin-independence regression case called `adf_render_managed_description` / `ConvertTo-JiraManagedAdfDocument`
  without a third argument. Omitting it now defaults to ownership `unknown` (contract §2) rather than `other`
  — a different row of the decision table, and the wrong one for what this case tests (the suffix-split
  path). Each call is updated to pass `human` explicitly; the migration behaviour under test is unmodified
  (contract §5.3).
- `tests/bash/ci/test_conformance_no_cross_os_shard.bats` — the hard-coded scenario count moves 106 → 107,
  for the new `us4-migration-ambiguous-human.json` the rewrite of `us4-migration-ambiguous.json` (above)
  would otherwise leave uncovered.
- `tests/conformance/mock-jira/configs/preserve-pre-release.json` — PRE-2 and PRE-3 flip from
  `origin:"bridge"` to `origin:"human"`. Left at `bridge`, both would route through rule 3 (`self`) and lose
  the human paragraph PRE-2 carries — the accepted trade-off in the spec's Edge Cases, not the suffix-split
  behaviour these two fixtures exist to pin. The flip keeps their pre-existing expectations green at the
  cost of removing the only fixture where a pre-018 bridge-origin ticket carries a human paragraph; T052
  adds a dedicated case for that trade-off rather than leaving it implicit in a relabelled fixture.

**Rationale**: A conformance scenario that encodes the defect as expected output will pass after the fix
only if it is rewritten. Discovering that during implementation, rather than here, is how a "green suite"
hides a behaviour change. The `test_adf.bats` / `Adf.Tests.ps1` case is the same lesson from a different
angle: adding an optional parameter with a non-identity default (`unknown`, not "no-op") changes what an
*existing* call that omits it now exercises, even though no existing call site's behaviour was the target.

---

## R8 — FR-005's scope, and the content dependency retained on the `other` branch (T045)

**Decision**: FR-005 ("the decision MUST NOT depend on the content being byte-stable across a round trip")
is fully satisfied for the `self` branch — rule 3, the reported defect and the reason this feature exists.
It is **not** satisfied for the `other` branch: `managed_section_ownership_split`'s `other` case delegates to
`managed_section_suffix_split` verbatim (R4), which is a structural array comparison, and its outcome
(`prefix` kept vs whole content preserved; `ok` vs `migrated-warned`) changes if the tracker re-serialises
the stored document between runs. This is a **named, justified exception**, not an oversight: `other` keeps
018's pre-existing migration behaviour byte-for-byte (contract §5.3, the regression guard), and the two are
in tension by construction — FR-005 was written against the `self` decision this feature adds, not against
the `other` branch this feature inherits unchanged.

**Rationale**: Narrowing rule 4 to be origin-only — dropping the suffix comparison and always preserving the
whole content with a warning, matching rule 5's `unknown` branch — was measured, not assumed, against
`tests/bash/sink/test_boundary_migration.bats`'s PRE-2 case (an adopted, human-origin story whose stored
description already ends with exactly what the mirror would render for it today). Under the narrowed rule,
that trailing line would be kept in `prefix` **and** re-rendered in the fresh region below the marker —
the literal duplication FR-006/FR-007 forbid, on the one tier (a legacy, human-adopted, pre-boundary ticket)
this feature does not touch. The suffix match exists to prevent exactly that: when it matches, the matched
tail is not discarded, it is deduplicated, because the identical content reappears in the freshly rendered
region immediately below (data-model.md §3's invariant — "`prefix` never contains a copy of" the rendered
region — already states this for every status, `other` included). When the suffix does not match, the whole
array is kept as `prefix` and nothing is stripped (PRE-3). So FR-003's "preserve the entire existing
description" holds in effect on both outcomes of rule 4 — nothing a human wrote is discarded — even though
the *mechanism* used to reach it depends on stored-content bytes, which is the part FR-005 (read as
unconditional) would forbid.

**Alternatives considered**: Narrowing rule 4 as above — rejected on the measurement immediately above: it
reintroduces the reported defect's shape on a surface this feature is not chartered to change (Out of
Scope: "Repairing or migrating tickets already carrying a duplicate"; the pre-boundary migration path is
018's, not 019's). Silently leaving FR-005 unqualified in the spec — rejected: `research.md` and
`data-model.md` did not mention FR-005 at all before this entry, which is the gap this section closes.

---

## Resolved unknowns

No `NEEDS CLARIFICATION` remains. The spec's two open questions were closed before it was written: the
identifying evidence is the recorded origin (R2), and repair of already-damaged tickets is out of scope by
the reporter's explicit decision.
