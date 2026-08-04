# Quickstart: Validating 013 — Jira Labels Containing Quotes and Backslashes

**Feature**: 013-fix-yaml-string-escaping | **Date**: 2026-08-03

Runnable checks that prove the feature works end to end. Scenario 1 is the regression test for the
reported defect and **must fail before the fix** — run it first, on an unmodified tree, and keep its
output.

## Prerequisites

- `bash` ≥ 4, `jq`, `bats` (`prereq.sh:79` refuses macOS's bash 3.2 — `brew install bash`)
- `pwsh` 7+ and Pester, for the PowerShell half
- Run everything from the repository root

---

## Scenario 1 — The reported defect (must fail first)

Reproduces the wedged configuration: a file already holding the escaped form.

```bash
cat > /tmp/013.yml <<'EOF'
allowed:
  - "Platform \"legacy\""
EOF

bash -c '
  source scripts/bash/lib/config.sh
  echo "--- decoded ---"
  config_yaml_to_json /tmp/013.yml
  echo "--- rewritten ---"
  config_yaml_to_json /tmp/013.yml | config_to_yaml
'
```

**Before the fix** (recorded on this worktree):

```text
--- decoded ---
{"allowed":["Platform \\\"legacy\\\""]}     <- literal backslashes, exit 0, silent corruption
--- rewritten ---
config: allowed[0]: a string value here contains " or \, ...   exit 4
```

**After the fix**:

```text
--- decoded ---
{"allowed":["Platform \"legacy\""]}          <- the label, intact
--- rewritten ---
"allowed":
  - "Platform \"legacy\""                    <- value byte-identical to the input
```

The key comes back double-quoted (`"allowed"` rather than the bare `allowed` of the input) —
unrelated to this fix, the writer has quoted every key unconditionally since 007
(yaml-key-grammar.md §2.1). Only the value is the byte-identical part this feature guards.

> The `bash -c` wrapper is required: sourcing a port script at the top level of the tool's shell
> corrupts its own `BASH_SOURCE` paths.

---

## Scenario 2 — Round trip over the adversarial corpus

Covers every Edge Case in the spec, and invariant I1 of [data-model.md](./data-model.md).

```bash
bash -c '
  source scripts/bash/lib/config.sh
  for v in "Platform \"legacy\"" "Delivery\\Platform" "Group \"A\\B\"" \
           "trailing\\" "a\\\\b" "\\\"" "Élevée 完了" "10004" "clean"; do
    out="$(jq -cn --arg v "$v" "{k:\$v}" | config_to_yaml)"
    printf "%s\n" "$out" > /tmp/013-rt.yml
    back="$(config_yaml_to_json /tmp/013-rt.yml | jq -r ".k")"
    [[ "$back" == "$v" ]] && echo "ok   [$v]" || echo "FAIL [$v] -> [$back]"
  done
'
```

**Expected**: every line `ok`. Any `FAIL` is a broken round trip (FR-007, FR-008).

---

## Scenario 3 — Nothing that loads today stops loading

Guards FR-012 and FR-022 — the compatibility claim.

```bash
cat > /tmp/013-hand.yml <<'EOF'
path: "C:\Users\shared"
single: 'a\"b'
bare: Won't Do
tricky: "a \" # b"
EOF

bash -c 'source scripts/bash/lib/config.sh; config_yaml_to_json /tmp/013-hand.yml'
```

**Before the fix** (recorded on this worktree):

```json
{"bare":"Won't Do","path":"C:\\Users\\shared","single":"a\\\"b","tricky":"a \\"}
```

**After the fix**:

```json
{"bare":"Won't Do","path":"C:\\Users\\shared","single":"a\\\"b","tricky":"a \" # b"}
```

Three of the four values MUST NOT move: the Windows path keeps both backslashes (unrecognised
escapes stay literal, FR-012), the single-quoted scalar is not decoded at all (FR-013), and the bare
key with an apostrophe still parses (007 research R1).

Only `tricky` changes, and it changes from broken to correct. `"a \" # b"` has an **odd** number of
escaped quotes before the `#`, so today's naive quote-toggling ends up outside the string, treats
the `#` as a comment, and truncates the value to `a \`. This is the FR-011 defect — note that a case
with an even number of escaped quotes hides it, which is why the fixture uses an odd one.

---

## Scenario 4 — The refusal that survives

Guards FR-020 and Constitution IV.

```bash
bash -c '
  source scripts/bash/lib/config.sh
  jq -cn "{label:\"has\nnewline\"}" | config_to_yaml; echo "exit=$?"
'
```

**Before the fix** (recorded on this worktree) — the write **succeeds**, emitting a corrupt file:

```text
"label": "has
newline"
exit=0
```

Loading that file then fails with a misleading diagnostic that blames the second line for not being
a mapping entry, and advises re-running the ceremony — which would regenerate the same broken file:

```text
config: …/nl.yml:2: cannot parse this line as a mapping entry: newline"
config: a key must be followed by ": " — quote the key if it contains a colon, …
config: re-run /speckit.jira.config to regenerate …
exit=4
```

**After the fix**: exit `4` from the **write**, one `config: label: …` line naming the path, **zero**
characters of the value in the output, nothing on stdout, and no file created.

This is not a hypothetical hole. Today the corruption is written silently and surfaces later as a
confusing parse failure at a line the operator did not author (research R8).

---

## Scenario 5 — Determinism and zero churn

Guards FR-017 and FR-019.

```bash
bash -c '
  source scripts/bash/lib/config.sh
  jq -cn "{allowed:[\"Platform \\\"legacy\\\"\",\"clean\"]}" > /tmp/013-in.json
  config_to_yaml < /tmp/013-in.json > /tmp/013-a.yml
  config_yaml_to_json /tmp/013-a.yml | config_to_yaml > /tmp/013-b.yml
  diff /tmp/013-a.yml /tmp/013-b.yml && echo "byte-identical"
'
```

**Expected**: `byte-identical`, no diff output.

---

## Scenario 6 — Suites and cross-port equivalence

```bash
tests/run-bash.sh --since HEAD~1          # change-scoped inner loop, ≤60s
tests/run-bash.sh                         # full bash suite, ~190s
pwsh -c 'Invoke-Pester tests/powershell'   # the whole tree: lib/Config.psm1 is shared
bash tests/conformance/ci-conformance.sh  # cross-port byte equivalence
shellcheck scripts/bash/lib/config.sh
```

**Expected**: all green; `shellcheck` and `actionlint` clean.

> Conformance success is **silent** — there is no pass banner. Success is exit 0 with zero
> "conformance divergence" lines; temp paths in the output are harness noise.

---

## Scenario 7 — Windows

The bash changes add two new backslash patterns (`[[ "${s}" != *\\* ]]` and `[[ "${ch}" == "\\" ]]`)
and modify the port's largest multi-line `jq` read — both classes with a history of behaving
differently under MSYS. Per research R7, a platform claim here is unproven without a green run on
the real runner.

```bash
git push origin HEAD:ci/windows-probe    # ~11 min; results arrive as annotations, not logs
```

**Expected**: zero conformance divergences on the Windows runner.

---

## Done when

- [ ] Scenario 1 fails before the fix and passes after
- [ ] Scenarios 2–5 pass
- [ ] Scenario 6 green on macOS and Linux
- [ ] Scenario 7 green on the Windows probe
- [ ] CHANGELOG records the FR-022 behaviour change
- [ ] Dogfood run against the reporting consumer project completes and records the label intact (T051, Constitution XII)
