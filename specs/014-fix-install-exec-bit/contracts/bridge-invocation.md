# Contract — How the bridge is invoked, and what it says when it cannot be

**Feature**: `specs/014-fix-install-exec-bit` | **Date**: 2026-08-03

This is the external contract of a CLI extension: the exact strings the assistant reads, the
operator copies, and both ports emit. It supersedes the invocation clauses of
`specs/003-install-hook-activation/contracts/reconcile-command.md`; everything not restated here
carries over from that contract unchanged.

---

## C1 — The invocation form

The Bash port is invoked **through its interpreter, resolved from `PATH`**:

```text
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh <command> [flags]
```

The Windows port is unchanged — PowerShell executes a `.ps1` by path and no file mode is involved:

```text
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 <command> [flags]
```

**Normative constraints**

- **C1.1** The interpreter is the bare name `bash`. Spelling `/bin/bash` is a defect: on macOS that
  is the 3.2 build `prereq_check` rejects, so it would trade a permission failure for a version
  failure.
- **C1.2** No invocation may rely on the entry point's executable bit. `./…` and a bare
  `spec-kit-jira` name are both forbidden — the second was already forbidden by 003 FR-014.
- **C1.3** The path stays repository-relative. The install puts nothing on `PATH` and this feature
  does not change that.

## C2 — Path-as-filename versus path-as-invocation

A path followed by nothing is a **filename**; a path followed by a command or flag is an
**invocation**. Only the second takes the interpreter prefix.

**Enforceable rule** — wherever the literal `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh`
is followed **on the same line** by whitespace and one of `config`, `reconcile`, `mention`,
`feature`, `--help`, it MUST be immediately preceded by `bash `. Any other occurrence is a filename
and MUST NOT be prefixed.

| Context | Correct form |
| --- | --- |
| Degraded-cause message naming an absent file | `…/spec-kit-jira.sh` (bare) |
| Host-selection table in the command documents | `…/spec-kit-jira.sh` (bare) |
| Fallback block (C4) | `…/spec-kit-jira.sh` (bare) |
| `output_bridge_invocation` / `Get-JiraBridgeInvocation` output | `bash …/spec-kit-jira.sh <args>` |
| Fenced examples in the command documents, `README.md`, `INSTALL.md`, `readme-block.template` | `bash …/spec-kit-jira.sh <args>` |

Scope of enforcement: `scripts/bash/**`, `scripts/powershell/**`, `commands/*.md`,
`templates/*.template`, `README.md`, `INSTALL.md` — the same scope
`tests/bash/ci/test_message_command_literals.bats` already walks.

## C3 — The runnable-hint literal, both ports

`output_bridge_invocation <args>` (Bash) and `Get-JiraBridgeInvocation <args>` (PowerShell) MUST
each produce this one string, byte for byte, so the two ports stay diff-clean:

```text
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh <args> (on Windows: .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 <args>)
```

The only change from today is the leading `bash `. The parenthetical, the separator and the
PowerShell spelling are untouched.

## C4 — The bridge-unavailable fallback block (supersedes 003 FR-030's wording)

The three command documents carry this text verbatim, and instruct the assistant to emit it exactly
as written rather than paraphrase it. One clause changes: *"or is not executable"* is deleted,
because after this feature it is never a cause.

```text
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found.
This spec-kit command completed normally and nothing was mirrored to Jira. To
restore the bridge, reinstall the extension with `specify extension add --dev
<path-to-spec-kit-jira> --force`.
```

The three properties 003 pinned all survive: it names the true cause (a missing file at a known
path, never a machine-wide CLI), it states that the host command completed normally, and every
literal in it is runnable as written. Line breaks are part of the verbatim block and are asserted
with `grep -F` over the multi-line pattern.

## C5 — The degraded-cause messages, both ports

The sixth degraded cause narrows from *absent or non-executable* to **absent**. Four message sites,
byte-identical across ports:

| Site | Text |
| --- | --- |
| `scripts/bash/lib/prereq.sh`, `scripts/powershell/lib/Prereq.psm1` | `spec-kit-jira: the bridge entry point <path> was not found — the extension install is incomplete. Restore it with: specify extension add --dev <path-to-spec-kit-jira> --force` |
| `scripts/bash/commands/reconcile.sh`, `scripts/powershell/commands/Reconcile.psm1` | `Jira mirror skipped: the bridge entry point <path> was not found; the extension install is incomplete. This spec-kit command completed normally and nothing was mirrored to Jira. Restore it with: specify extension add --dev <path-to-spec-kit-jira> --force` |

## C6 — The detection predicate

`prereq_bridge_missing` (Bash) and `Get-JiraMissingBridgeEntry` (PowerShell) become exact mirrors:

- **C6.1** Return the Bash entry-point path when `scripts/bash/spec-kit-jira.sh` does not exist.
- **C6.2** Otherwise return the PowerShell entry-point path when `scripts/powershell/spec-kit-jira.ps1`
  does not exist.
- **C6.3** Otherwise return empty. **A present-but-non-executable entry point returns empty.**
- **C6.4** Neither port may consult a file mode. The Bash `-x` clause is deleted; the PowerShell
  twin never had one, so C6 is the state it is already in.

Existence checks (`-f` / `Test-Path`) are unchanged — FR-004 keeps a genuinely broken install
detectable.

## C7 — Observable equivalence

For any command, any repository state, and any of `0644` / `0755` on either entry point: identical
stdout, identical stderr, identical exit code. This is FR-009 and it is what the conformance corpus
compares.
