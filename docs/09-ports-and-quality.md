# 9. Twin ports and quality gates

Portability here is not achieved by a portable runtime. It is achieved by two
native implementations *proven* equivalent.

## Why two implementations

```mermaid
flowchart TB
    Decision{"How do we run on<br/>macOS, Linux, and Windows?"}
    Decision -->|"rejected"| Runtime["Ship a compiled binary,<br/>or require Node/Python"]
    Decision -->|"chosen"| Twin["Two native ports"]

    Runtime --> Cost1["a download step"]
    Runtime --> Cost2["a build step"]
    Runtime --> Cost3["a runtime dependency to install and version"]

    Twin --> Bash["Bash >= 4 — macOS, Linux<br/>runtime deps: curl, jq, git"]
    Twin --> Pwsh["PowerShell 7+ — Windows<br/>runtime deps: none beyond the shell"]
    Twin --> Proof["Behavioural equivalence must be PROVEN,<br/>not assumed — hence the conformance corpus"]
```

The cost of the chosen design is that every change has to land twice. The
benefit is that the extension is `git clone` away from running on any of the
three platforms, with no build and no download at any point.

## The conformance corpus — the equivalence proof

Forty language-agnostic golden scenarios, each a JSON file, run against **both**
ports by one harness. For identical inputs the two ports must produce a
byte-identical capture.

```mermaid
flowchart LR
    Scn["scenario.json<br/>mock config · fixture repo · argv · env"] --> Harness["run-scenario.sh"]

    Harness --> MockA["mock Jira<br/>OS-assigned ephemeral port"]
    Harness --> RunB["Bash port"]
    Harness --> RunP["PowerShell port"]

    RunB --> OutB["out-bash/<br/>stdout · exit · calls.log · workdir"]
    RunP --> OutP["out-ps/<br/>stdout · exit · calls.log · workdir"]

    OutB --> Diff{"diff -r"}
    OutP --> Diff
    Diff -->|"any difference"| Fail["FAILING TEST<br/>never a documented quirk"]
    Diff -->|"identical"| Pass["Equivalence proven for this scenario"]
```

Four things are compared, not one:

| Capture | What it proves |
|---|---|
| `stdout` | identical run summaries, byte for byte |
| `exit` | identical exit codes |
| `calls.log` | identical Jira API call **sequence** |
| `workdir` | identical post-run repository tree |

The mock binds an **OS-assigned ephemeral port** and the harness injects the
resulting base URL, so scenarios never hard-code a port and concurrent runs
cannot collide.

## The test pyramid

```mermaid
flowchart TB
    subgraph Live["tests/live/ — real Jira, credentials required"]
        L1["Idempotency verified against a real instance<br/>mocks are NOT sufficient: three live-only bugs<br/>were found in the extension this one replaces"]
    end

    subgraph Conf["tests/conformance/ — both ports, mocked Jira"]
        C1["40 golden scenarios"]
        C2["mock-jira server + fixtures"]
    end

    subgraph Unit["tests/bash/ (bats) · tests/powershell/ (Pester)"]
        U1["engine/ · sink/ · lib/ · hooks/ · commands/"]
        U2["ci/ — the meta-tests that guard the design rules"]
    end

    Unit --> Conf --> Live
```

The live suite runs on push to the default branch, on a schedule, and on a
maintainer-applied label — **never** as a blocking gate on pull requests from
forks, because GitHub Actions does not expose repository secrets to fork PRs.
Fork PRs are gated by the mocked suites, linting, and coverage.

## CI gates

```mermaid
flowchart TB
    PR(["Pull request"]) --> CI

    subgraph CI["ci.yml"]
        M["Unit suites on the three-OS matrix<br/>ubuntu · macos · windows"]
        S["Static checks — manifest, messages, no registry write"]
        K["Conformance corpus — both ports, diffed"]
    end

    PR --> Boundary

    subgraph Boundary["boundary.yml — engine carries zero Jira knowledge"]
        B1["Gate 1 — no engine script imports sink/"]
        B2["Gate 2 — no Atlassian identifier in engine/"]
    end

    PR --> Gates

    subgraph Gates["gates.yml"]
        G1["Bash coverage >= 80% — kcov,<br/>traceability fallback if kcov is unviable"]
        G2["PowerShell coverage >= 80% — Pester CodeCoverage"]
        G3["Module parity — the two ports' leaf sets must match"]
        G4["Version literal single-sourced — it exists only in<br/>extension.yml and CHANGELOG.md"]
    end

    CI --> Merge{"All green?"}
    Boundary --> Merge
    Gates --> Merge
    Merge -->|"yes"| Ok(["mergeable"])
    Merge -->|"no"| No(["blocked"])
```

Coverage is computed on the **mocked** suites only, so the gate stays
verifiable on fork PRs without credentials. Critical paths — drift decision,
idempotency, fail-closed, privacy guard, credential resolution — target
coverage close to 100%.

## The version, single-sourced

```mermaid
flowchart LR
    Manifest["extension.yml<br/>extension.version"] --> C1["config command output"]
    Manifest --> C2["README managed-block markers"]
    Manifest --> C3["run summaries"]
    Manifest --> C4["upgrade check"]
    Manifest -.->|"the only other place the<br/>literal may appear"| Changelog["CHANGELOG.md"]

    Grep["CI greps the whole tree"] -->|"the literal anywhere else fails the build"| Manifest
```

## Test isolation — a rule learned from a real defect

A conformance harness test once detected "leaked" mock processes with
`pgrep -f mock-server.ps1` — a name-pattern scan across the whole machine.
Under `bats --jobs` it matched *other* scenarios' mock servers running
concurrently and failed a passing test with no real leak.

```mermaid
flowchart LR
    subgraph Wrong["Rejected at review"]
        W1["pgrep -f some-name"]
        W2["a fixed well-known port"]
        W3["a shared temporary path"]
    end

    subgraph Right["Required"]
        R1["a PID the test captured at launch"]
        R2["a port the harness bound and published<br/>into run-scoped output"]
        R3["a path the test itself generated"]
    end

    Wrong -->|"correct only by the accident<br/>of running alone"| Broken["Breaks the moment the suite is parallelised"]
    Right --> Stable["Green under bats --jobs"]
```

The generalised rule, now part of the constitution: a test must identify every
piece of state it observes, asserts on, or cleans up by an identifier it
recorded from what it spawned or created — never by a name pattern or any
machine-wide scan.

## Running the suites locally

```sh
tests/run-bash.sh
pwsh -NoProfile -Command "Invoke-Pester -Path tests/powershell -PassThru"
```

`tests/run-bash.sh` requires only `bats` and `jq` — no PowerShell, no GNU
`parallel`. It shards one `bats` invocation per file across cores with
`xargs -P`, falling back to serial execution when concurrency is unavailable,
and never silently reports zero executed tests. Each test isolates its own
tmpdir and the mock binds an ephemeral port (or, for the Bash port, no port at
all — a scripted `curl` shim), so concurrent runs cannot collide. Use
`tests/run-bash.sh --since <ref>` for a change-scoped inner loop; it fails
open to the full suite on any doubt about what a diff affects.
