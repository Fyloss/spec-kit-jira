# Contract — the timing report

Covers spec FR-001 … FR-006. The instrument every other requirement in this feature is measured with.

## 1. Activation

| Condition | Behaviour |
| --- | --- |
| `SPEC_KIT_JIRA_TIMING` unset or empty | Off. Zero additional bytes on any channel. |
| `SPEC_KIT_JIRA_TIMING` set to any non-empty value | On. |

There is no flag. The switch is an environment variable because lifecycle hooks are invoked by the host,
not by the operator, so a flag could not reach them (spec A-7).

The conformance harness scrubs every ambient `SPEC_KIT_JIRA_*` and `JIRA_*` variable before a run, so the
corpus is off by default and a scenario turns it on through its own `env` block.

## 2. Output shape

One line per phase reached, on **stderr**, in phase order, followed by one total line:

```text
timing: prereq          12 ms    0 requests
timing: state            7 ms    0 requests
timing: config          88 ms    0 requests
timing: parse           41 ms    0 requests
timing: gate             9 ms    0 requests
timing: recognition    734 ms    2 requests
timing: plan            63 ms    0 requests
timing: apply         2841 ms   11 requests
timing: total         3795 ms   13 requests
```

A short-circuited run reaches two phases and reports exactly two lines plus a total:

```text
timing: prereq          12 ms    0 requests
timing: state            7 ms    0 requests
timing: total           19 ms    0 requests
```

- The phase name is left-aligned in a fixed-width column; the duration and count are right-aligned.
  Both ports emit the same column widths, so a fixture with an injected clock diffs byte-for-byte.
- Phases are the eight of `data-model.md` §2, always in that order. A phase not reached is not printed.
  `state` is the run-state short-circuit; `gate` is the mandatory-field gate, which runs before recognition.
- `requests` counts curl **attempts**, retries included.

On a host without a sub-second clock (research R1, tier 3), one extra line precedes the report:

```text
timing: this host has no sub-second clock; durations are whole seconds
```

## 3. Invariants — what the corpus must prove

| # | Invariant | How it is proven |
| --- | --- | --- |
| T1 | stdout bytes identical with the mode on and off | Run the same scenario twice, diff `stdout` |
| T2 | Exit code identical | diff `exit` |
| T3 | Every written file identical | diff the post-run `workdir/` tree |
| T4 | `calls.log` identical | The mode issues no request of its own |
| T5 | Nothing but `timing:` lines is added to stderr | diff `stderr` after removing `^timing: ` lines |
| T6 | Phase names and order identical across ports | diff `stderr` between the bash and pwsh outdirs, with the clock injected |
| T7 | No credential appears anywhere, with tracing on | Run under `set -x` / `Set-PSDebug -Trace 1` and grep the whole outdir for the token |
| T8 | A short-circuited run reports `prereq`, `state`, and the total, and nothing else | Run the state-unchanged scenario with the mode on; assert the stderr phase set |

## 4. Test seam

`_TIMING_FAKE_CLOCK` — whitespace-separated integer millisecond readings, consumed in order by the clock
function. When set, no real clock is read.

It exists because the corpus diffs stderr byte-for-byte across ports, so a real clock makes any timing
scenario permanently red. Precedent in this codebase: `_CRED_SECRET_TOKEN`, `JIRA_NO_SLEEP`,
`_PREREQ_FORCE_MISSING`, `JIRA_MAX_ATTEMPTS`. Underscore-prefixed, absent from the CLI contract, never
documented for operators.

Exhaustion of the list is a defect in the fixture, not in the port: the function returns the last reading
again rather than failing, so a scenario that under-supplies readings shows `0 ms` phases instead of
crashing a run.

## 5. Secrecy

- Timing lines never carry a URL, a header, a token, or a derived authorisation value. They carry a phase
  name, an integer, and a unit.
- The timing module never lifts an existing `set +x` bracket. A phase boundary is marked *outside* the
  functions that suspend tracing, never inside one.
- `JIRA_REQUEST_COUNT` is an integer and is not exported.

## 6. Known boundary — counts inside command substitution

`jira_request` is called through `$( … )` at the `discovery.sh`, `ticket.sh`, and `duplicate_probe.sh`
call sites. An increment inside such a subshell does not reach the parent, so the config-ceremony and
mention paths undercount.

The `recognition` and `apply` phases — the ones every success criterion is written about — use
`> "${tmpfile}"` redirects and run in the parent, so their counts are exact. This boundary is stated
rather than fixed (research R5), and the authoritative count for any test is `calls.log`, which the mock
writes per request and which no subshell can lose.
