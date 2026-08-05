# Contract — the managed description boundary

Binding on both ports. Every clause is byte-observable from a run's payloads, warnings, and counts, so the
conformance corpus can prove the two ports agree.

Related: [`summary-record.md`](./summary-record.md), [`../data-model.md`](../data-model.md).

## §1 The delimiter

- The delimiter is a single content node: a paragraph whose one text node carries the marker text with a
  `strong` mark. The marker text is `Synced from spec-kit — do not edit below this line` and is produced by
  the sink alone.
- The engine MUST receive the marker as a parameter and MUST NOT contain it. An engine module carrying the
  marker text, or any tracker vocabulary, is a review rejection (Constitution VIII).
- Exactly one delimiter node is well-formed. Zero means "no boundary yet". More than one is malformed.
- The delimiter's wording, mark, and node shape are fixed. They are not configurable, not templatable, and
  not derived from anything the operator supplies.

## §2 Regions

For a description whose content array is `C` and whose single delimiter sits at index `k`:

| Region | Definition | Rule |
|---|---|---|
| Human prefix | `C[0:k]` | Preserved byte-for-byte in every payload. The mirror MUST NOT reorder, reformat, re-mark, re-encode, or drop any node in it. |
| Managed region | `C[k:]` | Replaced in full by `[delimiter] ++ freshly rendered managed nodes` on every write. |

The boundary has a top and no bottom: content after the managed nodes is inside the managed region and is
replaced.

- The human prefix is preserved **even when the resulting document is rejected by the tracker**. A
  rejection — a field-length limit, or any other refusal of the combined document — MUST be reported as one
  named warning identifying the ticket and MUST leave that ticket's description unwritten. The mirror MUST
  NOT truncate, elide, summarise, or drop any part of the human prefix to make a payload fit, and MUST NOT
  drop the managed region to make room either. Every other field of that ticket reconciles normally, and
  the run's exit code is unaffected.

## §3 Resolution — the single decision

Given a recognised ticket's existing description and the freshly rendered managed nodes `M`:

| Precondition | Result | Warning |
|---|---|---|
| delimiter count `> 1` | **No description is written for this ticket.** Every other field of that ticket reconciles normally. | One, naming the ticket key: the boundary is malformed and a human must remove the duplicate. |
| delimiter count `== 1` | `C[0:k] ++ [delimiter] ++ M` | None |
| delimiter count `== 0`, and `C` ends with `M` | `C[0:len(C)-len(M)] ++ [delimiter] ++ M` | None |
| delimiter count `== 0`, and `C` does not end with `M` | `C ++ [delimiter] ++ M` | One, naming the ticket key: the mirror's previous output could not be identified and is preserved above the boundary; it may now appear twice. |
| No existing description (a creation) | `[delimiter] ++ M` | None |

The suffix comparison is structural equality over the node arrays, element by element, not a string
comparison of a serialised document.

**Ordering guarantee**: the resolution runs before the churn comparison of §4 and before the privacy scan
of §5. A ticket whose boundary is malformed produces no description payload at all, so neither of those
ever sees one.

## §4 Churn

- Description churn MUST be decided by comparing the **managed regions alone** of the current and desired
  descriptions, both split at the delimiter.
- An edit confined to the human prefix MUST NOT produce a write of any kind for that ticket.
- The migration write of §3 is a change (the current description carries no delimiter, the desired one
  does), so it fires exactly once per ticket. The next unchanged run MUST report zero.
- A ticket whose content writes are suppressed — halted status, operator flag, unresolved drift — MUST NOT
  acquire a boundary on that run. The boundary follows the write; it is never an exception to a hold.

## §5 Privacy scan

- Every field the mirror composes MUST be scanned exactly as it is today: summary, labels, priority, the
  delimiter node, and every node of the managed region.
- The preserved human prefix MUST NOT be scanned. It is a verbatim round-trip — read from this ticket and
  written back to this ticket — so it can carry nothing into the tracker that the tracker does not already
  hold (research R4).
- The exemption is structural and per-region. It is not an allowlist entry, cannot be configured, and
  cannot be widened by a consumer.
- A blocked coordinate that the mirror composes MUST still refuse the run with the same exit code and zero
  writes as today.

## §6 Scope

- The boundary applies to every ticket the mirror manages: the specification-role parent, every story-role
  child, and every task-role sub-task.
- A ticket adopted from a human author already carries this boundary. Its behaviour MUST NOT change and it
  MUST NOT acquire a second delimiter.
- `--dry-run` MUST produce the payload the real run would send, byte for byte, and MUST establish no
  boundary.

## §7 Both ports

Byte-identical payloads, warnings, and counts for every clause above, proven by the shared conformance
corpus. The scenarios that must exist:

| Scenario | Asserts |
|---|---|
| Human prefix on a bridge-created parent, story, and sub-task | §2, FR-007 across all three tiers |
| A plan produced after the parent exists, with a prefix present | FR-001, FR-002, SC-002 |
| The plan changed, then deleted | FR-002, FR-004 |
| Prefix edited, nothing else | §4, FR-009, zero writes |
| Managed region deleted by a human | FR-008, restored in full |
| Migration: untouched pre-release description | §3 clean branch, no duplication |
| Migration: pre-release description with a human prefix | §3 suffix branch, nothing lost |
| Migration: ambiguous | §3 warned branch, one named warning, nothing lost |
| Two delimiters | §3 refusal, one named warning, other fields still written |
| A Jira link in the preserved prefix | §5, the run is not blocked |
| A blocked coordinate in the managed region | §5, the run is blocked exactly as today |
| A description the tracker rejects as oversized | §2, FR-011 — one named warning, no description written, other fields still written, host exit code unaffected |
