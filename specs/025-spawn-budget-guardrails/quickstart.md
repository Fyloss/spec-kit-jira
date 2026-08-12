# Quickstart: Verifying the Process Budget Guardrails

How to prove each user story delivered what it claims. Every step here is a **verification**
procedure, not an implementation sketch.

**Prerequisites**: `bats` and `jq` on `PATH`. No PowerShell, no GNU `parallel`, no live Jira — every
check below runs against the mock double.

---

## §1 US1 — The rule is discoverable and whole

This story has no automated test; it is verified by inspection, deliberately, because what it
asserts is about what a reader can find.

1. **Reachability.** Open `AGENTS.md` alone. Confirm it carries a named section on the process
   budget, in the same shape as the existing "Windows portability — non-negotiable" section, and
   that it points at `docs/11-process-budget.md`.

   ```bash
   grep -n -A5 -i "process budget" AGENTS.md
   ```

2. **Wholeness (the point of the story).** In `docs/11-process-budget.md`, confirm the batching rule
   and the argument-routing rule appear **as one rule**, not as a rule plus an optional note, and
   that the 128 KiB per-argument limit is named and distinguished from `ARG_MAX`.

3. **Single authority.** Confirm `specs/024-reconcile-local-performance/contracts/spawn-budget.md`
   points at the durable document as authoritative, and that its measurements and derivation are
   still present and unedited.

   ```bash
   git diff main -- specs/024-reconcile-local-performance/contracts/spawn-budget.md
   ```

   Expected: an added pointer only. Any deletion of measured figures fails FR-005.

**Passes when**: a reader with only automatically-loaded context can state both halves of the rule
and reach the full text without opening a `specs/` folder (SC-001).

---

## §2 US2 — BLOCKED, not built

`tests/bash/commands/test_reconcile_run_budget.bats` does not exist. Measured during
implementation (T004b; research.md R5/D7): whole-run C1.2 does not hold against today's code, on
two independent, non-constant sources — `plan_writes`' per-story payload construction (accepted
debt, 024 T030) and `tasks_parse_document`'s per-task line parsing (found during this feature's own
measurement, not previously documented). Both are real, in `scripts/`, and fixing either is out of
this feature's own scope (SC-007). Building the assertion as originally specified would either ship
permanently red or require a production change this feature is not authorised to make.

There is nothing to run for this section. Unblocking it is a maintainer decision — see research.md
R5 for what a fix would need to touch.

---

## §3 US3 — An oversized argument is caught on this machine, not only on Linux

```bash
bats tests/bash/sink/test_argv_size.bats
```

Expected: green on macOS. That is the whole point — the pre-existing
`test_reconcile_large_spec.bats` is a no-op on macOS by its own admission, so a green run there
previously proved nothing.

### §3a The failing-test-first demonstration (contract A5.1/A5.2)

`tests/bash/sink/test_argv_size.bats` carries two `@test` cases precisely for this: the first
covers the same call site `test_reconcile_large_spec.bats` exercises (`plan_apply.sh`'s
`plan_writes` assembly), the second covers `tasks_parse_document`'s own `tasks` array
(`engine/tasks_parse.sh:273`) — a genuinely different site, since the `plan_apply.sh` one is
already covered by the pre-existing test and "a site other than" that one is the whole point.

1. Revert `engine/tasks_parse.sh:273`'s `json_build` call to `jq -cn --argjson tasks "${tasks}"
   --argjson skipped "${skipped}" '{skipped:$skipped, tasks:$tasks}'`.
2. Run `bats tests/bash/sink/test_argv_size.bats` **on macOS**. The second test fails; the first
   (untouched) stays green — the shim correctly isolates the defect to the site actually touched.
3. Revert. Re-run. Both green.

**Passes when**: step 2 is red **on the development host** (SC-004). Measured: the offending
`tasks` argument was 427485 bytes.

---

## §4 No production behaviour changed

```bash
tests/run-bash.sh
bash tests/conformance/ci-conformance.sh
shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')
```

Expected: suite green; conformance **exit 0 with zero "conformance divergence" lines** (success is
silent — there is no pass banner, and the temp paths it prints are harness noise); `shellcheck`
clean.

Because no file under `scripts/` is modified by this feature, SC-007 holds by construction. The
conformance run confirms it rather than establishing it.

```bash
git diff --stat main -- scripts/
```

Expected: empty. A non-empty result means the feature exceeded its own scope.

---

## §5 What this feature deliberately does not verify

- **The PowerShell port's per-item behaviour.** It creates no external process per item by
  construction, so the whole-run assertion there would pass vacuously. Its protection is structural,
  not tested, and the durable document says so (contract W4.1/W4.2).
- **Wall-clock improvement of any kind.** This feature protects feature 024's measured gains; it
  produces none of its own and adds no timing assertion.
