# Contract: the Windows probe as a measurement instrument

`.github/workflows/windows-conformance.yml` reaches a real `windows-latest` host
from a throwaway branch without opening a pull request. It already carries a
host-profile `::notice::`; this feature adds performance measurement to the same
channel.

```
git push --force origin HEAD:ci/windows-probe
gh run list --branch ci/windows-probe --limit 2
```

Raw job logs answer **403** to a non-admin token on this repository;
annotations do not. Every fact this feature needs from Windows must therefore
arrive as an annotation.

## The four questions

| # | Question | Reports | Settles |
| --- | --- | --- | --- |
| **W1** | Cost of one process creation on this runner — a `jq.exe` start, a git-bash `fork`, a `pwsh` start — measured with Defender exclusions **off** and **on** | milliseconds per spawn, both states | whether lever B (Defender exclusions) is real, and the size of the prize for the `output.sh` guard question |
| **W2** | Does the corpus survive at concurrency 3 and at 4, and what is the wall-clock at each? | `survived`/`lost`, wall-clock, **verdict count** | FR-004's proof obligation before the cap may be raised |
| **W3** | Per-scenario, per-port time split on that host | seconds for the bash leg, seconds for the pwsh leg | confirms the spawn model on the real host and sizes what remains |
| **W4** | Does an MSYS-built `jq` on this runner emit LF (so the port's `output.sh` wrapper condition reports false), and what does the corpus cost with it? | `jq` CRLF probe result, corpus wall-clock | option (a) of the Complexity Tracking decision — worth measuring **before** asking the user to weigh a fidelity trade-off against a number nobody has |

## Guarantees

| # | Guarantee | Rationale |
| --- | --- | --- |
| P1 | Measurements arrive as **one** `::notice::`, appended to the existing host-profile block. | The ten-annotation cap; per-scenario annotations were tried and dropped the report that carried the bytes |
| P2 | W2 reports the **verdict count**, not only a duration. "It finished faster" is not evidence that a wider fan-out is safe; a complete verdict set is. | FR-004, FR-005 |
| P3 | A measurement that a POSIX host could have produced does not go here. The probe answers what only Windows can answer. | ~11 minutes and four Windows runners per round trip |
| P4 | No probe result is quoted as proof unless it names the run id and the commit it was measured on. | Constitution VI's measurement-over-emulation rule |
| P5 | Every quirk the probe establishes is written into `docs/10-windows-portability.md`, in the catalog's rule-then-measurement form. | FR-022, Constitution VI |

## Budget discipline

One retry maximum on an inconclusive Windows run, then the result is reported as
it stands. A `windows-latest` round trip costs roughly eleven minutes and four
runners; re-rolling a flake proves nothing and spends the loop this feature
exists to shorten.
