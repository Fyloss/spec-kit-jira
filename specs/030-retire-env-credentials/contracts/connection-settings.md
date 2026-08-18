# Contract: Connection settings — base URL and email

**Feature**: 030 | **Applies to**: `lib/config.sh`, `lib/Config.psm1`, and every
command entry point in both ports.

---

## §1 The chokepoint

**C1.1** — Each port exposes one resolution function
(`config_resolve_connection` / `Resolve-JiraConnection`) that runs **once per
run**, after `config_load` and before any Jira call.

**C1.2** — It sets `SPEC_KIT_JIRA_BASE_URL` in the process environment **only
when that variable is unset or empty**. A non-empty value is never overwritten.

**C1.3** — The same rule applies to `JIRA_EMAIL`.

**C1.4** — Empty string counts as unset. The conformance harness relies on this:
a scenario blanks `SPEC_KIT_JIRA_BASE_URL` to trigger degraded mode.

**C1.5** — Every entry point that can reach Jira calls it: `config`,
`reconcile`, `feature`, `mention`, `seed` — in both ports. An entry point that
omits the call is a command that works only when the operator also exported the
variable.

**C1.6** — After the chokepoint, the 72 existing readers of
`SPEC_KIT_JIRA_BASE_URL` and the 8 of `JIRA_EMAIL` are unchanged. This contract
adds no obligation to any of them.

---

## §2 `config.yml` — `base_url`

**C2.1** — `base_url` is added to the top-level allowed-key set in both ports.
An unknown-key error for `base_url` is a regression.

**C2.2** — Accepted: an absolute `https://` URL with a host and nothing else —
**or** `http://` when the host is a loopback literal (`127.0.0.1`, `[::1]`,
`localhost`), for which see C2.6.

| Value | Verdict |
| --- | --- |
| `https://example.atlassian.net` | accept |
| `https://jira.example.com` | accept |
| `http://127.0.0.1:8080` | accept — loopback (C2.6) |
| `http://localhost:8080` | accept — loopback (C2.6) |
| `http://[::1]:8080` | accept — loopback (C2.6) |
| `https://example.atlassian.net/` | refuse — trailing slash |
| `https://example.atlassian.net/jira` | refuse — path |
| `http://example.atlassian.net` | refuse — scheme, and the host is not loopback |
| `http://192.168.1.10:8080` | refuse — a private address is not a loopback address |
| `example.atlassian.net` | refuse — no scheme |
| `""` | refuse — empty declaration |
| *absent* | accept — the environment must supply it |

**C2.3** — Refusal is located, fail-closed (exit 4), and happens before any
network call:

```text
config: config (<dir>/config.yml): base_url is invalid
```

**C2.4** — `config.yml` is never written by either port. A missing `base_url` is
reported, never filled in.

**C2.5** — When neither the environment nor `config.yml` supplies a base URL,
the failure names both.

**C2.6** — **The loopback exception, and why it exists.** Plain `http` sends the
Basic-auth header in clear text, which is why it is refused. That argument does
not hold on the loopback interface: the bytes never leave the machine. It is
also the only way this contract's own happy path can be tested — the conformance
mock is `http://127.0.0.1:<port>` (`tests/conformance/mock-jira/lib.sh`), so a
rule refusing every `http` would refuse the fixture that proves a config-sourced
base URL reaches a request. The exception is narrow by construction: the scheme
is relaxed **only** for the three loopback literals, never for a hostname that
merely resolves to one, and never for a private-range address. See
`research.md` §R10.

**C2.7** — **The environment variable is not validated; the file is.** A
malformed `SPEC_KIT_JIRA_BASE_URL` is passed through as it is today, while the
same value in `config.yml` is refused. This asymmetry is deliberate and is
recorded so it is not read as an oversight: an environment variable is set by
whoever launched the process — a CI platform, a shell profile — and the bridge
has never validated that surface; a file is checked into a repository, read by
every team member, and is where a typo survives. Adding validation to the
variable would also refuse the mock URL the conformance harness exports for
every scenario, which C2.6 accepts only for `config.yml`. The consequence to
document (FR-037's neighbourhood): a value that worked as a variable may be
refused when moved into the file, and the located error says why.

---

## §3 `personal.yml` — `email`

**C3.1** — `email` is added to the allowed-key set in both ports.

**C3.2** — Accepted: a well-formed address. Refused: malformed, or present and
empty. Absent is accepted — the environment must supply it.

**C3.3** — Refusal is located and fail-closed:

```text
config: personal (<dir>/personal.yml): email is invalid
```

**C3.4** — When neither the environment nor `personal.yml` supplies an email,
the failure names both.

---

## §4 `personal.yml` — `team` becomes optional

**C4.1** — An **absent** `team` key is valid and yields `{"active": false}` —
identical to an absent file.

**C4.2** — A **present** `team` is validated exactly as today:
`^[a-z][a-z0-9]*$`, then membership of the `config.yml` catalogue.

**C4.3** — A present but empty `team` is still refused. Declaring the key blank
is a mistake, not an opt-out.

**C4.4** — The catalogue-membership check is **skipped** when `team` is absent.
A repository whose catalogue is empty must not fail merely because
`personal.yml` exists.

**C4.5** — Both ports produce the identical result object for each of the five
states in `data-model.md` §3.

---

## §5 The credential-shape guard

**C5.1** — The guard takes an exempt-path parameter. `privacy` remains exempt
unconditionally, independently of that parameter.

**C5.2** — Exemptions passed by caller:

| Surface | Exempt |
| --- | --- |
| `config.yml` | `base_url` |
| `config.local.yml` | *(none)* |
| `personal.yml` | `email` |
| the YAML parse-cache predicate | *(none)* |

**C5.3** — The token shape `^ATATT` is never exempt, at any key, on any surface.

**C5.4** — Cross-checks that MUST still refuse:

| Surface | Value | Refused by |
| --- | --- | --- |
| `config.yml` at any key | an email address | shape guard |
| `config.yml` at `base_url` | an email address | field validation §2.2 |
| `personal.yml` at any key | a Jira host | shape guard |
| `personal.yml` at `email` | a Jira host | field validation §3.2 |
| `config.local.yml` at any key | host or email | shape guard |
| any surface, any key | `ATATT…` | shape guard |

**C5.5** — §5.4 is the substance of the exemption not being a hole. It belongs
in a conformance scenario, not a unit test.

---

## §6 Ordering

**C6.1** — Configuration validation (§2, §3, §5) happens during
`config_load` / `Import-JiraPersonalConfig`, before the chokepoint runs and
therefore before any network call.

**C6.2** — A malformed setting refuses the run whether or not the environment
would have supplied a valid one. A file on disk that cannot be read correctly is
a fail-closed condition, not a value to be silently outranked.

---

## §7 Test obligations

| Contract | Where |
| --- | --- |
| C1.2 / C1.3 precedence | **Conformance** — env wins, file used when env blank |
| C2.2 table | Per-port unit test for the table, **including the three loopback rows and the private-range refusal**; **conformance** for one accept and one refuse |
| C2.6 (loopback accepted) | Per-port unit test; exercised end-to-end by every `@MOCK_BASE_URL@` scenario |
| C2.7 (variable not validated) | Per-port unit test: a malformed `SPEC_KIT_JIRA_BASE_URL` with no `base_url` in the file is passed through, not refused |
| C2.3 / C3.3 message text | **Conformance** — byte equality |
| C4.1–C4.4 | **Conformance** — the five states |
| C5.4 table | **Conformance** |
| C1.5 | Per-port test that each entry point resolves |
