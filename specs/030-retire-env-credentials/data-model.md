# Phase 1 Data Model: Retire the .env credential file

**Feature**: 030-retire-env-credentials | **Date**: 2026-08-18

Two schema additions, one schema relaxation, one guard parameterization, and one
precedence table. Nothing else in the configuration surface changes.

---

## 1. Resolution precedence

Applied by the chokepoint (`plan.md` §Key design decision) once per run, before
any Jira call.

| Setting | Rung 1 | Rung 2 | When neither |
| --- | --- | --- | --- |
| Base URL | `SPEC_KIT_JIRA_BASE_URL` (non-empty) | `config.yml` → `base_url` | Error naming both (FR-023) |
| Email | `JIRA_EMAIL` (non-empty) | `personal.yml` → `email` | Error naming both (FR-023) |
| Token | `JIRA_API_TOKEN` (non-empty) | run `JIRA_PAT_COMMAND` | Error naming both (FR-008) |

**"Non-empty" is the test, not "set".** The conformance harness already relies on
the empty string meaning *unset* (`run-scenario.sh` sets
`SPEC_KIT_JIRA_BASE_URL` to the mock URL and lets a scenario blank it to trigger
degraded mode). The chokepoint must preserve that idiom exactly.

**There is no third rung for any of the three.** `.specify/jira/.env` is read by
nothing after this feature (FR-002).

**Rung 1 is trusted, rung 2 is validated.** The two file-sourced settings are
validated (§2, §3); the three environment variables are not, exactly as today.
The asymmetry is deliberate — a variable is set by whoever launched the process
and has never been checked, while a file is committed, shared, and is where a
typo outlives the person who made it. The visible consequence is that a value
which worked as a variable can be refused once moved into the file; the located
error says which key and why. Recorded here because "the environment wins" reads
as "the environment is equivalent", and it is not. See
`contracts/connection-settings.md` C2.7.

---

## 2. `config.yml` — the tracked team config

### Schema change

Top-level allowed keys, today (both ports, identical lists):

```text
version_compat, projects, routing, routing_default, privacy, teams,
field_defaults, task_mirror
```

Add one:

```text
… , base_url
```

- Bash: the `IN(…)` set in `_CFG_CONFIG_ERRORS_JQ` (`lib/config.sh`).
- PowerShell: `$allowedTop` in `lib/Config.psm1` (line ~762).

### Entity

| Field | Type | Required | Rule |
| --- | --- | --- | --- |
| `base_url` | string | No — the environment may supply it instead | Must be an absolute URL with a host and **no trailing slash**, no path, no query, no fragment. Scheme `https`, or `http` when the host is a loopback literal |

### Validation rules

| Input | Outcome |
| --- | --- |
| `https://example.atlassian.net` | Accepted |
| `https://jira.example.com` | Accepted — self-hosted is not excluded |
| `http://127.0.0.1:8080` | Accepted — loopback exception (§2a) |
| `http://localhost:8080` | Accepted — loopback exception (§2a) |
| `http://[::1]:8080` | Accepted — loopback exception (§2a) |
| `https://example.atlassian.net/` | Refused — trailing slash (edge case in spec) |
| `example.atlassian.net` | Refused — no scheme |
| `http://example.atlassian.net` | Refused — plain `http` to a non-loopback host |
| `http://192.168.1.10:8080` | Refused — private range is not loopback |
| `https://example.atlassian.net/jira` | Refused — path segment |
| key absent | Accepted; the environment must supply the value |
| key present, empty string | Refused — an empty declaration is a mistake, not an opt-out |

### §2a The loopback exception

`http` is refused because Basic auth would cross the network in clear text. On
the loopback interface it crosses nothing, so the reason for the rule is absent
and the rule is lifted — for the three literals `127.0.0.1`, `localhost`, `[::1]`
and for nothing else. A hostname that merely *resolves* to a loopback address is
still refused: the check is on the literal, so it stays a pure string function
with no DNS lookup, no network, and no dependence on the machine it runs on.

This is not a convenience. Without it the feature's own happy path is untestable:
the conformance mock lives at `http://127.0.0.1:<port>`
(`tests/conformance/mock-jira/lib.sh:113,149`), and the `@MOCK_BASE_URL@`
substitution of `research.md` §R6 puts precisely that value into the fixture's
`config.yml`. A rule refusing every `http` would refuse the fixture at load time,
exit 4, before any request — so the scenario proving FR-013 could never pass. See
`research.md` §R10.

Error shape (located, before any network call — FR-014):

```text
config: config (<path>/config.yml): base_url is invalid
```

### Ownership

`config.yml` is **never written by the tool** (FR-015). The ceremony reports a
missing `base_url`; it does not fill it in. This is unchanged behaviour — the
tool has only ever written `config.local.yml`.

---

## 3. `personal.yml` — the gitignored per-operator config

### Schema change

Allowed keys today: `team`, `override`. Add one:

```text
team, override, email
```

- Bash: the `IN("team","override")` set in `_CFG_PERSONAL_ERRORS_JQ`.
- PowerShell: the `@('team', 'override')` list in `Test-JiraPersonalObject`.

### Entity

| Field | Type | Required | Rule |
| --- | --- | --- | --- |
| `team` | string | **No — changed** | When present: `^[a-z][a-z0-9]*$` **and** a member of the `config.yml` team catalogue |
| `email` | string | No | A well-formed address |
| `override` | object | No | Unchanged: `folder_prefix`, `branch_pattern` |

### The `team` change (FR-027)

| State | Today | After |
| --- | --- | --- |
| File absent | `{"active": false}` | `{"active": false}` — unchanged |
| File present, `team` absent | **`team is invalid`, exit 4** | `{"active": false}` |
| File present, `team: ""` | `team is invalid`, exit 4 | `team is invalid`, exit 4 — unchanged |
| File present, `team: "alpha"`, not in catalogue | `unknown team "alpha" — valid teams: …` | unchanged |
| File present, `team: "alpha"`, in catalogue | `{"active": true, team: "alpha", …}` | unchanged |

The catalogue-membership check must be **skipped entirely** when `team` is
absent — otherwise a repository whose catalogue is empty fails as soon as
`personal.yml` exists (`us3-feature-no-team`, `repo-with-teams-noselect`).

The distinction to implement precisely: *absent key* is inactive; *present but
empty or malformed* is still an error. Declaring the key and leaving it blank is
a mistake worth reporting.

### The `email` field

| Input | Outcome |
| --- | --- |
| `dev@example.com` | Accepted |
| `not-an-email` | Refused — `config: personal (<path>): email is invalid` |
| key absent | Accepted; the environment must supply the value |
| key present, empty string | Refused |

---

## 4. The credential-shape guard

### Current behaviour

A path walker over every scalar, flagging three shapes and exempting one
subtree:

| Shape | Reason string |
| --- | --- |
| `^ATATT` | `Atlassian API token` |
| `[a-z0-9][a-z0-9-]*\.atlassian\.net` | `Atlassian Cloud host` |
| `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$` | `email address` |

Exempt: any path under `privacy`.

### Change — an exempt-path parameter

| Caller | Surface | Exempt paths passed |
| --- | --- | --- |
| `config_load` | `config.yml` | `base_url` |
| `config_load` | `config.local.yml` | *(none)* |
| `config_personal_load` | `personal.yml` | `email` |
| `config_yaml_to_json` cache predicate | any | *(none — see research §R8)* |

`privacy` stays exempt unconditionally on every surface.

### Invariants (FR-020 – FR-022)

1. The token shape (`^ATATT`) is **never** exempted, at any key, on any surface.
2. An email at any key of `config.yml` or `config.local.yml` is still refused.
3. A Jira host at any key of `personal.yml` or `config.local.yml` is still
   refused.
4. An email at `config.yml`'s `base_url`, or a host at `personal.yml`'s `email`,
   is refused by the **field validation** (§2, §3) even though the shape guard
   exempted that path. The two layers are independent; neither is a substitute
   for the other.

Invariant 4 is what stops the exemption from becoming a hole, and is the
substance of US2 AC5.

---

## 5. Credential resolution

### Entity — the retrieval command

| Property | Value |
| --- | --- |
| Source | Process environment only (FR-005) — never any file |
| Shape | A program plus arguments, whitespace-separated |
| Execution | Direct argument-vector exec; no shell, no `eval` (FR-004) |
| Success | Exit 0 **and** non-empty stdout after trimming surrounding whitespace |
| Token | stdout, trimmed. stderr is ignored for the token's value (FR-006) |
| Frequency | At most once per run (FR-010) |
| Bound | **5 seconds**, the same literal in both ports. Exceeding it is a failure, not a fallthrough (FR-009) |

**Why 5 seconds, and why a literal rather than a knob.** The bound exists so a
lifecycle hook cannot hang on a vault waiting for an unlock nobody is there to
type. Every documented retrieval command returns in well under a second when the
store is unlocked — `security find-generic-password`, `secret-tool lookup`,
`op read`, `Get-Secret` — so 5 s is roughly an order of magnitude of headroom for
a cold store or a slow machine, while staying short enough that an operator reads
the failure as a failure rather than as a freeze. It is pinned as a literal
because SC-003 requires the message to **name the bound**: two ports that each
picked their own default would print two different sentences and diverge in the
corpus. Nothing reads it from a file — no requirement asks for a knob, and adding
one would be a YAGNI violation (Constitution XV).

### State machine — the per-process cache

Both ports already carry a three-state cache (`unset | resolved | unresolved`).
It is preserved exactly; only the resolution body changes.

```text
unset ──(env var non-empty)──────────────► resolved
  │
  ├──(no env; command declared, succeeds)─► resolved
  │
  ├──(no env; command declared, fails)────► unresolved  + error (FR-007)
  │
  └──(no env; no command declared)────────► unresolved  + error (FR-008)
```

`unresolved` is distinct from an empty token, so a token-less run consults its
sources once — the existing guarantee, unchanged.

**Bash-specific**: `cred_prime_cache` must still be called from the main shell.
`jira_request` callers are `$(...)` subshells, and a cache filled inside one
dies with it — the retrieval command would then run once per request instead of
once per run, breaking FR-010.

### Failure messages

**Five** states must be distinguishable from the message alone (SC-003): one for
"nothing was declared", plus the **four declared-failure paths** Constitution IV
enumerates by name — absent, non-zero exit, timeout, empty output.

| # | State | Message must name | Class of test |
| --- | --- | --- | --- |
| 1 | Nothing declared | Both the token variable and the retrieval-command variable | Conformance |
| 2 | Command not found | The command, and that it could not be executed | Conformance |
| 3 | Command failed | The command, and its exit status | Conformance |
| 4 | Command timed out | The command, and the bound it exceeded (`5s`) | Conformance |
| 5 | Command printed nothing | The command, and that its output was empty | Conformance |

Rows 2 and 3 are **separate** states, not one "the command failed" state: an
operator who typed the wrong program name and an operator whose vault is locked
have different next actions. Collapsing them is what let row 4 go missing when
the count was written as "four states" over a five-row table.

**Never** included in any of these: anything the command wrote to **stdout**
(FR-011) — that stream may hold a partial secret.

### Call-site gap to close

`sink/jira/client.sh` currently swallows the whole class:

```bash
if ! cfg="$(cred_curl_config "${email}")"; then
  rc="$(cli_exit_code auth)"
  break
fi
```

No message is emitted — the run exits with the auth code and says nothing.
FR-007 and FR-008 require the reason to surface here. The PowerShell twin
(`Get-JiraAuthHeader` returning `$null`) has the same gap.

### The third call site — and the one place silence is still correct

There is a **third** consumer, in the config ceremony itself, and it is the
command an operator runs precisely when credentials misbehave:

```bash
if ! cred_resolve_token > /dev/null 2>&1; then     # scripts/bash/commands/config.sh:942
```
```powershell
if (-not (Resolve-JiraToken)) { $missing.Add('JIRA_API_TOKEN') }   # Config.psm1:1043
```

Both ports discard the reason and enter degraded mode. Constitution IV ¶3 splits
this case in two, and FR-038 makes the split explicit:

| State | Ceremony behaviour |
| --- | --- |
| No retrieval command declared | Silent. Degraded mode as today — this is the "MUST NEVER be tested by the prerequisite check" half of the principle, and it is what keeps a fresh setup usable |
| A declared command that failed (states 2–5) | Reported on stderr **and** carried in the degraded run's `detail` — then the ceremony continues in degraded mode |

Continuing is the point: refusing here would deny the operator the very file in
which they declare their settings (`personal-config-creation.md` §1). "Reported,
not swallowed" is what the constitution requires; "fatal" is not. Every other
entry point keeps fail-closed behaviour, because every other entry point needs
Jira. See `contracts/credential-resolution.md` C6.4–C6.6.

The stale comment two lines above that call — "a token that resolves through
none of the **three rungs**" — is part of this change; there are two.

---

## 6. The created `personal.yml`

Produced by the ceremony when the file is absent (FR-024 – FR-027). Shape, not
exact wording:

```yaml
# .specify/jira/personal.yml — your personal settings. Never committed.

# Your Jira account email, used for authentication.
email: dev@example.com          # filled in when resolvable, else commented out

# Your team, from the catalogue in config.yml. Optional — leave it commented
# out to work without a team selection.
# Available: alpha, beta        # "(the catalogue declares no teams)" when empty
# team: alpha
```

| Property | Rule |
| --- | --- |
| `email` | Written uncommented **only** when resolvable from the environment; otherwise a commented placeholder (FR-024) |
| `team` | **Always** commented out, even when the catalogue holds exactly one team (FR-026) |
| Team list | A snapshot taken at creation; never refreshed, because the file is never rewritten (FR-028) |
| Empty catalogue | The comment says the catalogue declares none — not an empty list (US3 AC4) |
| Result | The file as created must load cleanly and select no team (US3 AC3, SC-006) |

---

## 7. Effects reporting

The ceremony's effects JSON gains one key, alongside `discovery`, `hooks`,
`readme`, `gitignore`:

| Status | When |
| --- | --- |
| `created` | The file was absent and has been written |
| `unchanged` | The file already existed and was left byte-identical |
| `would_create` | `--dry-run` and the file is absent (FR-029) |

The `detail` names what the operator still has to supply and where — including a
`base_url` missing from `config.yml`, which belongs to no other effect (FR-030).

This key must be present in the **degraded-mode** effects object too, which is
why the effect runs before that early return (research §R5).
