# Data Model: Pin the Jira Destination Host

**Feature**: 032-pin-jira-host | **Date**: 2026-08-28

## 1. Origin

The value both sides of the comparison reduce to. Derived, never stored in this
shape — it is the normalised form of a base URL.

| Field | Type | Rule |
| --- | --- | --- |
| `scheme` | string | Lower-cased ASCII. Compared exactly. |
| `host` | string | Case-folded by an explicitly enumerated ASCII mapping (FR-012). One trailing dot removed, and one only. A bracketed IPv6 literal keeps its brackets and is not split on an interior colon. |
| `port` | integer \| absent | Absent and the scheme's default are equal: 443 for `https`, 80 for `http`. |

**Derivation rules**

- A single trailing CR is stripped before parsing (`docs/10-windows-portability.md` §1; use `${x%$'\r'}`, never a `$'\r\n'` glob).
- Parsing uses in-process string matching only — no subshell capture (MSYS swallows a trailing CR across `$(...)`, which would make the two ports disagree on a contaminated input), no `jq`, no external process, and never `[System.Uri]`.
- Anything after the authority — path, query, fragment — is discarded and never distinguishes two origins.

**States**

| State | Meaning |
| --- | --- |
| `valid` | Scheme and host both parsed |
| `unparseable` | No scheme separator, or an empty authority |

An `unparseable` declared origin is not this feature's concern — the existing
`base_url` shape validator already refuses it earlier, with its own message.

## 2. Recorded destination (`bound_site`)

The origin this checkout is bound to.

| Property | Value |
| --- | --- |
| Location | `.specify/jira/config.local.yml`, top level, key `bound_site` |
| Layer | Local binding — gitignored, machine-owned, unreachable from a pull request |
| Written by | The binding ceremony only, in its existing single serialize-and-write |
| Read by | The connection chokepoint, once per run |
| Shape | A `valid` Origin serialised as `scheme://host[:port]`, normalised at write time |
| Absent | Legitimate — an installation that predates this feature. Refuse per FR-005. |

**Normalised at write time, not only at compare time.** Two ceremony runs whose
declared origins differ only in host case must produce byte-identical files, or
Constitution II's zero-churn proof (`tests/bash/commands/test_config_determinism.bats:62`)
fails.

**Distinct from `site_alias`.** That key remains a human label with its published
meaning (`specs/001-jira-reconcile-engine/contracts/config.local.schema.json:9-12`),
untouched by this feature and unread by it.

**Validation on read** (FR-014): the value must parse to a `valid` Origin and must
equal its own normalised form. A value that does not — including a human alias such
as `prod` written by hand at this key — is `malformed`, refused like an absent one
but naming the key.

### State transitions

```text
absent ──(ceremony reaches a destination)──> recorded
recorded ──(declared origin equals it)─────> recorded        [run proceeds]
recorded ──(declared origin differs)───────> recorded        [run refuses; record unchanged]
recorded ──(ceremony re-run, no argument)──> recorded        [ceremony refuses; record unchanged]
recorded ──(ceremony re-run, --accept-site names the new origin)──> recorded'
malformed ─(ceremony re-run, --accept-site names an origin)──> recorded
```

The record is never rewritten by a run that only *reads* Jira, and never by a
degraded ceremony — which by construction never reached a destination.

## 3. Declared destination

The origin the repository asks for. Not stored by this feature; resolved per run.

| Property | Value |
| --- | --- |
| Sources | `config.yml`'s `base_url`, or the `SPEC_KIT_JIRA_BASE_URL` environment variable |
| Precedence | The environment wins; the file seeds the variable only when it is empty |
| Provenance | Must be captured *at* the chokepoint — once the variable is seeded, which source won is no longer recoverable |

**Provenance decides whether the gate applies at all** (FR-011): a
file-supplied destination is compared, an environment-supplied one is exempt and
is never recorded.

## 4. Gate outcome

What the chokepoint returns, and what each caller does with it.

| Outcome | Condition | Exit | Requests | Writes |
| --- | --- | --- | --- | --- |
| `proceed` | Environment-supplied, or declared equals recorded | — | as usual | as usual |
| `mismatch` | File-supplied and declared ≠ recorded | 4 | 0 | 0 |
| `absent` | File-supplied and no record | 4 | 0 | 0 |
| `malformed` | File-supplied and the record does not parse | 4 | 0 | 0 |
| `binding` | The ceremony itself, opted out by argument | — | as usual | records |

The outcome is a **distinguishable status**, not a pre-formatted message. Reconcile's
existing chokepoint call site replaces the library's message with its own generic
one (`commands/reconcile.sh:615-618`), so a message composed inside the chokepoint
would be lost on precisely the path a lifecycle hook takes. The caller relays the
status and emits the located message itself, through `_reconcile_fault` where that
applies.

## 5. Pinned-origin process state (FR-008)

The credential producer takes an email and no URL today
(`lib/credentials.sh:214`, `lib/Credentials.psm1:179`). To refuse an unbound
destination it needs the pinned origin without re-reading or re-parsing anything —
the gate already computed it once, and `docs/11-process-budget.md` forbids paying
for it again per request.

| Property | Value |
| --- | --- |
| Set by | The chokepoint, on a `proceed` or `binding` outcome |
| Read by | The credential producer, per request |
| Scope | Process-local, non-exported — a child process must not inherit it (mirrors the credential cache's own rule, `lib/credentials.sh:38-41`) |
| Unset | The producer refuses — a call site that never passed the gate does not get a credential |

## 6. `--accept-site <origin>`

| Property | Value |
| --- | --- |
| Parsed by | The shared parser (`lib/cli.sh`, `lib/Cli.psm1`), emitted in the fixed key order both ports share |
| Consumed by | The `config` command only — the other four ignore it, as they already ignore flags aimed elsewhere |
| Value | An origin, shape-checked in the flag's own branch like `--style` and `--reuse` |
| Effect | Permits the ceremony to replace a record that differs. Its value must equal the destination the ceremony actually reached, or the ceremony refuses — naming a *different* origin is not an override. |

Requiring the value to match what was reached is what stops the flag from becoming
the bypass: an operator who pastes the invocation from a refusal message written by
an attacker still has to have reached that attacker's host, and the flag names it
on screen.
