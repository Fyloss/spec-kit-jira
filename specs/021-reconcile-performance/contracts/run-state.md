# Contract — the run-state short-circuit

Covers spec FR-019 … FR-028. The governing rule: **every doubt fails open to a full reconcile.** The
short-circuit may only ever skip work after a proven-complete prior run; it may never mask a failure.

## 1. Interface

`lib/run_state.sh` / `lib/RunState.psm1`:

| Function | Behaviour |
| --- | --- |
| `run_state_compose <spec-path> <base-url> <email> <on-drift> <field-values>` | Prints the canonical JSON document of `data-model.md` §1 for the current inputs. Returns 1, printing nothing, if any required input cannot be hashed. Takes `base-url`/`email`/`on-drift`/`field-values` as explicit arguments rather than reading them from the environment or from `cli_parse`'s output itself — `lib/run_state.sh` stays a pure function of its arguments, like `lib/config.sh` and `lib/credentials.sh`'s `cred_curl_config`, not a `sink/`-level module reaching into `JIRA_EMAIL`/`SPEC_KIT_JIRA_BASE_URL` directly. |
| `run_state_matches <spec-path> <base-url> <email> <on-drift> <field-values>` | Composes fresh from the same five arguments and returns 0 only when a recorded document exists, is readable, is valid, and is byte-equal to it. Returns 1 in every other case, including every error. |
| `run_state_record <spec-path> <base-url> <email> <on-drift> <field-values>` | Composes and writes atomically. Creates the directory and its self-ignoring `.gitignore` if absent. Never fails the run: a write error is a warning, not an exit code. |

Hashing primitive: `git hash-object --no-filters <path>` on both ports. `git` is already a declared
prerequisite, and it is the only content hash guaranteed present and identical on all three hosts
(research R7).

## 2. Placement in the pipeline

```text
0  · dispatch guard         (unchanged — disabled event exits 0, no config read, no network)
0a · spec file readable?    (unchanged — exit 1)
0b · basename == spec.md?   (unchanged — 017 target guard, exit 1, zero requests)
──> STATE PHASE  <──        NEW — the short-circuit
1  · resolve routing
...
```

Placed **after** both guards so a disabled event and a rejected target behave exactly as they do today.
Placed **before** the config phase, because config resolution is a meaningful fraction of the one-second
budget SC-001 is written in.

**On the name.** This step is called the **state phase** — `state` in the timing report — and never "the
gate". `gate` is already taken, by the mandatory-field gate that runs after parsing and before recognition
(`hierarchy_mandatory_gate`), and by the pre-write privacy gate inside apply. Two things called the gate in
one pipeline is how a checkpoint ends up asserting that a short-circuited run stops at a phase it never
reaches.

Because this phase runs before routing resolves, the document it composes cannot carry a resolved project
key — `_reconcile_resolve_routing` takes the parsed configuration as an argument. It carries the hashes of
routing's *inputs* instead; see `data-model.md` §1.

## 3. Decision table

| Condition | Outcome |
| --- | --- |
| `--force` given | Full reconcile. The recorded document is not read. |
| `--dry-run` given | Full reconcile. The document is neither read nor written. |
| No state file | Full reconcile. |
| State file unreadable, not valid JSON, or missing a required field | Full reconcile. |
| `schema` unknown | Full reconcile. |
| `extension_version` differs | Full reconcile. |
| Any input hash differs, or an input appeared/disappeared | Full reconcile. |
| `base_url`, `email`, `on_drift`, or `field_values` differs | Full reconcile. |
| Byte-equal | **SHORT-CIRCUIT** |

Short-circuit behaviour: exit `0`, **zero** Jira requests, **zero** writes, **zero** secret-store
consultations, and one line in the run summary naming the short-circuit and the file that recorded it.

## 4. When the state is recorded

Recorded **only** by a real run that:

- applied every planned action, **and**
- emitted no warning, **and**
- has no pending confirmation outstanding, **and**
- was not a `--dry-run`.

Anything less records nothing (spec A-4). A partial success is not recorded with a flag: every consumer
of such a flag would have to reason about which subset was applied, and recording nothing is both simpler
and correct.

`--force` skips the *read* and still records on success.

## 5. Atomicity

Write to a sibling temporary file in the same directory, then rename onto the final name. Two racing
lifecycle hooks each read a whole document or none — never half of one. The loser's write is overwritten
by an equally valid document, so a lost update costs at most one full reconcile, which is the fail-open
direction.

## 6. Ignoring

When the bridge creates `.specify/jira/state/`, it writes `.specify/jira/state/.gitignore` containing the
single line `*`. A gitignore `*` matches dotfiles, so the file ignores itself and nothing under that
directory can ever be staged.

This is the guarantee, not a convenience: FR-026 requires the location to be ignored **before the first
state file is written**, including in a repository bound by an earlier version whose root `.gitignore`
was written without such a line. Relying on the config ceremony's `_config_gitignore_effect` would leave
exactly that repository writing an unignored file on its first reconcile.

## 7. What the state does not attest to

The document hashes **local inputs only**. While it matches, a change made on the Jira side — a deleted
ticket, an edited description, a stripped label — is not detected and not healed.

This is the one guarantee this feature trades away, it is accepted deliberately in the specification, and
`docs/05-reconcile-flow.md` must state it in the same breath as the speed. `--force`, or any local edit,
restores full reconciliation and the self-healing that comes with it.

An expiring state — skip only within N minutes of the last full run — was considered as a way to keep
Principle X's self-healing on a longer horizon, and is recorded in the specification's Out of Scope as
the natural follow-up rather than silently dropped (research R8).

## 8. Invariants

| # | Invariant |
| --- | --- |
| S1 | Every doubt fails open to a full reconcile. There is no condition under which an error causes a skip. |
| S2 | A short-circuited run issues zero Jira requests and consults the secret store zero times. |
| S3 | A short-circuited run writes nothing — not to Jira, not to `spec.md`, not to `tasks.md`, not to the state file. |
| S4 | No credential ever enters the document, in any field, in any form. |
| S5 | The document is byte-identical between the two ports for identical inputs. |
| S6 | `--dry-run` neither reads nor writes it, so the preview still predicts the real run exactly (Principle XI). |
| S7 | A bridge upgrade invalidates every recorded document, so an upgrade that changes rendering is applied on the next run rather than suppressed. |
| S8 | The state file is never deleted or repaired by the bridge; a stale document is invalidated by comparison. |

## 9. Scenario coverage

| Case | Assertion |
| --- | --- |
| Reconcile, then reconcile again unchanged | Second run: exit 0, `calls.log` empty, summary names the short-circuit |
| Touch `spec.md` | Full reconcile |
| Touch `tasks.md`; then delete it | Full reconcile in both directions |
| Edit `config.yml`; edit `config.local.yml` | Full reconcile |
| `--force` on an unchanged spec | Full reconcile; state re-recorded |
| `--dry-run` on an unchanged spec | Full reconcile preview; state neither consumed nor written |
| Reconcile with `--on-drift=abort`, then with `--on-drift=proceed` | Full reconcile — the two modes do not share a state |
| Corrupt the state file to invalid JSON | Full reconcile |
| Change `extension_version` in the state file | Full reconcile |
| First run of all | No state file present; every phase runs; state recorded |
| Disabled lifecycle event, with a matching state recorded | Exit 0 silently, no config read, no state read — exactly today's behaviour (FR-027) |
| Rejected target (`plan.md` passed instead of `spec.md`), with a matching state recorded | Exit 1, zero requests, no state read — exactly today's behaviour (FR-027) |
| Run that ends in a pending confirmation | No state recorded; re-invocation does full work |
| Run that ends with a warning | No state recorded |
| Failed run | No state recorded |
| Two runs racing | Neither observes a partial document; no wrongful skip |
| Short-circuit path, counting secret-store stub | Counter reads 0 |
| Fresh clone, `git status` after a short-circuit | Clean; the state directory is ignored |

## 10. Option sweep (T017a)

Every option `cli_parse`/`ConvertFrom-JiraCliArgs` accepts, examined for whether it changes the set of
actions a reconcile takes — spec A-2 calls a missing input here a defect, not a gap, because it produces a
wrongful skip:

| Option | `cmd_reconcile` reads it? | Verdict |
| --- | --- | --- |
| `--on-drift` | Yes | Already a field (§3, `data-model.md` §1). |
| `--field-value` | Yes, into `field_values`, folded into every issue's written field values by `_reconcile_plan_context`/`Get-JiraReconcilePlanContextFromBinding` | **Gap found and closed by this task**: nothing else in the document changes when only this argument does, so it is now the `field_values` field of §3/`data-model.md` §1. |
| `--accept-defaults` | Yes, into `accept_defaults`, gating whether the mandatory-field gate blocks for confirmation | No document field needed: §4 records state only for a run with **no pending confirmation outstanding**, so a state was only ever recorded when the gate was not askable under the mode active on that run. A later run with unchanged local inputs recomputes the same "not askable", regardless of this run's own flag value — it cannot turn an already-resolved gate into a blocking one. |
| `--force` | Yes | Already a decision-table row (§3) — bypasses the read entirely rather than needing to be a field. |
| `--dry-run` | Yes | Already a decision-table row (§3) — bypasses the read and the write entirely. |
| `--style` | No — `cmd_reconcile`/`Invoke-JiraReconcileRun` do not read the `styles` key `cli_parse` emits | Consumed only by the `config` command (`scripts/bash/commands/config.sh` / `Config.psm1`), which persists the answer into `config.yml`'s managed block. That file is already a hashed `inputs` member, so a change reaching reconcile at all is already covered; the raw flag reaching reconcile itself has no effect to miss. |
| `--child-type` | No — same as `--style` | Same reasoning as `--style`: `config`-only, persisted to the already-hashed `config.yml`. |
| `--issue-type` | No — same as `--style` | Same reasoning as `--style`. |
| `--field-default` | No — `cmd_reconcile`/`Invoke-JiraReconcileRun` read `field_values` but never `field_defaults` | Consumed only by `config`, which splices the answer into `config.yml`'s `field_defaults` managed region (already hashed). Distinct from `--field-value` above precisely because this one is persisted and that one is not. |
| `--accept-defaults` (config context) / `--use-team` | No | `--use-team` is consumed only by the `feature`/`Feature.psm1` command, never parsed out by `cmd_reconcile`. Irrelevant to reconcile's action set. |
| `--verbose` | Yes, but only by `lib/output.sh` (`json_canonical`) and trace framing | Never changes what is planned or applied, only what is printed — matches the Constitution's tracing/output layer, not the action set. |
| `--json` | Yes, but only by the output formatter | Same reasoning as `--verbose`. |
