# Quickstart: validating "Hooks Active From Installation"

**Feature**: 003-install-hook-activation | **Date**: 2026-07-28

How to prove the feature works, from a clean machine state. Everything here is
runnable without Jira credentials except the last section, which is the dogfood
step required before release (Constitution XII).

## Prerequisites

- `specify` CLI ≥ 0.13.0 (`uv tool install specify-cli --from git+https://github.com/github/spec-kit.git`)
- Bash ≥ 4 with `jq`, `curl`, `git` — macOS ships Bash 3.2, so `brew install bash`
- PowerShell 7+ to exercise the Windows port
- `bats`, `Pester`, `shellcheck`, `PSScriptAnalyzer` for the suites

## 1. The reported defect, reproduced

Run this before implementing anything. It is the regression check the fix must
turn green, and it fails today.

```sh
scratch="$(mktemp -d)" && cd "$scratch"
specify init --here --integration claude --force
specify extension add --dev /path/to/spec-kit-jira
cat .specify/extensions.yml
```

**Expected today (the defect)**: no `hooks:` block from `jira` — the install
registered nothing.

**Expected after the fix**: seven events, each with one entry owned by `jira`,
`enabled: true`, `optional: false`. See
[contracts/hook-registry-entry.md](./contracts/hook-registry-entry.md).

## 2. Registration is idempotent and neighbourly

```sh
# Add a foreign entry, then reinstall twice.
specify extension add --dev /path/to/spec-kit-jira --force
specify extension add --dev /path/to/spec-kit-jira --force
```

**Expect**: exactly one `jira` entry per event after each run, and any entry
belonging to another extension present and unchanged (FR-005, FR-006, SC-004).

## 3. The extension never writes the registry — in any state

```sh
# Put a comment in the file first: an operator's comment is the canary.
printf '\n# our team disabled after_implement on purpose\n' >> .specify/extensions.yml
cp .specify/extensions.yml /tmp/before.yml

# Run the ceremony through the agent: /speckit.jira.config
diff /tmp/before.yml .specify/extensions.yml && echo "byte-identical ✅"
```

**Expect**: no difference, comment included, and the ceremony reports its hook
effect as `healthy` (FR-022, FR-023, SC-007, SC-012).

Now repeat the same `diff` after each of these states, and expect
byte-identical every time — this is the guarantee, and it has no exempted case:

| State to create | Expected report |
| --- | --- |
| Delete one event's entry by hand | `incomplete`, naming the event and the official install command |
| Set one entry to `enabled: false` | `held disabled`, naming the event and `--enable-hook` |
| Add an entry with our command and no `extension:` field | `duplicated`, naming the event and the manual edit |
| Corrupt the file | `unreadable`, naming the file — **never** "hooks missing" |

## 4. What the extension can repair, and what it cannot

```sh
# Delete one event's entry by hand, then run the ceremony.
```

**Expect**: the ceremony **reports** the missing event and names the one command
that restores it — `specify extension add --dev <path> --force` — and does not
restore it itself (FR-025). Run that command: the entry comes back in the
canonical eight-field shape.

```sh
# Now seed a leftover entry from a pre-manifest version:
# an entry whose command is ours but which has no `extension:` field.
```

**Expect**: the report names the affected event as `duplicated` and gives the
exact manual edit. Neither the extension nor the official install can remove it
— the install's purge matches on the `extension` field it does not have — so
this is the one case with no automated repair, by design (FR-028, plan.md
§ Complexity Tracking).

## 5. Every registered hook resolves to a real command

```sh
# From the extension repository:
ls commands/                                  # three .md files, including reconcile
grep -A2 'provides:' -n extension.yml         # three declared commands
grep -n 'command:' extension.yml              # every hook command is one of them
```

**Expect**: the sets match exactly. This is the check that would have caught
`speckit.jira.reconcile` being registered while never existing (SC-002).

## 6. The bridge runs straight after install

```sh
cd "$scratch"
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help
```

**Expect**: usage output, with no prior installation, `PATH` change or profile
edit. On Windows, the same through
`.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` (FR-012, FR-013).

Audit that the install touched nothing outside the repository (FR-008, US4
scenario 3):

```sh
git -C "$scratch" status --porcelain     # changes confined to the repo
```

## 7. Degraded runs stay non-blocking and truthful

With the repository installed but **not** configured, run any lifecycle step.

**Expect**: the host command succeeds, and at most one notice describes the
repository as not yet configured and names the configuration command spelled
correctly (FR-015 – FR-019). Repeat for each fault in the matrix — credentials
absent, credentials rejected, prerequisite missing, Jira unreachable, malformed
registry — and expect a succeeding host command and one correctly-attributed
message each time (SC-006).

## 8. A disabled hook stays disabled across a reinstall

This is the guarantee upstream does not give us, so test it explicitly.

```sh
# Set enabled: false on one jira entry, run the ceremony once to record it.
specify extension add --dev /path/to/spec-kit-jira --force
```

**Expect**: the install sets `enabled: true` in the registry (upstream
behaviour we cannot prevent), **and** the lifecycle step for that event still
performs no bridge step and emits no warning, because the recorded decision
overrides dispatch. After the next ceremony the registry reads `enabled: false`
again and the report names the flag that would release it (FR-007, FR-020,
SC-005). Background in [research.md](./research.md) R5.

## 9. Suites

```sh
bats tests/bash                       # Bash port
pwsh -c 'Invoke-Pester tests/powershell'
bats tests/conformance                # cross-port equivalence
shellcheck scripts/bash/**/*.sh
```

**Expect**: green on all three operating systems, statement coverage ≥ 80% on
the mocked suites (Constitution XIII).

## 10. Dogfood before release

Point a real repository at a real Jira project, install, configure, and run a
full lifecycle. **Expect**: a mirrored feature reached with only the install
command and the configuration command, no troubleshooting step (SC-010).
