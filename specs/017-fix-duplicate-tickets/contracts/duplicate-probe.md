# Contract — the duplicate probe

Covers FR-022 – FR-026 (User Story 4, P3). **This is the droppable slice.** It lives in its own
module per port so that removing it is a file deletion plus three call-site lines.

## §1 What it can and cannot do

Read this before implementing it.

`sink/jira/recognition.sh` reads recorded tickets **by key and never by search**, and says why:
"Jira's index is eventually consistent, and this is the reported defect's exact window". Feature 005
removed search from recognition because a lagging index answered *no such ticket* for a ticket that
existed, and the run duplicated it.

The probe asks the same index the same kind of question. Its false negative is therefore real and
unavoidable. What makes it defensible is the direction of the error:

| | Recognition by search (removed in 005) | This probe |
| --- | --- | --- |
| False negative causes | a duplicate write | today's behaviour, unchanged |
| True positive causes | — | a refusal, zero writes |

The probe can only fail to prevent a duplicate; it can never create one. It is a mitigation, not a
guarantee. **SC-001 rests on the marker line, not on this.**

## §2 When it fires

Only when **all** of:

1. the planning pass is about to **create** a parent, and
2. the specification holds **no** marker binding a parent, and
3. the run is not already refusing for another reason.

It never fires on a settled run, never on a run whose parent is recognised, and never once per
story — at most **one** request per run.

## §3 The query

```text
GET <base>/rest/api/3/search/jql?jql=<encoded>&fields=key&maxResults=50

jql := project = "<PROJECT KEY>" AND labels = "<provenance label>"
```

Issued through the existing `jira_request` transport — same credential handling, same retry policy,
same base-URL stripping in the reported action set. No new transport code.

## §4 Verdicts

| Verdict | Condition | Behaviour |
| --- | --- | --- |
| `clear` | 2xx, zero issues | proceed normally, emit nothing |
| `hit` | 2xx, one or more issues | **refuse for this specification**: zero writes of any kind, exit `4` (`EXIT_CONFIG` — a pre-write refusal, like every other), the §4 message naming every key |
| `unavailable` | **any** non-2xx | proceed exactly as before the probe existed, one warning |

**The `hit` refusal returns through `_reconcile_fault`, like every other planning-pass refusal.**
The probe fires inside the planning pass, beside the parent- and story-recognition refusals, which
already refuse with `_reconcile_fault "${EXIT_CONFIG}" …` followed by `return $?`. The probe uses
that same shape, and the `return $?` is load-bearing: it propagates the *fault helper's* return
value rather than the raw code, which is what performs the hook downgrade. Under
`SPEC_KIT_JIRA_HOOK_CONTEXT` the run therefore returns **0** and wraps the message in the standard
`WARNING: … (exit 4). This spec-kit command completed normally.` form, so the host command stays
green — Constitution III and SC-005. Outside hook context the `4` is returned unchanged and the run
fails closed.

A refusal returns early, so **no run summary is emitted** and the message is the whole of the
output — exactly as for the target guard. Only the `unavailable` verdict, which lets the run
continue, reaches the summary's `warnings` array.

### `hit` — verbatim

```text
reconcile: project <KEY> already holds tickets labelled "<label>" (<KEY-1>, <KEY-2>) but this specification records no ticket of its own — bind each with the bridge's `mention <issue-key>` command, or remove the label from them (zero writes)
```

Keys are sorted and comma-separated.

**Two things this message must not do.**

It must not name `/speckit.jira.mention`. That slash command **does not ship** — only
`docs/VISION.md` mentions it, as an idea, and the vision document authorises nothing. What ships is
the bridge subcommand `mention <issue-key>` (`spec-kit-jira <config|reconcile|mention|feature>`,
`cmd_mention` in `commands/mention.sh`), which adopts one existing ticket into the active
specification. Naming a command the operator does not have would be a defect wearing a remedy's
clothes.

It must not spell out the entry point either — `.specify/extensions/jira/scripts/bash/spec-kit-jira.sh`
on macOS and Linux, `…/powershell/spec-kit-jira.ps1` on Windows. FR-027 and Constitution VI require
both ports to emit **the same bytes**, and the conformance corpus enforces it, so a message carrying
a port-specific path could not pass. This is why neither this message nor the target guard's is a
literally runnable command line: the requirement they satisfy is *name the remedy precisely*, not
*be a shell command*. The agent reading the message knows its own port and holds the invocation
table in `commands/speckit.jira.reconcile.md`.

### `unavailable` — verbatim

```text
the duplicate-label check could not be performed on this site; the run proceeded on its recorded markers alone
```

## §5 Read-only, absolutely

On every path the probe issues exactly one `GET` and nothing else. A ticket it finds is **not**
adopted, **not** edited, **not** relabelled, **not** transitioned, and **not** stamped with an
identity marker. Constitution Principle I permits adoption only under the two controlled exceptions,
and this is neither — it is a refusal that leaves both systems exactly as it found them.

## §6 Test obligations

| # | Assertion | Where |
| --- | --- | --- |
| T1 | Labelled tickets exist, specification has no markers → zero writes, exit 4, §4 message listing both keys | bats + Pester |
| T2 | The found tickets are byte-identical on the mock afterwards — no write of any kind reached them | bats + Pester |
| T3 | Markers present and binding those very tickets → the probe never fires and no request is made | bats + Pester |
| T4 | Search returns 400 / 403 / 404 → the run completes exactly as it does with the probe absent, plus one warning | bats + Pester |
| T5 | No labelled ticket → no extra output, creation proceeds | bats + Pester |
| T6 | A settled re-run issues no probe request at all | bats + conformance |
| T7 | `--dry-run` predicts the refusal | bats + Pester |
| T8 | Both ports byte-identical | conformance `us4-duplicate-probe` |
| T9 | Under `SPEC_KIT_JIRA_HOOK_CONTEXT` the `hit` refusal returns **0** and wraps the message in the standard `WARNING: … (exit 4). This spec-kit command completed normally.` form — the host command stays green (SC-005) | bats + Pester |
