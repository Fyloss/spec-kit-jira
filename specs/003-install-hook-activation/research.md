# Phase 0 Research: Hooks Active From Installation

**Feature**: 003-install-hook-activation | **Date**: 2026-07-28

All findings below were verified against the installed Spec Kit CLI —
`specify_cli` **0.13.4**, the version this repository declares in
`.specify/init-options.json` and the minimum in `extension.yml`
(`requires.speckit_version: ">=0.13.0"`). The reference implementation read was
`specify_cli/extensions/__init__.py`, and the reference manifest was the
bundled `git` extension (`core_pack/extensions/git/extension.yml`).

Nothing here is inferred from documentation alone. Where the spec made an
assumption, this research either confirms it or records the conflict.

---

## R1 — How an extension declares lifecycle hooks

**Decision**: declare hooks under a **top-level `hooks:` key** in
`extension.yml`, a sibling of `provides:` — not nested inside it.

**Rationale**: `ExtensionManifest.validate()` reads `self.data.get("hooks")`
from the manifest root, and the `hooks` property returns `self.data.get(
"hooks", {})`. A `hooks:` block placed under `provides:` is silently ignored:
the manifest still validates (it has commands), and the install registers
nothing. The bundled `git` extension declares its eighteen hooks at the root,
and is the shape to copy.

Each event maps to **either a single mapping or a list of mappings**
(`coerce_hook_entries` accepts both). Recognised entry fields are `command`
(required — a missing one is a validation error), `optional`, `priority`
(integer ≥ 1), `prompt`, `description`, and `condition`.

**Alternatives considered**: keeping registration in the configuration ceremony
only — rejected, it is the reported defect. Declaring hooks under `provides:` —
rejected, silently inert.

---

## R2 — The exact entry the install writes

**Decision**: treat the following eight-field record as the canonical hook
entry, and make every path that writes an entry produce exactly it.

`HookExecutor.register_hooks()` normalises every manifest entry before writing
it to `.specify/extensions.yml`:

```yaml
- extension: jira                  # the manifest's extension.id — always added
  command: speckit.jira.reconcile
  enabled: true                    # hard-coded true (see R5)
  optional: <manifest value, default true>
  priority: <manifest value, default 10>
  prompt: <manifest value; the default is written EXPANDED — the host builds it
           with an f-string, `f"Execute {command}?"`, so the file receives
           "Execute speckit.jira.reconcile?" and never a "{command}"
           placeholder (verified at extensions/__init__.py:3866)>
  description: <manifest value, default "">
  condition: <manifest value, default null>
```

Two behaviours of that function shape the whole design:

- **Ownership by `extension` field.** On every install it purges *all* entries
  whose `extension` equals the manifest id — for the declared events and for
  events the manifest no longer declares — and re-adds them. Entries belonging
  to other extensions are matched by the same field and never touched.
- **Write only on change.** The file is saved only if the parsed structure
  actually changed, so a reinstall over an identical registry writes nothing.

**Consequence**: an entry lacking the `extension` field is invisible to the
purge and will be **duplicated** on the next install. The purge predicate is
literally `h.get("extension") == manifest.id` (`extensions/__init__.py:3833`),
which such an entry never satisfies. The extension's current registrar
(`scripts/bash/hooks/register_hooks.sh`) writes only four fields — `command`,
`description`, `enabled`, `optional` — and **no `extension` field**.

This is not a hypothetical about future writes. Every repository that already
installed a released version of this extension carries those four-field entries
**today**, so the duplication happens on the first upgrade after this feature
ships, in exactly the repositories that reported the defect. And because
FR-022 forbids this extension from writing the registry, it cannot clean them
up itself: the leftover entries must be reported precisely and removed by the
operator (FR-028). The host cannot do it either — it does not recognise them as
ours.

---

## R3 — The registry has one writer, and it is not us

**Decision**: this extension **never writes the hook registry**. Not to
register, not to repair, not to realign a field it believes is wrong. It reads
the file, classifies what it finds, reports it, and names what the operator or
the host install should do. `register_hooks_write` is deleted rather than
narrowed (FR-022, FR-023, SC-007, SC-011).

**Rationale**: the install serialises with PyYAML (`yaml.dump(...,
default_flow_style=False, sort_keys=False, allow_unicode=True)`); this
extension serialises with its own deterministic writer in
`scripts/bash/lib/config.sh`. The two will never agree byte for byte. The
current `register_hooks_write` decides its status by re-serialising the merged
structure and byte-comparing it with the file on disk (`cmp -s`); run against a
registry the install wrote, that comparison always fails, the status becomes
`repaired`, and the whole file is replaced by `mv` in our dialect.

Two facts make "write less often" an insufficient fix rather than a smaller
one:

1. **The reader is a deliberately restricted subset.**
   `scripts/bash/lib/config.sh` states it in its own header: 2-space block
   indentation, `key: value`, `- ` sequences, plain and quoted scalars,
   `true`/`false`/`null`, comments, blank lines — *"Flow collections and
   anchors are out of scope"*. That subset was designed for the files this
   extension writes and whose dialect it controls. The hook registry is not one
   of them: the host, other extensions and the operator all write it. Any
   round-trip through this reader silently discards whatever it does not model.
2. **Comments do not survive the round-trip.** The parser drops full-line
   comments (`[[ "${body}" == "#"* ]] && continue`) and strips inline ones
   (`_cfg_strip_inline_comment`). Every write, however rare and however
   well-targeted, deletes every comment an operator put in a file they are
   explicitly invited to edit.

So the question is not "how do we write this file without churn" but "why are
we writing a file we neither own nor can faithfully reproduce". With
registration moved to the manifest (R1), the answer is that we no longer need
to. Removing the writer removes the churn, the comment loss, the subset
hazard and the two-writer conflict in one move, and it removes code rather
than adding a guard (Principle XIV).

**Consequences accepted**: the extension can no longer self-heal a registry.
For a missing entry the report names the official install command, which does
repair it. For a leftover pre-manifest entry the install cannot help either
(R2), so the report gives the operator a copy-pasteable manual edit — the one
place where Constitution X's "one-command repair" is not available, recorded as
a tracked deviation in the plan.

**Alternatives considered**: *deciding on health and writing only genuinely
missing entries* — rejected, this was the earlier design of this feature; it
narrows the window but keeps a second writer on a shared file, and every write
it does perform still destroys the operator's comments. *Reimplementing
PyYAML's emitter, comment preservation included, in Bash and PowerShell* —
rejected as disproportionate and brittle (Principle XIV), and it would still
leave two writers. *Editing the file in place by line, touching only our own
entries* — rejected: it is the least bad way to write this file, but it is
still writing it, and it demands a line-addressed editor on both ports for a
capability FR-022 says we should not have.

---

## R4 — `optional` is a dispatch flag, not a blocking flag

**Decision**: declare every entry `optional: false`, and keep non-blocking
behaviour where it already lives — inside the bridge and the command
procedures.

**Rationale**: the agent-side contract is explicit. For `optional: false` the
host command emits `EXECUTE_COMMAND:` and must invoke the hook and wait; for
`optional: true` it merely prints the command and a prompt for the operator to
run later. So `optional` decides **whether the step happens**, not whether a
failure propagates. The current code has this backwards: the comment on
`_register_hooks_entry` reads "`optional: true` makes the hook non-blocking:
a bridge failure never fails the host command", and both entries are written
`optional: true`. That is why a correctly registered hook still never runs.

Non-blocking outcome propagation is unaffected by this change: it is provided
by the bridge returning success with a single warning, which Constitution III
requires and the existing hook-resilience tests already assert.

**Alternatives considered**: leaving `optional: true` and asking operators to
run reconcile by hand — rejected, it defeats the extension's purpose (US2).

---

## R5 — Conflict: the install re-enables a hook the operator disabled

**Finding**: `register_hooks()` writes `"enabled": True` unconditionally for
every entry it re-adds, after purging this extension's previous entries. There
is no read of the existing `enabled` value. Therefore **any `specify extension
add` re-run or upgrade silently re-enables a hook the operator set to
`enabled: false`.**

This contradicts FR-007 and SC-005, and Constitution X ("A hook the operator
explicitly disabled MUST be respected forever — no repair or upgrade may
re-enable it"). It also contradicts the spec's own assumption that reinstall
semantics can simply be inherited from the install command: that assumption was
written without knowledge of this behaviour, and this research supersedes it.

**Decision**: record the operator's decision where the install cannot reach it,
and honour it in two places.

1. The extension records the set of events the operator disabled in the
   gitignored local binding (`.specify/jira/config.local.yml`), which lives
   outside `.specify/extensions/` and therefore survives reinstall and upgrade
   by Principle V. An event enters that set when the **configuration ceremony**
   reads one of this extension's entries with `enabled: false`. The health
   computation itself stays strictly read-only — it classifies, it does not
   record — and the ceremony performs the write, on the same terms as its other
   writes: predicted by `--dry-run`, never performed by it (Principle XI).
2. **At dispatch**: the reconcile entry point exits inert — no Jira call, no
   warning (FR-020) — for any event in the recorded set, whatever the registry
   currently says. This covers the window between an install that re-enabled
   the entry and the next ceremony.
3. **At ceremony**: the divergence is **reported, not corrected**. FR-022
   forbids writing the registry, so when the record holds an event that the
   registry shows as `enabled: true`, the ceremony names the event, states that
   the bridge will not run for it, and names the command that releases it.
   Principle XVI is served by an accurate report rather than by editing a file
   we do not own — and the operator retains the last word, since they can also
   simply set `enabled: false` back by hand.

An operator who genuinely wants a disabled hook back needs a way to clear the
record; editing the registry alone cannot express it, because the extension has
no way to tell an operator's re-enable from the install's. A single explicit
flag on the configuration command provides it, and the ceremony's report names
it whenever it is holding an event disabled. This is the one added affordance
in the feature and it is tracked in the plan's Complexity Tracking section.

**Alternatives considered**: accepting the upstream behaviour and documenting
the limitation — rejected, Constitution X is non-negotiable and the principle
wins over inherited behaviour by the Governance rule. Restoring the state only
at ceremony time — rejected, it leaves a window in which the bridge mirrors to
Jira against the operator's explicit instruction. This finding is also worth
reporting upstream, but the fix here must not depend on that.

---

## R6 — Invoking the bridge without a machine-wide executable

**Decision**: the command procedures invoke the bridge through a
**repository-relative path** into the installed extension tree, selecting the
port from the host, and never through a bare `spec-kit-jira` command name.

**Rationale**: `specify extension add` copies this repository's content into
the consuming repository's `.specify/extensions/jira/` and installs nothing on
the machine — no binary, no `PATH` entry, no shell profile. Yet both command
procedures instruct the agent to run `spec-kit-jira config` and `spec-kit-jira
feature` as bare names. In a consuming repository no such command exists, which
is precisely the reported symptom ("spec-kit-jira CLI not installed"). The real
entry points after install are:

- `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` (macOS, Linux)
- `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` (Windows)

Both already exist and both already gate on prerequisites before any Jira
interaction, so no new entry point is needed — only correct, port-selecting
invocation text in the procedures the agent follows.

**Alternatives considered**: shipping an installer that puts a wrapper on
`PATH` — rejected by FR-008 and by the spec's hard constraint that install side
effects stay inside the repository. Publishing to a package manager — explicitly
out of scope.

---

## R7 — The reconcile command does not exist

**Finding**: `extension.yml` declares two commands, `speckit.jira.config` and
`speckit.jira.feature`. The registrar registers `speckit.jira.reconcile` under
all six `after_*` events. **That command has no file, no manifest entry, and is
not installed.** Every registered `after_*` hook today points at a command the
agent cannot resolve — US3 and FR-009 in one finding.

**Decision**: add `commands/speckit.jira.reconcile.md` with an ordered,
deterministic procedure matching the two existing command documents, and
declare it in `provides.commands`. Manifest hook references then resolve, and
the manifest's own reference-rewriting pass (which lifts `jira.reconcile` to
`speckit.jira.reconcile` and warns) is never triggered because the reference is
already canonical.

---

## R8 — Do not use `condition`

**Decision**: leave `condition` unset (serialised as `null`) on every entry.

**Rationale**: the agent-side hook contract states that a hook declaring a
non-empty `condition` is **skipped by the agent**, with evaluation left to the
`HookExecutor`. Setting a condition — however reasonable, such as "only when
the repository is configured" — would therefore make agent-driven dispatch skip
this extension's hooks entirely, reintroducing the defect through a different
door. The not-yet-configured case is handled where it belongs: inside the
bridge, which exits `0` with one notice (FR-019).

---

## R9 — Event coverage

**Decision**: declare exactly the seven events the spec names — `before_specify`
for feature naming, and `after_specify`, `after_clarify`, `after_plan`,
`after_tasks`, `after_implement`, `after_analyze` for reconcile.

The host supports more events (the `git` extension registers eighteen,
including `before_*` variants, `*_checklist` and `*_taskstoissues`). Adding any
of them is out of scope for this feature and forbidden by Principle XV until a
spec requires it.

Note the purge behaviour from R2: because the install removes this extension's
entries from events the manifest no longer declares, the seven declared events
are the complete and self-cleaning set.

---

## Resolved unknowns

| Question | Resolution |
| --- | --- |
| Does the install register manifest-declared hooks? | Yes — top-level `hooks:`, R1 |
| What shape does it write? | Eight normalised fields including `extension`, R2 |
| Is the `prompt` default a template or expanded? | Expanded — an f-string, so no `{command}` placeholder reaches the file, R2 |
| Can the ceremony and the install share one file without churn? | Yes — by the ceremony not writing it at all, R3 |
| What happens to entries written before this feature? | The install cannot recognise them and duplicates them; the operator removes them manually, R2/R3 |
| Does `optional: false` risk failing host commands? | No — it controls dispatch only, R4 |
| Are disabled hooks preserved across install? | **No** — upstream re-enables them; mitigated by R5 |
| How is the bridge invoked after install? | Repository-relative path per port, R6 |
| Does `speckit.jira.reconcile` exist? | No — it must be created, R7 |
| Should hooks carry a `condition`? | No — it suppresses agent dispatch, R8 |

No unresolved `NEEDS CLARIFICATION` items remain.
