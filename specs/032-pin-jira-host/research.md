# Phase 0 Research: Pin the Jira Destination Host

**Feature**: 032-pin-jira-host | **Date**: 2026-08-28

All findings below were established by reading the two ports and, where marked
**measured**, by executing the real modules against real inputs. Nothing here is
inferred from naming.

---

## R1. Where the gate goes

**Decision**: the gate lives inside `config_resolve_connection` (`scripts/bash/lib/config.sh:1611-1624`) / `Resolve-JiraConnection` (`scripts/powershell/lib/Config.psm1:1419-1473`), not in the transport.

**Rationale**: all five commands call the chokepoint before they can reach the transport, with no exceptions.

| Command | chokepoint | first possible request | ordered? |
| --- | --- | --- | --- |
| `config` | `commands/config.sh:1038` | `discovery_list_projects` `:1102` | yes |
| `reconcile` | `commands/reconcile.sh:615` | `prefetch_load` `:987` | yes |
| `mention` | `commands/mention.sh:65` | `identity_read` `:79` | yes |
| `feature` | `commands/feature.sh:889` | `_feat_seed_from_designators` `:972` | yes |
| `seed` | `commands/seed.sh:354` | adoption `:360` | yes |

PowerShell mirrors: `Config.psm1:1133`, `Reconcile.psm1:733`, `Mention.psm1:52`, `Feature.psm1:890`, `Seed.psm1:416`.

Three reasons the transport is the wrong home:

1. **Only the chokepoint knows provenance.** It is the one place that decides whether `SPEC_KIT_JIRA_BASE_URL` came from the environment or from `config.yml` (`lib/config.sh:1620-1624`). By the time the transport sees a URL, that distinction is gone — and FR-011 turns entirely on it.
2. **A transport gate refuses once per call**, so FR-004's "one message" becomes one per call site plus retries.
3. It refuses later, after work the spec says must not happen.

**Alternatives considered**: gating in `jira_request` / `Invoke-JiraRequest` — rejected for the three reasons above. Gating in each command — rejected as five copies of one rule (Constitution XIV).

**Consequence**: the ceremony calls the same chokepoint at `config.sh:1038`, so it would gate itself out of ever binding. It must opt out explicitly through a parameter, not by detection.

---

## R2. Exit code

**Decision**: reuse `EXIT_CONFIG` = 4, via `cli_exit_code config` / `Get-JiraExitCode 'config'`. No new code.

`scripts/bash/lib/cli.sh:15-37` defines the ladder: `EXIT_OK` 0, `EXIT_USAGE` 1, `EXIT_FAILCLOSED` 2, `EXIT_AUTH` 3, `EXIT_CONFIG` 4, `EXIT_PREREQ` 5, `EXIT_BLOCK` 9. PowerShell twin `lib/Cli.psm1:18-35`.

**Rationale**: every comparable refusal already uses 4 — routing unresolved (`reconcile.sh:726`), unknown project (`:750`), binding-predates-parent (`:1402`), `REF-EXISTS` (`seed.sh:347`), mention already-claimed (`mention.sh:97`). Constitution III's monotonic escalation is over *classes*, not sites; this refusal is a configuration refusal. Precedent for not inventing a code: `specs/004-reconcile-config-resolution/research.md:96`.

---

## R3. Where the record lives — and why not `site_alias`

**Decision**: a **new** key, `bound_site`, in `.specify/jira/config.local.yml`. Not `site_alias`.

This reverses the assumption in spec FR-001 as originally written. Three independent findings force it:

1. **`site_alias` is documented to mean the opposite.** `specs/001-jira-reconcile-engine/contracts/config.local.schema.json:9-12`: *"A non-secret human alias for the instance (e.g. 'prod'). The real site URL is resolved at runtime and never persisted here."* Mirrored at `specs/001-jira-reconcile-engine/data-model.md:54`. Spec 030 deliberately left it alone (`specs/030-retire-env-credentials/spec.md:551`).
2. **Reusing it creates a migration class we do not need.** 14 conformance scenarios and 8 bats files carry the literal `site_alias: prod`, including the tracked fixture `tests/conformance/fixtures/repo-with-config/.specify/jira/config.local.yml:3`. Under FR-014 each becomes a *malformed* record — a second refusal class with its own message and remedy. A new key makes every existing installation simply *absent*, which FR-005 already specifies.
3. **A new key is additive** in both allowed-key lists (`lib/config.sh:1020`, `lib/Config.psm1:1006`), where `site_alias` would require rewriting a published contract.

**Alternatives considered**:

- *Store a digest instead of the origin*, avoiding the constitutional question entirely. **Rejected.** The only digest primitive in the tree is `git hash-object --no-filters <path>` (`lib/run_state.sh:46`, `lib/RunState.psm1:33`) — file-based. Hashing a short string needs `--stdin`, which is both a process spawn and the exact cross-port hazard this project has already been bitten by (a PowerShell pipe to a native command appends a newline, and conformance cannot catch it). It also costs FR-004's ability to name the bound destination and Constitution XVI's readability, to buy a governance shortcut.
- *Reuse `site_alias` with an exemption.* Rejected per (1)-(3).

---

## R4. The credential-shape guard blocks the record — and Constitution IV/V with it

**This is the prerequisite, not a detail.**

`config_load` scans the local layer with **no exempt paths**:

- `scripts/bash/lib/config.sh:1548` — `_cfg_credential_errors` with no argument, versus `:1536` which passes `"base_url"` for the team layer.
- `scripts/powershell/lib/Config.psm1:1256` — `Get-JiraConfigCredentialError $localObj`, versus `-ExemptPaths @('base_url')` at `:1237`.

The rule that fires is `config.sh:811` / `Config.psm1:704`: `[a-z0-9][a-z0-9-]*\.atlassian\.net` → *"Atlassian Cloud host"*. Writing a hosted origin at any local-layer key makes the **next** `config_load` exit 4. A successful ceremony would render the configuration permanently unloadable — and only for Atlassian Cloud consumers, so a loopback-based test suite stays green while every real installation breaks.

This is not merely a code guard. It implements Constitution V's enforcement test (`.specify/memory/constitution.md:470-475`), which names exactly **two** narrow exemptions and requires a test proving the shape is refused *"at every key of the other files"*. Constitution IV (`:396-399`) states a real site URL is admitted at the committed team config's one dedicated key and *"anywhere else — any other key, any other file, any test fixture — a real site URL remains forbidden."*

**Decision**: a Constitution IV/V amendment adding a third narrow, key-scoped exemption (`bound_site`, local layer, gitignored) is a **prerequisite task**, on the same footing as the v2.0.0 amendment that unblocked 030. The exemption MUST stay key-scoped, or the live scenario `tests/conformance/scenarios/us030-guard-not-a-hole.json` (run 5, `overrides.site`) reddens — and that scenario is the proof the guard is not a hole.

---

## R5. The comparison primitive already exists — and carries two measured divergences

**Decision**: reuse the designator primitive, lifted from the sink into `lib/`, after fixing two pre-existing cross-port divergences.

`_desig_url_parts` + `designator_host_match` (`scripts/bash/sink/jira/designator.sh:119-160`) and `Get-JiraDesignatorUrlPart` + `Test-JiraDesignatorHostMatch` (`scripts/powershell/sink/jira/Designator.psm1:67-111`) already compute scheme/host/port and compare them lower-cased with default-port equivalence. Pure string work — no `jq`, no external process, no `[System.Uri]` on either side.

**Not** `_apply_known_coords` (`plan_apply.sh:1526-1531`) / `PlanApply.psm1:1428`, which the security review pointed at: it discards scheme and port, yielding a host, not an origin. Measured equivalent across ports on 9 inputs including CR contamination, but wrong shape for FR-002.

**Two divergences measured by executing both real modules:**

| # | Input | bash | pwsh |
| --- | --- | --- | --- |
| A | url `https://a.b../x` vs base `https://a.b.` | **NO MATCH** | **MATCH** |
| B | `İSTANBUL.X` lower-folded | `istanbul.x` | `İstanbul.x` |

A is arity: `${u_host%.}` (`designator.sh:146`) strips one trailing dot, `.TrimEnd('.')` (`Designator.psm1:101`) strips all. B is Unicode: `${x,,}` versus `ToLowerInvariant()` disagree on U+0130. Both are live defects in `feature`/`seed` today, and B is reachable by exactly the attacker-chosen `base_url` this feature exists to catch.

A third issue agrees across ports and is therefore invisible to conformance: `_desig_url_parts` splits host from port on the *first* colon, so `http://[::1]:8080` — a value `config.sh:1004` explicitly admits — parses to garbage in both. FR-002's "full origin" would record it.

**Decisions this forces**: fix A by pinning one trailing-dot arity in both ports; fix B by replacing both folds with an explicit ASCII-only fold (the character set spelled out, never delegated to locale or culture); handle bracketed IPv6 literals explicitly. Each fix is proven by its own failing conformance case *before* 032 builds on the primitive.

**`[System.Uri]` is rejected outright**: it lowercases scheme and host, elides default ports, inserts trailing slashes, and punycode-encodes IDN. Bash reproduces none of that, so FR-009 would break on the first non-trivial input.

**FR-012 needs a correction.** It says port is "compared exactly", but the primitive treats `https://x` ≡ `https://x:443` and the spec's own Edge Cases call a trailing separator insignificant. Default-port normalisation is the correct behaviour; FR-012 is amended to say so rather than leaving two statements standing.

---

## R6. Windows and process budget

**CR contamination is a correctness hazard, not an equivalence one.** Measured: a trailing `\r` on the base URL defeats the `:[0-9]+$` port strip identically in `sed` and in .NET. The two ports stay equal — but the recorded origin would never again equal the declared one, producing a permanent refusal loop. Strip a single trailing CR on read, using the single-character form `${x%$'\r'}`; `designator.sh` already has `_desig_strip_cr`. Per `docs/10-windows-portability.md` §1, never place `$'\r\n'` inside a glob.

MSYS `$(...)` swallows a trailing CR (`docs/10-windows-portability.md` §4), so a CR-contaminated origin can be present in-process and absent after capture — a divergence generator. Both existing primitives already avoid it by using `BASH_REMATCH` rather than a subshell; keep it that way.

**Process budget**: `docs/11-process-budget.md`. The gate runs **once per run** at the chokepoint and adds **zero external processes** — origin extraction needs no `jq` at all, as `_desig_url_parts` proves. FR-008's per-request check MUST consult already-computed state, never re-parse or re-read. Nothing here routes a payload through argv, so the 32 767-byte Windows cap is not engaged.

---

## R7. The hook non-blocking guarantee is not inherited

FR-007 is a real task, not a free property. Two layers exist today:

1. The command prompt (`commands/speckit.jira-mirror.reconcile.md:86-89`) — advisory.
2. `_reconcile_fault` (`commands/reconcile.sh:104-117`) / `Get-JiraReconcileFaultCode` (`Reconcile.psm1:89-116`), which downgrades to a single `WARNING:` and returns 0 when `SPEC_KIT_JIRA_HOOK_CONTEXT` is set.

Two facts the plan must absorb:

- **Layer 2 is `reconcile`-only.** `config`, `mention`, `seed` have no equivalent; `feature` uses a different mechanism (`_feat_fallback`, `feature.sh:1177-1182`). Since all six `after_*` events fire `reconcile` (`hooks/register_hooks.sh:55`), FR-007 is entirely reconcile's problem.
- **Reconcile's chokepoint call site replaces the library's message with its own.** `reconcile.sh:615-618` refuses with the generic *"team configuration could not be loaded (zero writes)"*. If the gate composes its message inside the chokepoint, FR-004's "names both destinations" is lost on the exact path a hook takes. The chokepoint must therefore return a **distinguishable status** that reconcile relays verbatim through `_reconcile_fault`.

`SPEC_KIT_JIRA_HOOK_CONTEXT` is set by nothing in the repository — only by tests. Do not make the *gate* conditional on hook detection; only the *reporting* is, through the existing fault path.

---

## R8. Refusal precedent to copy — and where not to copy it

The message shape: `hierarchy_binding_shape_stale_message` (`sink/jira/hierarchy.sh:331-334`), PowerShell twin `Hierarchy.psm1:398`. Detection returns a dedicated sentinel (`reconcile.sh:294-303`, return 6), emitted through `_reconcile_fault` at `reconcile.sh:1401-1403`.

**Copy its shape, not its position.** `INSTALL.md:164` claims that refusal happens "before the first read"; structurally it does not — the sentinel is captured at the gate phase (`reconcile.sh:788`) but deliberately emitted later (`:1402`), *after* `prefetch_load` (`:987`) and recognition (`:1016`). Its test passes with an empty call log only because the fixture's `spec.md` carries no markers. Copying that position would violate SC-001 on any already-mirrored specification. `INSTALL.md:164` is stale and is corrected by this feature's documentation sweep.

Test shape to copy: `tests/bash/commands/test_reconcile_stale_binding.bats:36-47` (exit 4, message substring, `mock_calls` empty) and `:49-58` (`SPEC_KIT_JIRA_HOOK_CONTEXT` set → exit 0 and exactly one `^WARNING: ` line).

---

## R9. FR-008 needs process-scoped state

`cred_curl_config` (`lib/credentials.sh:214-231`) and `Get-JiraAuthHeader` (`lib/Credentials.psm1:179-193`) take only `<email>`. They receive **no URL today**. SC-005 — reaching the credential producer directly and proving it refuses — requires either a signature change or a process-scoped "pinned origin" the producer consults. This is its own design task, not a side effect of the gate.

---

## R10. Conformance and blast radius

**Adding a refusal scenario that issues no request is a two-file change**: `tests/conformance/scenarios/<name>.json` and `tests/conformance/fixtures/repo-<name>/…`. Nothing under `mock-jira/` moves — the "five-file change" rule applies to widening a `fields=` query, not to this. Fixtures must be `git add -f`'d or `tests/bash/ci/test_fixtures_are_tracked.bats:21` reddens the suite.

Model scenario: `tests/conformance/scenarios/us030-base-url-malformed.json` (exit-4 refusal before any call, empty log). For SC-008's multi-run shape: `us030-guard-not-a-hole.json`'s `"runs": [...]` form.

**Harness facts**: `run-scenario.sh:211-217` scrubs every ambient `SPEC_KIT_JIRA_*`/`JIRA_*`, then `:221` sets `SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"` unconditionally; the scenario's own `env` is applied afterwards, including `""` to unset. **Every 032 refusal scenario must set `"SPEC_KIT_JIRA_BASE_URL": ""`**, or FR-011 exempts the run and the scenario proves nothing. Because the refusal precedes any request, its fixture `config.yml` can carry an unreachable literal and needs no mock sentinel.

**Blast radius — small, and confined to the paths FR-011 does not exempt:**

| Artifact | Impact |
| --- | --- |
| `tests/bash/lib/test_config.bats:1182`, `:1200` | 2 tests write `base_url` into `config.yml` and blank the env var — become exit 4 |
| `tests/powershell/lib/Config.Tests.ps1:1004`, `:1021` | exact twins |
| `tests/conformance/scenarios/us030-settings-from-files.json` | the only scenario consuming `config.yml`'s `base_url`; asserts exit 0 |
| `tests/conformance/fixtures/repo-030-base-url/.specify/jira/config.local.yml` | must be created carrying a recorded origin |
| `tests/conformance/run-scenario.sh:161-173` | must gain an `@MOCK_ORIGIN@` substitution into `config.local.yml`; today only `config.yml` is substituted, so the positive-path fixture is otherwise unwritable |

Not affected: ~100 bash and ~90 PowerShell files that set `SPEC_KIT_JIRA_BASE_URL` (FR-011 exempts them), ~45 sink files that take `base_url` as an argument and never reach the chokepoint, and 235 of 236 conformance scenarios.

**New artifacts**: at minimum 4 conformance scenarios (mismatch, absent record, malformed record, ceremony-without-argument per SC-008) with 3-4 fixtures, plus per-port suites for the comparison, the credential-path refusal (SC-005), and the hook guarantee across all seven events (SC-006).

---

## Spec amendments this research forces

| Spec item | Change |
| --- | --- |
| FR-001 | The record's key is the new `bound_site`, not the existing `site_alias`. |
| FR-004 | Unchanged in intent, but the chokepoint must return a distinguishable status so reconcile can relay the message rather than replacing it (R7). |
| FR-012 | Port comparison is default-port-normalised (`https://x` ≡ `https://x:443`), not byte-exact; host fold is explicit ASCII. |
| New FR-016 | The Constitution IV/V amendment is a prerequisite; the exemption is key-scoped to `bound_site` in the local layer only. |
| New FR-017 | Two pre-existing cross-port divergences in the origin primitive (trailing-dot arity, Unicode fold) are fixed, each with its own failing conformance case, before the gate is built on it. |
| Assumptions | The migration class for a hand-set `site_alias` disappears — a new key means existing installations are simply *absent*. |
