# Contract — The question, the answer, and the exits

**Feature**: 029 | Governs FR-001 to FR-017, FR-020, FR-021, FR-025 to FR-031,
FR-033, FR-034.

The CLI surface of `speckit.jira.feature` as this feature changes it. Both ports
MUST produce identical output bytes, identical exit codes, and identical Jira
request sequences on every path below.

---

## §1 New and reused flags

| Flag | Values | Status |
| --- | --- | --- |
| `--reuse` | `yes` · `no` | **new** |
| `--accept-defaults` | boolean | **reused** — already parsed at `lib/cli.sh:201` |
| `--parent`, `--story` | designators | unchanged (027) |
| `--use-team` | catalogue id | unchanged |

`--reuse` absent means unanswered. That absence is what makes the question appear;
no default may be substituted for it, because a default would answer on the
operator's behalf the one question this feature exists to ask.

`--accept-defaults` means "do not ask, take the safe default", and the safe default
is `no` — today's behaviour. Detecting an unattended run by probing for a terminal
is **forbidden**: the bridge runs inside lifecycle hooks and never has one, so a TTY
probe suppresses the question always and silently reduces this feature to a no-op.

---

## §2 Decision table

**Rows are evaluated top to bottom and the FIRST MATCH WINS.** Without that rule the
table is ambiguous — `any` legitimately includes "absent", so several rows overlap by
construction. Rows 1–3 are settled from argv alone, before any Jira read; everything
below row 3 is evaluated after the ticket is resolved and after the cross-team question
has been settled (§4). `—` means the input is absent.

| # | Mention | Designators | `--reuse` | `--accept-defaults` | Outcome |
| --- | --- | --- | --- | --- | --- |
| 1 | any | any | invalid | any | **usage error** naming both accepted values — at parse time, so an unreadable key never masks it (FR-016) |
| 2 | — | — | `yes` · `no` | any | **usage error**: an answer with nothing to answer (FR-015) |
| 3 | any | present | `no` | any | **usage error**: "create new" contradicts the designators supplied with it (FR-015) |
| 4 | — | — | — | any | today's run, byte-identical (FR-008) |
| 5 | — | present | — · `yes` | any | 027 designator path, unchanged — `yes` agrees with the designators and is accepted in silence |
| 6 | present, unresolvable | any | — · `yes` · `no` | any | today's fail-closed exit; no question (FR-007) |
| 7 | present | present | — · `yes` | any | 027 designator path; no question (FR-006) |
| 8 | present | — | — | true | today's run, plus a statement that the question was suppressed and `no` assumed (FR-013, FR-014) |
| 9 | present | — | — | false | **reuse question** (§3) |
| 10 | present | — | `no` | any | today's run from here on, byte-identical (FR-010) |
| 11 | present | — | `yes` | any | **which-issues question** (§3) |

Row 1 sits above row 6 deliberately: an invalid `--reuse` value with an unreadable
mentioned key must exit `1` for the reason the operator can fix, not `2` for the one
they cannot see.

Two rows carry the feature's regression guarantees and are the first tests to
write: row 4 (nothing named) and row 10 (`--reuse no`).

---

## §3 The question payload

Both variants share one shape and one rule.

**Shared rule — the omission.** A result carrying a question MUST NOT contain a
branch name or a folder short name. This is the contract's load-bearing clause: a
caller with no name cannot create the branch or the spec folder, so the question
cannot be skipped by a caller that simply proceeds. Every other clause here assumes
a caller that follows instructions; this one does not (FR-031).

**Reuse variant** — states **every** detected issue by key, summary, type and status,
each with the role it would be attached in, then proposes that placement and states
both what accepting routes into (the issues' content becomes the specification's source
material) and what declining creates instead, in the project's own type names. Two
answers, no third and no free-form one (FR-002, FR-003, FR-035).

**Which-issues variant** — reached from `--reuse yes` with no designator. Names the
same issue, states what is still missing, and asks for the designators. It writes
nothing and records nothing, so repeating the same incomplete input returns the same
question indefinitely without accumulating state (FR-029, FR-030).

**Halted status** — when the resolved status appears in the routed project's
configured halted list, both variants add that "reuse" would be refused for that
issue and name the three ways on: answer "create new", reopen the ticket, or name
another (FR-033). The refusal that would follow is `REF-TERMINAL`, unchanged, on the
designator path. No status is halted by default; an empty configured list means no
warning is ever added (Principle VII).

**Unmapped type** — an issue whose type is declared for no role is proposed in the
story role, with its type named as unmapped and with the statement that it needs no
parent (FR-036). It is never refused. A *misplaced* issue — one carrying the other
role's declared type — refuses instead, at the question (FR-022): the two cases look
alike and must not share an outcome.

**An unmapped issue designated as the parent** refuses (FR-039), and the refusal
explains the constraint rather than the mapping: the specification role is the
container, and this feature never changes an existing issue's type, so the issue cannot
be made into one. It then states the route that gets there —
`--reuse yes --parent "<title>" --story <that key>` — which creates the parent and
places the issue beneath it. This is the "my Bug turned out to be the whole feature"
path, and without the refusal naming it the operator has no way to discover it.

**No specification-role issue among them** — the question adds the parent routes to its
answers rather than posing a second question (FR-038): attach beneath an existing key,
beneath one created from a title, or accept as-is and create nothing above them.

**Every refusal reachable here** carries, beside its own remediation, the alternative
that always exists: decline, and the extension creates the specification-role issue plus
one story-role issue per drafted user story (FR-037).

### §3.1 The payload — one key per question, never a shared one

Three questions can now come out of this command, and a caller must tell them apart
without guessing. **Each gets its own top-level key**, and the existing one is not
touched:

| Question | Key | Introduced by |
| --- | --- | --- |
| cross-team | `confirmation_required` | shipped — **unchanged, byte for byte** |
| reuse | `reuse_required` | this feature |
| which issues | `reuse_issues_required` | this feature |

**Adding a discriminator *inside* `confirmation_required` was rejected.** A `kind`
field would change the cross-team question's own output, and
`us3-feature-cross-team.json` is one of the scenarios that must run unmodified and
byte-identical (mention-grammar §4). Distinguishing by which key is present is also
what the shipped renderer already does — `has("confirmation_required")` at
`commands/feature.sh:374` — so this adds a branch beside an existing pattern rather
than a new convention (Principle XIV).

```json
{"active":true,
 "reuse_required":{
   "issues":[
     {"key":"IJT-40","summary":"Rework the export pipeline","type":"Epic",
      "status":"In Progress","role":"specification","unmapped":false,"halted":false},
     {"key":"IJT-42","summary":"CSV export is too slow","type":"Story",
      "status":"To Do","role":"story","unmapped":false,"halted":false},
     {"key":"IJT-99","summary":"Legacy importer","type":"Bug",
      "status":"To Do","role":"story","unmapped":true,"halted":false}],
   "declines_to":{"specification":"Epic","story":"Story"}}}
```

`reuse_issues_required` carries the identical object. Rules that keep the two ports
from disagreeing by omission:

- **`issues` is ordered by argv position**, first detected first. That order is what
  the prose renders and what conformance compares.
- **`role`** is `specification`, `story`, or `null` when the project declares no
  hierarchy (FR-035). Never absent.
- **`unmapped`** is `true` only for FR-036's second case — a type declared for no role,
  proposed in the story role. A *misplaced* issue never reaches this payload at all: it
  refuses at the question (FR-022).
- **`halted`** is per issue, and a boolean, never null.
- **`declines_to`** names the types the `no` answer would create, so the prose can say
  "a new Epic, plus one Story per drafted user story" instead of "create new". Both
  members are `null` when no hierarchy is declared.

**No `branch_name` and no `short_name`, not even as `null`** — the omission of FR-031
is structural, and a key holding `null` is a name a careless caller could still read as
"unset, compute it yourself".

Prose form, pinned literally because byte equality across ports demands it (`—` for an
absent value, matching the shipped renderer):

```text
Feature: reuse decision required
Detected: IJT-40 (Epic, In Progress) Rework the export pipeline
Detected: IJT-42 (Story, To Do) CSV export is too slow
Attach IJT-40 as the Epic of this specification, and IJT-42 as a Story beneath it?
Source: the detected issues' content is what spec.md will be written from
Answers: --reuse yes attaches them as proposed · --reuse no creates a new Epic, plus one Story per drafted user story
```

One `Detected:` line per issue, in argv order. The `Attach …?` line names the proposal
in the operator's own vocabulary — the *configured* type names, never `specification`
and `story`, which are internal role names no operator has ever seen.

Conditional lines, each after `Attach …?` and in this order:

```text
Unmapped: IJT-99 is a Bug, a type this project declares for no role — proposed as a Story; it needs no Epic, and --reuse yes --parent <key|title> gives it one
Halted: IJT-42 is in In Progress, halted for IJT — --reuse yes would be refused (REF-TERMINAL); answer --reuse no, reopen it, or name another
Parent: no Epic was detected — --reuse yes attaches nothing above them; --reuse yes --parent <key|title> creates or names one
Drafted: user stories drafted beyond these become new Stories beneath the same Epic — named issues are reused, never duplicated
```

The `Drafted:` line appears whenever at least one issue is proposed in the story role
(FR-040). It states established behaviour — 027's own SC-002 fixes the arithmetic at
*drafted user stories minus named story-role issues, exactly* — but it belongs in the
question, because an operator who thinks the specification will be capped at the issues
they named will decline a proposal that would have served them.

When no hierarchy is declared, no role can be derived, so the `Attach …?` and
`Answers:` lines are replaced by a `Missing:`/`Answers:` pair. **The header line is
`Feature: reuse decision required` in every variant** — one header, so a caller
matching on it never has to know which question it got; the payload key
(§3.1) is what distinguishes them, and the `Missing:` line is what names the state:

```text
Feature: reuse decision required
Detected: IJT-40 (Epic, To Do) Rework the export pipeline
Missing: this project declares no hierarchy, so no placement can be proposed
Answers: re-invoke with --parent <key|title> and one --story <key> per issue to reuse
```

The which-issues variant (`reuse_issues_required`, reached from `--reuse yes` with no
designator, FR-029) is identical but for the `Missing:` line, which states what this
run could not derive rather than what the project failed to declare:

```text
Missing: which issues to reuse — this run cannot derive it without designators
```

**Exit code**: `0` for both. A question is not a failure, and the host command it
runs inside must complete normally (FR-005).

**Request budget**: composing either question MUST issue no Jira request beyond the
resolution the run already performed — see §7, which pins the field set that
resolution asks for (FR-017).

**Dry run**: `--dry-run` predicts that the question would be asked and for which
issue, without performing it (FR-020).

---

## §4 Ordering against the cross-team question

When both apply to one invocation, the cross-team question is returned **first**,
and this feature's question only on a subsequent invocation once the team is
settled (FR-025). They are never merged.

The order is load-bearing, not stylistic: the team answer decides the routed
project, and the routed project decides which hierarchy declares the roles against
which a `yes` answer will later be measured. Asking in the reverse order would have
the operator choose against a hierarchy that may not turn out to be theirs.

---

## §5 Missing team configuration

When a mention is present and no team configuration applies, the run reports the gap
instead of returning silently inactive. Two variants, two remediations:

| Gap | Names | Remediation |
| --- | --- | --- |
| catalogue absent, unreadable, or empty | `.specify/jira/config.yml` | run the configuration command |
| no team selected | `.specify/jira/personal.yml` | choose a team; the file is the operator's own and no script writes it |

Neither fails the host command, and neither issues a Jira request (FR-027).

**With no mention, all four early exits keep today's exact output** (FR-028). This
boundary protects every repository that does not use the extension, and it is the
single most breakable guarantee in this feature — see [plan.md](../plan.md)'s
Complexity Tracking.

---

## §6 Exit codes

| Code | Meaning |
| --- | --- |
| `0` | success, pass-through, fallback, a suppressed question, or **any question returned** |
| `1` | usage — an invalid `--reuse` value, or an answer supplied with no mention |
| `2` | fail-closed read on a mentioned key (unchanged) |
| `3` | auth on a mentioned-key read (unchanged) |
| `4` | personal-file / catalogue refusal (unchanged) |
| `9` | privacy BLOCK (unchanged) |

Identical on both ports. No code changes meaning, and none is added: a question
exits `0` precisely so that Principle III's non-blocking guarantee needs no
exception.

---

## §7 The mentioned-key read

One request, two field sets. `ticket_validate` (`sink/jira/ticket.sh:46`) and its
mirror `Confirm-JiraTicket` (`sink/jira/Ticket.psm1:42`) issue exactly one
`GET /issue/{key}`; this feature changes **what that one request asks for**, never how
many are made (FR-017).

| Condition | Field set |
| --- | --- |
| the run is about to ask (mention present · no designator · no `--reuse` · not `--accept-defaults`) | `fields=project,summary,issuetype,status` |
| every other path | `fields=project` — **unchanged, byte for byte** |

All four conditions of the first row are known from argv and the loaded configuration
alone, before the read. That is the whole reason the widening can be conditional, and
the conditionality is the whole reason FR-008, FR-010 and FR-028 remain provable: a
path that never asks issues the request the current release issues, query string
included (SC-015).

**The return shape widens additively.** Today `{key, project}`; on the question path
`{key, project, summary, type, status}`. `project` keeps its position and meaning, so
the cross-team decision that reads it is untouched.

**Mock obligation — this is the expensive part, and it is not optional.** The bash
shim special-cases the exact query string:

```bash
if [[ "${query}" =~ (^|\&)fields=project(\&|$) ]]; then   # curl-shim.sh:620
```

It synthesises `{key, fields:{project}}` from the key prefix and returns `404` when
the project is unknown to the run's mock config. A wider query **falls through this
branch** to the generic issue handler, which serves the `issue-mentioned` fixture — a
different key (`MENT-1`), no `project`, and no `issuetype`. Left alone, the widening
would silently turn `us3-feature-attach` into a cross-team question and delete the
`404` path that the fail-closed scenario depends on.

So the widening lands in **five** files, not two:

| File | Change |
| --- | --- |
| `scripts/bash/sink/jira/ticket.sh` | conditional field set, wider return |
| `scripts/powershell/sink/jira/Ticket.psm1` | the mirror |
| `tests/conformance/mock-jira/curl-shim.sh` | recognise the wider set in the same synthetic branch, including its `404` |
| `tests/conformance/mock-jira/mock-server.ps1` (+ `Mock.psm1`) | the mirror |
| `tests/conformance/mock-jira/fixtures/issue-mentioned.json` | gains `project` and `issuetype`, so the generic handler is no longer a trap |

A port that widens the request without teaching both mocks the wider shape does not
fail loudly: it silently answers a different question about a different issue.
