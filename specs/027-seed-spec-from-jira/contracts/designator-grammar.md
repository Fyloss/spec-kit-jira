# Contract — Designator grammar and reduction

**Feature**: 027 | **Module**: `sink/jira/designator.sh` · `sink/jira/Designator.psm1`

This contract is normative for both ports. Every rule below is byte-comparable
and belongs in the conformance corpus (FR-005, FR-046).

---

## §1 Placement — why the sink

Constitution VIII's enforcement grep forbids an engine script from containing an
"issue key pattern" or an Atlassian host. This module contains both. It is a
sink module and MUST NOT be sourced by any engine module.

---

## §2 Key grammar

```
^[A-Z][A-Z0-9_]+-[0-9]+$
```

Applied **after** upper-casing the candidate. This is character-for-character the
pattern `commands/feature.sh` already applies to its leading positional; the two
call sites MUST share this function so they cannot drift.

| Input | Reduced key | Outcome |
| --- | --- | --- |
| `PROJ-123` | `PROJ-123` | accept |
| `proj-123` | `PROJ-123` | accept — normalised |
| `P-1` | — | `REF-DESIGNATOR` (project key needs ≥2 chars) |
| `PROJ-` | — | `REF-DESIGNATOR` |
| `1PROJ-1` | — | `REF-DESIGNATOR` (must start with a letter) |

---

## §3 URL reduction (FR-004)

Ordered, first match wins. Applied after discarding the fragment.

```
1. strip  #...            (fragment)
2. if a `selectedIssue` query parameter is present
       → candidate = percent-decode(its value)
3. else if the path contains a `/browse/` segment
       → candidate = the segment immediately following it
4. else if the final path segment matches §2
       → candidate = that segment
5. else → REF-DESIGNATOR
```

The candidate is then upper-cased and MUST satisfy §2, or the designator is
refused. Extraction succeeding while validation fails is still `REF-DESIGNATOR`.

### The three recognised shapes (FR-005) — each a conformance scenario, per port

| Shape | Example | Rule |
| --- | --- | --- |
| Browse path | `https://acme.atlassian.net/browse/PROJ-123` | 3 |
| Board context | `https://acme.atlassian.net/jira/software/projects/PROJ/boards/7?selectedIssue=PROJ-123` | 2 |
| Trailing query or anchor | `https://acme.atlassian.net/browse/PROJ-123?filter=42#comment-9` | 1 then 3 |

### Ordering hazard

Rule 2 precedes rule 3 deliberately. A board URL may contain both a path segment
that looks key-shaped and a `selectedIssue` parameter naming a *different* issue;
the parameter is the issue the operator was looking at.

---

## §4 Host comparison (FR-006)

Compare **scheme**, **host**, and **port** against the configured site base URL.

- Host compared case-insensitively, after discarding one trailing dot
  (`acme.atlassian.net.` ≡ `acme.atlassian.net`).
- Port compared after applying the scheme default (`https` → 443).
- A **path prefix on the base URL is ignored** for this comparison. A Data Center
  install at `https://jira.example.com/jira/` matches a designator at
  `https://jira.example.com/jira/browse/PROJ-1`, and §3 rule 3 tolerates the
  prefix because it searches for a `/browse/` segment rather than anchoring at
  the root.

A mismatch is `REF-HOST`, **before any request is issued**. This is a credential
guard as much as a correctness one (Constitution IV): a cross-site fetch would
send the configured token to an unconfigured host.

---

## §5 Free text (FR-023, FR-053, FR-055)

Legal only for `role = specification`.

| Condition | Outcome |
| --- | --- |
| Flag absent entirely (`parent_seen = false`) | Ordinary parent behaviour (FR-024) |
| Flag present, value blank or whitespace-only | `REF-DESIGNATOR` (FR-053) |
| Flag present, value non-blank, not a key, not a URL | `form = free_text` — the title of a parent to create |
| Flag present on `role = story`, not a key or URL | `REF-DESIGNATOR` |

The parse state MUST carry `parent_seen` separately from `parent`. Collapsing a
blank value into "absent" is the specific defect FR-055 exists to forbid.

---

## §6 Order and de-duplication (FR-008, FR-054)

- Order is argv order, left to right, among same-role designators.
- Order survives reduction, upper-casing, and de-duplication.
- De-duplication compares **reduced keys**, never raw strings — a key and its
  browse URL are the same designator (spec Edge Cases). It removes the later
  occurrence and preserves the earlier one's position.
- Naming one issue as both roles is `REF-DUPLICATE`.
- The bulk read's response order is never used. The join is by key (data-model §2).

---

## §7 Windows (research R11)

- Fragment and query stripping use `${x%%\#*}` / `${x%%\?*}`. **No `$'\r\n'` may
  appear in any glob pattern in this module** — the MSYS matcher lets it match a
  bare LF (`docs/10-windows-portability.md`).
- A designator arriving with a trailing CR is trimmed by an explicit CR test,
  never by a pattern containing a CRLF pair.
- Any multi-line output from this module goes through `lib/output.sh`, never a
  bare `jq`.

---

## §8 Test obligations

| # | Assertion | Requirement |
| --- | --- | --- |
| D1 | Each §2 row, both ports, byte-identical result | FR-002 |
| D2 | Each §3 shape reduces to the same key from both ports | FR-004, FR-005 |
| D3 | Board URL where path segment and `selectedIssue` disagree → the parameter wins | FR-004 |
| D4 | Percent-encoded `selectedIssue` decodes before the grammar check | FR-004 |
| D5 | Host mismatch refuses with **zero requests issued** | FR-006 |
| D6 | Base URL with a path prefix matches, and reduces | FR-006 |
| D7 | Same issue as key and as URL → `REF-DUPLICATE` | FR-008 |
| D8 | Blank `--parent` → `REF-DESIGNATOR`; absent `--parent` → ordinary behaviour | FR-055 |
| D9 | Ten designators, shuffled response order, positions preserved | FR-054 |
| D10 | Designator with a trailing CR reduces identically on all three OSes | R11 |
