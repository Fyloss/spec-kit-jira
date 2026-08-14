# Quickstart — Validating 026 Release Asset Install

How to prove this feature works, on your own machine, without publishing anything. Every step below was
performed during Phase 0 planning; the numbers quoted are what it produced on macOS with `specify` 0.14.4.dev0
and `specify` 0.13.0.

Details live in the contracts — [surface derivation](./contracts/surface-derivation.md),
[artifact shape](./contracts/artifact-shape.md), [publication](./contracts/publication.md),
[bridge invocation](./contracts/bridge-invocation.md) — and the measurements behind the design decisions are in
[research.md](./research.md).

## Prerequisites

- `git`, `python3` (or `zip`), and a POSIX shell.
- `specify` on `PATH` — your normal installation, which is **never modified** by anything here.
- `uv` for the floor-host check. The floor version is fetched into an ephemeral environment with `uvx`, so it
  cannot replace your global `specify`.
- A scratch directory. Nothing below writes inside the repository.

## 1. The surface is what the exclusion list says

```bash
git ls-files > /tmp/all.txt
git -c core.excludesFile=.extensionignore check-ignore --no-index --stdin < /tmp/all.txt > /tmp/ignored.txt
grep -vxF -f /tmp/ignored.txt /tmp/all.txt | grep -vx '.extensionignore' | sort > /tmp/surface.txt
wc -l < /tmp/surface.txt
```

**Expected**: `87`. Breakdown: 76 under `scripts/`, 3 `commands/`, 3 `templates/`, plus `extension.yml`,
`README.md`, `INSTALL.md`, `CHANGELOG.md`, `LICENSE`.

**What it proves**: [surface-derivation §2](./contracts/surface-derivation.md). Change a pattern in
`.extensionignore`, re-run, and the count moves — with no other file edited (SC-004).

## 2. The archive fits, with room to spare

Build it (`packaging/build-artifact.sh` once implemented; the Phase 0 equivalent produced the same numbers),
then measure against every host bound:

```bash
python3 - "$ARTIFACT" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); i = z.infolist()
print("entries      ", len(i), "(host cap 512, our ceiling 256)")
print("uncompressed ", sum(x.file_size for x in i), "(host cap 50 MiB)")
print("largest      ", max(x.file_size for x in i), "(host cap 10 MiB)")
PY
```

**Expected**: `105` entries, `1 727 994` bytes uncompressed, largest member `148 356` bytes
(`scripts/powershell/commands/Reconcile.psm1`). Against the 1 638 entries of the source archive that started
this feature. (Byte counts drift a little from run to run as the shipped files themselves change; the entry
count and largest-member identity are the figures that matter.)

**What it proves**: [artifact-shape §3](./contracts/artifact-shape.md).

## 3. It actually installs — and `file://` will not do

The host rejects `file://` addresses, so serve over loopback. **Bind port 0 and read back the assigned port** —
Constitution XIII forbids a fixed well-known port, and the real test does the same.

```bash
cd "$(dirname "$ARTIFACT")"
python3 -m http.server 0 --bind 127.0.0.1 &   # note the PID; read the printed port
```

Then, in a pristine consumer repository:

```bash
mkdir -p /tmp/consumer && cd /tmp/consumer && git init -q .
specify init --here --force --integration claude --script sh --ignore-agent-tools
printf 'y\n' | specify extension add jira --from "http://127.0.0.1:$PORT/spec-kit-jira.zip"
```

The `printf 'y\n'` is not optional: an address outside a configured catalog raises an `⚠ Untrusted Source`
panel and blocks on `Continue with installation? [y/N]:`. Without stdin it prints `Aborted.` and installs
nothing — which in a script looks like success.

**Expected**: `✓ Extension installed successfully!`

```bash
find .specify/extensions/jira -type f | wc -l        # 87
```

**What it proves**: [publication §4](./contracts/publication.md), FR-024, FR-025.

## 4. The two install routes agree

```bash
mkdir -p /tmp/consumer-dev && cd /tmp/consumer-dev && git init -q .
specify init --here --force --integration claude --script sh --ignore-agent-tools
specify extension add --dev /path/to/spec-kit-jira --force

diff <(cd /tmp/consumer/.specify/extensions/jira && find . -type f | sort) \
     <(cd /tmp/consumer-dev/.specify/extensions/jira && find . -type f | sort)
```

**Expected after FR-002a**: empty.

**Expected before FR-002a** — and this is the defect the comparison found — 6 165 extra files and 38 MB of this
repository's `.git`, copied into the consumer tree by the `--dev` route. `.extensionignore` lists `.github/`,
`.gitignore` and `.gitattributes`, but not `.git/`.

**What it proves**: [surface-derivation §3](./contracts/surface-derivation.md), FR-002a, FR-014.

## 5. The hooks are registered

```bash
cd /tmp/consumer && cat .specify/extensions.yml
```

**Expected**: all seven lifecycle events — `before_specify`, `after_specify`, `after_clarify`, `after_plan`,
`after_tasks`, `after_implement`, `after_analyze` — each with `enabled: true`, plus
`.claude/skills/speckit-jira-{config,feature,reconcile}/`. Identical to what the `--dev` route registers.

## 6. The bridge runs — and this is where it used to stop

On your own host this passes before the fix, because `specify` 0.14.3+ restores the executable bit after
extraction. **That is exactly why this step must be run on the floor host**, and why the CI matrix has a second
dimension.

```bash
cd /tmp/consumer
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help ; echo "exit=$?"
```

Now the one that matters — the floor host, in an ephemeral environment:

```bash
S130="uvx --from git+https://github.com/github/spec-kit.git@v0.13.0 specify"
mkdir -p /tmp/consumer-floor && cd /tmp/consumer-floor && git init -q .
$S130 init --here --force --integration claude --script sh --ignore-agent-tools
printf 'y\n' | $S130 extension add jira --from "http://127.0.0.1:$PORT/spec-kit-jira.zip"
stat -f '%Lp' .specify/extensions/jira/scripts/bash/spec-kit-jira.sh
```

**Expected**: `644`. The bit does not survive extraction on a supported host.

```bash
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help ; echo "exit=$?"
bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh --help ; echo "exit=$?"
```

**Before FR-016**: `126` (`permission denied`), then `5` — our own prerequisite gate rejecting an intact
install and advising `--dev`, which a URL consumer does not have.

**After FR-016**: the second form exits `0` and prints usage, and the command documents instruct that form.

**What it proves**: [bridge-invocation §1 and §5](./contracts/bridge-invocation.md), FR-016, FR-018.

## 7. The documentation cannot regress

```bash
grep -rn 'archive/refs/' README.md INSTALL.md ; echo "exit=$?"
```

**Expected**: no matches (`exit=1`). Reintroduce one and the FR-023 check fails, naming file and line.

```bash
version="$(sed -n 's/^[[:space:]]\{1,\}version:[[:space:]]*//p' extension.yml | head -n1)"
grep -rn "$version" README.md INSTALL.md packaging/ ; echo "exit=$?"
```

**Expected**: no matches. The documented address is version-free and the builder computes the version — which
is what keeps the existing *Version literal single-sourced* job green.

## Teardown

Kill the server by the PID you recorded — not by `pgrep -f`, which is a machine-wide scan the constitution
forbids — and `trash` the scratch directories.

## Where each user story is proven

| story | steps |
| --- | --- |
| US1 — a consumer installs from the documented URL | 3, 5, 6 |
| US2 — the maintainer cuts a version and it publishes itself | 7, plus the release workflow's own dry run |
| US3 — a wrong artifact never reaches a user | 1, 2, 4 |
| US4 — the documentation stops lying | 7 |
