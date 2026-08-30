# Phase 0 — Research: The routing fallback follows the developer's team

All findings are measurements against the tree at `0be1c50`, not recollections.
Line references are to that commit.

---

## R1 — How the selected team reaches the resolver

**Finding.** `routing_resolve` (`scripts/bash/engine/interchange.sh:201`) takes
three arguments — folder name, labels JSON, config JSON — and runs exactly one
`jq` invocation. Its twin `Resolve-JiraRouting`
(`scripts/powershell/engine/Interchange.psm1:320`) is a pure function over the
same three inputs. Neither opens a file. The whole tree calls routing from two
places only: `reconcile.sh:128` and `Reconcile.psm1:144`.

`config_personal_load` (`config.sh:1342`) returns, on the active path,
`{active: true, team: "<id>", override: <obj|null>}` — the team **id**, not the
project. The project lives in the committed catalogue at `teams[].project`, which
the schema already validates as a well-formed project key (`config.sh:929`).

**Decision.** Pass the selected team **id** as a fourth parameter, and let the
resolver's existing jq program look the project up between the team route and
the default:

```text
$matched // $team_route // $personal_route // .routing_default // ""
```

where `$personal_route` is `first(.teams[] | select(.id == $team) | .project)`.

**Rationale.**

- **Zero new process spawns.** The lookup folds into the `jq` invocation that
  already runs. Resolving the project in the caller instead would cost one extra
  `jq` per run to duplicate work the resolver gets for free.
- **The engine stays pure** (Constitution VIII). It receives configuration as
  data and opens nothing. Letting it read `personal.yml` would make a pure
  function stateful and put per-operator vocabulary in the neutral layer.
- **The id is already trusted.** `config_personal_load:1385` refuses an id absent
  from the catalogue with a located error naming the valid ids. By the time the
  id reaches the resolver, catalogue membership is established, so
  `$personal_route` yields either a validated project key or nothing.

**Alternatives considered.** Resolver opens `personal.yml` (rejected: VIII).
Caller resolves the project (rejected: an extra spawn for a duplicated lookup).
Passing the whole personal object (rejected: the resolver needs one field, and a
wider parameter invites the engine to grow opinions about per-operator config).

---

## R2 — Boundness is not available where routing is resolved

**Finding — the ordering is wrong for FR-004 in both ports.**

| Port | Routing resolved | Spec first read | Spec first parsed |
| --- | --- | --- | --- |
| Bash | `reconcile.sh:736` | `reconcile.sh:891` | `reconcile.sh:892` |
| PowerShell | `Reconcile.psm1:861` | `Reconcile.psm1:1024` | `Reconcile.psm1:1026` |

FR-004 needs "does any story already carry a bound marker" at routing time, and
at routing time the file has not been opened. Nothing between the two points
writes the specification either — marker assignment happens after the first
parse (`reconcile.sh:921` parses the *assigned* text) — so the pre-run boundness
is stable across the whole interval.

**Decision.** Move the raw spec read ahead of the routing block in both ports and
derive the boolean from the in-memory text with a fork-free scan. One read, used
twice.

**Rationale.** The read has no side effect, and moving it earlier changes no
observable behaviour: the value it produces at line 700 is byte-identical to the
value it produced at line 891, because nothing in between writes the file. The
semantic this yields — "bound *before this run*" — is exactly the one FR-004
wants, and it is the semantic that makes the rank stable: a specification bound
by an earlier run keeps its project for every operator, forever.

**Alternatives considered.**

- *Move routing resolution after the parse.* Rejected. `project_key` feeds the
  placeholder check (`:751`), the unknown-project check (`:759`), the phase→status
  map (`:779`), the halted list, the local binding and the mandatory-field gate —
  all between routing and the parse. Reordering that is a large, unrelated change
  to the busiest command in the tree.
- *Read the file twice.* Rejected on the process budget for no benefit.
- *A second `parse_spec` just for boundness.* Rejected outright — the parser is
  the single most expensive local operation in the run (024).

---

## R3 — The marker form the scan must recognise

**Finding.** `engine/story_marker.sh:79-81` emits exactly three forms:

```text
<!-- speckit-jira story=<id> creating -->        # in flight, NOT bound
<!-- speckit-jira story=<id> ticket=<KEY> -->    # bound
<!-- speckit-jira story=<id> -->                 # assigned, NOT bound
```

Recognition on read is governed by the generic pattern at `:101`.

**Decision.** The predicate answers true only for the middle form. It lives in
`engine/story_marker.sh` / `StoryMarker.psm1` — the module that owns the grammar
— and it is fork-free: an in-shell scan of the text already in memory, never a
process per line or per story (`docs/11-process-budget.md`, and the same
fork-free trimming discipline `_smk_trim` already applies).

**Rationale.** Putting the predicate in the command instead would put marker
grammar outside the neutral engine and give the tree a second place to change
when the grammar changes.

**Windows note.** The scan must not put `$'\r\n'` inside a glob pattern
(`docs/10-windows-portability.md`) — the MSYS matcher bends it onto a bare LF.
Line splitting follows the existing CR-tolerant conventions in that module.

---

## R4 — FR-005 already holds, and needs a test rather than code

**Finding.** Reconcile calls `config_resolve_connection` at `reconcile.sh:610`,
before routing. When `personal.yml` is present, that function calls
`config_personal_load "${dir}" "${cfg}" > /dev/null || return $?`
(`config.sh:1836`) — **for its validation side effect, discarding the result.**
A malformed or unreadable `personal.yml` therefore already fails the run closed
with `EXIT_CONFIG`, before any routing decision and before any write.

**Decision.** FR-005 is satisfied by construction. It gets a regression test
proving the ordering (refusal *before* routing, zero writes), not an
implementation.

**Consequence for R1's wiring.** The load is already paid for on this path, so
capturing its result costs nothing. Expose it from `config_resolve_connection`
through a module-scoped variable rather than calling `config_personal_load` a
second time — the pattern this exact call site already uses for `_CFG_PIN_STATUS`
(consulted at `reconcile.sh:615`). A second load would be several `jq` spawns to
recompute a value the run already has.

**Subshell caveat.** The variable is only visible because
`config_resolve_connection` is invoked directly, not through `$(...)` — a capture
would compute it in a forked subshell and discard it with the subshell. Same trap
`lib/config.sh` documents for its recursive parsers.

---

## R5 — Making `routing_default` optional

**Finding.** The key is required by one rule in each port:

- `config.sh:875` — `(if (.routing_default|type) != "string" or ((.routing_default|projkey) != true) then "routing_default must be a valid project key" ...)`
- `Config.psm1:767` — the same rule, and it already reads the value through
  `Get-CfgProp`.

The key also appears in each port's allowed-top-level-key list
(`config.sh:877`, `Config.psm1:772`), which must **stay** — the key remains
legal, it merely stops being mandatory.

**Decision.** Drop the presence half, keep the shape half: absent is accepted;
present-but-not-a-project-key stays refused with the message it produces today.

**No StrictMode work is needed.** The reader is already
`Get-JiraInterchangeProp $cfg 'routing_default'`
(`Interchange.psm1:386`), so an absent key yields empty rather than throwing.
This was checked because a missing-property dot-access under StrictMode is a
known failure mode in this port; it does not apply here.

**Placeholder interaction.** The shipped template writes `routing_default: PROJ`
(`templates/config.yml.template:124`), and `PROJ` is the placeholder key already
refused downstream by `config_key_is_placeholder` (`reconcile.sh:751`). Making
the key optional does not change that path.

---

## R6 — The refusal states FR-007 must distinguish

**Finding.** Today the refusal is one sentence naming one remedy
(`reconcile.sh:737`): *"no rule … matched … and no routing_default is
configured; add routing_default to config.yml"*. After this feature that sentence
would be wrong twice over — it names one of four consulted sources, and it
prescribes a key the repository may have deliberately declined to declare.

**Decision.** One message reporting what each of the four ranks found, following
the precedent 031 set for team resolution (`specs/031-diagnose-team-resolution/`).
The findings to distinguish:

| Rank | Findings to report |
| --- | --- |
| 1 | no `routing:` rule matched — or none is declared |
| 2 | no catalogue team's `folder_prefix` matched — or no `teams:` are declared |
| 3 | no team selected — distinguishing *no `personal.yml`* from *a file selecting no team* |
| 4 | no `routing_default` declared |

**Rationale.** The two rank-3 states are separated because their remedies differ:
one operator needs to create a file, the other needs to uncomment a line. FR-008
binds every command literal in the result to be runnable exactly as spelled, and
the existing message↔command CI check (`tests/bash/ci/test_message_command_literals.bats`)
already enforces that.

---

## R7 — Blast radius, measured

**Finding.** Routing has two call sites in the entire tree (R1). Neither `seed`,
`feature`, nor `mention` resolves routing. `routing_default` appears in shipped
code at four places per port: the schema rule, the allowed-key list, the
resolver, and reconcile's refusal message.

**Consequence.** US2 (Phase A) is genuinely independent and shippable alone. The
rest is threaded through a single function whose only callers are one command per
port.

---

## Resolved unknowns

No `NEEDS CLARIFICATION` remains. The two decisions the specification recorded as
assumptions — rank order, and retaining `routing_default` as optional — were
settled in the spec with their reasoning and are not reopened here.
