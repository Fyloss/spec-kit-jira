# Contract: Origin Pinning

**Feature**: 032-pin-jira-host | **Date**: 2026-08-28

Every clause is numbered so a task, a test, and a review can cite it. Clauses
marked **[BYTE]** are cross-port byte-equivalence obligations and belong to the
conformance corpus, not to a per-port suite.

---

## C1. The origin primitive (`lib/url_origin.sh` / `lib/UrlOrigin.psm1`)

- **C1.1** — `url_origin_parts <url>` prints `scheme host port`, or fails with a non-zero status when the URL has no scheme separator or an empty authority. PowerShell twin: `Get-JiraUrlOriginPart`.
- **C1.2** — The scheme is lower-cased using an explicitly enumerated ASCII mapping.
- **C1.3** — The host is case-folded by that same explicit ASCII mapping. **[BYTE]** A host containing `U+0130` folds identically in both ports — the defect measured today, where `${x,,}` and `ToLowerInvariant()` disagree.
- **C1.4** — Exactly one trailing dot is removed from the host. **[BYTE]** `https://a.b..` and `https://a.b.` are different origins in both ports — the arity defect measured today, where bash strips one and PowerShell strips all.
- **C1.5** — A bracketed IPv6 authority is split at the closing bracket, not at the first colon. `http://[::1]:8080` yields host `[::1]`, port `8080`.
- **C1.6** — An absent port equals its scheme's default: 443 for `https`, 80 for `http`. Any other scheme with no port has no default and compares equal only to another absent port.
- **C1.7** — A single trailing CR is stripped before parsing. No `$'\r\n'` appears in any glob pattern.
- **C1.8** — Parsing spawns no external process, calls no `jq`, and does not use `[System.Uri]`. It performs no subshell capture of the value.
- **C1.9** — `url_origin_canonical <url>` prints the normalised `scheme://host[:port]`, omitting the port when it is the scheme's default. **[BYTE]**
- **C1.10** — `url_origin_equal <a> <b>` returns success when the two canonical forms are identical, and never compares the path, query, or fragment.

## C2. The record

- **C2.1** — The key is `bound_site`, at the top level of `.specify/jira/config.local.yml`.
- **C2.2** — It is accepted by the local layer's allowed-key list in both ports, alongside `site_alias`, `resolved_ids`, `overrides`, `hooks`.
- **C2.3** — Its value must be a string equal to its own `url_origin_canonical` form. A value failing this is `malformed`. **[BYTE]** The error names the key and the file, never a guess at intent.
- **C2.4** — `site_alias` is neither read nor written by this feature and keeps its published meaning.
- **C2.5** — The credential-shape guard exempts `bound_site` in the local layer and **no other key**. The exemption is per-key and per-layer, mirroring `base_url`'s on the team layer.
- **C2.6** — The existing scenario asserting the local-layer guard is not a hole continues to pass unchanged, because it exercises a different key.

## C3. The ceremony

- **C3.1** — The ceremony opts out of the gate by an explicit argument to the chokepoint, never by detecting that it is the ceremony.
- **C3.2** — It records the origin it actually reached, normalised at write time (C1.9), in the same single serialize-and-write that persists `resolved_ids`. No partial state is possible.
- **C3.3** — It records nothing before discovery has succeeded: every earlier refusal returns before the write site.
- **C3.4** — A degraded run records nothing. It returns before the write site by construction, since an empty base URL is one of its two triggers.
- **C3.5** — `--dry-run` suppresses the record exactly as it suppresses the rest of the write.
- **C3.6** — Re-running the ceremony against an unchanged destination produces a byte-identical `config.local.yml` and still reports `unchanged`.
- **C3.7** — When a record exists and the reached origin differs, the ceremony refuses unless `--accept-site` was given. **[BYTE]** Exit 4, zero writes.
- **C3.8** — `--accept-site <origin>` permits the replacement only when its value equals the origin actually reached. A mismatch between the flag's value and the reached origin refuses with its own message. **[BYTE]**
- **C3.9** — Replaying a refusal message's printed invocation verbatim, without `--accept-site`, records nothing (SC-008).

## C4. The gate

- **C4.1** — The comparison runs inside `config_resolve_connection` / `Resolve-JiraConnection`, once per run, before any caller can reach the transport.
- **C4.2** — It adds zero external processes.
- **C4.3** — Provenance is captured at the chokepoint: a destination supplied by the environment is exempt (FR-011) and is never recorded.
- **C4.4** — A file-supplied destination is compared against the record. Outcomes: `proceed`, `mismatch`, `absent`, `malformed`.
- **C4.5** — On any refusing outcome: zero requests, zero writes, exit 4.
- **C4.6** — The chokepoint returns a **distinguishable status**; it does not pre-format the operator message. Callers relay it.
- **C4.7** — **[BYTE]** The `mismatch` message names the declared origin, states that it is not the one this checkout is bound to, and gives the exact `--accept-site` invocation that accepts it.
- **C4.8** — **[BYTE]** The `absent` message names the ceremony to run.
- **C4.9** — **[BYTE]** The `malformed` message names the key and the file.
- **C4.10** — No message contains any portion of the credential, at any verbosity (FR-013, SC-007).
- **C4.11** — No path introduced here prompts, waits for input, or blocks (FR-006).
- **C4.12** — No value readable from a committed file can disable, weaken, or bypass the comparison (FR-015). There is no configuration key, team-config setting, or `overrides` entry that turns the gate off. The only inputs that change the outcome are the record (gitignored), the declared destination, and the provenance of that destination.

## C5. Hook behaviour

- **C5.1** — When the refusal occurs inside a lifecycle hook, the host command's exit status and output are unchanged: exactly one `WARNING:` line, and success returned to the host.
- **C5.2** — Reconcile relays the gate's status through its existing fault path so the located message survives, rather than being replaced by the generic configuration-load message its call site emits today.
- **C5.3** — The guarantee holds for all seven registered lifecycle events (SC-006).
- **C5.4** — The gate itself is never conditional on hook detection; only the reporting is.

## C6. The credential producer (defence in depth)

- **C6.1** — The producer refuses to emit an authorization value for an origin that is not the pinned one.
- **C6.2** — It consults process-scoped state set once by the gate; it does not re-read or re-parse configuration per request.
- **C6.3** — That state is not exported, so a spawned child does not inherit it.
- **C6.4** — When the state is unset, the producer refuses — a call site that bypassed the gate gets no credential.
- **C6.5** — The refusal is reachable directly, without going through the transport, so SC-005 can be proven.

## C7. Corpus obligations

- **C7.1** — Every 032 refusal scenario sets `SPEC_KIT_JIRA_BASE_URL` to the empty string in its `env`, or the harness's unconditional export makes the run environment-supplied and FR-011 exempts it — the scenario would prove nothing.
- **C7.2** — The harness substitutes an origin sentinel into a fixture's `config.local.yml`, not only into `config.yml`, so the positive path can be expressed at all.
- **C7.3** — Every new fixture file is tracked, or the fixture-tracking guard reddens the suite.
- **C7.4** — Minimum scenarios: `mismatch`, `absent`, `malformed`, the ceremony-without-argument replay (SC-008), the two divergence-repair cases from C1.3 and C1.4, and the off-switch probe from C4.12.
- **C7.5** — The off-switch probe (C4.12): a fixture whose committed `config.yml` carries plausible disabling keys — at the top level and inside a `teams` entry — and whose declared origin differs from the record. It must refuse exactly as the plain `mismatch` scenario does, proving no committed value alters the outcome.
