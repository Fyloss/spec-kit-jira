# Phase 0 Research: Survive Jira Labels Containing Quotes and Backslashes

**Feature**: 013-fix-yaml-string-escaping | **Date**: 2026-08-03

Every decision below was checked by running the real code or the real tool, not by reasoning about
it. Where a probe is quoted, it was executed against this worktree.

---

## R1. What actually fails today, and in which order

**Question**: The reported symptom is `EXIT_CONFIG` (4) from the writer. Is the writer the whole
defect?

**Probe** — a file holding the reported shape, through the real reader and writer:

```text
$ cat t.yml
allowed:
  - "Platform \"legacy\""

$ config_yaml_to_json t.yml
{"allowed":["Platform \\\"legacy\\\""]}      exit=0
$ config_yaml_to_json t.yml | config_to_yaml
config: allowed[0]: a string value here contains " or \, which this writer cannot represent
exit=4
```

**Finding**: two distinct defects, in sequence.

1. The **reader** returns the JSON string `Platform \"legacy\"` — the text carries literal
   backslashes the label never had — and exits **0**. Silent corruption, no diagnostic.
2. That corrupted text now contains both forbidden characters, so the **writer** refuses. The
   refusal is correct given its inputs; its cause is one step upstream.

**Decision**: both halves are in scope. A writer-only fix would leave a value that round-trips to
something else — and, once written, refuses on every subsequent write, wedging the file permanently.

**Alternatives considered**: fixing only the writer (rejected — leaves the corruption); fixing only
the reader (rejected — the ceremony still cannot write a fresh label).

---

## R2. The escape algorithm: targeted two-character escaping, not `@json`

**Question**: jq's `@json` produces a JSON-encoded string, which escapes `"` and `\` correctly and
is a subset of YAML's double-quoted form. Use it?

**Probe**:

```text
$ jq -rn '"a\tb" | @json'
"a\tb"
$ jq -rn '"Élevée 完了" | @json'
"Élevée 完了"          # non-ASCII left raw — good, 007's unicode keys survive
```

**Finding**: `@json` is *too broad*. It also escapes TAB as `\t`. A tab inside a value round-trips
correctly **today** (a literal tab is legal in a double-quoted YAML scalar), and under this
feature's decode rule `\t` is an unrecognised escape kept literally (FR-012) — so adopting `@json`
would turn a working value into a corrupted one. Widening the decoder to accept `\t` instead is
excluded by FR-013 and Principle XV.

**Decision**: escape exactly two characters, backslash first, then quote. Implemented with jq's
`/` operator, which splits on a **literal** string — no regex layer, so there is no second round of
escaping to reason about:

```jq
def yesc:
  (. / "\\"  | join("\\\\"))
  | (. / "\"" | join("\\\""));
```

**Verified output**:

```text
Platform "legacy"   -> "Platform \"legacy\""     # exactly the reported on-disk shape
Delivery\Platform   -> "Delivery\\Platform"
Élevée 完了          -> "Élevée 完了"              # untouched
a<TAB>b             -> "a<TAB>b"                 # untouched, unlike @json
clean               -> "clean"                   # byte-identical to today (FR-017)
```

Ordering is load-bearing: escaping `"` first would then have its introduced backslash escaped by the
second pass, doubling it.

**PowerShell mirror**: `$v.Replace('\','\\').Replace('"','\"')` — same two steps, same order.

**Alternatives considered**: `@json` (rejected, above); a regex `gsub` (rejected — two layers of
backslash escaping, and an early probe of exactly that produced four backslashes where two were
wanted, which is precisely the class of error the literal split removes); adopting a full YAML
library (rejected — new dependency in both ports, Principle XIV).

---

## R3. The decode rule, and its cost

**Decision**: a single left-to-right walk. On `\`, if the next character is `"` or `\`, emit that
character and advance two; otherwise emit the backslash and advance one.

This is the minimum rule satisfying FR-007, FR-008 and FR-012 simultaneously. It cannot be done with
parameter expansion or a JSON parse:

- Parameter substitution cannot express it — the two rewrites interleave, so `\\"` must be read
  left-to-right (escaped backslash, then a delimiter) rather than by independent passes.
- Handing the body to `jq` as a JSON string fails on hand-maintained input: `"C:\Users\shared"` is
  **invalid JSON** (`\U` is not a JSON escape), so jq would error where FR-012 requires the value to
  load unchanged.

**Round-trip probe** (encode via R2, then decode):

```text
ok  in=[Platform "legacy"]  on-disk=["Platform \"legacy\""]  out=[Platform "legacy"]
ok  in=[Delivery\Platform]  on-disk=["Delivery\\Platform"]   out=[Delivery\Platform]
ok  in=[Élevée 完了]         on-disk=["Élevée 完了"]           out=[Élevée 完了]
ok  in=[trailing\]          on-disk=["trailing\\"]           out=[trailing\]
ok  in=[a\\b]               on-disk=["a\\\\b"]               out=[a\\b]
ok  in=[\"literal]          on-disk=["\\\"literal"]          out=[\"literal]
```

The last two are the adversarial cases: a value whose text is itself `\"` must not be confused with
an escaped quote, and a trailing backslash must not swallow the closing delimiter. Both hold.

**FR-012 probe** (hand-maintained files, no recognised escape):

```text
C:\Users\shared -> C:\Users\shared
a\nb            -> a\nb
```

**Cost**: the walk is pure bash — no subprocess — and is guarded by a fast path,
`[[ "${s}" != *\\* ]] && return`, so it is skipped entirely for any scalar containing no backslash,
which is nearly all of them. The enclosing `_cfg_scalar_json` already spawns one `jq -Rn --arg` per
scalar; that subprocess dominates, and the decode does not add to it.

---

## R4. Three escape-blind call sites upstream of the decoder

**Question**: is fixing the scalar decoder enough?

**Finding**: no. Three functions inspect the raw line *before* the scalar is isolated, and each
counts quotes without regard to escaping. A correct decoder receives already-mangled input.

| Site | Bash | PowerShell | Failure if left alone |
| --- | --- | --- | --- |
| Inline-comment stripper | `_cfg_strip_inline_comment` (`config.sh:121`) | `Remove-CfgInlineComment` (`Config.psm1:134`) | Toggles `in_d` on an escaped `"`, so quote state inverts and a later ` #` inside the value truncates it (FR-011) |
| Quoted-key scan | `_cfg_map_entry_key` (`config.sh:244`) | `Get-CfgMapEntryKey` (`Config.psm1:245`) | Takes the first `"` after the opening one as the close, so a key containing an escaped quote splits at the wrong place (FR-010) |
| Refusal walker | `_CFG_WRITE_REFUSAL_JQ` (`config.sh:471`, invoked at `:535`) | `Get-CfgWriteRefusalError` (`Config.psm1:482`) | See R5 |

**Decision**: make the first two skip the character following a backslash — **only** while inside a
double-quoted region.

Two exclusions, both load-bearing:

- The **single-quoted** branch keeps no escape awareness. FR-013 leaves single-quoted scalars
  unchanged, and the writer never emits one.
- The **bare-key** scan at `config.sh:265` stays deliberately non-quote-aware. Feature 007's research
  R1 requires `Won't Do: "10004"` to parse, and a quote-aware scan there would open a region at the
  apostrophe and never find the delimiter. This feature does not touch that branch.

---

## R5. A pre-existing port divergence the new refusal scenario would expose

**Finding**, by reading both implementations:

- Bash `_CFG_WRITE_REFUSAL_JQ` (`config.sh:471`) ends `| unique | .[]` and `config_to_yaml`
  (`config.sh:535`) loops over the result, printing **one line per offending path**.
- PowerShell `Get-CfgWriteRefusalError` (`Config.psm1:482-519`) returns on the **first** error found;
  `ConvertTo-JiraConfigYaml` throws with that single message.

For a document with two unrepresentable values the ports emit different stderr. This is pre-existing
and, as far as the corpus goes, untested — the refusal path had no conformance scenario.

**Decision**: align PowerShell to bash (list every path, deduplicated, in the same order) as part of
this feature. Justification: FR-023 requires an identical verdict, the feature adds the first
conformance scenario that exercises a refusal, and that scenario would otherwise fail for a reason
unrelated to the defect being fixed. The alternative — writing the scenario to assert only the exit
code — was rejected as papering over a real Constitution VI divergence.

---

## R6. Why nothing above the serialiser needs code changes

FR-002 to FR-005 place requirements on display, allowed-value validation, identifier matching, and
values sent to Jira. Tracing each consumer:

| Consumer | Site | Depends on |
| --- | --- | --- |
| Allowed values from introspection | `discovery.sh:217` — `allowed_values: [ (.allowedValues // [])[] \| (.value // .name) ]` | The API payload, parsed by jq — already correct |
| Operator's allowed-values question | `config.sh:510` — `jq -r '.allowed_values \| join(", ")'` | The decoded in-memory value |
| Recorded default validation | `config.sh:278` — `(($f.allowed_values) \| index($v)) == null` | Exact string match on decoded values |
| Resolved-id reuse across runs | `config_load` → `config_yaml_to_json` | The decoded in-memory value |
| Values sent to Jira | `jira_create_fields_base` | jq-built JSON payload — already correct |

**Finding**: every consumer compares or prints the decoded value. None re-reads raw YAML text and
none re-escapes. Once the reader returns `Platform "legacy"`, an exact-match `index($v)` succeeds and
`join(", ")` prints the label as a human sees it in Jira.

**Decision**: no production code above the serialiser. FR-002 to FR-005 become **verification**
tasks — end-to-end assertions that would fail if this analysis is wrong. This is deliberately not
taken on trust: the exact-match at `config.sh:278` is precisely where a half-decoded value would
silently reject a value Jira accepts, so it gets its own test.

---

## R7. Platform constraints that bound the implementation

Re-checked against `docs/10-windows-portability.md` and `lib/output.sh`:

- **jq must stay behind the guard.** `output.sh:50` conditionally defines a `jq()` shell function
  wrapping `command jq | sed 's/\r$//'`, installed only when the host's jq emits CRLF. Both changed
  jq programs (`_CFG_WRITE_REFUSAL_JQ`, `_CFG_YAML_EMIT_JQ`) are invoked through existing call sites
  already inside that guard, so no new call site is introduced and no new CRLF exposure is created.
  This matters more than usual here: `config_to_yaml` is the port's largest multi-line jq read and
  the file it writes is the one an operator keeps.
- **No `$'\r\n'` in any glob.** The new comparisons are single-character tests against `"` and `\`;
  no pattern contains a line ending, so the MSYS matcher hazard is not engaged.
- **Backslash in bash patterns.** `[[ "${s}" != *\\* ]]` and `[[ "${ch}" == "\\" ]]` are the two new
  matches; both were exercised in the R3 probe on macOS. They must be re-verified on the Windows
  probe rather than assumed, per the project's rule that a platform claim is unproven without a
  green run there.
- **A Windows-only divergence is diagnosed by measurement**, not emulation. If the conformance
  corpus diverges on the Windows runner, the corpus on the probe is the failing test.

---

## R8. The line-break hole is live, not hypothetical

**Question**: FR-020 refuses a value carrying a line break. The spec assumed this was a hole the old
refusal rule was incidentally covering. Is it reachable today?

**Probe**:

```text
$ jq -cn '{label:"has\nnewline"}' | config_to_yaml
"label": "has
newline"
exit=0                                    <- the WRITE SUCCEEDS

$ config_yaml_to_json nl.yml
config: nl.yml:2: cannot parse this line as a mapping entry: newline"
config: a key must be followed by ": " — quote the key if it contains a colon, …
config: re-run /speckit.jira.config to regenerate nl.yml from the Jira instance.
exit=4
```

**Finding**: worse than the spec assumed. The writer emits the value raw and **exits 0**, producing
a file that cannot be parsed. The operator discovers it later as a parse failure blaming a line they
never wrote, with remediation advice — re-run the ceremony — that would regenerate the identical
broken file. A loop with no exit.

This is a second live defect in the same writer, independent of quotes and backslashes, and it is
currently masked by nothing at all: the old `"` / `\` refusal never covered it, because a value can
carry a line break and neither character.

**Decision**: FR-020 stands and is load-bearing, not defensive. It converts a silent corruption into
a fail-closed refusal at the moment of writing — Constitution III's exact purpose. It also means the
refusal path is not merely retained through this feature but **reaches a case it never previously
caught**, so it needs its own test rather than an assertion that the old behaviour is unchanged.

**Scope note**: this stays inside the feature rather than being split out. Narrowing the refusal
predicate (R2) is the same edit that must widen it to line breaks; leaving them apart would mean
touching one `test(...)` twice and shipping an interim state where nothing refuses at all.
