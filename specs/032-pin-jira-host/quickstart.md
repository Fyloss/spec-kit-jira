# Quickstart: Validating Origin Pinning

**Feature**: 032-pin-jira-host | **Date**: 2026-08-28

How to prove this feature works, end to end, without a real Jira. Details of the
rules live in [contracts/origin-pinning.md](./contracts/origin-pinning.md); the
shapes live in [data-model.md](./data-model.md).

## Prerequisites

- `bats` and `jq` for the bash port; PowerShell 7+ and Pester for the other
- No Jira credentials and no network — every scenario below refuses before the
  first request, or talks to the local mock

## The one trap to know first

`tests/conformance/run-scenario.sh` scrubs every ambient `SPEC_KIT_JIRA_*` and
`JIRA_*` variable and then exports `SPEC_KIT_JIRA_BASE_URL` pointing at the mock.
A destination supplied by the environment is **exempt** from the gate (FR-011).

So a scenario that does not blank that variable exercises nothing, silently, and
passes for the wrong reason. Every refusal scenario must carry:

```json
"env": { "SPEC_KIT_JIRA_BASE_URL": "" }
```

Verify this first when a new scenario passes on the first try.

## Scenario 1 — the redirected destination is refused (US1, SC-001)

Fixture: a repo whose `config.yml` declares one origin and whose
`config.local.yml` records a different one.

```bash
bash tests/conformance/ci-conformance.sh
```

Expected, on both ports, byte-identical:

- exit 4
- empty mock call log — this is the assertion that matters; a message alone does
  not prove zero requests
- stderr naming the declared origin and the exact `--accept-site` invocation
- `config.local.yml` unchanged

## Scenario 2 — no record on file (US2)

Fixture: `config.yml` declares an origin, `config.local.yml` has no `bound_site`.

Expected: exit 4, zero requests, **nothing written**, and a message naming the
binding ceremony. Assert the file is byte-identical before and after — the
refusal must not helpfully record what it just refused.

## Scenario 3 — the instruction is not the bypass (FR-010, SC-008)

The multi-run form, modelled on `us030-guard-not-a-hole.json`:

1. Bind against origin A — record written.
2. Rewrite `config.yml` to declare origin B. Run reconcile — refuses, names B.
3. Run the ceremony exactly as that message's prose suggests, **without**
   `--accept-site`. Expected: refuses, records nothing.
4. Run the ceremony with `--accept-site <B>`. Expected: succeeds, record now B.

Step 3 is the point of the whole feature. If it passes by recording B, the
control is a speed bump and the run must go red.

## Scenario 4 — the environment stays exempt (FR-011)

Any existing scenario. It supplies the destination through the environment and
must behave exactly as before this feature — no new output, no new exit code.
This is what keeps ~200 existing test files running unchanged; if they start
failing, the provenance capture at the chokepoint is wrong.

## Per-port checks

```bash
tests/run-bash.sh --since main        # change-scoped, ≤60s on a single-module diff
tests/run-bash.sh                     # full suite, ~190s
```

PowerShell: run the Pester suites for `lib/UrlOrigin`, `lib/Config`,
`commands/Config`, and `commands/Reconcile`.

What the per-port suites own, and the corpus does not:

- the origin primitive's table of inputs (C1.1-C1.10)
- the credential producer's direct refusal (C6.5 / SC-005) — reached without
  going through the transport
- the hook guarantee across all seven lifecycle events (C5.3 / SC-006), by
  setting `SPEC_KIT_JIRA_HOOK_CONTEXT` and asserting exit 0 with exactly one
  `WARNING:` line

## Proving the two divergence repairs (FR-017)

Before the gate is built on the primitive, each repair needs a case that is red
against the current tree:

| Case | Today | After |
| --- | --- | --- |
| url `https://a.b../x` vs base `https://a.b.` | bash refuses, PowerShell matches | both agree |
| host `İSTANBUL.X` folded | bash `istanbul.x`, PowerShell `İstanbul.x` | both agree |

Run each against the pre-repair code first. A guard that was never seen red is
not a guard — two of three shipped inert the last time this step was skipped.

## Manual smoke test

```bash
cd /tmp && mkdir -p pin-demo/.specify/jira && cd pin-demo
printf 'base_url: "https://one.example.invalid"\nteams: []\n' > .specify/jira/config.yml
printf 'bound_site: "https://two.example.invalid"\n' > .specify/jira/config.local.yml
SPEC_KIT_JIRA_BASE_URL= <bridge> reconcile --json specs/001-x/spec.md
```

Expect exit 4, a message naming `one.example.invalid`, and no network activity —
check with `tcpdump` or by running with no route if you want the strong version.
