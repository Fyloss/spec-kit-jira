# Contract: The canonical hook registry entry, and who may write it

> **SUPERSEDED by feature 034 (2026-08-31).** This contract described the shape
> of a registry entry so the extension could *classify* the entries it found in
> `.specify/extensions.yml` and report on them. 034 removed that classifier
> entirely: under Constitution X as amended in 4.0.0, the extension must not
> read, write, verify or report that registry, so it no longer has any reason to
> know what a well-formed entry looks like.
>
> What the entry shape still governs is the **host's** business — `specify
> extension add` writes it from this extension's manifest, and the manifest's
> `hooks:` block is unchanged.
>
> Kept, not deleted: it is the historical record of a contract that existed, and
> the specifications that cite it describe the world they were written in.

**File**: the consuming repository's `.specify/extensions.yml`
**Sole writer**: `specify extension add` (the host)
**This extension's role**: reader and reporter — never a writer
**Requirements**: FR-003 – FR-007, FR-021 – FR-025, FR-028, FR-029, SC-004,
SC-005, SC-007, SC-011, SC-012

The registry is **shared**. The host writes it, other extensions have entries
in it, and the operator edits it by hand and keeps comments in it. The rule
that keeps everyone out of everyone else's way is not "agree on a format" but
"have one writer": the host install. This extension reads the file and reports
what it finds.

## The record

```yaml
hooks:
  after_specify:
    - extension: jira
      command: speckit.jira.reconcile
      enabled: true
      optional: false
      priority: 10
      prompt: Execute speckit.jira.reconcile?
      description: Mirror the updated spec-kit artifacts into Jira Cloud.
      condition: null
```

All eight fields, always. This is what `HookExecutor.register_hooks()` emits
after normalising a manifest entry. Note `prompt`: the host builds the default
with an f-string, so the file receives the **expanded** string above and never
a literal `{command}` placeholder (research.md R2, verified at
`specify_cli/extensions/__init__.py:3866`).

This extension asserts this shape when it reads, and reports any deviation. It
does not produce the record, because it does not write the file.

## The one writer: the host

Documented so we can read and report accurately — not under our control:

1. Purges every entry whose `extension` equals `jira`, across all events —
   including events the manifest no longer declares.
2. Re-adds one entry per declared event, with `enabled` forced to `true`.
3. Saves the file **only if the parsed structure changed**.

Consequence (1) is load-bearing for FR-028: an entry written by a version of
this extension that predates manifest-declared hooks carries **no `extension`
field**, so the purge predicate `h.get("extension") == manifest.id` never
matches it. The host leaves it in place and adds a second entry beside it. The
host cannot clean it up, and neither may we.

## This extension: reader obligations

1. **Never writes this file.** Not to register, not to repair, not to realign,
   not to reformat, not on first run, not behind a flag. There is no code path
   in either port that opens the registry for anything but reading (FR-022,
   SC-011). Every command leaves it byte-identical, comments included (FR-023,
   SC-012).
2. **Classifies, then reports.** Every declared event is `present`, `missing`
   or `disabled`, annotated `held_disabled` and/or `duplicated` where it
   applies (data-model.md § Hook health).
3. **Names the remedy it cannot perform**:
   - `missing` → the official install command, which does register it;
   - `held_disabled` → the release flag on the configuration command;
   - `duplicated` → a copy-pasteable manual edit, because neither the host nor
     this extension can remove a leftover entry (FR-028).
4. **Reports an unreadable file as unreadable** — never as missing hooks — and
   distinguishes a genuinely broken file from valid YAML that uses a construct
   outside this extension's restricted reader (FR-024).
5. **Records the operator's disable decision outside this file**, in the
   gitignored local binding, and honours it at dispatch (FR-007, FR-029).

## Status vocabulary

The ceremony reports one of these for its hook effect, in prose. Every one of
them is a **report**; none of them is a write.

| Status | Meaning |
| --- | --- |
| `healthy` | All seven events present and enabled; nothing to do |
| `incomplete` | One or more events missing, each named, with the install command that registers them |
| `held disabled` | One or more events held disabled by the operator record, each named with the flag that releases it — including any the last install re-enabled in the file |
| `duplicated` | One or more leftover pre-manifest entries, each named, with the manual edit that removes them |
| `unreadable` | The registry could not be read; the file is named as the cause, and no claim is made about the hooks |

## Cross-port equality

Both ports produce the **same report** for the same registry content
(Constitution VI). Byte-identical serialisation is no longer a concern for this
file, because neither port serialises it.

## Verification

- Checksum the registry, run every command in every documented state, checksum
  again: identical every time (SC-007).
- Seed a registry containing comments, an unusual key order, and another
  extension's entries; run every command; the file is byte-identical (SC-012,
  FR-006).
- Grep both ports for any write, append, truncate, move or delete targeting the
  registry path: zero occurrences (SC-011).
- Install, ceremony, upgrade in any order, ten times, from a registry with no
  leftover entry: never more than one entry per event, none ever lost (SC-004).
- Disable an event, reinstall, run its lifecycle step: no bridge step, no
  warning, and the ceremony reports the divergence without editing the file
  (FR-020, FR-007, SC-005).
- Seed a leftover pre-manifest entry, install: the report names the duplicated
  event and the manual edit; the file is still untouched by us (FR-028).
- Corrupt the registry, and separately write a valid registry using a YAML
  anchor: both are reported as unreadable, distinguishably, with zero writes
  and no "hooks missing" claim (FR-024).
