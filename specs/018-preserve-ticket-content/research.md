# Phase 0 research — preserving what the mirror did not write

Six questions had to be settled before any design could be drawn. Four came from the specification's own
unknowns; two (R2 and R4) surfaced only from reading the shipped code and change the shape of the work.

Every "today" statement below is a reading of the code on this branch (`1aeedad`), not a recollection.

---

## R1 — Is the boundary a new mechanism, or an existing one behind a closed gate?

**Decision**: It is an existing mechanism behind a closed gate. This feature opens the gate.

**Rationale**: `sink/jira/adf.sh:200` already implements exactly the required rendering:

```
adf_render_managed_description <content> <origin> [existing]
  origin == "bridge-created"  ->  the whole description IS the managed section, no delimiter
  otherwise                   ->  prefix (split at the marker) + marker + freshly rendered managed nodes
```

The neutral split it delegates to, `managed_section_panel_split` (`engine/managed_section.sh:168`), takes
the marker as a **parameter** and treats every node as opaque JSON, so it already satisfies Principle VIII
for any origin. The churn comparison for the delimited case, `plan_managed_description_status`
(`sink/jira/plan_apply.sh:492`), already compares the managed portion alone.

The gate is closed in two places, both deliberately and both with a comment saying so:

- `commands/reconcile.sh:348` — `ticket_origins` is built with
  `with_entries(select(.value.origin != "bridge"))`, so a bridge ticket never appears in the map.
- `commands/reconcile.sh:1176` — the lifecycle context omits `origin` when it is `"bridge"`, for the same
  stated reason.

Both call sites then test `[[ -n "${origin}" && "${origin}" != "bridge-created" ]]`
(`plan_apply.sh:325`, `:446`, `:683`). The work is to stop excluding `"bridge"` and to make the delimited
path unconditional, then to fix everything that assumed otherwise.

**Alternatives considered**: A second, bridge-specific boundary mechanism — rejected by Principle XIV and
by the operator-facing consequence that two kinds of mirrored ticket would read differently in Jira. A
"preserve the whole description and append" scheme with no marker — rejected because without a delimiter
the mirror cannot find its own content again on the next run, so it could never refresh it.

---

## R2 — Where does the plan section have to move to satisfy FR-001?

**Decision**: Nowhere. It is already last, and User Story 1 is delivered almost entirely by User Story 2's
mechanism.

**Rationale**: `commands/reconcile.sh:731` appends the parsed plan blocks to `.epic.description.blocks`,
and `_adf_content_nodes` (`adf.sh:82`) renders, in fixed order: the description body, then the acceptance
panel, then the Design section. The parent carries neither an acceptance panel nor a Design section — 
`parse_spec` builds the epic from `parse_title` and `parse_description_blocks` only — so the plan blocks are
already the last nodes of the parent's description. FR-001's "after the specification-derived content" is
already true.

What is *not* true today is FR-001's other half — that the plan lands as an addition to the description
that already exists. That is the boundary, i.e. R1. Once the managed region exists, FR-002 (replace in
place, exactly one section), FR-004 (a deleted plan removes its section) and FR-005 (unchanged plan, zero
writes) all fall out of the region being re-rendered wholesale and compared as a unit — no per-section
bookkeeping is needed.

**Consequence for planning**: User Story 1 needs no production code of its own beyond User Story 2's. It
still needs its own tests, and it is still the story the operator asked for, so it keeps its P1 slot and
its acceptance scenarios become conformance scenarios.

**Alternatives considered**: A dedicated, separately delimited plan sub-region that could be spliced
independently of the rest — rejected as speculative genericity (Principle XV): nothing requires the plan
section to be updatable without re-rendering the region around it.

---

## R3 — How does a description that carries no boundary acquire one without loss or duplication?

**Decision**: Exact **suffix match** against the freshly rendered managed nodes; on no match, preserve
everything as human prefix and report one named warning.

**Rationale**: On the first run after the upgrade a bridge ticket's description is
`[human additions?] ++ [what the mirror wrote at the last reconcile]`. The mirror can render what it would
write *now*. Three cases follow:

| Existing content | Suffix match against freshly rendered managed nodes | Outcome |
|---|---|---|
| Exactly the mirror's output, untouched | Matches, prefix empty | Clean migration: prefix `[]`, marker, managed nodes. No duplication, nothing lost. |
| Human prose, then the mirror's output | Matches, prefix is the human's nodes | Exact: the human's nodes are preserved, the marker goes above the managed nodes. |
| The specification also changed this run, or the human edited inside the mirror's region | No match | Preserve everything as prefix, append marker + managed nodes, and warn by ticket key. |

The first two cases are the overwhelming majority in the reported workflow, because between `after_plan`
and `after_tasks` the specification does not change — which is precisely the sequence the defect report
describes.

The third case is a real, if narrower, outcome and it duplicates the mirror's previous output above the
new region. That is the lesser evil: duplication is visible in the ticket, recoverable by a human, and
loses no information, whereas discarding the unmatched remainder is silent and irrecoverable — forbidden
by Principle I ("never silently regress a ticket") and by Principle III's fail-closed rule. The warning is
what makes it actionable.

`managed_section_panel_split` cannot express this: it is marker-driven, and there is no marker. The
migration therefore needs a sibling engine function, `managed_section_suffix_split <managed-nodes>`
(stdin: the existing node array), returning `{prefix, matched}` — pure array comparison, no marker, no
tracker vocabulary.

**Spec impact**: FR-020 as written promises no loss *and* no duplication unconditionally. The third case
cannot honour both. Recommended refinement is recorded in the plan's Complexity Tracking and left for
`/speckit-clarify` rather than edited in here.

**Alternatives considered**: Recording a digest of the last-written description in the identity property —
rejected by Principle XV, because from this release onward the marker *is* the record, so the digest would
serve exactly one run per ticket and then be dead weight. Treating a boundary-less bridge description as
disposable — rejected as above. Writing the marker without re-rendering (a marker-only migration `PUT`) —
rejected because it doubles the write count for no gain: the same `PUT` can carry both.

---

## R4 — What happens the first time a human pastes a Jira link into a mirrored description?

**Decision**: Today, it would refuse the entire run — permanently. The pre-write scan must be narrowed to
the content the mirror **composes**, excluding the preserved human prefix.

**Rationale**: `privacy_guard_reason` (`sink/jira/privacy_guard.sh:85`) blocks on
`[a-z0-9][a-z0-9-]*\.atlassian\.net`, case-insensitively, with a dedicated exit code and zero writes. A
Jira ticket description containing a link to another Jira ticket matches it. Once the boundary preserves a
human's prefix, the mirror reads that link out of Jira and sends it back in the next `PUT` — so the payload
carries the match, the guard blocks, and `apply_writes` aborts the whole apply, not just that ticket. The
next run does the same, and the one after that: the only escape is a human deleting the link from Jira.
Linking one Jira ticket from another is an entirely ordinary thing to do.

The guard's purpose, in Constitution IV, is directional: "No token, authentication email, real site URL, or
accountId may ever enter a tracked file" and "a pre-write guard MUST scan the tracked tree and block on any
leak of a known coordinate". The concern is repository → Jira. Text read from a Jira ticket and written
back to that same ticket travels Jira → Jira; it cannot leak anything that is not already in the
destination.

Principle IX's own rationale settles it: "A blocking control with false positives ends up disabled:
precision wins over recall at the BLOCK tier." Scanning round-tripped remote content is a false-positive
generator by construction. Narrowing the scan to mirror-composed content therefore *serves* Principle IX
rather than conflicting with it — but it is still a change to a security control, so it is argued in the
plan's Complexity Tracking rather than slipped in.

The narrowing is bounded: every field the mirror composes — summary, the managed region's own nodes,
labels, priority, every other payload — is scanned exactly as today. Only the verbatim preserved prefix is
exempt, and only because it is verbatim.

**Side effect worth stating**: this closes the same latent defect on adopted (human-origin) tickets, where
the prefix is already round-tripped today and the same block is already reachable.

**Alternatives considered**: Downgrading the `*.atlassian.net` rule from BLOCK to WARN — rejected, it
weakens the guard for content the mirror genuinely composes. Requiring consumers to allowlist their own
site host — rejected: it makes the feature unusable without configuration, and it blinds the guard to that
host in every other payload. Blocking only the offending ticket instead of the run — rejected as a change
to the guard's fail-closed contract that R4 does not need.

---

## R5 — Where does the last-written summary live, and how is a rename distinguished from a retitle?

**Decision**: One additional field, `summary`, on the identity entity property the mirror already stamps.
Compare on a whitespace-normalised form.

**Rationale**: `identity_marker` (`sink/jira/identity.sh:36`) builds
`{origin, repo, spec_slug, role?, story?}` and `identity_write` `PUT`s it to the per-issue property
`spec-kit-jira`. Constitution II requires identity to rely on stable properties and never on an
operator-editable display name — an entity property is exactly that, and it is the only place a
last-written value can live where a human cannot edit it. `identity_claimed_by_other` compares `repo` and
`spec_slug` only, so an added field cannot disturb the claim logic. `recognition_run` already reads the
property (`recognition.sh:71` requests it inline with the issue fetch) and already extracts `origin` from
it at `:367`, so surfacing `last_summary` costs no extra request.

The decision table, per recognised ticket:

| Recorded `summary` | Current Jira summary | Outcome |
|---|---|---|
| absent (predates this release, or a ticket the mirror never updated) | anything | Reconcile the summary exactly as today; record what is sent. FR-018 — the first run never warns about a rename it could not have observed. |
| present, equals current (normalised) | — | The mirror owns the summary: send the specification's title if it differs, silently. FR-017. |
| present, differs from current (normalised) | — | A human renamed it. Omit `summary` from the desired fields, warn by ticket key and field name, keep the human's wording. FR-015. |
| present, differs, and `--on-drift=proceed` | — | Send the specification's title, report the overwrite as an ordinary update, and record the new value. FR-016. |

Normalisation is trim-then-collapse-internal-whitespace on both sides, because Jira normalises summaries
server-side and an un-normalised comparison would warn about a divergence no human created. The **raw**
value sent is what gets recorded; normalisation applies only to the comparison.

**Write discipline**: `identity_write` is called today only on `POST` (`plan_apply.sh:1053`, `:1104`,
`:1162`) — an update never re-stamps. The record must therefore also be stamped after a `PUT` that carried
a summary. Binding the stamp to "a summary was actually written this run" is what keeps Constitution II
intact: a settled mirror emits no summary write, so it emits no property write either, so an unchanged
re-run stays at zero.

**Alternatives considered**: A label — rejected, operator-editable, and Constitution II forbids identity on
mutable display state. A separate entity property — rejected, a second round-trip per ticket for one
scalar. Storing the summary in the local binding — rejected, the binding is gitignored and per-developer,
so a second developer's run would see no record and warn spuriously.

---

## R6 — What does a malformed or duplicated boundary do?

**Decision**: `managed_section_panel_split` gains a `marker_count`; more than one marker node warns by
ticket key and the description write is skipped for that ticket alone.

**Rationale**: The split takes the **first** node whose strings contain the marker and treats everything
from there on as managed. With two markers, any human text written between them is inside the "managed"
region and is destroyed by the next re-render — the precise failure this feature exists to prevent. The
split already computes the information needed (`had_marker`); returning a count instead is a one-line
change to a jq expression, and the return shape stays canonical.

Skipping one ticket rather than refusing the run keeps the failure proportionate: the ambiguity is local to
that description, and Principle III's fail-closed rule is satisfied by not writing it. Every other ticket
in the specification reconciles normally, and the warning names the ticket so a human can delete the
duplicate marker.

**Alternatives considered**: Self-healing to a single marker — rejected, it silently destroys whatever sits
between the two markers, which is the defect. Refusing the whole run — rejected as disproportionate to a
single ticket's damaged description.

---

## Consolidated decisions

| # | Decision | Primary consequence |
|---|---|---|
| R1 | Open the existing origin gate; the delimited managed panel becomes universal | The bulk of FR-006…FR-009 is a discriminator removal plus test inversion |
| R2 | The plan section already sits correctly; US1 rides on US2's mechanism | No production code specific to US1; its scenarios become conformance scenarios |
| R3 | Suffix-match migration, preserve-and-warn on no match | One new engine function; one spec refinement recommended for FR-020 |
| R4 | Narrow the pre-write scan to mirror-composed content | A security-control narrowing, argued in Complexity Tracking; also fixes a latent defect on adopted tickets |
| R5 | `summary` field on the existing identity property, whitespace-normalised comparison | No extra read; one extra property `PUT` bound to an actual summary write |
| R6 | `marker_count` from the split; >1 warns and skips that description | Proportionate fail-closed behaviour, no run-wide refusal |
