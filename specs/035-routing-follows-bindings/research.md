# Research — routing follows a specification's own bindings

## R1 — Where the defect actually lives

**Finding**: the guard is at `scripts/bash/commands/reconcile.sh:782-787` and its
twin at `scripts/powershell/commands/Reconcile.psm1:910-913`. It computes a
boolean and, when true, passes an EMPTY team id to the resolver. The resolver
(`scripts/bash/engine/interchange.sh:256`) then evaluates:

```text
$matched // $team_route // $personal_route // .routing_default // ""
```

With `$personal_route` forced empty, a bound specification resolves to
`routing_default`. Nothing in either port ever reads the project recorded in the
markers.

**Decision**: the repair is one rank, not a rewrite. Insert the marker-derived
project between `$team_route` and `$personal_route`.

**Alternatives considered**: making the marker rank the highest was rejected —
it would prevent a team from ever moving a specification by committing a rule,
which FR-002 forbids. Removing the 033 guard entirely was rejected — it
reintroduces the per-operator ping-pong 033 exists to prevent, in the degenerate
case where markers yield nothing (FR-006).

## R2 — One scan answers three requirements

**Finding**: FR-001 (which project), FR-011 (markers naming more than one) and
FR-012 (routed project differs from recorded) are all questions about the same
value: the SET of distinct project prefixes carried by a specification's bound
markers.

- empty set → not bound; today's resolution applies unchanged (FR-005)
- exactly one element → that is the marker-derived project (FR-001); a routed
  project differing from it is the FR-012 refusal
- more than one element → the FR-011 refusal

**Decision**: compute that set ONCE, in the command layer, from the
specification bytes already read at `reconcile.sh:776-778`, before routing and
before any Jira read. Every downstream tier then inherits a guarantee rather
than repeating a check.

**Rationale**: this is what makes FR-009 ("no run splits one specification
across two projects") true by construction rather than by three tiers agreeing.
It also guarantees zero Jira writes for both refusals, since neither can be
reached after a read has occurred.

**Alternatives considered**: implementing the comparison inside recognition,
where the story tier already performs it, was rejected. It would require adding
the same comparison to the parent tier and the task tier, leaving three copies
of one rule — exactly the divergence that produced defect 2 — and it would place
both refusals after the first Jira read.

## R3 — The re-route branch becomes unreachable, and is removed

**Finding**: `scripts/bash/sink/jira/recognition.sh:354-364` (and
`scripts/powershell/sink/jira/Recognition.psm1:349-351`) classify a bound item
whose recorded key names another project as NEW, and record it as `rerouted`.
The command layer then reports it — but only outside `--dry-run`
(`reconcile.sh:2076-2098`).

Once R2's pre-check refuses on any mismatch, the recognition branch can no
longer be entered on the specification tier: the routed project provably equals
the single project the markers name.

**Decision**: remove the branch, the `rerouted` channel, and the dry-run-gated
note in both ports (FR-018). Keep `_recognition_project_of` /
`Get-JiraRecognitionProjectOf`, which the task-tier check reuses.

**Rationale**: Principle XV — a report for a state that can no longer occur is
not kept as a precaution. Leaving it would also leave a second, contradictory
definition of what a mismatch does.

**Blast radius, measured**: `rerouted` / `former_project` appear in
`tests/bash/commands/test_reconcile_durability.bats` (2 occurrences),
`tests/powershell/commands/Reconcile.Durability.Tests.ps1`, and the mock
server. No conformance scenario covers the re-route. This is the smallest
blast radius of the three defects.

## R4 — The task tier is checked where it is already read

**Finding**: `tasks.md` is read only when a task tier is active
(`task_tier_mode` is `subtask` or `checklist`). Reading it during routing would
add a file read to every run, including runs with no task tier at all.

**Decision**: the specification tier (parent + stories) is checked before
routing; the task tier is checked at the point `tasks.md` is already parsed,
applying the SAME rule and emitting the SAME message class, before any task
write. FR-012's "identically for the parent, story and task tiers" is satisfied
by one shared rule evaluated at two points, not by two rules.

**Alternatives considered**: reading `tasks.md` unconditionally during routing
was rejected on Principle XIV and on the process budget — it adds an
unconditional read to every reconcile for a state that only a legacy re-route
can produce.

## R5 — `story_marker_any_bound` is subsumed, not supplemented

**Finding**: `story_marker_any_bound` returns a boolean by scanning story
markers fork-free. The new value is a set, computed by the same scan.

**Decision**: replace it with `marker_bound_projects`, in the same module, with
the same fork-free discipline (no `jq` per line, no subshell per line — 033
C3.4). "Bound" becomes "the set is non-empty", which is what FR-006 needs.

**One deliberate widening**: the new scan reads the PARENT marker grammar
(`spec=<id> ticket=<KEY>`) as well as the story grammar. A specification whose
parent is bound but none of whose stories are is therefore now "bound" for
routing purposes, where today it is not. This is correct — a bound parent pins
the project exactly as a bound story does — and it closes the gap 033 left. It
is called out here because it changes behaviour for a state no existing test
covers, and it gets its own failing test first.

**Process budget**: the scan is one pass over the specification's lines with
shell-native matching only. It spawns nothing per line, per marker, or per
story (FR-008), and it runs once per run.

## R6 — Distinguishing where the routed project came from

**Finding**: FR-012's message must say where the routed project came from. With
the marker rank inserted below ranks 1 and 2, a routed project that differs from
the marker-derived one can only have come from two places: an explicit
project override supplied by the caller, or the repository's committed routing
configuration (a `routing:` rule or a `teams[]` entry).

**Decision**: report those two cases and no finer. The command layer already
distinguishes them — `project_from_config` is `false` exactly when an override
supplied the key. No rank-reporting machinery is added to the resolver.

**Rationale**: Principle XIV. Naming which of ranks 1 and 2 matched would
require the resolver to return a rank alongside a key, changing its contract and
both ports' signatures, to add a distinction whose two remedies are the same
(edit `config.yml`).

## R7 — Windows

**Finding**: the new scan walks lines of a document that may arrive CRLF-ended,
which is the shape that produced the 15 `bash=0d` divergences.

**Decision**: strip a single trailing CR per line with an explicit suffix
removal, never a glob pattern containing `$'\r\n'` (FR-023). The existing
`story_marker_any_bound` already does exactly this (`line="${line%$'\r'}"`) and
the new function inherits the technique verbatim.

## R8 — Risk: existing reconcile tests whose override contradicts their fixtures

**Finding**: fixtures across the suites carry markers with several project
prefixes (`TASKS`, `COMP`, `PROJ`, `ALPHA`, ...) while some reconcile tests
supply `SPEC_KIT_JIRA_PROJECT_KEY` with a different key. Any such test reaches
the FR-012 refusal after this change, where today it silently re-routes.

**Decision**: this is not designed around. FR-012 is the intended behaviour, and
a test whose fixture contradicts its own override is asserting the behaviour
this feature removes. The mitigation is measurement, not avoidance: run the full
bash suite and the Pester suite after the pre-check lands, and correct each
affected fixture so that its markers and its project agree — which is what every
real repository looks like.

**Expected shape of the correction**: change the fixture's marker prefix, never
relax the guard.
