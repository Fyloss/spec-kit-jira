# Contract: Locale-Independent Clock Reading

**Feature**: 024 | **Satisfies**: FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, FR-008

Governs how `scripts/bash/lib/timing.sh` turns a host clock into milliseconds. The PowerShell port is out of
scope here: `Timing.psm1` reads `[datetime]::UtcNow.Ticks / 10000`, Int64 arithmetic with no textual rendering,
so no separator exists anywhere in its path (research R7).

## §1 The reading

**C1.1** — A clock reading is reduced to digits before any arithmetic touches it. Every non-digit character is
removed; what remains is a base-10 integer of microseconds since the epoch.

**C1.2** — No code path may name, match, or branch on a decimal separator character. This is what FR-002 means
by "by construction": a list of known separators — however long — does not satisfy this contract.

**C1.3** — The digit string is coerced with an explicit base-10 prefix. A leading zero must not be read as
octal. *(This is half of today's defect: `093486` is parsed as an octal literal and rejected for containing
`8` and `9`.)*

**C1.4** — Milliseconds are `digits / 1000` on the microsecond tier. The six-fractional-digit format is bash's
own and is fixed for every version that offers this tier.

## §2 Fail-open — the instrument never decides an outcome

**C2.1** — Before arithmetic, the digit string must match `^[0-9]+$`. Empty or malformed ⇒ degrade.

**C2.2** — Degrading means: mark the instrument degraded, return **success**, leave the run untouched.

> **Why this clause exists.** `scripts/bash/spec-kit-jira.sh:17` sets `set -euo pipefail`. A failing arithmetic
> expansion returns non-zero and aborts the entire reconcile. Today the instrument can kill the run it is
> measuring; that is the defect, not a side effect of it.

**C2.3** — §2 applies to **every** clock tier, not only the microsecond one (FR-003 is written about any
failure of the instrument).

**C2.4** — Degrading emits nothing that would alter the error stream's bytes in a way the corpus diffs
(FR-004). The instrument degrades quietly.

## §3 Report invariance

**C3.1** — Phase names, their order, field widths, and line shape are unchanged from feature 021, and identical
between ports (FR-006, FR-007).

**C3.2** — Under an injected clock, the report is **byte-identical across every locale** (FR-006).

**C3.3** — With the mode off, the run emits nothing additional on any channel (FR-007).

**C3.4** — The whole-second degraded notice on a host with no sub-second clock is unchanged (FR-008).

## §4 Verification

| # | Assertion | Locale |
| --- | --- | --- |
| V1 | A phase of known duration reports that duration **correctly** | `fr_FR.UTF-8` |
| V2 | Same | `de_DE.UTF-8` |
| V3 | Same | `C` |
| V4 | Report byte-identical across V1-V3 under the injected clock | all three |
| V5 | Forced malformed reading ⇒ exit code, stdout, and written files identical to timing-off | any |
| V6 | Forced malformed reading ⇒ run is **not** aborted by `set -e` | any |

> **V1-V3 must assert the duration, never the absence of an error.** Measured (research R1): the pre-change
> code errors only when the fractional part begins with `0` — roughly one reading in ten. For the other nine it
> returns silently with the seconds discarded. An error-absence test therefore **passes against the broken
> code ~90% of the time** and is not a regression test for this defect. This is spec FR-005's explicit
> requirement and the single most important line in this contract.
