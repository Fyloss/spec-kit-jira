# Contract — Routing resolution

Binding on both ports. Every clause is byte-equivalent across
`scripts/bash/engine/interchange.sh` and
`scripts/powershell/engine/Interchange.psm1` unless it explicitly says otherwise.

Supersedes the three-rank chain described in
`specs/004-reconcile-config-resolution/contracts/resolution-contract.md` for the
resolution order only; every other clause of that contract stands.

---

## C1 — The resolver's interface

**C1.1** The resolver takes four inputs: folder name, labels JSON, config JSON,
and a selected team id. The fourth is new and MAY be empty.

**C1.2** The resolver is PURE. It MUST NOT open a file, MUST NOT read the
environment, and MUST NOT make a Jira request. Everything it needs arrives as a
parameter.

**C1.3** The resolver MUST make at most one external-process invocation for a
whole resolution, and the rank-3 lookup MUST be folded into it. A resolution MUST
NOT scale its process count with the number of declared teams, rules, or
projects.

**C1.4** With input 4 empty, the resolver MUST produce byte-identical output to
the three-input resolver it replaces, for every possible configuration. This is
the clause that makes FR-009 verifiable rather than assumed.

---

## C2 — The chain

**C2.1** Four ranks are consulted in strict order, and the first that yields a
non-empty project key wins:

1. the first `routing:` rule whose every declared condition holds;
2. the first `teams[]` entry whose `folder_prefix` prefixes the folder name with
   its leading `NNN-` removed;
3. the `project` of the `teams[]` entry whose `id` equals input 4;
4. `routing_default`.

**C2.2** A rule declaring no condition MUST NOT match. An empty-string condition
counts as undeclared. (Unchanged; restated because the shipped template's
placeholder rule depends on it.)

**C2.3** Rank 3 MUST NOT be reachable when input 4 is empty. An empty input 4 is
not an error and produces no diagnostic.

**C2.4** When no rank yields a key, the resolver MUST fail with `EXIT_CONFIG` (4)
and MUST print nothing on stdout.

**C2.5** Ranks 1 and 2 MUST remain ahead of rank 3 unconditionally. A per-operator
selection MUST NEVER override a committed routing decision.

---

## C3 — Rank 3's precondition, at the call site

**C3.1** The caller MUST supply input 4 as empty when any story in the
specification carries a bound marker, and as the selected team id otherwise.

**C3.2** Boundness MUST be evaluated against the specification's text **as it
stood before this run**, ahead of any marker this run assigns.

**C3.3** Only the ticket-bearing marker form counts as bound. The in-flight form,
the bare assigned form, and the absence of any marker MUST all count as not
bound.

**C3.4** Boundness MUST be evaluated at most once per run, and MUST NOT spawn a
process per story, per line, or per marker.

**C3.5** A specification that is already bound MUST resolve identically for every
operator, whatever team each has selected.

---

## C4 — The selected team id

**C4.1** The id supplied as input 4 MUST already have been validated as a member
of the committed catalogue. The resolver MUST NOT re-validate it and MUST NOT
report on it.

**C4.2** An id that survives validation but matches no catalogue entry at
resolution time MUST yield rank 3 nothing, falling through to rank 4. This state
is unreachable through the supported path and is specified so the resolver has no
undefined behaviour.

**C4.3** A `personal.yml` that is present but cannot be read or validated MUST
fail the run closed with `EXIT_CONFIG` before routing is resolved, with zero
writes. This is existing behaviour (`config.sh:1836`); this contract pins it.

**C4.4** An absent `personal.yml`, and a present one selecting no team, MUST both
yield an empty input 4 with no warning and no diagnostic on the ordinary path.

---

## C5 — Configuration

**C5.1** `routing_default` MUST be optional. Its absence MUST validate.

**C5.2** `routing_default`, when present, MUST still be a valid project key, and
a violation MUST produce the message it produces today, unchanged.

**C5.3** `routing_default` MUST remain a legal top-level key. Optional means
"may be absent", never "is refused".

**C5.4** No key is added to `personal.yml` by this contract.

---

## C6 — The refusal

**C6.1** When C2.4 fires, the command MUST refuse with exit 4 and zero writes.

**C6.2** The message MUST report what each of the four ranks found, not merely
the last one. Reporting a single missing key is a violation of this clause.

**C6.3** The message MUST distinguish, for rank 3: no per-operator file; a file
selecting no team; and rank 3 not consulted because the specification is already
bound. These have different remedies and MUST NOT be conflated.

**C6.4** Every command literal in the message MUST be runnable exactly as
spelled, and MUST be covered by the existing message↔command check.

**C6.5** The message MUST NOT prescribe declaring `routing_default` as the sole
remedy. A repository may have declined to declare it deliberately.

---

## C7 — Cross-port equivalence

**C7.1** Both ports MUST produce byte-identical resolved keys, byte-identical
refusal messages, and identical exit codes for every state in this contract.

**C7.2** The conformance corpus MUST cover, at minimum: one scenario per rank;
one scenario per refusal state of C6.3; one scenario proving C1.4 against a
repository that declares `routing_default` and no catalogue; and one proving C3.5.

**C7.3** Windows: no `$'\r\n'` may appear inside a glob pattern in the boundness
scan, and the scan MUST tolerate CRLF input on both ports.
