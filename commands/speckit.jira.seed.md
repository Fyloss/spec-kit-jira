---
name: "speckit.jira.seed"
description: "Seed a specification from named, existing Jira issues — validate the drafted pinning, confirm the write plan, then bind, create, and re-parent. Agent-invoked; bound to no hook event."
argument-hint: "A spec file path, and --confirm once the operator has approved the write plan"
---

# /speckit.jira.seed

This is **moment 2** of seeding a specification from existing Jira issues
(research R1). It is **not** a lifecycle hook — it cannot be, because a
confirmation prompt cannot live in a hook (Constitution IV: "there is nobody
to answer a prompt and a wait is indistinguishable from a hang"). You invoke
it yourself, deliberately, after you have drafted `spec.md` from the seed
material `speckit.jira.feature` handed you at `before_specify`.

**This invocation is mandatory whenever moment 1 handed you seed material.**
If you forget it, nothing is lost — moment 1 already recorded a
seeded-not-bound state and nothing was written to Jira — but the operator's
named issues stay unbound until you (or a later invocation of yours) runs
this command. Do not silently skip it.

## Invoking the bridge — normative

Same repository-relative entry points as every other command in this
extension:

| Host | Entry point |
| --- | --- |
| macOS, Linux | `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh` |
| Windows | `.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1` |

Invoke the Bash entry point **through the interpreter** (`bash <path>`), not
by bare path.

### When the entry point is missing — emit exactly as written

When the entry point is not found, emit the following text **exactly as
written**. Do not paraphrase it, do not summarise it, and do not compose your
own explanation of the situation:

```text
Jira bridge not available: the entry point
.specify/extensions/jira/scripts/bash/spec-kit-jira.sh (or, on Windows,
.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1) was not found.
This spec-kit command completed normally and nothing was mirrored to Jira. To
restore the bridge, reinstall the extension with
`specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/releases/latest/download/spec-kit-jira.zip --force`
(it will ask you to confirm an untrusted-source prompt — answer y).
```

## Drafting `spec.md` — the pinning marker (FR-015, FR-056)

**The human-authored content of the named issues is the primary source
material for `spec.md`** — its overview, its user-story narratives, its
stated intent. You are not decorating a separately-invented draft with their
words; their words are the draft. This is a drafting instruction, not a
mechanically enforced one (no deterministic check can judge prose quality),
but it is what the whole feature exists for, and the provenance report makes
your attribution visible to the operator before they confirm anything.

For each named story-role issue, write a **pinning marker** immediately
after the heading of the user story it seeded:

```
<!-- speckit-jira pin=KEY -->
```

`KEY` is the designated issue's key exactly as `speckit.jira.feature`
resolved it (available in the seed material moment 1 handed you). Rules:

- **One marker per named issue, one issue per marker** — a bijection. Do not
  merge two named issues into one user story, split one across several, or
  drop one.
- **Order matters** (FR-054, FR-017): the pinned user stories MUST appear in
  `spec.md` in the same order the operator named the issues — not the order
  you find convenient, not alphabetical, not by your own sense of priority.
- **New user stories with no named counterpart are welcome** — add them
  freely alongside the pinned ones. They carry no pinning marker; that
  absence is exactly how the following command tells "seeded from an issue"
  from "drafted new".
- **The marker is not a binding.** It expresses only your intention. The
  script that runs after this file exists validates it deterministically and
  only THEN, after confirmation, replaces it with the real binding marker.

A specification that violates the bijection or the order refuses at the next
step with `REF-DECOMP`, naming exactly what is wrong — accept the human's
decomposition or ask the operator to re-invoke with different designators.

## Ordered procedure

1. **Draft `spec.md`** using the seed material from moment 1, following the
   pinning rules above. Local writes are not gated — write freely.
2. **Invoke the bridge**:

   ```text
   bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh seed <path-to-spec.md> --json
   ```

3. **`REF-EXISTS` / any refusal class** ⇒ relay the message and remediation
   verbatim to the operator. Zero writes occurred. Do not retry blindly —
   the remediation tells you or the operator what changed.
4. **`confirmation_required`** ⇒ this is the gate (FR-033). Render the write
   plan and the provenance report for the operator **exactly as the bridge
   emitted them** — do not paraphrase, reorder, or summarise a re-parenting
   line out of existence. Ask a single closed question: proceed, or not?
   - **Operator declines, or you are running unattended** ⇒ stop here. The
     seeded-not-bound state persists; nothing is lost; re-invoking this same
     command later resumes at this exact gate.
   - **Operator confirms** ⇒ re-invoke:

     ```text
     bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh seed <path-to-spec.md> --confirm --json
     ```

5. **Success** ⇒ report the bindings, creates, and any re-parenting exactly
   as the bridge's run summary states. The seed record is now deleted; the
   specification is fully bound, exactly like any other reconciled feature
   from here on.

## Behaviour rules (normative)

- **The read that seeded `spec.md` never happens again** (FR-009, FR-010).
  From here on this specification behaves exactly like a greenfield one:
  the filesystem is the source of truth, and later reconciles never rewrite
  `spec.md` from Jira content.
- **A resume re-reads Jira, never re-drafts `spec.md`** (FR-062, FR-063).
  If you invoke this command again against a seeded-not-bound state with the
  same designators, it recomputes the plan from the current file and the
  current Jira state — it does not replay what it showed you before, and it
  does not touch your draft.
- **A different designator set than the one recorded is `REF-RESEED`.** This
  command only ever operates on the set moment 1 fixed; it cannot be used to
  add or remove named issues after the fact.
- **The re-parenting line, when present, is the one to read most carefully**:
  it is the only write in this feature that changes an artifact the operator
  did not name (another epic's child count). It renders with a leading `! `
  in column 1 — do not let it blend into the rest of the plan when you relay
  it.

## Flags

- `<spec-file>` — the leading positional, required: the specification this
  invocation seeds and binds.
- `--confirm` — passes the gate; binds, creates, and re-parents. Absent by
  default.
- `--parent`, `--story` — **optional, and normally omitted.** The ordinary
  decline/resume cycle above needs neither: the designator set moment 1
  recorded is used as-is. Resupply them only to re-state that set as an
  explicit safety check — a different set than the recorded one refuses
  `REF-RESEED` before any read (S-3/S-4). Same grammar as
  `speckit.jira.feature`'s own flags.
- `--dry-run` — predicts the identical action set with zero writes,
  including never writing or deleting the seed record.
- `--json` — emit the canonical machine-readable result.
- `--help` — usage; exits `0`.

## Exit codes

`0` success, or `confirmation_required` · `1` usage · `2` an unreliable read
during a resume · `4` every refusal class of `contracts/seed-cli-contract.md`
§7 (`REF-EXISTS`, `REF-RESEED`, `REF-DECOMP`, `REF-DRAFT-EDIT`, and the rest)
· `9` privacy BLOCK. Identical on both ports.
