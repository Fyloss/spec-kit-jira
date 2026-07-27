# Contract — `adopt` command (new, both ports)

**Feature**: 003-label-based-adoption | **Parity**: NFR-1 (both ports identical)

Extends [`001/contracts/cli-contract.md`](../../001-jira-reconcile-engine/contracts/cli-contract.md).
Every value below is asserted byte-identically by the conformance corpus on both
ports; a divergence is a failing test, not a documented quirk.

## Synopsis

```text
spec-kit-jira adopt [--spec <folder>]... [--bind <folder>[:us<N>]=<ISSUE-KEY>]...
                    [--yes] [--dry-run] [--json] [--verbose]
```

`adopt` is a **dedicated command**. It is never registered as a hook and never
fired by one (FR-029): it requires an operator confirmation and is a one-time
deliberate transition, whereas hooks are automatic and non-blocking.

## Flags

| Flag | Repeatable | Effect | FR |
|------|-----------|--------|----|
| `--spec <folder>` | yes | Restrict the run to these spec folders. Everything else is reported *out of scope* with zero reads and zero writes against its tickets. Absent ⇒ every spec folder on disk. An unknown folder ⇒ usage error, exit 1, zero writes. | FR-026 |
| `--bind <folder>[:us<N>]=<KEY>` | yes | Pin a target to a specific issue key, replacing label discovery for it. Validated exactly like a discovered candidate. An unknown folder ⇒ usage error, exit 1, zero writes. | FR-020, FR-021 |
| `--yes` | no | Pre-confirm the apply phase. The plan is still printed first. | research §6 |
| `--dry-run` | no | Print the plan and the action set the real run would perform; zero writes. The reported action set equals the real run's exactly. | FR-023 |
| `--json` | no | Emit the run summary as JSON instead of the default prose. | FR-024 |
| `--verbose` | no | Extra diagnostics. The resolved token never appears, even here. | NFR-3, FR-025 |
| `--help` | no | Usage; exits 0. | XVI |

`--bind` and `--spec` are parsed structurally in `lib/cli.sh` (non-empty on both
sides of `=`); the **issue-key shape is validated in the sink**, so no
key-shaped literal enters the neutral layers (research §9). Global flags
inherited unchanged from the 001 contract: `--dry-run`, `--json`, `--verbose`,
`--help`. `--on-drift` is **not** accepted by `adopt` — adoption performs no
transition and reads no status, so drift has no meaning here.

## Phases

`adopt` is strictly two-phase (FR-006). No write of any kind may occur in
phase 1, ever.

### Phase 1 — discovery (read-only)

1. **Enablement gate.** `adoption.enabled` absent or `false` ⇒ refuse with exit
   **4**, name the configuration key that enables it, perform zero reads against
   candidate tickets and zero writes (FR-001, SC-009).
2. **Label-prefix validation.** Empty, containing whitespace, or exceeding
   Jira's 255-character label limit once a suffix is appended ⇒ located
   configuration error, exit **4**, nothing searched, nothing written (FR-002).
3. **Scope + pin resolution.** Any `--spec` or `--bind` naming a folder absent
   from disk ⇒ usage error, exit **1**, zero writes (FR-021, FR-026).
4. **Target derivation.** One `feature` target per spec folder in scope, plus one
   `story` target per user story; each carries the exact labels it implies
   (data-model §2, §3).
5. **Discovery.** One paginated JQL search per distinct routed project over the
   union of that project's label values. Any unreliable read — network error,
   404, authentication failure, exhausted 429 retries — **aborts the whole run
   before any write** with the mapped exit code (FR-008).
6. **Claim reads.** One identity read per candidate and per pinned key. A 404 is
   "unclaimed", not a failure.
7. **Classification.** Each target becomes a binding or one of the eight refusal
   classes (data-model §8).
8. **Print the plan.** One line per spec folder in scope.

### Phase 2 — apply (only after confirmation)

The only action set built is one
`PUT /rest/api/3/issue/{key}/properties/spec-kit-jira` per binding whose status
is `adopt`, with body `{"origin":"human","repo":…,"spec_slug":…}`. It is executed
through the existing `apply_writes`, so the BLOCK-tier privacy guard runs before
the first write with no exemption (FR-028) and any transport failure at or above
exit 2 aborts the remainder (FR-008).

**Adoption emits no other write kind.** No create, no delete, no transition, no
comment, no link, no relabel, no description or summary change (FR-007).

Bindings with status `already-adopted` produce **no action** — they are counted
as skipped (FR-027), which is what makes an interrupted adoption complete on
re-run with exactly one stamp per ticket (SC-007).

## Confirmation

| Situation | Behaviour | Exit |
|-----------|-----------|------|
| `--yes` passed | Plan printed, apply phase runs. | 0, or 4 if any refusal occurred |
| Interactive terminal, operator confirms | Plan printed, apply phase runs. | 0, or 4 if any refusal occurred |
| Interactive terminal, operator declines | Plan printed, zero writes, summary reports **adoption cancelled**. | 0, or 4 if any refusal occurred |
| `--dry-run` | Plan and action set printed, zero writes. Never prompts. | 0, or 4 if any refusal occurred |
| Not a terminal, no `--yes` | Identical to `--dry-run`, and the output names `--yes` as the way to proceed. Zero writes. | 0, or 4 if any refusal occurred |

A decline is an operator **choice**, not a failure — exit 0 (research §6). No
new exit code is introduced for any of these paths (FR-030).

## Exit codes

Reuses the 001 ladder unchanged (FR-030). When more than one class occurs, the
**highest applicable code wins** (FR-013).

| Code | Trigger in `adopt` |
|------|--------------------|
| `0` | Run completed, including a zero-binding run, an already-adopted no-op re-run, and a declined confirmation. |
| `1` | Usage: bad flag, malformed `--bind` value, unknown spec folder in `--spec` or `--bind`. Whole run stops, zero writes. |
| `2` | Fail-closed read during discovery (network, 404, exhausted 429). Whole run aborts before any write. |
| `3` | Authentication failure (401/403). Whole run aborts, zero writes. |
| `4` | Configuration/claim refusal: adoption disabled, invalid label prefix, **or any per-binding refusal**. Unambiguous bindings in the same run still apply. |
| `5` | Prerequisite failure (Bash < 4, missing `curl`/`jq`/`git`, `pwsh` < 7) — before any Jira interaction. |
| `9` | Privacy BLOCK — the pre-write guard matched a known coordinate. Zero writes; adoption is not exempt (FR-028). |

## Refusal classes and their messages

Every message names the spec folder, every issue key involved, and a
copy-pasteable remediation (Principle XVI, FR-013).

| Class | Message names | Remediation |
|-------|---------------|-------------|
| `no-candidate` | the spec folder and **the exact label searched for** | apply the label in Jira, or `adopt --bind <folder>=<KEY>` |
| `several-candidates` | the spec folder and **every** candidate key (never a truncated pair) | `adopt --bind <folder>=<KEY>` naming the intended one |
| `already-claimed` | the spec folder, the candidate, and the spec that already claims it | resolve in Jira, or bind a different ticket |
| `spec-owns-bridge-ticket` | the spec folder and both tickets | resolve the collision in Jira, then re-run |
| `wrong-project` | the spec folder and **both project keys** | bind a ticket in the routed project; adoption never migrates a ticket |
| `unbound-parent` | the spec folder, the story ordinal, and the candidate | bind the spec's feature-level ticket in the same run |
| `wrong-parent` | the spec folder, the candidate, its parent, and the expected parent | re-parent in Jira; adoption never re-parents a ticket |
| `ambiguous-short-number` | **both** spec folders sharing the number | use the full-folder label form, or `--bind` |

**Documented limitation** (research §5, plan Complexity Tracking):
`spec-owns-bridge-ticket` fires when the *candidate itself* carries this spec's
marker with origin `bridge-created`. A bridge-created ticket for the same spec
that is neither labelled nor pinned is not visible to adoption — Jira Cloud
cannot search entity properties, and no spec→ticket index exists in the tree.
The following reconcile's drift reporting is the layer that surfaces it.

## Output

**Default is prose** (Principle XVI). One line per spec folder in scope:

```text
Adoption plan (adoption.enabled: true, label prefix: speckit-adopt:)

  003-label-based-adoption            → PROJ-42   adopt          (label match)
  003-label-based-adoption:us2        → PROJ-43   adopt          (explicit binding, overrides PROJ-44)
  004-billing-export                  → PROJ-51   already adopted (skipped)
  005-audit-trail                     —           REFUSED        (several candidates: PROJ-61, PROJ-62)
      remediation: spec-kit-jira adopt --bind 005-audit-trail=PROJ-61

  out of scope: 001-jira-reconcile-engine, 002-config-discovery-team-prefix

Apply this plan? [y/N]
```

`--json` emits the run summary conforming to
[`run-summary.schema.json`](../../001-jira-reconcile-engine/contracts/run-summary.schema.json)
with the deltas in [`adoption-plan.schema.json`](./adoption-plan.schema.json):
`command` gains `"adopt"`, and an `adoption` block carries the plan.

**No output at any verbosity may contain a credential or a site host** (FR-025,
NFR-3). Issue keys, project keys, and spec folder names only — the same rule the
existing action-set output already follows by emitting host-relative URLs.

## Parity guarantees

- The printed plan is byte-identical between ports for identical state (SC-008).
- The `--json` summary is byte-identical between ports for identical state
  (FR-024, SC-008).
- Exit codes are identical between ports for every scenario in the corpus.
- `--dry-run` and the real run report the same action set for the same state
  (FR-023, SC-003).

## Dispatcher and usage surface

`lib/cli.sh` gains `adopt` in its command list; `spec-kit-jira.sh` /
`spec-kit-jira.ps1` gain it in the usage block:

```text
usage: spec-kit-jira <config|reconcile|mention|feature|adopt> [options]
```

`adopt` appears in **no** hook registration table (FR-029); `register_hooks`
is unchanged by this feature.
