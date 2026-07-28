# Quickstart walk-through results — 003 Hooks Active From Installation

**Task**: T083 | **Date**: 2026-07-28 | **Host**: macOS, `specify` CLI 0.13.4,
PowerShell 7.5.2, bash 5.x (Homebrew)

Every section of [quickstart.md](./quickstart.md) was walked against a fresh
scratch repository created by the T001 harness. Results below, in order.

## §1 — the reported defect, reproduced

```
specify init --here --integration claude --force
specify extension add --dev <path-to-spec-kit-jira>
```

| Assertion | Result |
| --- | --- |
| events declared under `hooks:` | **7** |
| entries owned by `jira` | **7** |
| `enabled: true` | **7** |
| `optional: false` | **7** |

The install alone registers and activates all seven. No configuration ceremony
ran. This is the state the defect report said did not exist.

> **Correction to quickstart.md § Prerequisites**: the CLI flag is
> `--integration claude`, not `--ai claude`, which `specify init` rejects on
> 0.13.4. The quickstart and both harnesses were corrected.

## §2 — registration is idempotent and neighbourly

Two further `--force` reinstalls: still exactly **one** `jira` entry per event.

## §3 — the extension never writes the registry, in any state

An operator comment was appended to the registry as a canary, then the ceremony
was run in each documented state:

| State | Reported | Registry |
| --- | --- | --- |
| healthy | `healthy` | byte-identical ✅ |
| one entry deleted by hand | `incomplete` | byte-identical ✅ |
| one entry `enabled: false` | `held_disabled` | byte-identical ✅ |
| leftover pre-manifest entry | `duplicated` | byte-identical ✅ |
| YAML anchor (unreadable) | `unreadable` | byte-identical ✅ |

The comment survived every run.

## §4 — what can be repaired, and what cannot

- **Missing entry** → reported as `incomplete`, naming
  `specify extension add --dev <path-to-spec-kit-jira> --force`. The extension
  did not restore it; running that command did.
- **Leftover pre-manifest entry** → reported as `duplicated` with the exact
  manual edit. Still present after the official install, as designed: the purge
  matches on the `extension` field the entry does not have.

## §5 — every registered hook resolves to a real command

Three documents installed (`speckit.jira.config.md`, `speckit.jira.feature.md`,
`speckit.jira.reconcile.md`); the hook commands are exactly
`speckit.jira.feature` and `speckit.jira.reconcile`. The sets agree.

## §6 — the bridge runs straight after install

`.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help` printed usage
immediately after install, invoked by path from the repository root, with no
`PATH` change and no prior step. `git status --porcelain` showed changes confined
to the repository.

> This is where the **executable bit** defect surfaced: the entry point was
> committed `0644`, so the documented invocation failed with "permission denied"
> while the file plainly existed. Fixed to `0755`.

## §7 — degraded runs stay non-blocking and truthful

Installed but not configured, a reconcile printed exactly:

```
Jira mirror skipped: this repository is not bound to a Jira project yet.
Nothing was mirrored, and this spec-kit command completed normally.
To bind it, run /speckit.jira.config.
```

Three lines, exit `0`, naming a command that exists.

## §8 — a disabled hook stays disabled across a reinstall

1. `enabled: false` set by hand → ceremony reports `held_disabled` and records
   the event in `.specify/jira/config.local.yml`.
2. `specify extension add --force` → the registry reads `enabled: true` again
   (upstream behaviour we cannot prevent).
3. The lifecycle step for that event: **exit 0, no output at all** — no Jira
   call and no warning.
4. The ceremony's report names `/speckit.jira.config --enable-hook <event>`.
5. After releasing it, the step runs again.

## §9 — suites

| Suite | Result |
| --- | --- |
| `bats -r tests/bash` | green |
| `Invoke-Pester tests/powershell` | 469 passed, 0 failed |
| conformance corpus (31 scenarios, both ports) | zero divergence in stdout, exit, calls, workdir |
| `shellcheck scripts/bash/**/*.sh` | clean |
| `Invoke-ScriptAnalyzer` with the project settings | clean (0 findings) |
| PowerShell statement coverage | **88.52%** (3972/4487) |
| Bash statement coverage | Linux-only (see tasks.md § Verification status) |

## §10 — dogfood

Not performed: requires a real Jira Cloud project and credentials. Everything up
to the Jira boundary was exercised. Tracked as open task T084.
