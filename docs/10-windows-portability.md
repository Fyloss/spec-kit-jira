# 10. Windows portability — measured host quirks and the probe loop

Every rule in this document was **measured on a real `windows-latest` runner**,
not reasoned about. That distinction is the whole lesson: during the CRLF saga
(commits `6802a3f`..`2289340`) three plausible Windows hypotheses were disproved
by measurement, and a faithful emulation — a stub `jq` on PATH that appends CR
exactly the way `jq.exe`'s text-mode stdout does — passed the entire conformance
corpus while the real runner failed fifteen scenarios. A model of Windows is not
Windows.

## The quirks catalog

Each entry states the rule first, then the measurement that proved it.

### 1. Never put `$'\r\n'` inside a glob pattern

The MSYS bash pattern matcher lets a CRLF **inside a pattern** match a bare LF.
This affects `[[ == *…* ]]`, `${x#…}`, `${x%…}` and `${x//…/…}` alike. A
substring count with a `$'\r\n'` needle therefore counts every LF, which made
`managed_section_line_ending` call every LF host CRLF and re-render every
authored line with `\r\n` — one uniform +1 byte per authored line across
fifteen scenarios.

Measured (probe run on `a901562`, MSYS bash 5.3.15): `_ms_count "$c" $'\r\n'`
returned **12** on a 387-byte capture holding **zero** CR bytes, and **2** on
the literal `a\nb\n`. The capture, the pipe, and `igncr` all measured clean.

Single-character forms are unaffected on that host (also measured):
`${x%$'\r'}`, the class `[!$'\r']`, and `*$'\r'*` all behave. To count CRLF
pairs, walk CR by CR and check the byte after — see `_ms_count_crlf` in
`scripts/bash/engine/managed_section.sh`.

### 2. `jq` emits CRLF on multi-line output

The runner's `jq` is a MinGW build with a text-mode stdout: any output that
embeds newlines arrives with `\r\n`. Single scalars arrive clean — which is
why the defect hides until a filter emits its first multi-line document.

Rule: never call `jq` directly in the bash port; go through the wrapper in
`scripts/bash/lib/output.sh`, which detects the behavior once
(`jq -rn '"a\nb"'`) and strips the CR on every read.

### 3. `curl` only reads `cygpath -m` data paths

The `curl` on PATH is native (`x86_64-w64-mingw32`). In a `--config` file, a
`data = "@path"` entry is readable **only** in mixed spelling
(`C:/Users/...`). Measured with a dead-port probe where exit 26 = could not
read the data file, exit 7 = file read fine, connection refused:
`posix=26 win=26 mixed=7`. Spell every path handed to curl with `cygpath -m`.

### 4. Command substitution swallows a trailing CR

On MSYS bash, `$(...)` strips a trailing `\r\n` the way POSIX strips trailing
`\n` (measured: "CR survives a capture: no"). When trailing bytes matter,
protect the capture with a sentinel: `v="$(cmd; printf x)"; v="${v%x}"`.

### 5. Pester discovery order differs by host

A Pester test that is green on macOS can be red on the Linux/Windows runner
purely because files are discovered in a different order. Never let a test
depend on the discovery order of its siblings.

### 6. The checkout itself is clean

`.gitattributes` pins `* text=auto eol=lf` and it **is** effective on the
runner despite `core.autocrlf=true` (measured: `eol: lf` attribute, 0 CR bytes
in fixtures). If bytes diverge on Windows, suspect the toolchain above — not
the checkout.

## The probe loop — how to ask Windows a question

`.github/workflows/windows-conformance.yml` runs the conformance corpus alone
on `windows-latest`, sharded 4 ways (~11 min wall clock):

```
git push --force origin HEAD:ci/windows-probe   # starts the run
gh run list --branch ci/windows-probe --limit 2
```

Raw job logs answer `403` with a non-admin token; **annotations do not**.
Results come back through exactly one `::error::` (the byte-level divergence
report — GitHub drops everything past the tenth annotation, so per-scenario
errors are forbidden) and one shard-0 `::notice::` carrying the host profile.
When a new question needs a fact only Windows can supply, add one measurement
line to that notice — that is how every quirk above was established.

## The law

Constitution Principle VI already makes byte-identical ports and the three-OS
matrix a merge gate. The rule this saga added: a divergence that manifests on
only one operating system MUST be diagnosed by measurement on a real runner of
that OS — never by emulation — and a platform-specific fix is unproven until a
run on that platform is green. The failing test comes first; for a
Windows-only defect the conformance corpus on the probe **is** that failing
test, because a POSIX host cannot reproduce the host behavior being fixed.
