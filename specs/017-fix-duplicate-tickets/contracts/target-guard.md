# Contract — the target guard

Covers FR-001 – FR-008. Both ports implement this identically; the conformance corpus compares the
bytes.

## §1 Position in the run

```text
cli_parse
  ↓
dispatch guard        (operator disable record — unchanged; a disabled event returns 0, silently)
  ↓
positional resolution (unchanged)
  ↓
readability check     (unchanged — a missing or unreadable file keeps today's message)
  ↓
TARGET GUARD          ← this contract
  ↓
not-configured notice · bridge-availability · config load · routing · … (all unchanged)
```

Between the dispatch guard and the target guard, nothing reads configuration, resolves a credential,
opens a network connection, or writes a file. The dispatch guard ahead of it reads the operator's
disable record and nothing else. The guard's position is therefore the earliest point at which the
target is known, and every consequence of a bad target is downstream of it.

The ordering against the dispatch guard is deliberate and is argued in
[research R1](../research.md#r1--where-the-target-guard-sits-and-the-one-requirement-it-cannot-satisfy-literally):
an event the operator disabled stays silent.

## §2 The decision

```text
name := basename(target)          # Split-Path -Leaf on the PowerShell port

if name == "spec.md"   → proceed, unchanged in every respect
else                   → refuse (§3)
```

- Byte equality. Case-sensitive. Not a glob, not a suffix test, not a substring search — see
  research R3 for the three failure modes each of those admits, and for the Windows pattern hazard a
  glob would reintroduce.
- The comparison happens **after** the existing readability check, so a missing or unreadable file
  keeps reporting the message it reports today.

## §3 The refusal

- Exit code **`1`** (`EXIT_USAGE`). `cmd_reconcile` already returns `1` for a missing or unreadable
  argument (`reconcile.sh:410-413`), so the code alone does not identify the cause — the verbatim
  message below does. `1` is unclaimed in the command document's message-discipline table, which is
  why the new row can carry it.
- Zero Jira requests. Zero file writes. Zero markers assigned. The rejected file is left
  byte-identical.
- Reported through `_reconcile_fault`, so under a hook the exit becomes `0` and the host command
  completes normally, with the same `WARNING: … This spec-kit command completed normally.` wrapper
  every other degraded cause already uses.
- `--dry-run` refuses identically: the guard precedes the dry-run branch entirely.

### Message — verbatim

When the target's own folder holds a `spec.md`:

```text
reconcile: "<target>" is not a feature specification — only a feature folder's spec.md is ever mirrored (zero writes); the target for this folder is "<sibling>"
```

When it does not:

```text
reconcile: "<target>" is not a feature specification — only a feature folder's spec.md is ever mirrored (zero writes); no spec.md exists in that folder
```

`<target>` is the path exactly as the caller spelled it — never normalised, never absolutised. A
caller that passed a relative path is shown its own relative path, which is the one it can fix.

`<sibling>` is the correct target spelled as it must be passed, and **not** wrapped in an entry-point
invocation. The entry point differs per port, and FR-027 requires both ports to emit the same bytes,
so a runnable command line could not pass the conformance corpus. FR-004 asks the message to name the
correct target precisely; the agent reading it holds the invocation table in
`commands/speckit.jira.reconcile.md`.

## §4 The stray-marker warning (FR-007)

Runs on a **valid** target, after routing, on the real and the dry-run path alike.

- Scans the top-level files of the specification's folder, excluding `spec.md`, for the bridge's
  marker framing comment.
- Emits **one** warning naming every match, sorted, comma-separated, as bare file names.
- Opens no file for writing. Deletes nothing. Never changes the exit code and never blocks the run.

```text
spec-kit-jira markers were found in files this mirror never writes: plan.md, tasks.md — they are inert, were left untouched, and can be removed by hand
```

Absent any match, nothing is emitted.

## §5 Test obligations

| # | Assertion | Where |
| --- | --- | --- |
| T1 | `reconcile plan.md` against a mock that fails on **any** request: zero requests, exit 1, message of §3 | bats + Pester |
| T2 | The rejected file is byte-identical before and after | bats + Pester |
| T3 | `tasks.md`, `research.md`, `data-model.md`, `quickstart.md`, `contracts/api.md`, `spec.md.bak`, `my-spec.md` — each refuses | bats + Pester |
| T4 | `SPEC.MD` refuses (case-sensitivity is asserted, not incidental) | bats + Pester |
| T5 | Under `SPEC_KIT_JIRA_HOOK_CONTEXT`, the same refusal returns 0 and wraps the message — asserted for each of the six events (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_analyze`, `after_implement`), which share one entry point and one guard (SC-001) | bats + Pester |
| T6 | With the event disabled, `reconcile plan.md` is silent and returns 0 (research R1) | bats + Pester |
| T7 | A valid `spec.md` run is byte-identical to the pre-feature baseline | conformance |
| T8 | The refusal is byte-identical across both ports | conformance `us1-target-refusal` |
| T9 | A feature folder holding markers in `plan.md` produces the §4 warning, and `plan.md` is unmodified | bats + Pester + conformance |
| T10 | `--dry-run plan.md` refuses exactly as the real run does | bats + Pester |
| T11 | Path shapes that must **refuse**: a directory; a path that does not exist; a symlink whose own name is not `spec.md`, even when it resolves to one; a path carrying trailing whitespace. The first two keep today's readability message (§1); the last two carry §3's | bats + Pester |
| T12 | Path shapes that must **pass**: the relative spelling `./specs/001-test-page/spec.md`, a symlink *named* `spec.md`, and — on the PowerShell port only — the native `specs\001-test-page\spec.md` (research R3) | bats + Pester |
