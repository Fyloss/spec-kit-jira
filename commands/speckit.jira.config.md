---
name: "speckit.jira.config"
description: "Configure the Jira reconcile bridge: discover project metadata, verify the lifecycle hooks the install registered, and manage the README block — a deterministic, model-independent ceremony."
argument-hint: "Optional: a project key to (re)bind, e.g. PROJ"
---

# /speckit.jira.config

Run the single installation ceremony for the Jira reconcile bridge. The ceremony
is **fully deterministic and model-independent** (US1, FR-001): every step below
is exactly one of

- an **API read** (a `GET` against Jira, never a write), or
- a **config read** (reading `.specify/jira/config.yml` / `config.local.yml`), or
- a **closed, enumerated question** to the operator (a fixed list of choices — no
  free-form judgement, no inferred field or key).

No step is left to model judgement, with exactly **one** stated exception: the
board-position mapping of step 11, where you may propose a draft. That exception
is bounded and named there — the proposal draws every status name from the
project's own discovered list, it decides nothing on its own, and declining it
writes nothing. Everything the entry point itself does remains
model-independent. Because the ceremony reads only and persists
through the canonical serialiser, running it twice against an unchanged project
produces a **byte-identical** `config.local.yml` on both ports (FR-003, SC-004).

The heavy lifting is performed by the deterministic entry point; this file is the
exact, ordered algorithm the agent follows to drive it. **Never invent a project
key, an issue-type name, a status, a field id, or a strategy** — each comes from
an API read or a closed question.

## Invoking the bridge — normative

The install places **nothing** on `PATH`: `specify extension add` copies the
extension into the consuming repository's `.specify/extensions/jira/` and
installs no machine-wide executable. Invoke the entry point by its
**repository-relative path**, selecting the port from the host:

| Host | Entry point |
| --- | --- |
| macOS, Linux | `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` |
| Windows | `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` |

```text
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh config [PROJECT_KEY] [flags]
```

You MUST NOT invoke a bare `spec-kit-jira` command name. No such command exists
in a consuming repository, and assuming it does is what produced the reported
"spec-kit-jira CLI not installed" message. Invoke the Bash entry point **through
the interpreter** (`bash <path>`) rather than by bare path: a zip install on an
older host does not always restore the executable bit, and the interpreter form
works either way (026 FR-016).

### When the entry point is missing — emit exactly as written

When the entry point is not found, emit the following text **exactly as
written**. Do not paraphrase it, do not summarise it, and do not compose your
own explanation of the situation:

```text
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found.
This spec-kit command completed normally and nothing was mirrored to Jira. To
restore the bridge, reinstall the extension with
`specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip --force`
(it will ask you to confirm an untrusted-source prompt — answer y).
```

## Git state is never a source (FR-004/FR-007) — normative

Normative rule: in a connected run the project key and the project style are NEVER inferred from git state
(branch names, branch prefixes, folder names, remote names).
You MUST NOT read, suggest, or use any of them as a source for the project key
or style, no matter what the checked-out branch looks like. Every
branch-derived output belongs to the degraded mode only and is provisional
(see below); it MUST NOT be treated as authoritative or written anywhere.

The interactive closed questions this ceremony may ask are exactly: the project
style (two values), the project key (over the discovered list), and the
pre-existing template enumerations of step 1 — nothing else.

## Preconditions (fail before touching Jira)

1. **Prerequisite gate** — the entry point checks `bash ≥ 4` (macOS ships 3.2 —
   name it explicitly), `curl`/`jq`/`git`, or `pwsh ≥ 7`. On failure it exits `5`
   **before any Jira interaction** (NFR-4). Do not proceed.
2. **Credentials** — resolve the token via env → OS secret manager → gitignored
   `.specify/jira/.env` (NFR-3). The token NEVER appears in argv, logs, or errors.

## Degraded mode (FR-008/FR-009)

When `SPEC_KIT_JIRA_BASE_URL` is undefined or the token resolves through none of
the three rungs, the entry point enters degraded mode **before any Jira call**:
it exits `0`, prints exactly one warning naming the missing variables, proposes
team names scanned from existing branch prefixes with every proposal marked
`provisional: true`, and writes **nothing** — the authoritative resolved-id
binding is untouched. Relay the warning and the `rerun_guidance` verbatim and
invite the operator to define the variables and re-run; a later connected run
performs authoritative discovery and surfaces any mismatch with the provisional
proposals. Defined-but-wrong credentials fail with the auth/network exit codes
and never trigger the degraded mode — do not retry into it.

## Algorithm (ordered, each step is read / config-read / closed question)

1. **Config read** — read `.specify/jira/config.yml`. If absent, create it from
   `.specify/extensions/jira/templates/config.yml.template` and ask the operator
   the closed questions it documents (each key is an enumeration):
   - `priority_map`: for each of **P1 / P2 / P3**, pick a priority **from the
     discovered priority list** (step 4).
   - `style` is **not** pre-filled: it is detected at step 4 or answered via the
     closed question below.
2. **Closed question (project key)** (FR-004/FR-005) — the bound key comes
   exclusively from: (a) the command argument, (b) the committed
   `projects[].key` where the literal `PROJ` placeholder counts as **unset**, or
   (c) this closed question. When no usable key exists the entry point exits `4`
   and its error lists the accessible projects discovered via the paginated
   `GET /project/search` read (key, name, style). Ask the operator to choose
   **from that list only**, persist the choice into `config.yml`, and re-invoke
   the entry point by its repository-relative path with the chosen key:
   `bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh config <KEY>` (on
   Windows, the `powershell/spec-kit-jira.ps1` twin). An unknown or
   unresolvable key fails closed
   with the transport's exit code — never substitute another key (FR-006).
3. **Config read** — for each project, resolve its routing (`routing[]` /
   `routing_default`). A credential-shaped value in either YAML layer is refused
   with exit `4` (FR-023); the offending value is never echoed.
4. **API reads (discovery, US2)** — for each configured project the entry point
   runs the fixed, style-first read sequence (research §1–§3), **in this order**:
   1. `GET /project/{key}` → detect **style** (this is the first Jira call).
   2. `GET /issue/createmeta/{key}/issuetypes` → issue types + hierarchy levels.
   3. `GET /issue/createmeta/{key}/issuetypes/{firstType}` → the project's own
      field schema (estimation candidates + flagged field come from **here**,
      never the global `/field` catalogue — research §3).
   4. `GET /project/{key}/statuses` → statuses + `statusCategory`.
   5. `GET /priority` → priorities.
   6. `GET /field` → the logical-name → id catalogue.
5. **Closed question (project style)** (FR-001/FR-002) — the style is resolved
   per project, in order:
   1. an unambiguous API signal is persisted with `style_source: "api"`;
   2. when the payload is ambiguous (absent or contradictory signals, or a
      committed declaration conflicting with the API signal) the entry point
      exits `4` naming the project and the missing signal. Ask the operator the
      closed two-value question and re-invoke with the answer:
      `--style <KEY>=company_managed` or `--style <KEY>=team_managed` —
      persisted with `style_source: "operator"`. Never pick a default yourself.
   The run summary audits `style` + `style_source` per project (FR-003).
6. **Closed question (estimation field)** — the entry point *ranks* the project's
   numeric fields and **proposes** the top candidate; the operator **confirms or
   picks another from the ranked list**. It is never silently assumed, and never
   the global Story Points field (research §3).
7. **Closed question (status classification)** — each discovered status is seeded
   objectively from its `statusCategory` (done → `post-scope`, else `unknown`) and
   the operator maps phases → statuses from the **discovered** status list. There
   is **no built-in "ideal" status/phase table** — the operator's workflow is
   authoritative (FR-012).
8. **Role mapping (010, US1–US4)** — for each of the three roles —
   `specification`, `story`, `task` — the entry point resolves which issue type
   plays it, with precedence **declared → operator → derived**, evaluating all
   three roles in one pass before refusing on any of them:
   - **declared**: the project's committed `projects[].hierarchy.<role>` in
     `config.yml`, matched by exact name against the project's own issue
     types;
   - **operator**: a `--issue-type <PROJECT_KEY>=<role>=<name>` flag from this
     invocation (or `--child-type <PROJECT_KEY>=<name>`, the accepted alias
     for `--issue-type <PROJECT_KEY>=story=<name>`);
   - **derived**: only for `specification` and `story`, and only when exactly
     one non-sub-task type occupies the tier. `task` is **never** derived —
     undeclared and unanswered, it is simply absent, not an error.

   No Atlassian default name (`Epic`, `Story`, …) is ever assumed — every name
   comes from the project's own metadata.

   **When a role stays unresolved** (its level holds more than one candidate
   and nothing declared or answered it), the entry point does **not** prompt.
   It refuses with exit `4`, printing a closed question per unresolved role —
   naming the level and every candidate by its Jira name — and, under
   `--json`, an `unresolved_roles` array with the same information
   structured. **Read that block; do not guess.** Ask the human which
   candidate to use for each unresolved role, offering **only** the named
   candidates, then re-invoke the ceremony once with one
   `--issue-type <PROJECT_KEY>=<role>=<name>` per answer. Never invent a name
   outside the candidate list, and never retry with a derived guess.

   A declared type that names a type of the wrong kind (a sub-task type for
   `specification`/`story`, a non-sub-task type for `task`), an unknown name,
   a name matching more than one type, or a `specification` that does not sit
   above its `story` in the hierarchy, each refuse at config time with exit
   `4`, zero writes, naming the mistake precisely — never silently corrected.
   Likewise a project with no level above the story tier (`no-parent-level`)
   refuses, naming the candidates it does offer.
9. **Closed questions (field defaults, 011/012)** — for the `specification`
   and `story` types, and — whenever a `task` role is declared — the type
   carrying it too (**no others** — FR-025; no `task` role means no
   question about any sub-task type, FR-035), plus any type named by
   `--field-default` this run (FR-026), the entry point asks about every
   field Jira's create metadata marks **required** that the bridge cannot
   supply itself (`summary`, `description`, `issuetype`, `project`,
   `priority`, `reporter`, and `parent` where the type offers it). It asks
   about no other field: an optional defaultable field is never turned into
   a question (FR-002, FR-004). Exactly as with role mapping, the entry point does not prompt beyond this fixed list.
   A team states an optional field's default by writing the entry by hand into `config.yml`'s `field_defaults` managed region, or through `--field-default <KEY>=<Type>=<Label>=<Value>` (repeatable); both are validated identically and carried forward unchanged by every later run.
   A field with a non-empty `allowedValues` is a closed question
   over exactly those values; anything else is an open question for a
   scalar. A field whose shape cannot be expressed as a recorded value (an
   array, an issue link) is never asked about — it is reported once, by
   label, with the reason (FR-010). A field already carrying a recorded
   value is presented with that value as the current answer; keeping it
   requires no input and reproduces the file byte-for-byte (FR-007). Answer
   with `--field-default`, one flag per field, and re-invoke.

   **The sub-task type is different from the other two in one respect**: an
   unanswered required field on `specification` or `story` blocks the whole
   run before any write, but the same gap on the `task` type withholds only
   the task tier (FR-037) — the specification and its stories still mirror
   exactly as they would with no `task` role declared, with zero sub-task
   writes and no durable identifier recorded for any withheld task
   (FR-038). Recording the missing default (by hand, or with
   `--field-default`) and re-running reconcile creates exactly the
   withheld sub-tasks on that next run (FR-039) — there is no cleanup step,
   no flag, and no repair command.
10. **Closed question (task mirroring, 022)** — when a project has no
    `task_mirror` value recorded, the entry point prints its closed question on
    stderr on **every** run, followed by the per-project effect line
    `Task mirror: <KEY> — not recorded; today's behaviour applies`. **Relay that
    question**; it is one of the two the run itself emits, and a run that
    reports it while you say nothing is how a team ends up believing the
    ceremony asked nothing. The two answers are `subtask` and `checklist`, and
    recording nothing is a legitimate third state that keeps today's behaviour.
    Answer by re-invoking with `--task-mirror <KEY>=<subtask|checklist>`, which
    splices the value into `config.yml`'s `task_mirror` managed region.
11. **Board-position mapping (023)** — spec-kit's lifecycle events are not a
    workflow; **your team's workflow is**, and nothing in this product holds an
    opinion about which status an event should land on. So this step is a
    proposal you make and the operator judges, never a decision you take:

    - **When it happens.** After the entry point's run has completed, since it
      reads what step 12 has just persisted. A degraded or refused run reaches
      no board-position proposal at all — there are no discovered statuses to
      draw one from, and a mapping is never proposed from anything else.
    - **Source of names.** The only permitted status names are the ones
      discovery just wrote for that project into `.specify/jira/config.local.yml`
      (`projects[].statuses[]`, each with its `name` and `status_category`).
      Never propose a name from anywhere else — not from another project, not
      from Jira's defaults, not from the spelling a human used in conversation.
    - **When to skip.** A project whose `config.yml` entry already declares
      `phase_status_map` is finished: do not re-ask, do not rewrite it, do not
      offer to improve it. The same holds for `halted_statuses`.
    - **The proposal.** Present a draft `phase_status_map` in the per-role
      shape, covering only the roles the project actually resolved at step 8,
      and only the events your draft has a defensible status for — an event you
      would have to invent a status for is left out, not filled. State the
      status_category you drew each line from, so the operator can see the
      reasoning rather than trust it. Print the full discovered status list
      beside the draft.
    - **The three answers.** Accept, amend (the operator names a different
      discovered status for any line, or removes a line), or decline. Declining
      writes nothing, and nothing is exactly what the shipped behaviour is: a
      project that declares no mapping is never moved and never warned about.
      Do not press a declined proposal a second time.
    - **The write.** Write the confirmed mapping by hand into `config.yml`,
      under that project's entry, exactly as the template documents it.
      `config.yml` is the human-owned layer — the entry point owns only its two
      marker-delimited regions — so leave every other byte of the file, comments
      included, untouched. Then re-invoke the ceremony once: it validates the
      shape and refuses with exit `4`, naming the offending key, if the mapping
      is malformed.
    - **What you must tell the operator.** The mapping moves a ticket only when
      exactly one of its real available transitions lands on the declared status
      ungated; ambiguous, gated, and unreachable each withhold the move and warn
      once, at reconcile time, naming the ticket. And it only takes effect on a
      reconcile run that carries the lifecycle event — the
      `SPEC_KIT_JIRA_HOOK_EVENT` variable the `/speckit.jira.reconcile`
      definition requires you to set.
12. **Persist (deterministic write)** — the resolved-id table (logical name → id
    for issue types — with hierarchy level and sub-task flag — priorities,
    statuses, `style`/`style_source`, the resolved `roles.<role>` map with each
    role's provenance, the dual-written `child_type`/`parent_type` derived from
    `roles.story`/`roles.specification`, `required_fields`,
    `parent_link_available`, and `defaultable_fields` per written type) is
    written into the machine-owned `.specify/jira/config.local.yml` via the
    canonical serialiser, preserving the operator's `site_alias` /
    `overrides`. The field-defaults answers are spliced into `config.yml`'s
    managed region through the same byte-preserving splice the README block
    uses; every byte outside the region survives. Nothing else in
    `config.yml` is rewritten.

Three retired keys from an earlier, never-built mechanism (`epic_strategy`, `task_strategy`, `link_type`) are refused wherever they appear in `config.yml`, exit `4`, naming the project and the retired key. The hierarchy above replaces
what they were meant to configure; delete the line.

## The effects (reported separately — FR-054)

A single run's effects are each reported **separately** in the summary:

- **discovery** — the resolved-id table written to `config.local.yml` (above),
  including the per-project style audit.
- **hooks** — a **read-only verification** of the lifecycle hooks (see below).
- **readme** — the version-marked managed README block (US5).
- **gitignore** — idempotent `.gitignore` coverage of the gitignored config
  layer (`config.local.yml`, `.env`, `personal.yml` — FR-019).

## The hooks effect: verify and report, never write — normative

The lifecycle hooks are declared in the extension manifest and registered by
`specify extension add`. **They are already active before this ceremony runs.**
This ceremony does not register them, and **never modifies
`.specify/extensions.yml`** — not to register, not to repair, not to realign an
entry it believes is wrong, not on first run, and not behind a flag. Every run
leaves that file byte-identical, comments included.

It reports one of five states, and names what the operator should do:

| State | Meaning and remedy |
| --- | --- |
| `healthy` | All seven events present and enabled; nothing to do |
| `incomplete` | One or more events have no entry. Re-run the official install: `specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip --force` (confirm the untrusted-source prompt with `y`) |
| `held_disabled` | The operator disabled one or more events. No bridge step runs for them, whatever the registry currently says. Release one with `/speckit.jira.config --enable-hook <event>` |
| `duplicated` | A leftover entry from a version that predates manifest-declared hooks: our command with no owning `extension` field. Neither the install nor this extension can remove it, so the report gives the exact manual edit |
| `unreadable` | The registry could not be read. The file is named as the cause; **no claim is made about the hooks** |

Relay the reported detail verbatim. Do not offer to edit
`.specify/extensions.yml` on the operator's behalf, and do not describe a state
in your own words when the report already names it.

## Flags

- `<PROJECT_KEY>` — optional positional: the key to (re)bind (validated by the
  first discovery read; fail-closed on an unknown key).
- `--style <KEY>=<company_managed|team_managed>` — repeatable; the operator's
  answer to the closed style question.
- `--issue-type <KEY>=<specification|story|task>=<name>` — repeatable; the
  operator's answer to one unresolved role, last occurrence per `(KEY, role)`
  wins (010).
- `--child-type <KEY>=<name>` — repeatable; the accepted alias for
  `--issue-type <KEY>=story=<name>`.
- `--field-default <KEY>=<Type>=<Label>=<Value>` — repeatable (011); the
  operator's answer to one required-field question, or a value recorded for
  an optional defaultable field without ever being asked. A value outside
  `allowedValues`, an empty value, an unknown type, or an unknown field
  label each refuse with zero writes, naming the offending item.
- `--task-mirror <KEY>=<subtask|checklist>` — repeatable (022); the operator's
  answer to the task-mirroring question the run prints for any project with no
  value recorded. Last occurrence per key wins; the value is spliced into
  `config.yml`'s `task_mirror` managed region.
- `--enable-hook <event>` — repeatable; release one lifecycle event the operator
  previously disabled. It clears the extension's own record and **does not touch
  the hook registry**.
- `--json` — emit the machine-readable run summary (`run-summary.schema.json`).
- `--dry-run` — compute everything and report, but write nothing.
- `--verbose` — extra diagnostics (the token never appears, even here).
- `--help` — usage; exits `0`.

## Exit codes

`0` success (including a degraded report-only run) · `1` usage (bad `--style`
value) · `2` fail-closed read (unknown key, network) · `3` auth · `4`
config/capability refusal (ambiguous style unattended; no usable key unattended)
· `5` prerequisite failure · `9` privacy BLOCK. Monotonically escalating
(Constitution III); identical on both ports.
