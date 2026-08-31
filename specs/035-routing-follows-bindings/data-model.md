# Data model — routing follows a specification's own bindings

No persisted structure changes. No key is added to `config.yml`, to
`personal.yml`, or to `config.local.yml`. Nothing new is written to disk. The
feature introduces one derived value and changes one function signature.

## §1 — Bound project set (derived, never stored)

The set of distinct Jira project keys carried by a document's bound markers.

| Property | Value |
| --- | --- |
| Source | the document's own bytes, as they stood before this run |
| Grammars read | parent (`spec=<16 hex> ticket=<KEY>`) and story (`story=<16 hex> ticket=<KEY>`) for a specification; task (`task=<id> ticket=<KEY>`) for a tasks document |
| Element shape | the project prefix of an issue key — the text before the first `-` |
| Ordering | sorted, unique |
| Lifetime | one run; recomputed, never cached to disk |
| Cost | one pass, no process per line/marker/story |

**States**

| Cardinality | Meaning | Consequence |
| --- | --- | --- |
| 0 | the document is not bound | resolution unchanged from today (FR-005); the operator's selected team is offered as it is today |
| 1 | the document is bound to one project | that project becomes routing rank 3 (FR-001) |
| >1 | the document's markers disagree | refusal, zero writes (FR-011) |

Only the ticket-bearing marker form contributes. `creating`, a bare assigned
marker, a malformed marker, and the absence of a marker all contribute nothing —
unchanged from 033 C3.3.

## §2 — Resolution chain (amended)

Five ranks, first non-empty wins. Rank 3 is new; every other rank keeps its
present definition and order.

| Rank | Source | Reasons about | Changed |
| --- | --- | --- | --- |
| 1 | first `routing:` rule whose every declared condition holds | the specification | no |
| 2 | first `teams[]` entry whose `folder_prefix` prefixes the de-numbered folder | the specification | no |
| 3 | **the specification's bound project set, when it has exactly one element** | **the specification's own record** | **new** |
| 4 | `project` of the `teams[]` entry whose `id` is the operator's selection | the person | no |
| 5 | `routing_default` | the repository's fallback | no |

Rank 3 sits below ranks 1 and 2 because those are committed decisions about
where this specification belongs, and a team must remain able to move it
(FR-002). It sits above ranks 4 and 5 because those know nothing about this
specification at all.

Rank 4 remains suppressed for a bound specification (FR-006), so the degenerate
case — bound, but the marker set yields no usable project — falls to rank 5
exactly as it does today rather than reintroducing per-operator divergence.

## §3 — Resolver signature

| Port | Before | After |
| --- | --- | --- |
| Bash | `routing_resolve <folder> <labels> <cfg> [team]` | `routing_resolve <folder> <labels> <cfg> [team] [marker-project]` |
| PowerShell | `Resolve-JiraInterchangeRouting -Folder -Labels -Config -SelectedTeam` | ... `-MarkerProject` |

The fifth input is OPTIONAL and MAY be empty. Empty is not an error, produces no
diagnostic, and yields output byte-identical to the four-input resolver for
every possible configuration — the clause that makes FR-005 verifiable rather
than assumed, mirroring 033 C1.4.

The resolver stays PURE: no file opened, no environment read, no Jira request,
and one external-process invocation for the whole resolution.

## §4 — Retired

| Item | Ports | Why |
| --- | --- | --- |
| `story_marker_any_bound` / `Test-JiraStoryMarkerAnyBound` | both | subsumed by §1 — "bound" is "the set is non-empty" |
| the `rerouted` recognition branch | both | unreachable once §5's pre-check refuses on mismatch |
| the `rerouted` channel in the recognition result | both | nothing left to populate it |
| the dry-run-gated re-route note | both | reports a state that can no longer occur (FR-018) |

`_recognition_project_of` / `Get-JiraRecognitionProjectOf` are KEPT: the task
tier's check reuses them.

## §5 — Refusals

Both fail closed with `EXIT_CONFIG` (4) and zero Jira writes, both are evaluated
before any Jira read, and both are downgraded to a single actionable warning
under a lifecycle hook, leaving the host command's exit code unaffected
(FR-013).

| Class | Fires when | Names |
| --- | --- | --- |
| `spec-markers-split` | the bound project set has more than one element | the specification, every project found, and that the markers disagree |
| `routed-project-mismatch` | the bound project set has exactly one element and the routed project differs from it | the specification, the recorded project, the routed project, and whether the routed project came from an explicit override or from the repository's committed routing configuration |

A third existing refusal gains a marker-aware variant: where the marker-derived
project is not declared in `projects[]`, the message says the project came from
the specification's own markers rather than from a routing rule (FR-007).

## §6 — What the run summary carries

No new field. Both refusals travel through the existing fault path, so they
appear in the structured summary exactly as every other `EXIT_CONFIG` refusal
does, and identically under `--dry-run` (FR-014) — neither is conditioned on the
run being a real one.
