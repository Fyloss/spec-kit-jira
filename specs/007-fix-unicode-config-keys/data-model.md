# Phase 1 Data Model: The Local Binding Survives Names the Jira Instance Actually Uses

**Feature**: 007-fix-unicode-config-keys | **Date**: 2026-07-31

This feature stores no new data. It changes how one existing document is written and read, and
it adds one internal structure to the parser. The entities below are the specification's three
(spec, Key Entities), expressed at the level the implementation needs.

---

## 1. Mapping key

The text naming an entry in a configuration document: a project key, an issue-type name, a
priority name, a status name, or a structural key such as `resolved_ids`, `statuses`, `style`.

**Origin**: for structural keys, this extension. For everything else, the Jira administrator —
which is why the extension has no authority over its character content.

**Fields**: the key is a single string. It carries no metadata.

**Written form** (produced by `config_to_yaml` / `ConvertTo-JiraConfigYaml`):

- Always double-quoted: `"<key>": <value>`.
- Emitted in ordinal-sorted order, unchanged from today (byte-determinism, FR-003 of spec 002).

**Accepted forms** (recognised by `config_yaml_to_json` / `ConvertFrom-JiraConfigYaml`):

| Form | Example | Where it comes from |
| --- | --- | --- |
| Double-quoted | `"À faire": "10001"` | this extension's writer |
| Single-quoted | `'À faire': "10001"` | hand editing |
| Bare | `epic_strategy: per_feature` | the committable `config.yml` template, and `.specify/extensions.yml` as PyYAML writes it |

**Validation rules**:

| Rule | On read | On write |
| --- | --- | --- |
| Non-empty after trimming | a line whose key text is empty is malformed → parse failure | an empty key is refused → `EXIT_CONFIG` |
| Contains no `"` and no `\` | not checked (a quoted key ends at its closing quote) | refused → `EXIT_CONFIG` (research R3) |
| Any other character permitted | letters of any script, digits, punctuation, spaces | quoting makes all of them representable |
| Unique within its mapping frame | a repeat at the same level is malformed → parse failure (FR-016) | JSON input cannot carry a duplicate, so nothing to refuse |

**Explicitly not applied**: no normalisation, no case folding, no transliteration. A key is
preserved as the exact sequence of characters it was written with (spec, Out of Scope).

---

## 2. Local binding document

`.specify/jira/config.local.yml` — gitignored, machine-owned, per developer (Constitution V,
layer 2). Unchanged in shape; only the byte-level rendering of its keys changes.

```yaml
resolved_ids:
  "JET":
    "issue_types":
      "Récit": "10004"
      "Story": "10005"
    "priorities":
      "Élevée": "1"
      "Faible": "4"
    "statuses":
      "Terminé": "10002"
      "Won't Do": "10004"
      "À faire": "10001"
      "完了": "10003"
    "style": "company_managed"
```

**States**:

| State | Recognised by | Behaviour |
| --- | --- | --- |
| Absent | file does not exist | `{}` — the project was never bound. Unchanged. |
| Empty | file exists, no retained lines | `{}` — a legitimate state after the last held event is released (test_config.bats, 003 T013). Unchanged. |
| Readable | every line parses | parsed content returned |
| **Unreadable** | any line fails the mapping-entry test | **new**: parse failure, `EXIT_CONFIG`, no partial content returned to any caller |

The fourth state is the substance of the change: today it is silently collapsed into the first.

**Relationships**: read by `config_load` (merged under the team layer), by
`config_hooks_disabled_read`, and by `_reconcile_local_binding_for`. The same parser also reads
the committable `config.yml`, `personal.yml`, and the host's `.specify/extensions.yml` hook
registry, so all four gain the same guarantees.

---

## 3. Parse failure

Raised when a line cannot be interpreted as a mapping entry at the level being parsed. It is an
internal value, not a persisted one.

**Fields**:

| Field | Source | Purpose |
| --- | --- | --- |
| `file` | the path passed to the parser | FR-009 |
| `line` | `_cfg_linenos[i]` / `$script:CfgLineNos[$i]` — the 1-based number in the **source** file | FR-009; blank lines and comments are dropped before parsing, so the retained-array index is not the source line |
| `content` | the retained, comment-stripped line, **redacted** per `contracts/parse-failure.md` §2.1 | FR-009, Constitution IV |
| `remediation` | fixed text (contract) | FR-009 |

**Lifecycle**: set into `_CFG_ERR` / `$script:CfgErr` at the raising site → every enclosing
parser loop returns immediately → `config_yaml_to_json` / `ConvertFrom-JiraConfigYaml` formats
it to stderr and returns `EXIT_CONFIG` (4) → the calling command propagates → in `after_*` hook
context the existing downgrade (reconcile.sh:632-648) converts it to one `WARNING:` line and
exit 0 for the host.

**Exit code**: `EXIT_CONFIG` (4), already defined in `lib/cli.sh:21` and already the code for
every other configuration fault. No new code is introduced, so the monotonic escalation of the
existing table is untouched (Constitution III).

---

## 4. Parser state (internal, changed)

`_cfg_prep` retains only non-blank, non-comment lines in parallel arrays. One array is added.

| Array | Today | After |
| --- | --- | --- |
| `_cfg_indents` | leading-whitespace count per retained line | unchanged |
| `_cfg_lines` | trimmed, comment-stripped content | unchanged |
| `_cfg_linenos` | — | **new**: 1-based source line number per retained line |
| `_cfg_seen` | — | **new**: keys already seen in the mapping frame being parsed, scoped to that frame (FR-016, grammar §1.5) |
| `_cfg_n`, `_cfg_i` | count and cursor | unchanged |

PowerShell mirrors this with `$script:CfgLineNos` and `$script:CfgSeen` alongside
`$script:CfgIndents` and `$script:CfgLines`. `_cfg_parse_sequence` rewrites entries of `_cfg_lines` and `_cfg_indents`
in place when a dash introduces a mapping (config.sh:267-268); `_cfg_linenos` is *not* rewritten
there — the source line is the same line — which keeps the reported number correct for a
malformed key inside a sequence item.
