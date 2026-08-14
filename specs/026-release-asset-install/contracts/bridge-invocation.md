# Contract: Bridge Invocation Without the Executable Bit

**Feature**: 026 | **Satisfies**: FR-016, FR-017, FR-018

Governs how the Bash port is invoked and what the prerequisite gate is allowed to treat as fatal. This is the
one contract in this feature that changes shipped behaviour rather than build tooling, and it exists because
the user's own acceptance condition — *the bridge answers `--help`* — is otherwise unreachable from a URL
install on a supported host.

## §1 The defect, measured

Reproduced in Phase 0 on `specify` 0.13.0 — the floor `requires.speckit_version: ">=0.13.0"` declares — after
installing a correct archive:

| invocation | exit | result |
| --- | ---: | --- |
| `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help`, the form all three command documents instruct | `126` | `permission denied` |
| `bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help`, the natural workaround | `5` | our own gate: *"the bridge entry point … was not found or is not executable — the extension install is incomplete. Restore it with: `specify extension add --dev …`"* |
| the same archive and command on `specify` 0.14.4.dev0 (control) | `0` | prints usage |

The mechanism: an archive member records `0o100755`, and `ZipFile.extractall` restores it as `0644`. The
permission is stored and then discarded. Hosts from 0.14.3 restore it afterwards; supported hosts below that do
not.

Two things follow. The second row is the more damaging: the install is entirely intact, the workaround would
have worked, and our own gate converts a survivable state into a hard failure — then advises a route
(`--dev`) that a URL-installing consumer does not have.

## §2 The rule

**C2.1** — After extraction, the bridge MUST be runnable on macOS, Linux and Windows **without depending on the
executable bit having survived**.

**C2.2** — The prerequisite gate MUST NOT treat a present-but-non-executable entry point as a missing bridge.
`scripts/bash/lib/prereq.sh` keeps both `-f` clauses and drops the `-x` clause. A genuinely *absent* entry point
is still reported, with its own cause — nothing about the sixth degraded cause of 003 FR-017 is weakened; only
the one sub-case that is survivable stops being fatal.

**C2.3** — Every place that instructs an invocation of the Bash port — the three command documents, the three
consumer documents (`README.md`, `INSTALL.md`, `templates/readme-block.template`), and any message literal that
spells a command — instructs it **through the interpreter**:
`bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh …`. See C4.3 for why the consumer documents are
named here rather than left implied.

**C2.4** — The remediation text in the bridge-missing message names a route the reader actually has. Telling a
consumer who installed from a URL to re-run `specify extension add --dev <path-to-spec-kit-jira>` is advice
they cannot follow.

> **OPEN — the replacement literal.** It must be runnable exactly as spelled (003 FR-018), byte-identical
> across both ports, and free of a version literal (`publication.md` C1.4). The URL-route form
> `specify extension add jira --from …/releases/latest/download/spec-kit-jira.zip --force` satisfies all three,
> but research R8 measured that it **blocks on an interactive trust prompt** — so a message emitting it sends
> the reader into a `[y/N]` with no warning. Decide before T024/T025: name the URL form and add one clause
> about the prompt, or name both routes. Not decided here, because either answer changes the literal the tests
> pin.

## §3 Port parity

**C3.1** — The PowerShell twin requires **no logic change**. `Prereq.psm1` never checked an executable bit — its
own doc-comment says why: NTFS carries no such bit, so asserting it would report a broken install on every
healthy Windows repository. Removing the Bash check therefore *increases* parity rather than threatening it,
and this clause records that so review does not reflexively demand a mirrored edit.

**C3.2** — The message literals **do** change on both ports, and stay byte-identical between them, as the
existing literal tests already require.

## §4 Blast radius

Twenty files, enumerated so that no instance is missed — the project's own history records surfaces being
missed on merge. An earlier draft of this section said fourteen; a grep of the tree found six more, four of
them in **shipped** files, which is the class that reaches a consumer.

| file | change |
| --- | --- |
| `scripts/bash/lib/prereq.sh` | drop the `-x` clause (lines 56–61); keep both `-f` clauses; remediation literal (line 106) |
| `scripts/powershell/lib/Prereq.psm1` | message literal only (line 94) |
| `scripts/bash/commands/reconcile.sh` | message literal (line 599) |
| `scripts/powershell/commands/Reconcile.psm1` | message literal (line 738) |
| `scripts/bash/hooks/register_hooks.sh` | `HOOK_INSTALL_COMMAND` remediation literal (line 62) |
| `scripts/powershell/hooks/RegisterHooks.psm1` | `$script:HookInstallCommand`, byte-identical to its twin (line 45) |
| `commands/speckit.jira.config.md` | instructed invocation → `bash <path>`; **and** the `incomplete` remedy row (line 255) |
| `commands/speckit.jira.feature.md` | instructed invocation → `bash <path>` |
| `commands/speckit.jira.reconcile.md` | idem |
| `templates/readme-block.template` | instructed invocation → `bash <path>` (line 69). **Shipped**: this template writes the text into the consumer's own README, so a wrong form here propagates into every consuming repository |
| `README.md` | instructed invocation → `bash <path>` (lines 109, 213) |
| `INSTALL.md` | instructed invocation → `bash <path>` (line 183) |
| `tests/bash/ci/test_agent_doc_invocation.bats` | pinned invocation form; **changes first** |
| `tests/bash/ci/test_agent_fallback_block.bats` | pinned literals; **changes first** |
| `tests/bash/ci/test_message_command_literals.bats` | pinned literals; **changes first** |
| `tests/bash/ci/test_consumer_docs_invocation.bats` | **NEW** — pins the form in the three consumer documents, which nothing pins today; **changes first** |
| `tests/bash/conformance/test_us4_bridge_runnable.bats` | drops its executable-bit premise; **changes first** |
| `tests/powershell/ci/AgentDocInvocation.Tests.ps1` | mirrored; **changes first** |
| `tests/powershell/ci/AgentFallbackBlock.Tests.ps1` | mirrored; **changes first** |
| `tests/powershell/ci/MessageCommandLiterals.Tests.ps1` | mirrored; **changes first** |

Counted rather than estimated: those five bash test files hold 8 references to the bridge path and 10 to its
executable bit between them; the three consumer documents hold 4 more bare-path instructions; the `--dev`
remediation literal appears 6 times across the two ports' scripts and once more in
`commands/speckit.jira.config.md`. An earlier draft of this contract said "two test files"; the search says
eight.

The `static-checks` CI job is the reason the test files cannot be skipped: it enforces that *every command
literal in every emitted message is runnable as spelled* (003 FR-018, FR-030, SC-009). Changing the instructed
form to `bash <path>` without changing those literals turns that job red, which is the correct outcome and the
proof the change is complete.

**C4.1** — The test files change before the implementation, and their failure is what proves the defect
(Principle XIII, and the project's bug-fix rule that a regression test precedes the fix).

**C4.2** — The Windows path is unaffected in substance: the PowerShell port is invoked through its interpreter
already, so C2.1 holds there for free. That is not a reason to skip the Windows dimension of the end-to-end
matrix — it is the reason to expect it green.

**C4.3** — The consumer documentation is inside C2.3, not adjacent to it. `README.md`, `INSTALL.md` and
`templates/readme-block.template` instruct the same invocation the command documents do; US1 AC4 says the
operator invokes the bridge *"exactly as the installed command documents spell it"*, and for a first-time
reader that document is the README. Nothing in the tree pins those three files today — verified — which is
precisely why the instance was missed.

## §5 What proves it

**C5.1** — A regression test asserts that a bridge entry point which exists but is not executable is **not**
reported as missing, and that the run proceeds.

**C5.2** — The end-to-end test of `publication.md` §4 exercises the real path: a real archive, a real install,
the floor host, and the invocation exactly as the command documents spell it. This is the failing test for
Windows-invisible and host-version-dependent defects, because unit tests on the maintainer's machine cannot
reach the condition — the maintainer's own host restores the bit.

**C5.3** — Explicitly rejected alternatives, recorded so they are not re-proposed: raising
`requires.speckit_version` to `>=0.14.3` (fixes nothing for anyone running today, and leaves installed trees
broken); `chmod +x` from the config ceremony (the ceremony runs *through* the bridge, so it cannot); shipping a
wrapper the host marks executable (no such mechanism exists — speculative machinery, Principle XV).
