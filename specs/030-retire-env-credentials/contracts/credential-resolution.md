# Contract: Credential resolution

**Feature**: 030 | **Applies to**: `lib/credentials.sh` and `lib/Credentials.psm1`

Both ports MUST satisfy every clause below identically. Where output is
specified, it is byte-identical across ports.

---

## §1 Sources

**C1.1** — The token resolves from exactly two sources, in order:

1. the environment variable `JIRA_API_TOKEN`, when set and non-empty;
2. the program named by the environment variable `JIRA_PAT_COMMAND`.

**C1.2** — No other source exists. `.specify/jira/.env` MUST NOT be opened,
stat-ed, or referenced. The functions `_cred_from_env_file` /
`Get-JiraEnvFileToken` are deleted, not disabled.

**C1.3** — No credential store is probed under a service name of the extension's
own choosing. `_cred_from_secret_manager` / `Get-JiraSecretManagerToken` are
deleted. A store is reached only through `JIRA_PAT_COMMAND`.

**C1.3a** — The proof that the probe is gone is a **per-port** test, not a
conformance scenario: a `security` (and `secret-tool`) stand-in is placed first
on `PATH` and would return a token, no `JIRA_PAT_COMMAND` is declared, and
resolution still fails per C3.3. Planting a real secret in three operating
systems' credential stores is out of scope by the spec's own assumption ("no
credential store is bundled or provisioned"), and a `PATH` shim is not
expressible in a scenario's `env` block. The counting shim that today lives in
`tests/bash/helpers/secret_store_stub.bash` /
`tests/powershell/helpers/SecretStoreStub.psm1` is **repurposed** for this, not
deleted — see C7.1.

**C1.4** — `JIRA_PAT_COMMAND` is read from the process environment only. It MUST
NOT be read from `config.yml`, `config.local.yml`, `personal.yml`,
`.specify/extensions.yml`, or any other file in the workspace.

**C1.5** — The test override `_CRED_SECRET_TOKEN` is retained and keeps
precedence over executing `JIRA_PAT_COMMAND`, so no test needs a real vault.

---

## §2 Execution

**C2.1** — The value of `JIRA_PAT_COMMAND` is split on whitespace into an
argument vector and executed directly. No shell, no `eval`, no
`Invoke-Expression`.

**C2.2** — Given `JIRA_PAT_COMMAND='echo a | tee /tmp/x'`, the program `echo`
receives the literal arguments `a`, `|`, `tee`, `/tmp/x`. No pipe is created and
`/tmp/x` is not written.

**C2.3** — The token is the command's **stdout**, with leading and trailing
whitespace (including `\r`, for a Windows-authored helper) removed. Interior
whitespace is preserved.

**C2.4** — The command's **stderr** never contributes to the token's value.

**C2.5** — Execution is bounded at **5 seconds**. That literal is pinned here
because C3.6 requires the failure message to name it, and a message naming a
different number in each port is a conformance divergence. Exceeding the bound
terminates the command (no orphan is left behind) and is reported per §3. The
value is not configurable — nothing in this feature reads it from a file, and no
requirement asks for a knob.

**C2.6** — The command is executed **at most once per run**, whatever the number
of requests or retries. In the Bash port this requires `cred_prime_cache` to be
called from the main shell before the first `$(jira_request …)`.

---

## §3 Outcomes

| # | Condition | Result | Message names |
| --- | --- | --- | --- |
| C3.1 | `JIRA_API_TOKEN` non-empty | Token resolved | — |
| C3.2 | No `JIRA_API_TOKEN`; command succeeds with non-empty stdout | Token resolved | — |
| C3.3 | Neither variable set | Failure | `JIRA_API_TOKEN` **and** `JIRA_PAT_COMMAND` |
| C3.4 | Command not found / not executable | Failure | the command, and that it could not be executed |
| C3.5 | Command exits non-zero | Failure | the command, and its exit status |
| C3.6 | Command exceeds the bound | Failure | the command, and the bound (`5s`) |
| C3.7 | Command exits zero with empty stdout | Failure | the command, and that its output was empty |

**C3.8** — Every failure message points to the credential documentation.

**C3.9** — No failure falls through to another source. There is nothing after
the second rung.

**C3.10** — **Five** states, not four: C3.3 (nothing declared) plus the **four
declared-failure paths** C3.4–C3.7 that Constitution IV's enforcement test
enumerates — absent, non-zero exit, timeout, empty output. All five are mutually
distinguishable from the message text alone, and each of the four declared ones
carries its own test (§7). An earlier draft of this clause said "four states
C3.3–C3.7", which is where the missing timeout scenario came from: the count
excluded one path while the range included it.

**C3.11** — `JIRA_API_TOKEN` set and non-empty means `JIRA_PAT_COMMAND` is never
executed, even when the token is invalid at Jira. Precedence is decided before
any request.

---

## §4 Secrecy

**C4.1** — The resolved token never appears in a log line, an error message, an
execution trace (`set -x` / `-Verbose`), a process argument list, or any file.

**C4.2** — Bash: the `set +x` bracket around token handling uses a
**function-local** saved state and stays down through the final emptiness test.

**C4.3** — Bash: the token reaches `curl` through `--config` on stdin, never
`-H`. PowerShell: it stays in-process via `-Headers`.

**C4.4** — A failure report MUST NOT echo anything the command wrote to
**stdout**. That stream may hold a partially-retrieved secret. Reporting the
command's own stderr is permitted and expected.

**C4.5** — The cache variables are non-exported in both ports: a child process
spawned mid-run never inherits a copy.

---

## §5 Cache

**C5.1** — Three states: `unset`, `resolved`, `unresolved`.

**C5.2** — `unresolved` is distinct from a resolved-but-empty token. A
token-less run consults its sources once.

**C5.3** — Cache-on-miss: correctness never depends on priming having run. Only
the at-most-once guarantee does.

---

## §6 Call-site obligations

**C6.1** — `sink/jira/client.sh` MUST emit the resolution failure before
returning the auth exit code. Today it breaks silently:

```bash
if ! cfg="$(cred_curl_config "${email}")"; then
  rc="$(cli_exit_code auth)"   # nothing printed
  break
fi
```

**C6.2** — `Get-JiraAuthHeader` returning `$null` MUST likewise surface the
reason at its call site in `sink/jira/Client.psm1`.

**C6.3** — The message emitted at both call sites is byte-identical across
ports.

### The third call site — the config ceremony's degraded-mode trigger

**C6.4** — There is a **third** consumer of token resolution, and it is the one
an operator reaches for when credentials misbehave. Both ports test the token to
decide whether to enter degraded mode, and both discard the reason:

```bash
if ! cred_resolve_token > /dev/null 2>&1; then       # scripts/bash/commands/config.sh:942
```
```powershell
if (-not (Resolve-JiraToken)) { $missing.Add('JIRA_API_TOKEN') }   # Config.psm1:1043
```

Constitution IV ¶3 splits this in two, and the ceremony MUST split with it:

| State | Ceremony behaviour |
| --- | --- |
| No `JIRA_PAT_COMMAND` declared | **Silent.** Degraded mode as today, `JIRA_API_TOKEN` listed among the missing parameters. The rung raises nothing — this is the "MUST NEVER be tested by the prerequisite check" half of the principle. |
| `JIRA_PAT_COMMAND` declared and failing (C3.4–C3.7) | **Reported.** The C3.x failure is emitted on stderr *and* carried in the degraded run's `detail`, before the effects report. |

**C6.5** — A declared-command failure MUST NOT make the ceremony fatal. The
ceremony still completes in degraded mode — creating `personal.yml`, applying
gitignore coverage, reporting hooks — because that is the state a fresh setup is
in, and refusing there would deny the operator the very file in which they
declare their settings. "Reported, not swallowed" is the constitutional
requirement; "fatal" is not, and would contradict `personal-config-creation.md`
§1. Every *other* entry point keeps the fail-closed behaviour of C6.1/C6.2:
`reconcile`, `feature`, `mention` and `seed` need Jira and therefore fail.

**C6.6** — The degraded `detail` text and the stderr line are byte-identical
across ports, and the token-secrecy rules of §4 apply to them unchanged — in
particular C4.4: the command's stdout is never echoed here either.

---

## §7 Test obligations

| Contract | Where the test belongs |
| --- | --- |
| C1.3a (probe removed) | **Per-port** test with a `PATH` shim — not expressible as a scenario |
| C2.2 (metacharacter inertness) | Per-port unit test |
| C2.5, C2.6 | Per-port unit test |
| C3.3, and each of C3.4–C3.7 | **Conformance scenario, one per class — five in total.** The timeout class (C3.6) is not exempt for being awkward to stage; see C7.2 |
| C4.1 | Per-port token-leak test at maximum verbosity |
| C4.4 (stdout never echoed) | Per-port unit test **and** asserted in the C3.4–C3.7 scenarios |
| C6.1–C6.3 | **Conformance scenario** |
| C6.4–C6.6 (ceremony) | **Conformance scenario** — a declared failing command under `config`, exit 0, degraded, reason reported |

A per-port unit test where the table says *conformance* does not discharge the
obligation: byte equality between ports is precisely what a unit test cannot
observe.

**C7.1** — The counting `PATH` shim that today stands in for the OS secret store
is repurposed, not deleted. Feature 021 used it to prove "the store is consulted
at most once per run"; after this feature the identical counting claim applies to
`JIRA_PAT_COMMAND` (C2.6), and the same helper — renamed for what it now counts —
discharges both C2.6 and C1.3a. Its two meta-tests
(`tests/bash/ci/test_secret_store_stub_helper.bats`,
`tests/powershell/ci/SecretStoreStubHelper.Tests.ps1`) follow the rename.

**C7.2** — Staging the five classes in the corpus. The corpus diffs the **two
ports against each other on one machine**, with no golden file, so a scenario's
`env` hands both ports the same literal string; the constraint is only that the
string behaves identically under both ports on that machine.

| Class | `JIRA_PAT_COMMAND` value | Why it is portable |
| --- | --- | --- |
| C3.3 | *(unset)* | — |
| C3.4 absent | `spec-kit-jira-no-such-helper` | Nothing by that name exists anywhere |
| C3.5 non-zero | `jq --spec-kit-jira-no-such-flag` | `jq` is a hard dependency of the Bash port, so it is on `PATH` for both ports on every conformance runner |
| C3.7 empty | `jq -n empty` | Exit 0, nothing on stdout, on all three platforms |
| C3.6 timeout | `@PAT_HANG_COMMAND@` | **Harness-substituted**, because no single literal blocks on all three platforms. `run-scenario.sh` resolves the sentinel once per run and hands the **same resolved string to both ports**, so byte equality holds; the resolved value appears in both ports' messages identically |

The `@PAT_HANG_COMMAND@` substitution is the same mechanism `@MOCK_BASE_URL@`
uses, extended to the scenario's `env` values rather than only to the copied
fixture. Resolution: `sleep 30` on POSIX; on Windows an absolute path to a
sleeping executable the runner already has. A scenario that hardcoded `sleep 30`
would pass on macOS and Linux and silently change failure class on Windows,
which is the divergence this corpus exists to catch.
