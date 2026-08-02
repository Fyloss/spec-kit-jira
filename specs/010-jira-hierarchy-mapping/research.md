# Phase 0 Research — The Operator Declares Which Issue Types Carry the Mirror

**Feature**: `specs/010-jira-hierarchy-mapping/` | **Date**: 2026-08-02

Every question below was answered by reading the code that exists today, not by
inference. File and line references are to the tree at `b4331d0`.

---

## R1 — Exactly where the consumer's run dies

**Question**: Which line refuses the consumer's instance, and is the story tier
also blocked, or only the specification tier?

**Finding**: The specification tier is the hard block; the story tier already has
a (poor) answer channel.

The ceremony's per-project loop runs derivation *before* child resolution:

- `scripts/bash/commands/config.sh:527` calls `hierarchy_derive`.
- `scripts/bash/commands/config.sh:528-531` refuses on any non-`ok` status.
- `hierarchy_derive` (`scripts/bash/sink/jira/hierarchy.sh:57-65`) returns
  `parent-level-ambiguous` when more than one non-sub-task type occupies the
  lowest level strictly above the child level.

On the consumer's instance level 1 holds `Epic` and `Service Category`, so the
run exits `EXIT_CONFIG` at line 531 — **before** `_config_resolve_child_type`
(line 533) is ever reached. That ordering matters twice:

1. The operator never even sees the story-tier question, so the existing
   `--child-type` flag is unreachable on this instance. Reversing the order is
   not the fix (the parent refusal would simply move later), but the fix must
   not preserve an ordering that hides one question behind another's failure.
2. Any test that exercises the story-tier flag on an instance that is *also*
   parent-ambiguous is testing nothing today.

**Decision**: Resolve all roles through one resolver invoked once per project,
with per-role refusals accumulated and reported together rather than the first
one aborting the loop. A consumer with two ambiguous tiers learns both in one
run instead of two.

**Alternatives considered**: Keeping two independent resolvers and simply adding
a `--parent-type` flag. Rejected — it preserves the ordering trap, duplicates
the candidate-matching and provenance logic a third time (a fourth, counting the
PowerShell twin), and leaves the two tiers with visibly different error prose.

---

## R2 — What the existing answer channel actually looks like

**Question**: What patterns does the repository already have for "an operator
answers a closed question and it is persisted with provenance"?

**Finding**: Two, and they are the same shape.

| Concern | Flag | Resolver | Persisted as |
| --- | --- | --- | --- |
| Project style | `--style KEY=value` (`lib/cli.sh:54-66`) | `_config_resolve_style` (`commands/config.sh:187-206`) | `style` + `style_source: api\|operator` |
| Child type | `--child-type KEY=name` (`lib/cli.sh:68-82`) | `_config_resolve_child_type` (`commands/config.sh:225-255`) | `child_type: {logical_name, id, source}` |

Both take a repeatable `KEY=VALUE` flag, last occurrence wins
(`_config_style_flag_for`, `_config_child_type_flag_for` — identical loops), and
both record provenance next to the value. The local-binding schema already
validates `style_source` against `api|operator`
(`lib/config.sh:_CFG_LOCAL_ERRORS_JQ`).

`parent_type` is persisted today with a hard-coded `source: "derived"`
(`commands/config.sh:544`) — the slot for provenance exists and is currently
constant.

**Decision**: Generalise, do not invent. One repeatable flag `--issue-type
KEY=role=name` replaces `--child-type` as the operator answer channel for all
three roles; `--child-type KEY=name` is kept as an accepted alias for
`--issue-type KEY=story=name` so no existing invocation, script, or documented
command breaks.

**Rationale for the alias rather than a rename**: `--child-type` is documented
in `commands/speckit.jira.config.md` and in 008's contract, and a consumer may
already have it in a shell history or a runbook. Keeping it costs four lines in
each port's CLI parser.

**Alternatives considered**: Three separate flags (`--parent-type`,
`--child-type`, `--task-type`). Rejected — three flags, three parsers, three
validation messages per port, and the flag name embeds a *relationship* (parent
of what?) rather than a *role*, which is precisely the vocabulary the spec
argues against.

---

## R3 — Where the committed declaration goes, and how it is validated

**Question**: The committed layer is validated by a jq program encoding the
schema. What does a new per-project key cost there, and what is the retired-key
interaction?

**Finding**: `_CFG_TEAM_ERRORS_JQ` (`lib/config.sh:617-660`) validates project
entries with a per-entry error list and **has no unknown-key check inside
project entries** — 008's FR-030a and its Out of Scope both say so explicitly.
Three retired keys (`epic_strategy`, `task_strategy`, `link_type`) are refused
by name at `lib/config.sh:648-651`.

Two consequences:

1. Adding `projects[].hierarchy` needs no unknown-key relaxation — unknown
   project keys are already tolerated. The new validation is purely *positive*:
   if the key is present, its shape must be right.
2. Because unknown project keys are tolerated, a **typo in the role name would
   be silently ignored** if roles were validated the same way. FR-030 exists for
   exactly this reason, and it must be enforced *inside* the `hierarchy` mapping
   (which this feature owns) rather than by the absent general check.

**Decision**: `projects[].hierarchy` is an object with the closed key set
`{specification, story, task}`, each an optional non-empty string. Validation
added to `_CFG_TEAM_ERRORS_JQ`:

- `projects[N].hierarchy must be a mapping of role to issue type name`
- `projects[N].hierarchy declares unknown role \`X\`; the roles are
  specification, story, task`
- `projects[N].hierarchy.<role> must be a non-empty issue type name`

**On the credential scan (FR-003)**: no new code. `config_load` already runs a
credential-shaped scan over every string value in both layers
(`lib/config.sh:552` comment, excluding `privacy.allowlist`), so a value shaped
like a token or a `*.atlassian.net` host in `hierarchy.story` is refused with
exit `4` and never echoed by the *existing* mechanism. This must be asserted by
a test, not assumed.

**On "no identifier in the committed layer" (FR-003)**: a positive rule is
wrong here — `10701` is a perfectly legal issue type *name* in a project
perverse enough to use it, and refusing digits would be a compiled-in
assumption about Jira naming (Constitution VII). The rule is enforced
structurally instead: the resolver matches the declared value against
`logical_name`, never against `id`, so a declared identifier fails FR-013's
unknown-type refusal with the candidate list attached. That is a better message
than a syntax rule would produce.

---

## R4 — Whether `config_to_yaml` can round-trip the new binding shape

**Question**: The local binding is written by a canonical serialiser and read
back by the repository's own YAML subset parser. Does a nested per-role object
survive?

**Finding**: Yes, and the precedent is exact. `child_type` is already persisted
as `{logical_name, id, source}` — a nested mapping under a project's
`resolved_ids.<KEY>` entry — and round-trips today.

One hazard is documented at `commands/config.sh:97-101`: **the YAML round-trip
has no number type.** `config_to_yaml` emits a bare numeral and the reader reads
it back as a string, which is why `hierarchy_level` is stored via `| tostring`
and why `hierarchy.sh` uses `tonumber` at every comparison. Any level comparison
this feature adds must do the same.

**Decision**: Persist under `resolved_ids.<KEY>` as:

```
roles:
  specification: {logical_name, id, hierarchy_level, subtask, source}
  story:         {logical_name, id, hierarchy_level, subtask, source}
  task:          {logical_name, id, hierarchy_level, subtask, source}   # only when resolved
```

`hierarchy_level` as a string, `subtask` as a boolean, `source` in
`declared|operator|derived`.

**On the existing `child_type` / `parent_type` keys**: both are **kept, written
in lockstep with `roles.story` / `roles.specification`, and remain the keys the
reconcile path reads.** See R5.

---

## R5 — The blast radius of changing what reconcile reads

**Question**: If `roles` becomes the new binding shape, how much of the
reconcile path changes?

**Finding**: `_reconcile_plan_context` (`commands/reconcile.sh:216-296`) reads
`.child_type.id` (line 240) and `.parent_type.id` (line 246), plus
`.parent_link_available[story_type]` (line 247). It also runs a shape check:
`_reconcile_local_binding_for` returns `6` (binding-shape-stale) when
`issue_types` is an object rather than a list (line 199-201), and `7`
(child-type-unresolved) when `.child_type.id` is empty (line 245).

`hierarchy_mandatory_gate` (`sink/jira/hierarchy.sh:137-175`) reads
`.child_type`, `.parent_type`, `.parent_link_available`, `.required_fields`.

**Decision — dual-write, single-read.** The ceremony writes **both** `roles.*`
and the existing `child_type` / `parent_type` keys, with identical content. The
reconcile path and the mandatory gate keep reading `child_type` / `parent_type`
unchanged. `roles` is the authoritative record of *what was resolved and why*
(it carries provenance, level, and the sub-task flag for all three roles);
`child_type` / `parent_type` remain the compatibility surface.

**Rationale**: three separate benefits, none speculative.

1. **The stale-binding detector keeps working.** Return code `6` fires on
   `issue_types` being an object, and `7` on an absent `child_type`. A binding
   written by *this* release must not look stale to a *previous* release's
   reconcile in a mixed-machine repository, and must not look stale to itself.
2. **The write path is untouched by a config-layer change.** FR-022 says the
   mirror's behaviour is unchanged except for type resolution; dual-writing
   makes that literally true instead of merely intended.
3. **It bounds the diff.** `plan_writes`, `plan_apply`, `recognition`,
   `identity`, and both ports' equivalents need no edit for User Stories 1–4.

**Cost**: two keys carrying the same value. That is a real KISS tension and it is
recorded in Complexity Tracking with its removal trigger, rather than waved
through.

**Alternatives considered**: Migrating reconcile to read `roles.story.id`
directly and dropping `child_type`/`parent_type`. Rejected for this feature —
it makes every existing local binding stale on upgrade, which converts a
config-layer feature into a forced re-run for every installation, and it drags
the mandatory gate, the plan context, the stale-binding codes and both ports'
reconcile tests into a change whose stated purpose is to let a consumer answer
a question. Recorded as the follow-up in Out of Scope terms.

---

## R6 — Validating the ordering without compiling in an assumption

**Question**: FR-014 requires the specification role to sit strictly above the
story role. What does "above" mean when the operator may pick a non-adjacent
level (FR-012)?

**Finding**: The project reports `hierarchyLevel` per type
(`sink/jira/discovery.sh:288` maps it into the binding as `hierarchy_level`).
`hierarchy_derive` compares levels numerically after `tonumber`. Nothing else
in the tree interprets a level.

**Decision**: the ordering rule is exactly three numeric comparisons on the
levels the project reported, and nothing else:

| Rule | Refusal |
| --- | --- |
| `level(specification) > level(story)` | FR-014 |
| `subtask(specification) == false` and `subtask(story) == false` | FR-015 |
| `subtask(task) == true` | FR-016 |

No adjacency requirement (FR-012), no cap on the gap, no assumption that a
sub-task type sits at level -1 — the `subtask` flag is authoritative, the level
is not. A project that reports a sub-task type at level 0 is handled correctly
by the flag-based rule and would be mishandled by a level-based one.

**On FR-017 (parent link)**: no new logic. `parent_link_available` is already
discovered per issue-type id and the refusal message already exists
(`hierarchy_parent_link_unavailable_message`). The change is *when* it is
consulted: at configuration time against the resolved story role, in addition to
the existing reconcile-time gate.

**On FR-019 (duplicate names at one level)**: the resolver matches by
`logical_name`; two candidates matching one declared name is ambiguity the
bridge must not resolve. Detected in the resolver as "more than one candidate
matched", refused, naming the level.

---

## R7 — How the closed question reaches a human

**Question**: FR-008 requires a closed enumerated question. The entry point is a
non-interactive script. Who asks?

**Finding**: The command layer does. `commands/speckit.jira.config.md:71-73`
states normatively that the ceremony's closed questions are "the project style
(two values), the project key (over the discovered list), and the pre-existing
template enumerations" — and each is implemented the same way: **the entry point
exits `4` with a message listing the candidates and the exact re-invocation, and
the agent reading that message asks the human and re-invokes with the answer.**

There is no interactive prompt anywhere in either port, and adding one would
break the `--json` contract, the conformance corpus (which runs every scenario
non-interactively), and the hook path.

**Decision**: The "question" is the refusal message plus a machine-readable
block, and the command document is updated to instruct the agent to ask. FR-009
(non-interactive refusal) and FR-008 (closed question) are therefore the *same
code path*, differing only in who consumes the output — which resolves what
would otherwise read as a contradiction between the two requirements.

The refusal gains a structured `questions` array in the `--json` summary so the
agent renders the enumeration rather than re-parsing prose:

```
{"role":"specification","project":"PROJ","level":"1",
 "candidates":[{"logical_name":"Epic","id":"10701"}, …],
 "declaration":"projects[].hierarchy.specification",
 "flag":"--issue-type PROJ=specification=<name>"}
```

**Rationale**: this is the only design that satisfies FR-008 and FR-009
simultaneously, keeps the ports byte-identical, and leaves the hook path
non-blocking. It is also how the project-key question already works
(`commands/config.sh:479-489` prints the accessible-project list and the re-run
command to stderr, then exits `4`).

---

## R8 — What FR-011 ("report the declaration to commit") costs

**Finding**: The run summary is assembled per effect
(`commands/config.sh` — the three/four-effect summary) and rendered as prose or
JSON. Adding a `notes`-style line naming the exact YAML to paste is a summary
change, not a new mechanism.

**Decision**: When any role resolves with `source: operator`, the discovery
effect carries one note per project, naming the file, the key path, and the
resolved names. Never a warning and never a non-zero exit — the run succeeded.

---

## R9 — The task tier (User Story 5): what does not exist yet

**Question**: US5 mirrors tasks as sub-tasks. What is actually missing?

**Finding**: Everything below the story. Concretely:

- `engine/parse.sh` (23 KB) parses `spec.md` only. There is **no task parsing**
  in either port — `grep -n "task" scripts/bash/engine/parse.sh` returns
  nothing.
- The neutral interchange document (`engine/interchange.sh`) is shaped
  `{epic, stories[]}`; the schema validates that shape and rejects unknown
  members.
- `engine/story_marker.sh` (13 KB) + `engine/spec_marker.sh` (8 KB) implement
  durable identifiers and the byte-preserving splice for two tiers. A task tier
  needs a third, splicing into `tasks.md`, which no hook currently passes to
  reconcile as its file argument.
- `sink/jira/recognition.sh`, `identity.sh`, `drift.sh` and the zero-churn
  assertions all enumerate two tiers.

**Decision**: US5 is planned as a **separate stage with its own gate**, and the
plan is explicit that stages A–E ship without it. Its design is sketched (the
role, its validation, and its opt-in semantics are all specified and validated
in stages A–C whether or not the tier is built) but its implementation is not
interleaved with the unblock.

**Rationale**: the consumer is blocked *now*. Stages A–E are a config-layer
change with a bounded diff and no engine work; stage F is an engine feature
roughly the size of 008. Coupling them would delay the unblock by the length of
the larger piece, and Constitution XV's own logic (build when a spec requires
it) does not say *in the same release*.

**Consequence for FR-016**: the `task` role's *validation* ships in stage C even
though no tier consumes it yet — otherwise a team could commit
`hierarchy.task: Sous-tâche`, see no error, and reasonably conclude sub-tasks
were being created. A declared-but-unbuilt role must say so. The resolver
therefore accepts and validates the role, persists it, and the run summary
reports it as `recorded, not yet mirrored` until stage F lands.

This applies only to a role the team **declared**. An undeclared `task` role is
absent, not unresolved: no record, no note, no refusal (`contracts/role-mapping.md`
§3.4). `task` is never derived, so the opposite reading would refuse every
project that does not want a task tier.

---

## R10 — Windows and the non-ASCII hazard

**Question**: FR-029 names `Tâche` / `Sous-tâche`. What specifically is at risk?

**Finding**: Two documented hazards apply directly.

1. **Multi-line jq output on the Windows jq build emits CRLF** (`AGENTS.md`,
   `docs/10-windows-portability.md`). The new refusals interpolate a
   comma-joined candidate list — a *single-line* scalar, which the recorded
   measurement says arrives clean. But the `questions` block of R7 is
   multi-line JSON. It must go through `lib/output.sh`, never a bare `jq`.
2. **Feature 007 shipped a fix for unicode config keys** — `_cfg_map_entry_key`
   recognises keys by structure specifically so a non-ASCII key survives. A
   declared value like `Tâche` is a *value*, not a key, so it takes the
   `_cfg_scalar_json` path, which is `jq -Rn --arg`. That is byte-safe, but the
   PowerShell twin's scalar path must be confirmed equivalent on the runner, not
   by reading.

**Decision**: A conformance scenario using the consumer's real type names
(`Tâche`, `Sous-tâche`, `Récit` for the localised case) is part of Phase 5, and
the Windows probe (`ci/windows-probe`, ~11 min, results as annotations) is run
before the feature is called done. Per `AGENTS.md`, a platform fix is unproven
without a green run there — and equally, a platform *claim* of safety is
unproven without one.

---

## R11 — Test corpus: what already exists to build on

**Finding**: The fixture for this exact defect already exists.

- `tests/conformance/mock-jira/fixtures/createmeta-issuetypes-hier-ambiguous.json`
  — `Capability`/`Feature` at level 1, `Story` at 0, `Sub-task` at -1.
- `tests/conformance/fixtures/repo-with-ambiguous-hierarchy/` — the committed
  config for it.
- `tests/conformance/scenarios/us1-hierarchy-ambiguous.json` — asserts the
  refusal, non-interactively.
- `tests/bash/commands/test_config_child_type.bats`,
  `tests/bash/commands/test_reconcile_hierarchy.bats`.

**Decision**: The existing ambiguity scenario **stays and stays red-to-green in
the same sense** — with no declaration and no flag it must still refuse
(FR-009), so it is unchanged and becomes the regression guard for R7's claim
that FR-008 and FR-009 share a path. New fixtures are added rather than
existing ones mutated:

- `createmeta-issuetypes-consumer.json` — the consumer's real shape: 2 types at
  level 1, 13 at level 0, 2 sub-task types at -1, with the real names.
- `repo-with-declared-hierarchy/` — the same instance with `hierarchy` declared,
  which must configure and mirror.

The consumer fixture is the one artifact that proves SC-001, and it is worth its
size: it is the only place the 13-candidate list, the non-ASCII names and the
two-ambiguous-tiers-at-once case are exercised together.
