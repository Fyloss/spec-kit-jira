# Contract: Configuration Parse Failure

**Feature**: 007-fix-unicode-config-keys | **Date**: 2026-07-31

What the extension does when a configuration file contains a line it cannot interpret. Both
ports MUST produce identical text and identical exit codes (Constitution VI).

This contract replaces a behaviour that had no contract: the parser stopped, returned what it
had, and exited zero.

---

## 1. Trigger

Exactly one condition raises a parse failure:

> While parsing a mapping, a line at that mapping's own indentation is not a mapping entry
> under `yaml-key-grammar.md` §1, and is not one of the two legitimate boundaries (a change of
> indentation, or a sequence marker).

An empty key (grammar §1.2 step 4) is included in this condition.

Not a trigger: a `- x` sequence item whose payload is not a mapping entry. It is a scalar item.

A second condition raises a parse failure, added by FR-016:

> While parsing a mapping, a key at that mapping's own level repeats a key already seen in the
> same frame (`yaml-key-grammar.md` §1.5).

Its message names the repeated key and both line numbers:

```
config: <file>:<line>: duplicate key <key> — already defined at line <first-line>
config: two entries cannot claim the same name; delete or rename one of them.
config: re-run /speckit.jira.config to regenerate <file> from the Jira instance.
```

`<key>` is redacted per §2.1 like any other printed line content.

---

## 2. Output

Three lines on **stderr**, in this order, with this wording:

```
config: <file>:<line>: cannot parse this line as a mapping entry: <content>
config: a key must be followed by ": " — quote the key if it contains a colon, e.g. "Blocked: waiting": "10001"
config: re-run /speckit.jira.config to regenerate <file> from the Jira instance.
```

| Placeholder | Value |
| --- | --- |
| `<file>` | the path as it was passed to the parser, verbatim |
| `<line>` | 1-based line number **in the source file**, counting blank lines and comment lines |
| `<content>` | the retained line: leading whitespace removed, inline comment already stripped |

### 2.1 `<content>` is redacted before it is formatted

Every credential-shaped substring of the line is replaced by `[redacted]` before the message is
built, using the BLOCK-tier shapes the privacy guard already recognises (Atlassian token
prefixes, non-documentation `*.atlassian.net` hosts) and the WARN-tier email shape
(Constitution IX).

Redaction applies to the **whole** line, not to a value half. A line that failed the
mapping-entry test has no reliable delimiter, so there is no value half to isolate — which is
precisely the case a "we only print the key" reading would miss.

A line reduced entirely to `[redacted]` still carries its file path and its line number, which is
what FR-009 requires the operator to act on.

Requirements this satisfies: FR-009 (file, line, content, copy-pasteable remediation),
Constitution XVI (never a bare code), Constitution IV (no credential in any output).

Nothing is written to **stdout**. A caller that captures stdout receives no partial document.

---

## 3. Exit code

`EXIT_CONFIG` — **4**. Already defined (`lib/cli.sh:21`) and already the code for every other
configuration fault, so the existing monotonic escalation is unchanged (Constitution III). No
new exit code is introduced.

---

## 4. Propagation

| Caller | Behaviour on parse failure |
| --- | --- |
| `config_yaml_to_json` / `ConvertFrom-JiraConfigYaml` | prints §2, returns 4, prints nothing on stdout |
| `_cfg_local_json` | propagates. **Only an absent file yields `{}`**; a present-but-unreadable file is a failure. |
| `config_load` | returns 4, as it already does for a schema or credential fault |
| `config_hooks_disabled_read` | propagates — an unreadable binding is not evidence that no hook is disabled (Constitution X) |
| `_reconcile_local_binding_for` | propagates — **zero Jira writes** for the affected spec (FR-010, Constitution III) |
| `config_personal_load` | propagates the located message, then returns 4 as it already does |
| `register_hooks_health` | reports the registry unreadable and returns 4, as it already does; gains the located message |

### 4.1 Inside an `after_*` lifecycle hook

The host spec-kit command's exit code MUST be unaffected (FR-011, Constitution III). This uses
the downgrade that already exists (`reconcile.sh:632-648`): the non-zero exit becomes a single
line on stderr and exit 0 for the host.

```
WARNING: Jira mirror not completed — <reason> (exit 4). This spec-kit command completed normally. Run /speckit.jira.config to re-check the binding.
```

The three lines of §2 precede it, so the operator still learns which file and which line.

---

## 5. Invariants

1. **No silent truncation.** There is no input for which a read returns a document shorter than
   the file describes *and* exits 0. A mapping parse ends only at a change of indentation, at a
   sequence marker, at end of input, or by raising this failure (FR-012).
2. **No partial document.** A caller either receives a document representing the whole file, or
   receives the failure. Never a prefix.
3. **No credential in the message.** `<content>` is redacted per §2.1 before formatting. The
   pre-write credential scan cannot be relied on here: it runs on a parsed document, and this
   failure is raised before any document exists. `config_personal_load` already promises the
   same thing — "Credential-shaped values are refused without echoing"
   (`scripts/bash/lib/config.sh:648`) — and §2.1 is what keeps that promise true once the
   located message replaces its generic one.
4. **Both ports, same bytes.** The three lines of §2 and the exit code are byte-identical
   between Bash and PowerShell for the same input file and the same path string.
