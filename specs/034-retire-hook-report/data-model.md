# Phase 1 Data Model: Retire the hook registry report

**Feature**: `034-retire-hook-report` | **Date**: 2026-08-30

This feature adds no entity. Every item below is an existing one being **removed**
or **narrowed**, so each entry states what it is today, what it becomes, and what
enforces the change.

---

## 1. Hook registry — `.specify/extensions.yml`

**Today**: an input. The extension locates it (default `.specify/extensions.yml`
relative to the repository root, overridable through `SPEC_KIT_JIRA_EXTENSIONS_YML`),
parses it through the restricted YAML reader, and classifies every entry.

**After**: **not an input in any form.** The extension holds no path to it, no
environment override for it, and no parser call against it.

**Relationships removed**: `hooks/register_hooks.sh` → `lib/config.sh`
(`config_yaml_to_json`); `commands/config.sh` → the reader; `commands/reconcile.sh`
→ the reader.

**Enforced by**: FR-001, proven by the widened absence guard (research R6). The
file remains present in three conformance fixtures; that is deliberate — a guard
proving "we never open it" is only meaningful where it exists.

---

## 2. Lifecycle event set

**Today**: seven names — `before_specify`, `after_specify`, `after_clarify`,
`after_plan`, `after_tasks`, `after_implement`, `after_analyze` — declared once per
port (`JIRA_HOOK_EVENT_NAMES`, `$script:JiraHookEventNames`) and consumed by two
readers: the registry classifier, and the six-event slice feeding the
`phase_status_map` schema enum.

**After**: **unchanged in value, one reader fewer.** The declaration survives; only
the classifier's consumption goes.

**Validation that survives**: the manifest's declared set must equal the port's
declaration — re-pointed from the deleted module to `lib/config.sh` (research R1).

**Enforced by**: FR-006, FR-009.

---

## 3. Operator disable record — `hooks.disabled` in `config.local.yml`

**Today**: an optional key of the gitignored local binding, holding a list of
lifecycle event names. Written by the ceremony on encountering an `enabled: false`
registry entry; cleared by `--enable-hook <event>`; read at three places — the
ceremony's report, reconcile's summary, and reconcile's dispatch hold.

**After**: **retired.** Not in the accepted key set, not written, not read.

**State transitions removed**: `absent → recorded` (ceremony write) and
`recorded → absent` (`--enable-hook`). Both writers are deleted; Principle II
improves by one conditional write.

**Encounter behaviour**: a file still declaring the key falls to the schema's
existing unknown-key path — exit 4, message `unknown config.local key: hooks`,
reported against the file's full path. Zero new code (research R4).

**Enforced by**: FR-005, SC-004.

---

## 4. Reconcile dispatch hold

**Today**: a guard at the top of `reconcile`, ahead of the prerequisite check and
every network call, that returns 0 **silently** when the current lifecycle event
appears in the disable record.

**After**: **removed with the record it reads** (research R3). Every lifecycle
event the host dispatches now proceeds to the normal target and prerequisite
guards.

**Authorised by**: Constitution 4.0.0, which removes the obligation to honour a
hand-disabled hook forever and records the loss as deliberate.

**Enforced by**: FR-005 makes it unimplementable; FR-011 makes it documented.

---

## 5. Run summary — configuration ceremony

**Today**: `effects` carries four objects — `discovery`, `hooks`, `readme`,
`gitignore`.

**After**: three. The `hooks` property is removed from
`contracts/run-summary.schema.json`, which forbids additional properties, so a
summary still carrying it is invalid rather than tolerated.

**Enforced by**: FR-002, FR-008, SC-001.

---

## 6. Run summary — reconcile

**Today**: a top-level `hook_health` object of seven fields — `present`, `missing`,
`disabled`, `held_disabled`, `duplicated`, `unreadable`, `repair_hint` — emitted on
every run, including the hard-coded empty default reconcile substitutes when the
reader returns nothing.

**After**: **absent.** Both the field and its empty default go; an empty object
asserting nothing is the same defect quieter (spec Assumptions).

**Enforced by**: FR-003, FR-008.

---

## 7. Effect status vocabulary

**Today**: one shared enum of eleven values — six write outcomes (`written`,
`unchanged`, `created`, `repaired`, `refused`, `skipped`) and five read-only
verification outcomes (`healthy`, `incomplete`, `held_disabled`, `duplicated`,
`unreadable`) produced only by the hooks effect.

**After**: six values. The five read-only outcomes are removed with their sole
producer (research R2), and the enum's description loses the partition sentence.

**Enforced by**: FR-008.

---

## 8. Configuration command flag — `--enable-hook <event>`

**Today**: repeatable; each occurrence clears one event from the disable record and
appends `released: <events>` to the hooks effect detail.

**After**: **not accepted.** It reaches the existing unknown-flag path and is
refused with the exit code that path already uses, naming the flag.

**Enforced by**: FR-004, US3 AC1.

---

## 9. Environment override — `SPEC_KIT_JIRA_EXTENSIONS_YML`

**Today**: redirects the registry path, for tests.

**After**: **removed** from both ports, from test harnesses and from documentation.
An override naming a path nothing opens is a claim about a capability that no
longer exists (research R5).

**Enforced by**: FR-001, and directly by the absence guard's token list.

---

## 10. Deleted modules

| Port | File | Public surface removed |
| --- | --- | --- |
| Bash | `scripts/bash/hooks/register_hooks.sh` | `register_hooks_health`, `register_hooks_command_for`, `register_hooks_events_json`, `register_hooks_commands_json`, `register_hooks_entry_is_ours`, `register_hooks_entry_is_leftover`, `register_hooks_entry_shape_errors`, and the `HOOK_*` constants |
| PowerShell | `scripts/powershell/hooks/RegisterHooks.psm1` | `Get-JiraHookHealth`, `Get-JiraHookEventList`, `Get-JiraHookCommandFor`, `Get-JiraHookCommandList`, `Get-JiraHookProp`, `Test-JiraHookProp`, `Test-JiraHookEntryOwnership`, `Test-JiraHookEntryIsLeftover`, `Get-JiraHookEntryShapeError`, `New-JiraHookUnreadable`, `Get-JiraHookRepairHint` |

`scripts/bash/lib/config.sh` loses `config_hooks_disabled_read`,
`config_hooks_disabled_add`, `config_hooks_disabled_remove`; the PowerShell mirror
loses `Get-JiraHooksDisabled`, `Add-JiraHooksDisabled`, `Remove-JiraHooksDisabled`
and their `Export-ModuleMember` entries.

The `hooks/` directory is not emptied: `readme_block.sh` / `ReadmeBlock.psm1` stay.

**Watch for**: `Get-CfgUnsupportedConstruct` is defined **inside**
`RegisterHooks.psm1` (line 182) under a `Get-Cfg*` name. Its callers must be traced
before the module is deleted; if anything outside the module calls it, it moves
rather than dies.

---

## 11. What is explicitly unchanged

- **The manifest.** `extension.yml`'s top-level `hooks:` block keeps all seven
  events, `optional: false`, no `condition`, no `priority`, no `prompt`. It is the
  host's input (FR-006).
- **Hook execution.** The bridge runs on every dispatched event exactly as today.
- **Hook-context failure handling.** One actionable warning to stderr, exit
  downgraded to 0, host command unaffected (FR-007).
- **The other three ceremony effects.** Discovery, the managed README block and the
  ignore rule keep their behaviour and their reported shape (US1 AC4) — the block's
  *text* changes (research R7), its mechanism does not.
- **`config.local.yml`'s other keys.** `site_alias`, `bound_site`, `resolved_ids`,
  `overrides` are untouched (US3 AC3).
