# Phase 0 Research: Retire the .env credential file

**Feature**: 030-retire-env-credentials | **Date**: 2026-08-18

Every decision below is grounded in a measurement or a quoted line of the
current code, not in an assumption about it.

---

## R1 — How the two non-secret settings reach 28 files

**Decision**: Resolve `base_url` and `email` **once**, at command entry
immediately after `config_load`, and export them into the process environment
under their existing variable names. Every existing reader stays unchanged.

**Measurement**:

| Variable | References | Files |
| --- | --- | --- |
| `SPEC_KIT_JIRA_BASE_URL` | 72 | 28 |
| `JIRA_EMAIL` | 8 | 6 |
| `JIRA_API_TOKEN` | 12 | 4 |

Every reader uses one of two shapes — `${SPEC_KIT_JIRA_BASE_URL:-}` in Bash,
`$env:SPEC_KIT_JIRA_BASE_URL` in PowerShell — so seeding the environment is
transparent to all of them.

**Rationale**: FR-013 and FR-017 require environment-first precedence. A
chokepoint that writes the variable *only when it is unset or empty* delivers
that precedence as a property of the assignment rather than as a rule 72 sites
must each honour. It also means the feature cannot silently miss a reader.

**Alternatives considered**:

- *Thread a config object through every reader.* 72 call sites across two ports,
  many of them on the reconcile path. Rejected under Constitution XIV, and it
  would put a config lookup inside loops the process budget governs.
- *A lazy accessor function (`jira_base_url`) replacing each read.* Still 72
  edits, and in Bash each call is a function invocation in paths that are
  already spawn-sensitive (`docs/11-process-budget.md`).
- *Resolve inside `config_load` itself.* Rejected: `config_load` is a pure
  reader used by tests and by the ceremony's dry-run; giving it an environment
  side effect makes it non-obvious and hard to test in isolation.

**Consequence to honour**: the chokepoint must run in **every** entry point that
reaches Jira — `config.sh`, `reconcile.sh`, `feature.sh`, `mention.sh`,
`seed.sh` in Bash, and their five PowerShell twins. A missed entry point is a
command that works only when the operator also exported the variable.

---

## R2 — Executing the retrieval command without a shell

**Decision**: Tokenize the declared value on whitespace and `exec` the resulting
argument vector directly. Bash: read into an array with `read -ra` and invoke
`"${argv[@]}"`. PowerShell: split, then invoke the program with its arguments —
never `Invoke-Expression`.

**Rationale**: FR-004 requires shell metacharacters to be inert. Direct
invocation of an argument vector never constructs a command line for an
interpreter, so a pipe or `$(...)` in the value arrives as a literal argument to
the program and does nothing. This mirrors the Figma extension's stated
behaviour ("executed without a shell (tokenized exec), so pipes or substitutions
in its value are inert").

**Alternatives considered**:

- *`eval` / `Invoke-Expression`.* Would make the value a code-execution surface.
  Rejected outright even though FR-005 keeps the value out of workspace files —
  defence in depth, and the Bash port already refuses to `source` a `.env` for
  exactly this reason ("Extract the value without sourcing (avoid executing
  arbitrary content)", `lib/credentials.sh`).
- *Requiring a single executable with no arguments.* Breaks every realistic
  value: `security find-generic-password -s spec-kit-jira -w`,
  `op read op://Private/jira-pat/credential`.
- *Full POSIX word-splitting with quote handling.* Rejected under KISS.
  Whitespace tokenization covers every documented secret manager. A value
  needing embedded spaces in one argument should point at a wrapper script —
  which is documented rather than engineered around.

**Windows note**: `Get-Secret` is a cmdlet, not an executable, so the Bash port
can never launch it under Git Bash / WSL. FR-034 requires documenting the
wrapper (`pwsh -NoProfile -NonInteractive -Command Get-Secret …`). The
PowerShell port invokes the cmdlet directly.

---

## R3 — Bounding the retrieval command's wait

**Decision**: Bound the execution at **5 seconds** and treat exceeding the bound
as a retrieval-command failure (FR-009). Both ports pin that same literal, and
it is not configurable.

**Why the number is fixed here and not left to implementation**: C3.6 requires
the failure message to name the bound, so the literal is part of the output two
ports must agree on byte for byte. A "sensible default per port" is a
conformance divergence waiting to be discovered on a Windows runner. 5 s is
about an order of magnitude above every documented retrieval command's warm
latency (`security find-generic-password`, `secret-tool lookup`, `op read`,
`Get-Secret` all return in well under a second against an unlocked store), and
short enough that a hook fails visibly instead of appearing to freeze. No
requirement asks for a knob; adding one would be a YAGNI violation.

**Rationale**: The bridge runs inside lifecycle hooks. Constitution IV is
explicit that "a wait is indistinguishable from a hang" where nobody can answer
a prompt — and a SecretStore vault in password mode does exactly that on its
first `Get-Secret` of a session. The old probe satisfied this by swallowing
everything silently; the new rung satisfies it by failing fast and saying why.

**Alternatives considered**:

- *No bound, rely on the store being non-interactive.* This is the documented
  Windows failure mode the Figma extension calls out — the operator is told the
  PAT is missing when the vault is merely locked. A hook would hang instead.
- *Bounding via the existing HTTP timeout.* Wrong layer: credential resolution
  happens before any request is built.

**Portability**: `timeout(1)` is not universally present on macOS. The Bash port
therefore backgrounds the command and polls, rather than depending on a GNU
coreutils binary — consistent with the port's existing no-new-dependency rule.

---

## R4 — Relaxing the credential-shape guard per key

**Decision**: Parameterize the existing guard with an exempt-path list.
`_cfg_credential_errors` gains an optional path argument; the PowerShell
`Get-JiraConfigCredentialError` gains `-ExemptPaths`. Callers pass the one key
their surface legitimately holds.

**Grounding**: The guard already works on paths and already carries exactly this
mechanism for one subtree:

```bash
| select( ($p[0] // "") != "privacy" )     # bash, _cfg_credential_errors
```
```powershell
if ($Path -like 'privacy*') { return }      # powershell, Get-JiraCredentialPathError
```

So the exemption is an extension of a pattern the code already has, not a new
concept.

**Why it is unavoidable**: the guard refuses email-shaped **and**
`*.atlassian.net`-shaped scalars at every non-`privacy` key, and
`config_personal_load` pipes `personal.yml` through it explicitly. Both values
this feature stores are precisely those two shapes. Without the exemption,
US2 fails at load time on both ports.

**Scope** (FR-021, FR-022): exactly one exempt path per surface — the base-URL
key of `config.yml`, and the email key of `personal.yml`. Token shapes stay
refused everywhere, unconditionally (FR-020). US2 AC5 is the test that the
relaxation did not become a hole.

**Alternatives considered**:

- *Stop scanning `personal.yml` entirely.* The operator chose the narrow option
  (Q2 = A). A whole-file exemption also loses the accidental-paste guard on
  `override.*`.
- *Detect the surface inside the guard from the filename.* Couples a pure
  value-shape function to the filesystem and makes it untestable in isolation.

---

## R5 — Where the ceremony creates `personal.yml`, and the degraded-mode consequence

**Decision**: Run the new `_config_personal_effect` **after `config_load` and
before the degraded-mode early return**, and move `_config_gitignore_effect` to
the same position.

**Grounding** — measured call order in `scripts/bash/commands/config.sh`:

| Line | Step |
| --- | --- |
| 925 | `_config_hooks_effect` |
| 932 | `config_load` |
| 939–950 | degraded-mode trigger → **early return** |
| 1271 | `_config_gitignore_effect` |

**The problem this solves**: degraded mode fires when the base URL or the token
is missing — which is exactly the state of a fresh setup. With the effect at
line 1271, an operator would need working Jira credentials in order to obtain
the file in which they declare their credentials. `personal.yml` would never be
created for the one person who needs it created.

**Why the gitignore effect moves too**: FR-029 requires the created file to be
covered by the repository gitignore. Creating a gitignored file in degraded mode
while the ignore rule is only written in full mode would leave an uncovered file
on disk.

**Precedent**: the degraded path already makes this argument for the hooks
effect, in its own comment — reporting an effect as `skipped` when the work was
in fact performed "would be a lie about work that was in fact performed". The
gitignore effect needs no Jira at all, so the same reasoning applies.

**Cost, stated plainly**: `us2-degraded-mode` currently asserts
`gitignore: {status: "skipped"}`. That expectation changes, and the scenario
must be updated as part of this feature. This is an observable behaviour change
beyond the letter of the FRs, justified in `plan.md` Complexity Tracking.

**Prerequisite**: the team placeholder (FR-025) needs the catalogue from
`config.yml`, which is why the effect sits after `config_load` rather than with
the other offline effects. A repository whose `config.yml` is missing or invalid
already fails before this point; that is unchanged.

---

## R6 — Testing a config-sourced base URL in the conformance corpus

**Decision**: Two scenario families.

1. **Validation and refusal** (malformed URL, missing everywhere) — a scenario
   sets `SPEC_KIT_JIRA_BASE_URL: ""` and supplies a fixture `config.yml`. No
   mock interaction needed.
2. **The value actually used for a request** — requires a new harness
   substitution: `run-scenario.sh` replaces a `@MOCK_BASE_URL@` sentinel in the
   copied workdir's `config.yml` after the fixture copy.

**Why the substitution is unavoidable**: the two ports do not share a base URL
value. `run-scenario.sh` documents it:

> "the Bash port is exercised through the curl shim (no process); the PowerShell
> port needs the real socket server, since its native HTTP client cannot reach
> the shim's sentinel `MOCK_BASE_URL`."

So the Bash port sees a literal sentinel and the PowerShell port sees a real
`http://127.0.0.1:PORT`. No fixture file can hardcode a value that works for
both, and a fixture is copied verbatim today.

**The empty-string idiom is already established** — `run-scenario.sh`:

> "The mock base URL is set FIRST so a scenario's env can override it (e.g. to
> the empty string, which the ports treat as unset — the degraded-mode trigger)."

**Alternatives considered**:

- *Only test family 1.* Leaves FR-013's happy path — the base URL from
  `config.yml` reaching a live request — unproven cross-port. Rejected: that is
  the requirement's whole point.
- *Let scenarios declare fixture file contents inline.* A much larger harness
  change for one need.

**Constitutional constraint**: Principle IV forbids a real site URL in a test
fixture. Fixture `config.yml` files use the sentinel or an `.invalid` host —
never a real tenant.

---

## R7 — Making `team` optional when absent

**Decision**: Treat an **absent** `team` key as "no team selected" — the same
inactive result an absent file yields — and validate the pattern only when the
key is present.

**Grounding** — both ports currently score an absent key as invalid:

```bash
(if ((.team // "") | test("^[a-z][a-z0-9]*$") | not) then "team is invalid" else empty end)
```
```powershell
if ($team -cnotmatch '^[a-z][a-z0-9]*$') { $errs.Add('team is invalid') }
```

Verified directly:

```console
$ printf '%s' '{"email":"a@b.com"}' | jq -r '[ (if ((.team // "") | test("^[a-z][a-z0-9]*$") | not) then "team is invalid" else empty end) ] | .[]'
team is invalid
```

**Why this is a blocker, not a nicety**: FR-024 creates `personal.yml` with the
team placeholder commented out. Under today's rule the ceremony would therefore
emit a file that makes every subsequent command in that repository fail with
`config: personal (…): team is invalid`. The ceremony's own output would break
the repository.

**Blast radius beyond the new feature**: the catalogue-membership check that
follows must also be skipped when no team is declared, or a repository whose
`config.yml` declares no teams — a shape the corpus already covers
(`us3-feature-no-team`, `repo-with-teams-noselect`) — fails the moment
`personal.yml` exists.

**Alternatives considered**:

- *Write a real team into the created file.* Violates the existing rule that a
  team selection is never required, and FR-026 (the ceremony never chooses).
- *Omit the team placeholder.* The operator asked for it, and it is the file's
  primary purpose.
- *Create the file only when a team can be resolved.* Reintroduces the
  chicken-and-egg of R5.

---

## R8 — Interaction with the YAML parse cache

**Decision**: Accept that a `personal.yml` carrying an email is never written to
the parse cache, and change nothing.

**Grounding**: `config_yaml_to_json` only caches a parse when the result is
credential-clean:

```bash
if [[ -n "${cachefile}" ]] && [[ -z "$(printf '%s' "${canon}" | _cfg_credential_errors)" ]]; then
```

The cache-side call passes no exemptions, so an email in `personal.yml` makes
the parse uncacheable.

**Rationale**: the effect is one small YAML parse per run, on a file of a few
lines — not on the reconcile path, and not per item. Threading exemptions into
the cache predicate to save it would widen what may be written to a disk cache
in exchange for negligible time. The conservative behaviour is the right one.

**Consequence to verify at implementation**: the spawn-budget guardrails must
not regress. The file is parsed once per run either way.

---

## R9 — The constitutional amendment

**Decision**: Ratify Constitution v2.0.0 amending Principle IV on three points
**before** implementation begins. `/speckit-constitution` is the vehicle; this
feature does not amend the constitution as a side effect.

**The three points** are tabulated in `plan.md` §Constitution Check (IV-a site
URL in a tracked file, IV-b the rung order, IV-c fail-loud on a declared
command) with the justification for each in the Complexity Tracking table.

**Explicitly out of scope of the amendment** — these clauses of IV stay exactly
as they are:

- no token, authentication email, or accountId in a tracked file;
- the token never logged, never echoed, never on a command line;
- the pre-write payload guard and its dedicated exit code;
- the no-prompt / no-hang rule for credential resolution.

**Also unchanged**: the mechanism-substitution escape hatch already in IV covers
replacing `security` / `secret-tool` / `Get-Secret` with an operator-declared
command, so that part of the feature needs no amendment at all.

**Alternative considered**: *redesign the feature to fit v1.3.0.* That means
keeping `.env` — the exposure the feature exists to delete — and keeping the
base URL out of the shared config, which is the operator's stated requirement.
Both were raised and re-affirmed. The constitution is the thing that moves.

---

## R10 — `http` on the loopback interface, and the test it unblocks

**Decision**: `base_url` accepts `https://` for any host, **and** `http://` when
the host is one of the three loopback literals `127.0.0.1`, `localhost`, `[::1]`.
Plain `http` to any other host — including private ranges such as
`192.168.1.10` — stays refused.

**What forced the question**: the validation rule as first written refused every
`http://` URL. The conformance mock is
`http://127.0.0.1:<port>` (`tests/conformance/mock-jira/lib.sh:113` for the curl
shim, `:149` for the real socket server), and §R6's `@MOCK_BASE_URL@`
substitution writes exactly that value into the fixture's `config.yml`. The two
rules collide: the loader would refuse the fixture with `base_url is invalid`,
exit 4, before any request — so `us030-settings-from-files.json`, the scenario
that proves FR-013's happy path, could never pass. The rule and its own test
could not both be right.

**Rationale for resolving it in favour of loopback rather than of the harness**:
the reason `http` is refused is that Basic auth would cross the network in clear
text. On loopback it crosses nothing — the same reasoning browsers apply when
they treat `http://localhost` as a secure context. So the exception is not a hole
punched for a test; it is the rule stated at the precision it always needed.

**Kept narrow on purpose**: the check is against the three literals, never
against a hostname that resolves to a loopback address. That keeps validation a
pure string function — no DNS, no network, no dependence on the machine — which
is what lets both ports agree byte for byte and what keeps `internal.example.com`
pointed at `127.0.0.1` from becoming a way to smuggle plain `http` past the rule.

**Alternatives considered**:

- *Give the mock TLS so the fixture can say `https://`.* A certificate to
  generate, trust, and rotate on three operating systems, for a corpus whose
  whole point is to have no moving parts. Rejected outright.
- *Exempt the fixture from validation.* Then the scenario proves the loader
  accepts a value the loader would refuse in production — a test asserting the
  opposite of the shipped behaviour.
- *Have the harness substitute a validating hostname.* Works for the Bash port,
  whose curl shim keys on the path and ignores the host, and breaks the
  PowerShell port, whose real HTTP client must actually connect to the socket.
- *Drop the scheme check entirely.* Loses a real protection for the case that
  matters — a team config committing `http://jira.example.com` and sending every
  operator's Basic-auth header in clear text across the corporate network.

**Consequence for the environment variable**: `SPEC_KIT_JIRA_BASE_URL` stays
unvalidated (`contracts/connection-settings.md` C2.7). The asymmetry is recorded
there rather than quietly relied upon.

---

## R11 — Staging the five credential-failure classes in the corpus

**Decision**: exercise C3.3 and each of C3.4–C3.7 as its own conformance
scenario, using commands drawn from the ports' existing dependency set, with one
harness-substituted sentinel for the timeout class.

**What makes this tractable**: `ci-conformance.sh` diffs the **two ports against
each other on one machine** — there is no golden file. A scenario's `env` block
is static JSON, so both ports receive the same literal string by construction.
The constraint is therefore not "the string must be identical across operating
systems", only "the string must behave identically under both ports on the
machine running them".

| Class | `JIRA_PAT_COMMAND` | Why it holds on all three platforms |
| --- | --- | --- |
| C3.3 nothing declared | *(unset)* | — |
| C3.4 absent | `spec-kit-jira-no-such-helper` | No such program exists anywhere |
| C3.5 non-zero exit | `jq --spec-kit-jira-no-such-flag` | `jq` is a hard dependency of the Bash port and of the harness itself, so it is on `PATH` for both ports on every conformance runner |
| C3.7 empty output | `jq -n empty` | Exit 0, nothing on stdout, everywhere |
| C3.6 timeout | `@PAT_HANG_COMMAND@` | Substituted by the harness — see below |

**Why the timeout class needs a sentinel**: no single literal blocks on macOS,
Linux and Windows alike. `sleep 30` is absent from a bare Windows `PATH`;
`ping 127.0.0.1` runs forever on Linux and returns in about three seconds on
Windows, which would silently turn a timeout scenario into a *success* scenario
on one platform — precisely the kind of green-on-one-host divergence this corpus
exists to catch. `run-scenario.sh` therefore resolves `@PAT_HANG_COMMAND@` once
per run (`sleep 30` on POSIX; on Windows an absolute path to a sleeping
executable the runner already carries) and hands the **same resolved string to
both ports**, so the value that appears in both failure messages is identical and
the byte diff is clean.

**Mechanism reused, not invented**: this is `@MOCK_BASE_URL@` (§R6) applied to
the scenario's `env` values instead of to the copied fixture — one substitution
pass, two sentinels.

**What stays a per-port test, and why**: US1 AC4 — a token sitting in the OS
store under the service name the extension used to probe, with no command
declared, must still fail. Planting a real secret in three operating systems'
credential stores contradicts the spec's own assumption that no store is
provisioned, and a `PATH` shim cannot be expressed in a scenario's `env` block.
The existing counting shim (`tests/bash/helpers/secret_store_stub.bash` and its
PowerShell twin) is repurposed for it: installed first on `PATH`, returning a
token that must never be reached. The same helper also discharges C2.6's
at-most-once count, which is what it was built for under feature 021.
