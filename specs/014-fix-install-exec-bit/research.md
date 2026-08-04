# Phase 0 — Research: A Fresh Install Runs Immediately

**Feature**: `specs/014-fix-install-exec-bit` | **Date**: 2026-08-03

Every unknown the Technical Context raised is resolved below by reading the tree, not by inference.
Measured facts carry the file and line they came from.

---

## R1 — Where exactly does the run die, and why is the workaround also closed?

**Finding.** Two independent defects stack.

1. `scripts/bash/spec-kit-jira.sh` is committed `100755`, but the mode is not ours to keep: the
   install route documented for consumers (`README.md:100`, the `--from …zip` form) extracts an
   archive, and archive extraction drops file modes. The developer route (`--dev`) copies the tree
   and preserves them. The host only began restoring modes for extensions in a version *newer than
   the `>=0.13.0` floor `extension.yml:30` declares. So a supported install legitimately lands the
   entry point at `0644` and `./…/spec-kit-jira.sh` dies in the kernel, before any of our code runs.
2. `scripts/bash/lib/prereq.sh:58-61` then rejects the interpreter workaround. `prereq_bridge_missing`
   returns the entry-point path when `[[ ! -x … ]]`, and `prereq_check` (`prereq.sh:105`) turns that
   into `EXIT_PREREQ`. So `bash …/spec-kit-jira.sh --help` — which would otherwise work perfectly —
   is refused by us with "the extension install is incomplete", and the remedy the message names
   (`specify extension add … --force`) reproduces the same state.

**Decision.** Fix both in the same change. Fixing only (2) leaves every document instructing an
invocation that cannot run; fixing only (1) leaves the gate refusing the fix.

**Alternatives considered.** Raising `requires.speckit_version` to the version that restores modes —
rejected by FR-010: it helps only hosts no consumer is on and repairs no existing tree. Calling
`chmod` from inside the bridge — rejected by FR-008 (see R6).

---

## R2 — Which invocation form is mode-independent, and does it regress anything?

**Decision.** `bash <repository-relative path> <args>`, with `bash` resolved from `PATH` — never
`/bin/bash`, never `sh`.

**Rationale, verified rather than assumed.**

- The shebang is `#!/usr/bin/env bash` (`scripts/bash/spec-kit-jira.sh:1`), which resolves `bash`
  from `PATH`. A bare `bash <script>` resolves it the same way, so interpreter selection is
  **unchanged** — this is what keeps macOS working, where `/bin/bash` is the disqualified 3.2 and
  the Homebrew 5.x is the one on `PATH`. Spelling `/bin/bash` would turn a permission bug into a
  "Bash >= 4 required" bug on every Mac.
- `sh <script>` is wrong for the same reason and additionally loses `set -o pipefail` semantics.
- **Nothing in the Bash port reads `$0`** — verified by `grep -rn '\$0' scripts/bash/`, which
  returns nothing. The entry point resolves its own root from `BASH_SOURCE[0]`
  (`spec-kit-jira.sh:19`), which is identical under both invocation forms. So the two forms are
  behaviourally indistinguishable for this codebase: same exit codes, same output, same root
  resolution.
- The form is already proven on all three operating systems. `tests/conformance/run-scenario.sh:223`
  invokes the Bash port as `bash "${ENTRY}" …` and that is the line the cross-port conformance
  corpus runs on the Windows/MSYS runner today. We are adopting a spelling the corpus already
  exercises, not introducing an untested one.

**Alternatives considered.** A generated wrapper the host would mark executable (nothing guarantees
that either — same defect, one indirection further away). Putting an executable on `PATH` (003
FR-008 forbids it, and it is the assumption that produced the original "CLI not installed" report).

---

## R3 — A path in a message is not an invocation. Which literals gain the prefix?

**Finding.** The same path string is used for two different jobs, and prefixing both would produce
the nonsense line *"the bridge entry point bash .specify/… was not found"*.

| Use | Constant | Job | Prefix? |
| --- | --- | --- | --- |
| Degraded-cause message | `PREREQ_BRIDGE_BASH` (`prereq.sh:24`), `$script:PrereqBridgeBash` | Names a **file** that is absent | **No** |
| Runnable hint | `JIRA_BRIDGE_BASH_ENTRY` (`output.sh:103`) via `output_bridge_invocation`; `$script:JiraBridgeBashEntry` (`Output.psm1:147`) via `Get-JiraBridgeInvocation` | Emits an **invocation** the operator copies (`Config.psm1:152`, `:946` and the Bash twin) | **Yes** |
| Fallback block (FR-030) | Verbatim text in the three `commands/*.md` | Names **files** | **No** |
| Host-selection table in the command docs | Table cell | Names **files** | **No** |
| Fenced example commands in docs, `README.md`, `INSTALL.md`, `templates/readme-block.template:64` | Copy-and-run text | **Invocation** | **Yes** |

**Decision.** Keep the path constants as paths. Introduce the prefix at the *invocation* seam only —
in `output_bridge_invocation` / `Get-JiraBridgeInvocation`, and in every fenced example. The
mechanical rule, stated so a test can enforce it: *whenever the Bash entry path is followed on the
same line by whitespace and one of `config|reconcile|mention|feature|--help`, it MUST be immediately
preceded by `bash `.* A path with nothing after it is a filename and is exempt.

---

## R4 — The PowerShell twin already diverges, and its message already lies

**Finding.** `Get-JiraMissingBridgeEntry` (`Prereq.psm1:44-57`) tests **only** `Test-Path` for both
entry points. It has never had an executable-bit clause — deliberately, per its own doc comment,
because NTFS carries no such bit. Yet its message (`Prereq.psm1:94`) and the Reconcile twin
(`Reconcile.psm1:536`) both say *"was not found or is not executable"*.

So today: on a mode-stripped tree the Bash port refuses and the PowerShell port runs — a real
cross-port behavioural divergence that the conformance corpus cannot see, because the corpus never
strips the mode. And the PowerShell message describes a condition that port never evaluates.

**Decision.** Removing the `-x` clause from `prereq_bridge_missing` makes the Bash helper an exact
mirror of the PowerShell one (`-f`-only, both ports, both entry points). The message change —
dropping *"or is not executable"* — makes both messages true. This feature therefore **reduces**
port divergence; it does not trade one platform against another.

---

## R5 — Which committed assertions currently demand the opposite?

Five assertions were written by feature 003 to pin the behaviour 014 removes. They are not
collateral damage; they are the specification of the old contract and must be superseded explicitly,
or the next reader will restore them.

| Location | Asserts today | Disposition |
| --- | --- | --- |
| `tests/bash/ci/test_agent_doc_invocation.bats:75` | the entry point is `-x` | Delete; replace with the R3 prefix rule |
| `tests/bash/ci/test_message_command_literals.bats` (entry-points test) | the entry point is `-x` | Delete the `-x` line, keep the `-f` lines |
| `tests/bash/conformance/test_us4_bridge_runnable.bats:51-59` | `./${BASH_ENTRY} --help` works, comment says "no `bash` prefix" | Rewrite as the mode-stripped reproduction |
| `tests/bash/conformance/test_us4_bridge_runnable.bats:61-67` | "the entry point arrives EXECUTABLE" | Delete |
| `tests/bash/ci/test_agent_fallback_block.bats:73-74` | the block says `is not executable` | Update to the new block |

**Superseded requirements.** 003 FR-017 enumerates *"the bridge entry point being absent or not
executable"* as the sixth degraded cause; 014 FR-004 narrows it to **absent**. 003 FR-012's
"invocable with no additional setup" survives unchanged — 014 only changes *how* it is spelled. The
verbatim block is pinned in `specs/003-install-hook-activation/contracts/reconcile-command.md`; that
file gets a one-line supersession pointer to this feature's contract so the old wording is not
"restored" as a regression fix later.

**Decision.** Every one of these edits ships in the same commit as the code change (Constitution
XIII: the corpus is never left describing behaviour the tree no longer has).

---

## R6 — Why not just `chmod` from inside the extension?

**Decision.** Forbidden by FR-008, and the reasons are concrete rather than stylistic.

- It writes to the consumer's tree for a reason unrelated to the mirror, which Principle I confines
  to two named exceptions — this would be a third.
- It cannot succeed on a read-only checkout, a `noexec` mount, or a Windows filesystem, so the
  fallback path (invoke through the interpreter) has to exist anyway. Building both is strictly more
  code than building only the one that always works — Principle XIV.
- It has to run again after every re-install and upgrade, so it never converges.
- The bit would have to be repaired *before* the first invocation, which is exactly the moment
  nothing of ours is running.

---

## R7 — The failing test: how do we reproduce a zip install without a zip install?

**Finding.** `tests/conformance/install-harness.sh:92` installs with `specify extension add --dev`,
the `copytree` route — the one route that **preserves** modes. That is why ~945 existing tests never
caught this defect: the harness only ever produces the healthy state.

**Decision.** Reproduce by construction: `harness_install`, then clear the mode on the installed
entry point (`chmod a-x`), then run the documented invocation and require success. This is a
deterministic reproduction of the archive route's outcome without depending on network access, on a
particular host version, or on which install route the developer's machine happens to support.

**Rationale.** The alternative — driving a real `--from <zip>` install in CI — adds a network
dependency and a host-version dependency to a test whose subject is one file mode. It proves nothing
the `chmod a-x` form does not, and it is the difference between a test that runs everywhere and one
that skips on most machines. Add a second assertion in the same file that the *unstripped* tree
behaves identically (FR-009), so both states stay covered.

**Alternatives considered.** Flipping the repository's own git index mode to `100644` so the tree
always represents the worst case — rejected: it breaks nothing but proves nothing either, since the
explicit strip covers the case deterministically regardless of the index mode, and it would surprise
every developer with muscle memory for `./scripts/bash/spec-kit-jira.sh`. The index stays `100755`
and, after this feature, means nothing.

---

## R8 — Does this need a Windows probe run?

**Decision.** No dedicated `ci/windows-probe` push. The standard three-OS matrix is sufficient.

**Rationale.** `AGENTS.md` requires the probe for a **Windows-only divergence diagnosed by
measurement**. This defect is the opposite shape: POSIX-only, with the Windows port structurally
immune (R4). What Windows *does* gate here is byte-equivalence of the changed message literals, and
that is precisely what the ordinary matrix conformance job measures on every push. Escalate to the
probe only if the matrix goes red — which spends ~11 minutes on evidence rather than on a hunch.

---

## R9 — Second-order consequence: the managed README block

**Finding.** `templates/readme-block.template:64` carries a bash invocation and lands in every
consumer's `README.md` as a managed block.

**Decision.** Change it with the rest, and accept exactly one rewrite of that block on the first
reconcile after upgrade.

**Rationale.** Principle II forbids *churn* — a write that changes nothing. A corrected instruction
is a genuine content change, and the self-healing mirror (Principle X) exists to propagate it. The
testable obligation is that the **second** run after the upgrade writes nothing, which the existing
idempotency corpus already asserts and which the quickstart re-checks by hand.
