# Quickstart: Validating 007 — Unicode and Punctuated Configuration Keys

**Feature**: 007-fix-unicode-config-keys | **Date**: 2026-07-31

Runnable checks that prove the feature works end to end. Every command is run from the
repository root. See `contracts/yaml-key-grammar.md` for the rules being validated and
`contracts/parse-failure.md` for the failure contract.

---

## Prerequisites

| Requirement | Why |
| --- | --- |
| Bash ≥ the declared minimum (macOS's system Bash 3.2 does not qualify) | Constitution VI |
| PowerShell 7+ | the second port |
| `jq`, `curl`, `git` | existing runtime dependencies |
| `bats` and `Pester` | the two unit suites |
| A UTF-8 locale (`LANG`/`LC_ALL`) | the fixtures contain non-ASCII keys |

No Jira credentials are needed. Every check below runs against the mock or against local files.

---

## Check 1 — Red before green (Constitution XIII)

Run **before** touching `lib/config.sh` or `lib/Config.psm1`. The regression tests must fail.

```sh
bats tests/bash/lib/test_config.bats
pwsh -c "Invoke-Pester tests/powershell/lib/Config.Tests.ps1"
```

**Expected before the fix**: the new cases fail — including the reproduction case, which
returns `{"resolved_ids":{"JET":{"issue_types":{}}}}` instead of the full binding. Record the
failure; it is the evidence Principle XIII requires.

**Expected after the fix**: green, with the pre-existing cases still green — in particular the
empty-collection fixed point, the quoted-`[]`-is-a-string rule, the PyYAML flat-sequence parse,
and the two-indentation equivalence (research R7).

---

## Check 2 — The bug report's own document round-trips

The reproduction from the bug report, end to end through writer and reader.

```sh
cat > /tmp/007-check.json <<'JSON'
{"resolved_ids":{"JET":{
  "issue_types":{"Récit":"10004","Story":"10005"},
  "priorities":{"Faible":"4","Élevée":"1"},
  "statuses":{"Terminé":"10002","Won't Do":"10004","À faire":"10001","完了":"10003"},
  "style":"company_managed"}}}
JSON

source scripts/bash/lib/config.sh
config_to_yaml < /tmp/007-check.json > /tmp/007-check.yml
config_yaml_to_json /tmp/007-check.yml | jq -S . > /tmp/007-back.json
diff <(jq -S . /tmp/007-check.json) /tmp/007-back.json && echo "round trip OK"
```

**Expected**: `round trip OK` — no diff. Today the reader returns an almost-empty object and the
diff is large.

Inspect `/tmp/007-check.yml`: every key is double-quoted (`"Élevée": "1"`), matching
`yaml-key-grammar.md` §2.1.

The PowerShell port must produce the **same bytes** for the same input:

```sh
pwsh -c "Import-Module ./scripts/powershell/lib/Config.psm1; \
  [Console]::Out.Write((ConvertTo-JiraConfigYaml -Json (Get-Content -Raw /tmp/007-check.json)))" \
  > /tmp/007-check-ps.yml
diff /tmp/007-check.yml /tmp/007-check-ps.yml && echo "writer parity OK"
```

---

## Check 3 — Keys the old character set rejected, and keys the writer had to learn to quote

```sh
printf '%s\n' \
  '"Done (QA)": "10004"' \
  '"high/low": "4"' \
  '"Приоритет": "2"' \
  '"Größe": "3"' \
  '"Blocked: waiting on QA": "5"' \
  '"Sprint # 2": "6"' \
  "\"Won't Do\": \"7\"" \
  > /tmp/007-keys.yml
config_yaml_to_json /tmp/007-keys.yml | jq -S .
```

**Expected**: seven entries, every key exact. Note `Blocked: waiting on QA` and `Sprint # 2` —
these are the two forms that require §2.1's unconditional quoting, and they are why the writer
changed rather than only the reader.

A **bare** apostrophe key must still parse, because hand-written and PyYAML-written files use
bare keys:

```sh
printf "Won't Do: \"7\"\nepic_strategy: per_feature\n" > /tmp/007-bare.yml
config_yaml_to_json /tmp/007-bare.yml
```

**Expected**: both keys present. This guards research R1's deliberately non-quote-aware bare
scan against regression.

---

## Check 4 — A URL is still a value, not a key (FR-003)

```sh
printf 'site: https://example.atlassian.net\n' > /tmp/007-url.yml
config_yaml_to_json /tmp/007-url.yml
```

**Expected**: `{"site":"https://example.atlassian.net"}`. The colon in the URL is followed by
`/`, so it is not a delimiter. This is the behaviour the original character-class restriction
existed to protect, and it survives the inversion.

---

## Check 5 — A malformed line fails closed and says where (FR-007 to FR-009)

```sh
printf 'resolved_ids:\n  JET:\n    this line has no delimiter\n' > /tmp/007-bad.yml
config_yaml_to_json /tmp/007-bad.yml; echo "exit=$?"
```

**Expected**: exit `4`, nothing on stdout, and three lines on stderr naming the file, line `3`,
the offending content, and the remediation — the exact wording in `contracts/parse-failure.md`
§2. Today this exits `0` and silently returns a truncated document.

Verify the line number counts blank and comment lines, which the parser discards:

```sh
printf '# a comment\n\nresolved_ids:\n  JET:\n    broken\n' > /tmp/007-bad2.yml
config_yaml_to_json /tmp/007-bad2.yml 2>&1 >/dev/null | head -1
```

**Expected**: the message names line `5`, not line `3`.

The PowerShell port must print the same three lines and exit `4`:

```sh
pwsh -c "Import-Module ./scripts/powershell/lib/Config.psm1; \
  ConvertFrom-JiraConfigYaml -Path /tmp/007-bad.yml; exit \$LASTEXITCODE" 2>&1
```

---

## Check 6 — Zero Jira writes on an unreadable binding (FR-010)

```sh
bats tests/bash/commands/test_reconcile*.bats
```

**Expected**: the new case passes — reconcile against a repository whose `config.local.yml` is
unreadable performs no Jira write and exits `4`. It must **not** report the project as unbound,
which is the downstream symptom the bug report describes.

---

## Check 7 — A hook still lets its host command succeed (FR-011)

```sh
bats tests/bash/hooks/
```

**Expected**: with an unreadable binding, an `after_*` hook emits the three failure lines plus
one `WARNING:` line and returns exit `0` to the host spec-kit command. Constitution III's second
half is not weakened by the first.

---

## Check 8 — The writer refuses what it cannot represent (research R3)

```sh
printf '%s' '{"resolved_ids":{"JET":{"statuses":{"say \"hi\"":"1"}}}}' | config_to_yaml
echo "exit=$?"
```

**Expected**: exit `4` and a named error identifying the path. The value itself is not printed
(Constitution IV). Emitting it would produce a file that reads back wrong — the silent
corruption this feature exists to close.

---

## Check 9 — Conformance: content per port, then parity between ports (FR-014, SC-005)

```sh
bats tests/bash/conformance/test_us1_unicode_binding.bats
pwsh -c "Invoke-Pester tests/powershell/conformance/"
```

**Expected**: each port is asserted against the fixture's **expected content**, then the two
captures are diffed. Both assertions fail today.

To prove the suite can see a defect the ports share (SC-005), revert the fix in one port only
and re-run: the unfixed port fails the content assertion and the pair fails the parity diff.

---

## Check 10 — The message leaks nothing, and an ambiguous file is refused

```sh
printf 'resolved_ids:\n  JET:\n    ATATT3xFfGF0 someone@example.com https://acme.atlassian.net\n' \
  > /tmp/007-leak.yml
config_yaml_to_json /tmp/007-leak.yml 2>&1 >/dev/null | head -1
```

**Expected**: the line is reported with each of the three coordinates replaced by `[redacted]`,
the file path and line `3` intact (`contracts/parse-failure.md` §2.1). The pre-write credential
scan cannot help here — it runs on a parsed document, and the failure precedes one.

```sh
printf 'statuses:\n  "Terminé": "1"\n  "Terminé": "2"\n' > /tmp/007-dup.yml
config_yaml_to_json /tmp/007-dup.yml; echo "exit=$?"
```

**Expected**: exit `4`, naming the repeated key and both line numbers (FR-016). Today the second
entry silently wins through jq. A file where the same key appears at two *different* levels —
`"statuses"` under two project keys — must still parse.

---

## Check 11 — Full gates

```sh
bats --jobs 4 tests/bash/
pwsh -c "Invoke-Pester tests/powershell/"
```

**Expected**: green under parallel execution (Constitution XIII, test isolation), on all three
CI operating systems, with statement coverage at or above 80% for both ports.
