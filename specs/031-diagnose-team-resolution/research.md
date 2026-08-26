# Phase 0 — Research: a pass-through that says which state produced it

Four unknowns, all resolved by measurement against the shipped code and the
host, not by preference. One resolution conflicts with a shipped contract and
is escalated rather than settled here (D3).

---

## D1 — How the repository root is resolved, in both ports, without git

**Decision**: reimplement the host's own rule natively in each port — honour an
explicit `SPECIFY_INIT_DIR`, then walk up from the working directory for the
first ancestor containing a `.specify/` directory, stopping at the filesystem
root.

**Rationale**: the host already resolves its root exactly this way and
deliberately does not use git. `.specify/scripts/bash/common.sh:54-73`:

```
# Get repository root, prioritizing .specify directory
# This prevents using a parent repository when spec-kit is initialized in a
# subdirectory
```

That comment describes the reported workspace precisely — a spec-kit project
nested inside a larger checkout. Adopting the host's marker means this feature
inherits the host's answer instead of inventing a second definition, which is
what the specification's Assumptions already commit to.

It also preserves a boundary this extension has never crossed. Measured:

```
grep -rE "\bgit (checkout|switch|branch|init|add|commit|rev-parse)\b" \
     scripts/bash scripts/powershell   →   0 matches
```

**Alternatives considered**:

- `git rev-parse --show-toplevel` — rejected. It would be the first git
  invocation in the extension's history, it returns the wrong answer in the
  very workspace shape that motivated this feature (a submodule's own root, not
  the spec-kit project's), and it has no answer at all outside a repository.
- Sourcing the host's `common.sh`, which the host's own comment recommends for
  bundled extensions ("bundled extensions inherit it by sourcing core … rather
  than duplicating it") — rejected on three counts. It is Bash-only, so the
  PowerShell port would need a different source and the two ports would stop
  being symmetric. It couples this extension to host script internals across
  the whole `speckit_version: ">=0.13.0"` range the manifest supports. And
  `common.sh` is ~29 KB of unrelated machinery whose `set -e` interactions
  would enter this extension's process.

The rule itself is roughly ten lines per port; duplicating ten lines is the
KISS answer against importing a library to avoid them (Principle XIV).

---

## D2 — Where the discarded diagnostic is destroyed, and what recovers it

**Decision**: stop discarding the loader's stderr at the feature command's call
site; keep the absent-file branch exactly as it is.

**Rationale**: the destruction is one redirection, `commands/feature.sh:767`:

```bash
if ! merged="$(config_load "${dir}" 2> /dev/null)"; then
```

`config_load` already writes located lines — `config: schema (<file>): <detail>`
— through `_cfg_report_errors`. Nothing needs to be computed; the diagnosis
exists and is thrown away three characters before it would have been printed.

The distinction the specification asks for is already structural: the absent
file returns earlier, at `feature.sh:758`, from a separate `[[ ! -f ]]` branch.
So "absent stays silent, present-but-broken speaks" needs no new detection —
only the second branch stops silencing itself.

**Alternatives considered**: re-running `config_load` a second time to capture
its errors after the first failed — rejected, it doubles the cost of the
failure path and can disagree with itself on a file being written concurrently.

---

## D3 — An unloadable personal file, against contract C6.2 — RESOLVED

**Status**: escalated by this research, decided 2026-08-24, and closed by
amending the contract it conflicted with. Spec 030's
`contracts/connection-settings.md` now carries **C6.2a**, and its FR-018 carries
a pointer to it. Contract clause C3.3 here is in force.

**The conflict**. Spec 030, `contracts/connection-settings.md` C6.2:

> A malformed setting refuses the run whether or not the environment would have
> supplied a valid one. A file on disk that cannot be read correctly is a
> fail-closed condition, not a value to be silently outranked.

That contract is enforced at `lib/config.sh:1477-1488`, inside
`config_resolve_connection`, which the feature command calls at
`feature.sh:781` — **before** the explicit personal load at ~797. So the
earlier call site is where an unloadable personal file actually fails today,
and any change confined to the later one would never execute.

**Recommended resolution**: scope, not amendment. C6.2's stated concern is a
malformed file being *silently outranked* by an environment value and the run
then proceeding — with an identity nobody chose — to the network. A
pass-through under FR-013 outranks nothing and reaches nothing: it declines the
file, reports it by name, names the fallback, and makes zero Jira requests. The
fail-closed property C6.2 protects (no write under an unverified setting) is
preserved intact; only the exit code changes, from 4 to 0.

Under that reading, C6.2 continues to govern unchanged on every path that
reaches the network, and FR-013 governs only the naming path, whose defining
property is that it does not.

**Why it was escalated rather than assumed**: C6.2 says "refuses the run", and
a successful exit is not a refusal by that phrase's plain reading. Reading
intent over letter is a judgement this repository's governance does not let a
plan make quietly — a conflict means the feature is redesigned or the contract
is amended, separately and deliberately.

**Decided**: amend. C6.2a records the carve-out where the rule lives, because
`lib/config.sh:1477` cites C6.2 by name and a reader arriving from the code must
find the exception there rather than in another feature's research notes.

The alternative — splitting the validation so a bad `email` stays fatal while a
bad `team` is merely reported — was rejected. `personal.yml` carries `email`,
`team` and `override` in **one** file, validated by **one** call returning
**one** verdict (`config.sh:1287`). Splitting it would give a single file two
behaviours depending on which line is broken, which is the asymmetry FR-013
exists to remove.

---

## D4 — Where the on-request diagnosis attaches

**Decision**: consume the `--verbose` flag that already exists.

**Rationale**: `lib/cli.sh:98` parses `--verbose` and `:350` emits it into the
command's parsed state. Measured: `grep -n verbose commands/feature.sh` returns
**nothing** — the feature command never reads it. The wire is already run and
terminated; this feature connects it.

This is what keeps FR-011 cheap. No new flag means no new argument surface, no
manifest change, and no default output moves — the two conformance scenarios
that pin the silent path pass no `--verbose` and cannot observe the addition.

**Alternatives considered**: adding the state to the `--json` payload —
rejected outright. `us3-feature-no-team.json` invokes `["feature", "--json",
"invoice export"]` and compares bytes, so any new key in that object breaks the
scenario that exists to protect FR-004/FR-005.
