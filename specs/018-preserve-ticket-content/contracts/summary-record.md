# Contract — the last-written summary record

Binding on both ports. The record is the only evidence that distinguishes a human's rename from a
specification's retitle; without it the mirror cannot tell them apart and reverts both.

Related: [`managed-description.md`](./managed-description.md), [`../data-model.md`](../data-model.md).

## §1 Where the record lives

- The record is a `summary` field on the identity marker the mirror already stamps into the per-issue
  entity property `spec-kit-jira`.
- It MUST NOT live in a label, the summary itself, the description, or any other operator-editable field
  (Constitution II).
- It MUST be **omitted** when no summary has ever been recorded, never written as an empty string. An
  omitted field is the "no record" state, exactly as `role` and `story` already express absence.
- Adding it MUST NOT change the claim decision: `identity_claimed_by_other` compares the repository
  reference and the specification identifier only.
- A marker written by a previous release, carrying no `summary`, MUST remain valid and MUST NOT be treated
  as damaged.

## §2 What is recorded, and when

- The recorded value is the **exact string the payload carried** — raw, untruncated by this contract, and
  including whatever shortening the tier's own rules applied before sending (a sub-task summary the sink
  shortens is recorded as shortened, because that is what was sent).
- The record MUST be written after a create, and after an update **whose payload actually carried a
  `summary` field**. It MUST NOT be written otherwise.
- That binding is the zero-churn guarantee: a settled mirror sends no summary, therefore sends no property
  write, therefore an unchanged re-run stays at zero writes of every kind (Constitution II).
- A ticket whose write is suppressed — halted, flagged, or drifted — acquires no record on that run.

## §3 Comparison

Both sides are normalised before comparison and only for comparison:

1. Strip leading and trailing whitespace.
2. Collapse every internal run of whitespace to a single space.

The tracker normalises summaries server-side, so an un-normalised comparison would report a divergence no
human created. Normalisation MUST NOT be applied to the value that is recorded or to the value that is
sent.

## §4 The decision

| Recorded `summary` | Normalised current vs recorded | `--on-drift` | `summary` in the desired fields | Reported |
|---|---|---|---|---|
| absent | — | any | Present | Nothing |
| present | equal | any | Present when it differs from the specification's title | Nothing |
| present | different | `abort` (default) | **Omitted** | One warning naming the ticket key and the summary field |
| present | different | `proceed` | Present, carrying the specification's title | An ordinary update in the counts |

- The field is **omitted from the payload**, not suppressed by dropping the whole write: every other field
  of that ticket MUST reconcile normally in the same run.
- The existing zero-churn comparison inspects only the keys present in the desired object, so an omitted
  `summary` needs no further special-casing.
- The warning MUST name the ticket key and the field. It MUST NOT quote the human's wording or the
  specification's title — the run summary names the problem and the remedy, not the content.
- `--on-drift=proceed` is the **existing** flag. No second override, no new spelling, no new vocabulary.

## §5 Scope

- The record and the decision apply to every tier: the specification-role parent, every story-role child,
  and every task-role sub-task.
- `--dry-run` MUST predict the warning and the payload exactly, and MUST write no record.

## §6 Both ports

Byte-identical payloads, warnings, and counts, proven by the shared conformance corpus. The scenarios that
must exist:

| Scenario | Asserts |
|---|---|
| First run after upgrade on a ticket with no record | §4 row 1 — no warning, record established |
| Specification title changed, record matches current | §4 row 2 — silent update, record refreshed |
| Human renamed the ticket | §4 row 3 — no summary sent, one named warning, other fields written |
| Same, with `--on-drift=proceed` | §4 row 4 — the specification's title restored, counted |
| Human renamed to exactly the specification's title | No write, no warning |
| Current differs from the record by whitespace only | §3 — no warning |
| Settled ticket, nothing changed | Zero writes, zero property writes, no warning |
| A sub-task renamed by a human | §5 — the task tier behaves identically |
