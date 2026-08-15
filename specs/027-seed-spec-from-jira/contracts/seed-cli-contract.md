# Contract — The two moments, their CLI surface, and the confirmation gate

**Feature**: 027 | **Modules**: `commands/feature.sh` (extended) ·
`commands/seed.sh` (new) · `lib/cli.sh` (extended) · `sink/jira/adoption.sh` (new)

---

## §1 Why two moments (research R1)

A prompt inside a lifecycle hook is a hang, and Constitution IV says so
explicitly. An `after_*` hook may also never fail its host (Principle III), while
FR-035 requires every refusal to exit non-zero. The confirmation gate is
therefore structurally not a hook.

| | Moment 1 | Moment 2 |
| --- | --- | --- |
| Command | `speckit.jira.feature` (existing) | `speckit.jira.seed` (**new**) |
| Trigger | `before_specify` hook | Agent, after `spec.md` exists |
| Does | Parse, resolve, refuse, compute slug, record, hand over seed material | Validate pins, re-plan, confirm, bind |
| Jira | 1 bulk **read** | reads on resume + all writes |
| Mutations | **zero** | after `--confirm` only |

`speckit.jira.seed` MUST be declared in `extension.yml` under
`provides.commands` with a `commands/speckit.jira.seed.md` definition, and MUST
NOT be bound to any hook event. Declaring it is part of this feature: `mention`
has shipped working in both ports since 001 and is unreachable to this day
because it was never declared (`docs/VISION.md` §6).

---

## §2 New flags

Accepted by `feature` and `seed` alike.

| Flag | Cardinality | Value |
| --- | --- | --- |
| `--parent` | at most once | key, URL, or free text (may contain spaces) |
| `--story` | repeatable | key or URL; argv order is normative (FR-054) |
| `--confirm` | `seed` only, at most once | none — passes the gate |

`cli_parse` accumulates both into **`\x1f`-joined** streams, not space-joined
ones, following the `field_defaults` precedent its own comments justify: "a field
VALUE may itself contain spaces". A free-text parent title has the same property.

The parse state emits, in the fixed key order both ports share:

```
parent_seen=true|false
parent=<value>
stories=<\x1f-joined>
confirm=true|false
```

`parent_seen` is separate from `parent` **because FR-055 requires a blank value
and an absent flag to differ**. A parser that drops empties collapses them.

### Unchanged

The leading positional single mentioned key keeps today's exact behaviour
(FR-048, US5 AC3). An invocation supplying neither new flag MUST be
byte-identical in output, exit code, and request sequence to the current release
— asserted by running the existing feature conformance scenarios unmodified.

---

## §3 Moment 1 — order of operations

Refusals are ordered cheapest-first so that nothing is spent on an invocation
that cannot proceed. Everything through step 4 issues **zero** requests.

```
1. parse designators                    → REF-DESIGNATOR
2. host check                           → REF-HOST          (before any request)
3. de-duplicate                         → REF-DUPLICATE
4. folder exists?                       → REF-EXISTS   unless seeded-not-bound
                                                       with an unchanged set
5. ── one bulkfetch, ceil(N/B) requests ──
6. absent keys                          → REF-UNRESOLVED
7. type vs hierarchy role               → REF-ROLE
8. project vs routing                   → REF-ROUTING
9. stories span >1 project              → REF-MULTIPROJECT
10. terminal / halted status            → REF-TERMINAL
11. identity names another slug         → REF-CLAIMED
12. description all whitespace          → REF-THIN
13. compute slug (FR-059)
14. write the seed record (FR-049)
15. emit seed material + provenance for the agent
```

Step 4 precedes the read so a retro-seed attempt costs nothing.
Steps 6–12 are evaluated over the **whole set** and reported **together** — an
operator who mistyped three designators should learn all three at once
(Principle XVI).

### Fail-closed, not degraded (FR-038)

Today an unreachable Jira makes `feature.sh` emit `{active:false}` plus one
warning (`_feat_fallback`). **That fallback MUST NOT be taken when designators
were supplied**: proceeding would create the duplicates this feature exists to
prevent. With designators, an unreliable read is `EXIT_FAILCLOSED`.

This is the one place moment 1 departs from the existing ceremony's
non-blocking posture, and it is deliberate. A run supplying no designators keeps
the fallback exactly as today.

---

## §4 Moment 2 — order of operations

```
1. read the seed record                 → REF-EXISTS if absent and folder exists
2. compare designator sets              → REF-RESEED on any difference
3. read the recorded slug               (FR-060 — never re-derived)
4. ── re-read Jira: ceil(N/B) ──        (resume only; FR-062)
5. re-evaluate every refusal class of §3 steps 6–12   (FR-062)
6. validate pins against spec.md as it now stands
        first run → REF-DECOMP | resume → REF-DRAFT-EDIT     (FR-058, FR-063)
7. compute the write plan from the CURRENT spec.md            (FR-064)
8. render provenance + plan + delta vs plan_digest            (FR-032, FR-033, FR-064)
9. no --confirm → emit confirmation_required, exit 0, zero mutations
10. --confirm → bind, create, re-parent; delete the seed record
```

A refusal at any step leaves the seeded-not-bound state **untouched** — same
folder, same `spec.md`, same recorded set, order, and slug (FR-062). The
operator fixes the Jira-side cause and re-invokes.

`spec.md` is never re-drafted by moment 2, whatever the re-read returns.

---

## §5 The confirmation payload

Reuses the shape `commands/feature.sh` already emits for the cross-team question,
so the extension has one confirmation idiom rather than two:

```json
{"active":true,"confirmation_required":{"plan":[…],"provenance":[…],"delta":{…}}}
```

Exit 0. Zero mutations. The agent puts the question to the operator and, on a
yes, re-invokes with `--confirm`.

### §5.1 The rendered write plan — pinned to the byte

FR-051 requires the re-parenting line to be "visually distinct". FR-046 requires
the two ports to emit **byte-identical** output. Those two hold together only if
"visually distinct" is a literal, not a judgement — otherwise each port satisfies
it its own way and the corpus cannot tell them apart. The literal is fixed here.

Prose rendering, one line per plan entry, in this order — adopt, create,
reparent, note:

```
Write plan
  adopt      PROJ-1   specification  Payment webhooks rollout
  adopt      PROJ-11  story          Accept a partial payment
  adopt      PROJ-12  story          Refund a captured payment
  create     -        story          Reconcile a disputed charge
! reparent   PROJ-11  from PROJ-99 "Q3 payments" [In Progress] - loses 2 children
  note       PROJ-13  stays under PROJ-88 "Legacy billing" - re-run naming a parent to group
```

Normative rules:

| Element | Literal |
| --- | --- |
| Header | `Write plan`, then one entry per line |
| Ordinary line prefix | two spaces |
| **Re-parenting line prefix** | `! ` — an exclamation mark and one space, in column 1 |
| Verb column | `adopt`, `create`, `reparent`, `note`, left-aligned, padded to 10 characters |
| Key column | the issue key, or `-` when none exists yet, padded to 8 characters |
| Re-parent body | `from <KEY> "<summary>" [<status>] - loses <n> children` |
| Child-loss count | always stated, **including when it is one** (`loses 1 child`) |

The `! ` prefix is the whole of "visually distinct", and it is enough: it is the
only line in the plan that starts in column 1, so it cannot be skimmed past in a
uniform list. Nothing about the rendering may depend on a terminal capability —
no colour, no bold, no width detection. A capability-dependent rendering is not
byte-identical across hosts and would fail FR-046 on the first CI matrix run.

A conformance scenario MUST pin these bytes for a plan containing at least one
line of each of the four kinds (test C-17).

The command never reads from the terminal. A blocking read is the hang
Principle IV warns about, and the command may run non-interactively.

`--dry-run` stays distinct: it predicts the same action set (FR-034) and writes
nothing at all — **including** the seed record.

---

## §6 Cost ceiling — per run (FR-043)

| Phase | Requests, over and above today |
| --- | --- |
| Designator resolution | `ceil(N / B)` — one call at the working range |
| Role and hierarchy validation | **0** — types arrive in the resolution read (research R5) |
| Current-parent disclosure (FR-051) | **0** — folded into the same call as a second id list |
| Parent resolution | ≤ 1 create |
| Binding | 1 identity write per named issue; ≤ 1 parent-link write per named story |
| A resume | the same `ceil(N / B)`, never one per issue, never comment bodies |
| **A run naming nothing** | **exactly 0** |

The ceiling is **per run**, and a resume is a run. Writes are per-issue by
nature — Jira offers no bulk entity-property write — and that is why FR-028's
stamp-and-record-immediately ordering is what makes an interrupted run safe.

### Process budget

- No loop spawns an external process per designator or per marker.
- The bulkfetch body is built by one `jq -n` and written to a **temp file**
  before `jira_request`, never passed as a growable argument. Linux caps a
  single argument at 128 KiB independent of `ARG_MAX`; macOS does not, so the
  defect is invisible locally (`AGENTS.md`, `docs/11-process-budget.md`).
- The seed material handed to the agent — N descriptions — travels by file.

---

## §7 Exit codes

No new codes. The existing monotonic table (`lib/cli.sh`) is reused:

| Situation | Code |
| --- | --- |
| Bad flag shape | `EXIT_USAGE` (1) |
| Unreliable read with designators supplied (FR-038) | `EXIT_FAILCLOSED` (2) |
| Every refusal class in FR-036 | `EXIT_CONFIG` (4) |
| Confirmation required, or success | `EXIT_OK` (0) |

FR-061's scatter disclosure is **not** a refusal: zero writes attributable to it,
no exit-code change, never blocking.

---

## §8 Test obligations

| # | Assertion | Requirement |
| --- | --- | --- |
| C-1 | No designators → byte-identical stdout, exit code, request sequence vs current release | FR-048, US5 |
| C-2 | Each of the 14 refusal classes: zero writes, named message, remediation, exit 4 | FR-036, FR-039 |
| C-3 | Refusals at §3 steps 1–4 issue **zero** requests | §3 |
| C-4 | Three mistyped designators reported together, not one per run | Principle XVI |
| C-5 | Unreachable Jira **with** designators → exit 2, not `{active:false}` | FR-038 |
| C-6 | Unreachable Jira **without** designators → today's `{active:false}` + one warning | FR-048 |
| C-7 | Gate without `--confirm`: zero mutations, `confirmation_required`, exit 0 | FR-033 |
| C-8 | Decline → seed record present, pins present, zero identity markers | FR-049 |
| C-9 | Resume, same set → gate again, `spec.md` byte-identical, no `REF-EXISTS` | FR-050 |
| C-10 | Resume, different set → `REF-RESEED` | FR-041 |
| C-11 | Resume after a story is closed in Jira → `REF-TERMINAL` | FR-062 |
| C-12 | Resume after the operator adds a user story → plan shows the extra create **and** the delta | FR-064 |
| C-13 | Second identical run against a bound spec → 0 writes of every kind | FR-040 |
| C-14 | 100 designators → 1 bulkfetch; 101 → 2; neither spawns per issue | FR-043, FR-044 |
| C-15 | Body reaches `jira_request` via a temp file, never argv | FR-045 |
| C-16 | `--dry-run` predicts the identical action set and writes no seed record | FR-034 |
| C-17 | Reparent line renders with the `! ` column-1 prefix of §5.1, naming parent key + summary + status + child-loss count; the rendered plan is byte-identical between ports for a fixture containing all four line kinds | FR-051, FR-046 |
| C-18 | No parent designator + already-parented stories → scatter note, exit 0, zero writes | FR-061 |
