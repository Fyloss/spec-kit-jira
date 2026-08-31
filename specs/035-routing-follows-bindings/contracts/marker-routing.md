# Contract — Marker-derived routing

Binding on both ports. Every clause is byte-equivalent across the Bash and
PowerShell ports unless it explicitly says otherwise.

Amends `specs/033-routing-follows-team/contracts/routing-resolution.md` for the
resolution order and for C3's rank-3 precondition. Every other clause of that
contract stands, and `specs/004-reconcile-config-resolution/contracts/resolution-contract.md`
stands except where 033 already superseded it.

---

## C1 — The bound project set

**C1.1** The scan takes a document's full text and produces the sorted, unique
set of project prefixes carried by its bound markers.

**C1.2** Only the ticket-bearing marker form contributes. `creating`, a bare
assigned marker, a malformed marker, and the absence of a marker MUST each
contribute nothing.

**C1.3** For a specification, BOTH the parent grammar and the story grammar MUST
be read. A specification whose parent alone is bound MUST yield a one-element
set. (This widens 033 C3.3, which read the story grammar only.)

**C1.4** A project prefix is the text of an issue key before its first `-`. A
key that does not match the issue-key grammar MUST contribute nothing.

**C1.5** The scan MUST be evaluated at most once per document per run, and MUST
NOT spawn an external process per line, per marker, or per story.

**C1.6** The scan MUST be evaluated against the document's text as it stood
BEFORE this run, ahead of any marker this run assigns.

**C1.7** The scan MUST tolerate CRLF input on both ports. No line ending may
appear inside a glob pattern.

---

## C2 — The chain

**C2.1** Five ranks are consulted in strict order, and the first that yields a
non-empty project key wins:

1. the first `routing:` rule whose every declared condition holds;
2. the first `teams[]` entry whose `folder_prefix` prefixes the folder name with
   its leading `NNN-` removed;
3. the single element of the specification's bound project set;
4. the `project` of the `teams[]` entry whose `id` equals the operator's
   selection;
5. `routing_default`.

**C2.2** Rank 3 MUST NOT be reachable when the bound project set is empty or has
more than one element. An empty set is not an error and produces no diagnostic.

**C2.3** Ranks 1 and 2 MUST remain ahead of rank 3 unconditionally. A
specification's record of where it currently lives MUST NOT override a committed
decision about where it belongs.

**C2.4** Rank 4 MUST remain suppressed whenever the bound project set is
non-empty, as 033 FR-004 requires. Rank 3 replaces it rather than joining it.

**C2.5** With the marker input empty, the resolver MUST produce byte-identical
output to the four-input resolver it replaces, for every possible configuration.
This is the clause that makes FR-005 verifiable rather than assumed.

**C2.6** When no rank yields a key, the resolver MUST fail with `EXIT_CONFIG`
(4) and MUST print nothing on stdout. The existing four-rank refusal message
gains a fifth clause reporting what rank 3 found; it MUST NOT be replaced.

**C2.7** The resolver MUST remain PURE: no file opened, no environment read, no
Jira request, and at most one external-process invocation for a whole
resolution, whatever the size of the catalogue or of the marker set.

---

## C3 — The mismatch refusals

**C3.1** Where the bound project set has more than one element, the run MUST
refuse with `EXIT_CONFIG` and zero Jira writes. The message MUST name the
specification and EVERY project the set contains.

**C3.2** Where the bound project set has exactly one element and the routed
project differs from it, the run MUST refuse with `EXIT_CONFIG` and zero Jira
writes. The message MUST name the specification, the recorded project, the
routed project, and whether the routed project came from an explicit override or
from the repository's committed routing configuration.

**C3.3** Both refusals MUST be evaluated BEFORE any Jira read. Neither may be
reached from a state in which a request has already been issued.

**C3.4** Both refusals MUST behave identically under `--dry-run` and without it:
same facts, same wording, same exit code. Neither may be conditioned on the run
being a real one.

**C3.5** Both refusals MUST be downgraded to a single actionable warning under a
lifecycle hook, leaving the host spec-kit command's exit code unaffected —
the existing hook-context downgrade, unchanged.

**C3.6** Each message MUST tell the operator what to do next, and every command
literal it spells MUST be runnable exactly as spelled.

---

## C4 — The task tier

**C4.1** A tasks document's bound project set MUST be evaluated by the SAME rule
as a specification's, at the point the document is already parsed, and BEFORE
any task-tier write.

**C4.2** A task marker naming a project other than the routed one MUST produce
the C3.2 refusal, not a create. The three tiers MUST NOT hold different
definitions of a project mismatch.

**C4.3** No unconditional read of `tasks.md` may be added. A run with no task
tier active MUST NOT open it.

---

## C5 — What is retired

**C5.1** The recognition branch that classified a bound item in another project
as NEW MUST be removed, together with the `rerouted` channel it populated, on
both ports.

**C5.2** The re-route note emitted only outside `--dry-run` MUST be removed. A
report for a state that can no longer occur is not kept as a precaution.

**C5.3** The issue-key project extraction helper MUST be REMOVED from both
ports. This clause originally required keeping it, on the ground that C4's
task-tier check would reuse it — that turned out to be false: C4 is implemented
with the C1 scan over the tasks document, which needs no per-key extractor. The
helper was left with no caller in either port, which Principle XV forbids.
Convergence found it; the clause is corrected rather than the code bent to fit
it.

**C5.4** `story_marker_any_bound` / `Test-JiraStoryMarkerAnyBound` MUST be
replaced by the C1 scan. "Bound" becomes "the set is non-empty".

---

## C6 — Cross-port equivalence

**C6.1** Both ports MUST produce byte-identical resolved keys, byte-identical
messages, and identical exit codes for every state in this contract.

**C6.2** The conformance corpus MUST cover, at minimum: a bound specification
resolving to its own project against a contradicting `routing_default`; the same
specification resolving identically for a second operator selecting a different
team; a bound specification placed in a repository declaring no
`routing_default` at all; the C3.1 refusal; the C3.2 refusal; and one scenario
proving C2.5 against a repository configured exactly as it is today.

**C6.3** Re-running a reconcile against an unchanged bound specification MUST
produce zero Jira writes of every kind, in the repository shape that produces a
full duplicate ticket set today.
