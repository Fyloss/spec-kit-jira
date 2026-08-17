# Feature Specification: Ask once whether an existing ticket should be reused

**Feature Branch**: `029-confirm-ticket-reuse`

**Created**: 2026-08-17

**Status**: Draft

**Input**: User description: "Ask the operator, once, whether an already-existing Jira issue should be reused."

## Context — the reported defect

A developer ran `/speckit.specify "ticket https://<site>.atlassian.net/browse/IJT-2241"`.
The `before_specify` step resolved the ticket, used it to name the branch and the
flat spec folder, and reported the ticket action `attached`. The specification was
then drafted from that ticket's own content.

Nothing bound the two. `attached` is a naming outcome, never a binding: no identity
marker is written into `spec.md`, and none can be — at `before_specify` the file
does not exist yet.

The consequence surfaced one step later. The reconcile fired by `after_specify`
planned four creations — a new parent plus one issue per drafted user story — none
of them referencing the mentioned ticket. Only because the developer stopped at the
dry-run were the duplicates never written. The recovery attempt refused
`REF-EXISTS` ("retro-seeding is out of scope; create a new specification"), which is
correct: the designator path that seeds a specification from existing issues is
chosen at invocation time and cannot be applied to a feature already created
without it.

So the operator had the right intent, said it out loud in the prompt, and the
ceremony silently took the other branch — with no way back short of discarding the
feature folder and the branch. This feature closes that gap by asking, once, at the
only moment when the answer still costs nothing.

## Clarifications

### Session 2026-08-17

- **Q**: When the operator answers "reuse" but the named issue's type matches no
  role the configured hierarchy declares, does the run refuse, ask again, or place
  the issue wherever its type fits?
  **A**: Refuse, with zero writes, naming the issue, the type found, and the type
  the role declares — and state both ways forward, including the one that needs no
  pre-existing parent: supply a **title** for the parent role instead of a key, and
  the parent is created with the reused issue placed beneath it. Placing an issue
  wherever its type happens to fit was rejected as silently wrong; a second question
  was rejected as one more chained agent decision.
- **Q**: When the existing cross-team question and this one both apply to a single
  invocation, are they ordered or merged?
  **A**: Ordered, team question first, across two round-trips; never merged. The
  team answer decides the routed project, and routing decides which hierarchy the
  reuse answer is measured against — the reverse order would have the operator
  choose against a hierarchy that may not turn out to be theirs.
- **Q**: What happens when the operator answers "reuse" but names no issue?
  **A**: Ask them which issues. The answer is incomplete, not wrong, and refusing an
  operator who just said yes to the thing this feature exists for would be perverse.
  The follow-up writes nothing and records nothing, so it may be repeated
  indefinitely — no round costs anything, and none leaves state behind.
- **Q**: What stops a caller from skipping the question altogether?
  **A**: The result carrying the question omits the branch name and the folder short
  name, so the caller physically cannot create either without first obtaining an
  answer. This was written as a naming-hygiene detail; it is in fact the only
  requirement here that holds against a caller which does not follow instructions,
  and it is now stated as such (FR-031).
- **Q**: Does a pasted link count as mentioning a ticket?
  **A**: It must. Today only a bare key is recognised on this path — a link is
  swallowed into the feature description, which is why the reported incident depended
  on the assistant extracting the key by hand. The mention path must reduce URLs with
  the rules the designator grammar already applies (FR-032). Conversely, a request
  naming neither a key nor a link never produces the question, whatever else it
  contains.
- **Q**: User Story 6 repairs a different defect and could ship on its own. Does it
  stay in this specification or become its own?
  **A**: It stays. Both defects have the same trigger — the operator named a ticket
  — and the same root cause: the extension knew something the operator needed and
  said nothing. Splitting them would put the message behind a second schedule while
  the incident that motivated both is one incident. The accepted risk is that a
  partial implementation ships the question without the message; it is mitigated by
  User Story 6 being independently testable with no Jira double at all, so it can be
  verified first and cannot hide behind the rest.
- **Q**: What does an operator see when they name a ticket in a repository where no
  team configuration applies to them?
  **A**: Today, nothing at all — the run returns inactive with no message, before
  the mentioned key is even read. That silence is in scope here: naming a ticket
  MUST produce a report that names the missing configuration and the command that
  creates one. A run naming nothing keeps the silent pass-through unchanged.

### Session 2026-08-17 — after `/speckit-analyze`

- **Q**: FR-003 wants the issue's summary, type and status, but the mentioned-key read
  asks Jira for the project alone and returns nothing else. Widen the read, or show
  less?
  **A**: Widen it, on the question path only. All four conditions that decide to ask
  are known before the read, so the wider field set can be requested exactly when it
  will be used. Showing only the key was rejected: the question exists so the operator
  can recognise their ticket, and a bare number does not let them. Widening the read
  unconditionally was also rejected — it would change the recorded request of every
  run that mentions a ticket, breaking the regression proof FR-010 rests on.
- **Q**: What happens when the mentioned ticket is cancelled, in progress, or done?
  **A**: The question is asked in all three cases and states the status. When the
  configuration declares that status halted for the project, the question adds that
  "reuse" will be refused for it, so the operator is not sent round the loop to
  discover it (FR-033). An in-progress ticket is the ordinary case and gets no extra
  warning. Which statuses end a workflow is never assumed — only the configured list
  is read, per Principle VII.
- **Q**: What happens when the request names several tickets?
  **A**: The mention stays the leading positional alone, so naming, branch and folder
  are unchanged. But the extra tokens are named back to the operator, with a pointer
  to the designator route that does accept several issues (FR-034). Recognising them
  all as mentions was rejected: it would make the computed name depend on which
  ticket was typed first and would re-open the whole-description scan that research
  R2 closed. Silence was rejected as the defect this feature exists to end.

### Session 2026-08-17 — the question becomes a proposal

- **Q**: Should the question be an abstract choice ("reuse, or create new?") or a
  concrete proposal ("attach IJT-42 as the Epic?")?
  **A**: A proposal, per detected issue, naming the role each would be attached in.
  The type is already in hand from the widened read and the role mapping is already in
  the loaded configuration, so the concrete form costs nothing and removes the
  "which issues?" round-trip in every ordinary case. It also moves the role-mismatch
  refusal *before* the answer instead of after (FR-022). The decision reverses research
  R2's "leading positional only" recognition rule, which R2 itself recorded as the one
  decision a maintainer could reasonably overturn.
- **Q**: If several tickets are named, are they all detected?
  **A**: All of them, each on its own line with its own proposed role — but only when
  the leading positional is itself a ticket. That gate is what keeps `COVID-19` in an
  ordinary description from producing Jira guidance in a repository that named nothing.
  The leading positional still computes the branch and folder names alone, so
  reordering words can never rename a branch. A ticket merely *cited* for context does
  appear in the list; the operator declines it by naming the ones they meant, which is
  the mitigation R2 wanted and could not have while the extension only guessed.
- **Q**: What happens to an issue whose type is neither the declared Epic nor the
  declared Story — a Bug, say?
  **A**: It is *unmapped*, not misplaced, and the two must not share an outcome
  (FR-036). A Bug is proposed in the story role, with its unmapped type stated plainly,
  and the operator confirms or redirects. **It does not require a parent**: accepting it
  with no specification-role issue named creates nothing above it and re-parents
  nothing. Requiring an Epic for a Bug would be this specification inventing a workflow
  rule, which Principle VII forbids. Refusing outright — today's behaviour — was
  rejected as the defect being fixed, one type further along.
- **Q**: When reuse is refused, what is the operator told?
  **A**: The cause in their own terms, and the way out that always exists: decline, and
  the extension creates the Epic and one Story per drafted user story itself (FR-037).
  Every refusal class reachable on this path carries it, because an operator who
  reached a refusal has already stated an intent this extension can satisfy another
  way.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - The operator is asked before anything is created (Priority: P1)

An operator names an existing Jira issue in the feature description. Before any
branch is named, any folder is created, and any ticket is touched, they are asked a
single closed question: should this specification reuse existing Jira issues, or
should new ones be created alongside the mentioned ticket?

**Why this priority**: This is the reported defect. Every other story in this
specification is either the answer to this question or the guarantee that asking it
broke nothing. Without it, the operator learns about the choice only after the
duplicates are planned, when the only remedy left is discarding the feature.

**Independent Test**: Can be fully tested against a mocked double holding one
resolvable issue: invoke the naming step with that issue mentioned and no
designator, and assert the run stops at a stated question, names nothing, creates
nothing locally, writes nothing to Jira, and exits successfully.

**Acceptance Scenarios**:

1. **Given** one or more detected issue keys that resolve, and no designator supplied,
   **When** the naming step runs, **Then** it returns a closed question instead of
   naming the feature, exits successfully, and performs zero writes of any kind —
   Jira-side or local.
2. **Given** the same invocation, **When** the question is returned, **Then** no
   branch name and no folder short name appear in the result — so the caller
   cannot create the branch or the spec folder without first obtaining an answer
   (FR-031). This is what makes the question unskippable rather than merely
   mandatory, and it is the difference between this feature and the follow-up step
   the reported incident shows an agent silently dropping.
3. **Given** a mentioned ticket supplied as a browser URL rather than a key,
   **When** the naming step runs, **Then** the same question is returned for the
   same issue: pasting a link and typing a key are the same act (FR-032).
4. **Given** a mentioned issue key that does not resolve, **When** the naming step
   runs, **Then** the existing fail-closed behaviour applies unchanged and no
   question is asked — a question about an issue that could not be read would
   invite an answer the following step cannot honour.
5. **Given** a mentioned issue key **and** at least one designator supplied
   together, **When** the naming step runs, **Then** no question is asked: the
   designators already state the operator's intent.
6. **Given** neither a mentioned key nor a link anywhere in the request, **When**
   the naming step runs, **Then** no question is asked and the run is byte-identical
   to the current release. Naming a ticket is the sole trigger; nothing else, and no
   configuration, may cause the question to appear.
7. **Given** the invocation that returns the question, **When** its Jira requests are
   recorded, **Then** their count matches the current release's for the same input and
   only the mentioned-key read's field list differs (FR-017) — and **Given** any
   invocation that does not ask, **Then** not one byte of any request differs,
   query string included.
8. **Given** a mentioned ticket whose team differs from the selected one, and no
   designator, **When** the naming step runs, **Then** the cross-team question is
   returned **alone** — this feature's question follows on the invocation that answers
   it, and the two are never merged (FR-025).

*What the question **says** is User Story 7's subject; this story owns only that it is
asked, that asking costs nothing, and that it cannot be walked past.*

---

### User Story 2 - Answering "create new" changes nothing but the asking (Priority: P1)

The operator answers that they want new issues created alongside the mentioned
ticket. From that point the run is indistinguishable from the current release. The
run as a whole is not: it now carries one question and one further invocation that
the current release does not have. What is unchanged is every byte of what the run
produces, never the number of steps it takes to produce it — a run that mentions no
ticket keeps even that (User Story 5).

**Why this priority**: This is the regression guarantee for every consumer who
mentions a ticket purely to drive naming — today the majority. Asking a question is
only acceptable if the ordinary answer costs nothing but the answer itself. It ships
with User Story 1 because a question with no honoured answer is not a shippable
slice.

**Independent Test**: Can be fully tested by running the current release and the new
one against the same mocked double and the same mentioned key, and comparing the
answered invocation's result against the current release's single invocation:
identical output bytes, identical exit code, identical recorded request sequence
from the answered invocation onward.

**Acceptance Scenarios**:

1. **Given** a mentioned key and the recorded answer "create new", **When** the
   naming step is re-invoked with that answer, **Then** its output, its exit code,
   and its ticket action are byte-identical to the current release's result for the
   same input.
2. **Given** the same invocation, **When** it completes, **Then** the question is
   not asked again — an answered run never re-poses the question it was given.
3. **Given** the answer "create new", **When** the following reconcile runs,
   **Then** it behaves exactly as it does today: a new parent and one issue per
   drafted user story, with the mentioned ticket untouched.
4. **Given** the answer "reuse" but no issue named alongside it, **When** the
   naming step runs, **Then** it returns a question asking which issues to reuse,
   writes nothing, and records nothing — and repeating the same incomplete answer
   returns the same question, indefinitely and without accumulating state.
5. **Given** that follow-up question, **When** the operator names the issues,
   **Then** the run continues exactly as if they had been named the first time.

---

### User Story 3 - Answering "reuse" reaches a bound specification (Priority: P2)

The operator answers that they want existing issues reused. They name the issues,
and the run continues into the established path that seeds a specification from
named issues and binds them.

**Why this priority**: It is the outcome the operator actually wanted, but it
delivers value only once the question exists, and it is reached through machinery
that already ships in full. It carries the least new behaviour of the three and can
therefore follow.

**Independent Test**: Can be fully tested against a mocked double holding one
parent-role issue and one story-role issue: answer "reuse", supply both as
designators, and assert the run produces the same seeded-not-bound state that the
same designators produce today with no question involved.

**Acceptance Scenarios**:

1. **Given** the answer "reuse" and a set of named issues, **When** the naming step
   is re-invoked with those issues as designators, **Then** the resulting state is
   identical to the state the same designators produce when supplied directly,
   with no residue of the question anywhere in it.
2. **Given** the operator names the mentioned ticket itself among the issues to
   reuse, **When** the run continues, **Then** it is treated exactly as any named
   issue is: no special case, no double resolution.
3. **Given** the answer "reuse" but a mentioned ticket whose type matches no role
   declared in the configured hierarchy, **When** the run continues, **Then** it
   refuses with zero writes, names the issue, the type found, and the type the
   role declares — and states **both** ways forward: name a different issue for
   that role, or supply a title instead of a key so the missing parent is created
   and the mentioned issue placed beneath it.
4. **Given** an operator who has no parent-role issue at all, **When** they supply
   a title for the parent role rather than a key, **Then** the parent is created
   and the reused issue is placed beneath it, in the single confirmed step that
   already binds every other named issue — no separate ceremony, and no
   pre-existing epic required.

---

### User Story 4 - An unattended run never waits (Priority: P2)

A run with nobody to answer — continuous integration, a scripted invocation, an
agent operating without an operator — proceeds without asking.

**Why this priority**: A question that can hang an automated pipeline is worse than
the defect it fixes. It is P2 rather than P1 only because the question is returned
rather than waited on, so the failure mode is a stalled ceremony, not a hung
process.

**Independent Test**: Can be fully tested by invoking the naming step with the
unattended declaration and a mentioned key, and asserting the result is the current
release's result with no question in it.

**Acceptance Scenarios**:

1. **Given** a mentioned key and a caller declaring itself unattended, **When** the
   naming step runs, **Then** no question is returned and the run proceeds exactly
   as the "create new" answer would.
2. **Given** an unattended run, **When** it completes, **Then** it states in its
   result that the question was suppressed and which answer was assumed, so an
   operator reading the log later can tell a suppressed question from one that
   never applied.

---

### User Story 5 - A run naming nothing is untouched (Priority: P3)

The operator mentions no ticket and supplies no designator. Behaviour, output bytes,
exit code, and the Jira request sequence are identical to the current release.

**Why this priority**: It protects the majority of runs, and it holds by
construction — the question's only trigger is a mention. It is listed explicitly
because it is the guarantee reviewers must be able to check without reading the
implementation, and because the equivalent guarantee in the preceding feature is
what made that feature safe to ship.

**Independent Test**: Can be fully tested by running the existing conformance
scenarios that name nothing, unmodified, and asserting byte-identical output and
exit codes.

**Acceptance Scenarios**:

1. **Given** no mentioned key and no designator, **When** the naming step runs,
   **Then** its output, exit code, and recorded request sequence are byte-identical
   to the current release's.

---

### User Story 6 - Told what to configure, instead of silence (Priority: P2)

An operator names an existing issue in a repository where no team configuration
applies to them. Instead of the run passing through silently, they are told that no
team configuration was found and which command sets one up.

**Why this priority**: It is the same defect one layer down. An operator who names
a ticket has stated an intent that cannot be honoured without a configured team,
and today that intent meets total silence: the run returns inactive with no message
at all, before the mentioned key is even read. The operator concludes the extension
is broken or absent. It is P2 rather than P1 because it strands the operator
without destroying anything, whereas User Story 1 prevents duplicate tickets.

**Independent Test**: Can be fully tested with no Jira double at all: invoke the
naming step with a mentioned key in a repository whose configuration declares no
team applicable to the operator, and assert the result names the missing
configuration and the command that creates it.

**Acceptance Scenarios**:

1. **Given** a mentioned issue key and no team configuration applicable to the
   operator, **When** the naming step runs, **Then** it reports that no team
   configuration was found, names the configuration file it looked in, and states
   the command to run before retrying — and it still does not fail the host
   command.
2. **Given** the same situation, **When** the run completes, **Then** it performs
   zero Jira requests: the missing configuration is established from the
   filesystem alone, before any read.
3. **Given** **no** mentioned key and no team configuration, **When** the naming
   step runs, **Then** its result is byte-identical to the current release's —
   silent pass-through. The guidance is owed to an operator who named something,
   never to a repository that simply does not use this extension.

---

### User Story 7 - The question shows, per ticket, what it will do (Priority: P1)

The operator does not face a principle ("reuse, or create new?"). They face a list: one
line per ticket they named, each with the role it would be attached in, what the
specification will be written from, and what declining creates instead. They confirm a
placement.

**Why this priority**: it ships with User Story 1 because a question nobody can evaluate
is not a shippable question. It is also what makes the ordinary answer cost **one**
re-invocation instead of two — without the proposal, "reuse" has to be followed by
"which issues?", and the reported incident is evidence that agents drop chained
follow-ups. The whole feature's value collapses to a slower version of the defect if the
question cannot be answered in one step.

**Independent Test**: against a mock holding one issue of the declared specification
type, one of the declared story type, and one of a third type, invoke with all three
named and assert three lines, three roles — specification, story, and story-marked-
unmapped — plus the source line and the decline line, all in the project's own type
names.

**Acceptance Scenarios**:

1. **Given** detected issues that resolve, **When** the question is returned, **Then**
   each appears on its own line with key, summary, type, status and the role it would be
   attached in, in argv order (FR-003, FR-035).
2. **Given** the same question, **When** it is read, **Then** it states that the
   detected issues' content is the specification's source material, and states what
   declining creates in the project's own type names — never "create new issues"
   (FR-002).
3. **Given** a request whose leading positional is a key and which contains further keys
   or links, **When** the naming step runs, **Then** every one is detected and proposed,
   one answer settles all of them, and the branch and folder are computed from the
   leading positional alone — reordering the words changes neither (FR-034, FR-032).
4. **Given** a routed project that declares no hierarchy, **When** the question is
   returned, **Then** no role is proposed for any issue and the question asks for
   explicit designators — a plainer question, never a guess (FR-035).
5. **Given** an issue whose status the configuration declares halted, **When** the
   question is returned, **Then** it states that "reuse" would be refused for that issue
   — and **Given** a status the configuration does not declare halted, **Then** the
   status is stated with no such warning (FR-033).
6. **Given** a proposal holding at least one story-role issue, **When** it is returned,
   **Then** it states that user stories drafted beyond the named issues become new
   story-role issues beneath the same parent (FR-040).
7. **Given** a proposal holding story-role issues and no specification-role issue,
   **When** it is returned, **Then** its own answers carry the three parent routes and
   **no second question is posed** (FR-038).

---

### User Story 8 - A ticket that does not fit is redirected, never dead-ended (Priority: P2)

The operator names a ticket that cannot play the role they aimed it at. Instead of a
refusal that states a mapping, they get the reason and a route — including, always, the
route that needs nothing from them: decline, and the extension builds it fresh.

**Why this priority**: it is the reported defect one layer down. An operator who reaches
a refusal has already stated an intent this extension can satisfy; being told only "wrong
type" leaves them to guess, and guessing here means creating things by hand in Jira. It
is P2 rather than P1 because it strands rather than destroys.

**Independent Test**: against a mock holding one issue per refusal class, assert each
refusal names its cause, its issue, and both the cause-specific remediation and the
decline-and-create-fresh alternative.

**Acceptance Scenarios**:

1. **Given** a detected issue whose type maps to no declared role — a Bug where the
   project declares Epic and Story — **When** the naming step runs, **Then** it is
   proposed in the story role with its type named as declared for no role, the run does
   **not** refuse, and accepting it alone creates nothing above it and re-parents
   nothing (FR-036).
2. **Given** a detected issue whose type equals the type declared for the *other* role,
   **When** the naming step runs, **Then** it refuses at the question itself, before any
   answer is given, naming both types (FR-022).
3. **Given** any refusal raised while evaluating detected issues, **When** it is
   returned, **Then** it names its cause **and** states that declining has the extension
   create the specification-role issue plus one story-role issue per drafted user story
   (FR-037).
4. **Given** an unmapped-type issue designated in the specification role, **When** the
   run evaluates it, **Then** it refuses explaining that the role is the container and
   that this feature never changes an issue's type, and carries the route that works —
   a title for the parent plus that issue as a story (FR-039).
5. **Given** an operator with no specification-role issue at all, **When** they supply a
   title for it, **Then** it is created and the reused issues are placed beneath it in
   the same confirmed step (FR-023, FR-024).

---

### User Story 9 - Every message says what the run already knows (Priority: P2)

No message states a fact the run holds and stops short of what the operator must do
next; and no message promises something that will not happen.

**Why this priority**: this is the reported incident's own defect class, stated as a
requirement rather than fixed one site at a time — the extension knew it had not bound
the ticket and said nothing. It is P2 because each instance is small; it is a story
rather than a checklist item because the instances share one cause and one test.

**Independent Test**: enumerate every message class this feature adds or changes, and
assert each names the problem, the issue involved, and a copy-pasteable next step. No
Jira double is needed for the enumeration itself.

**Acceptance Scenarios**:

1. **Given** any message class introduced or changed here, **When** it is emitted,
   **Then** it names the problem, the issue involved, and a copy-pasteable next step
   (FR-018).
2. **Given** a mentioned ticket that cannot be read, **When** the fallback message is
   emitted, **Then** it names which cause occurred — credentials rejected, issue not
   found or not visible, Jira unreachable — states that new issues will be created, and
   **never** claims the ticket will be attached later (FR-041).

---

### Edge Cases

- **Both questions pending at once.** The naming step already asks a closed
  question when the mentioned ticket belongs to a different team than the selected
  one. When that question and this one both apply to a single invocation, they are
  asked in a fixed order across two round-trips: the team question first, this one
  second. The team question decides which project the run routes to, and routing
  decides which hierarchy declares the roles this question's answer will be
  measured against — so asking them the other way round would ask the operator to
  choose against a hierarchy that may not turn out to be theirs. Each question
  stays short and independently testable; neither is ever merged into the other.
- **An answer arrives with nothing to answer.** A run supplies the answer but mentions
  no ticket and supplies no designator: the answer applies to no question and MUST be
  reported as a usage error rather than silently ignored, so a mis-scripted invocation
  is visible.
- **An answer arrives contradicting its own designators.** `--reuse no` alongside
  `--parent`/`--story` says "create new issues" and "reuse these issues" in one breath.
  It is a usage error naming both halves. `--reuse yes` alongside designators says the
  same thing twice and is accepted in silence — redundancy is not a mistake, and an
  assistant that restates the answer it was given must not be punished for it.
- **An unrecognised answer.** A value that is neither of the two stated answers is
  a usage error naming both accepted values; it is never treated as either.
- **Jira becomes unreachable between the question and the answer.** The
  re-invocation carrying designators is fail-closed by the established designator
  behaviour: it refuses rather than degrading into a run that creates duplicates.
  The re-invocation carrying "create new" keeps the ordinary non-blocking fallback.
- **The operator abandons the run at the question.** Nothing was named, nothing was
  created, nothing was written. Re-invoking from scratch is the whole recovery
  procedure; no state needs cleaning up, and none is left behind.
- **The same invocation is answered twice.** An answer is a per-invocation input,
  not recorded state: two answered invocations are two independent runs, and
  neither can observe the other's answer.
- **The mentioned ticket is cancelled, done, or otherwise finished.** The question is
  still asked — the status is a fact of the instance, not a verdict — but it carries
  the status and, when the configuration declares that status halted for the project,
  a statement that "reuse" will be refused for it (FR-033). An operator whose ticket
  is merely *in progress* sees the status and nothing more: an ordinary open ticket is
  the case this feature was built for. Nothing here decides on the operator's behalf
  which statuses end a workflow; the configured list is the only source.
- **Several tickets in one request.** `IJT-40 IJT-42 IJT-43 make exports faster` names
  three. Each appears on its own line with its own proposed role, and one answer
  settles all three (FR-034). The branch and folder are still computed from `IJT-40`
  alone, so reordering the words cannot rename the branch. Pasting three links behaves
  identically to typing three keys. When the **first** token is not itself a ticket —
  `ticket IJT-1 IJT-2 …` — nothing is detected and the run stays silent, unchanged:
  the key shape also matches ordinary words like `COVID-19`, and a control that speaks
  unprompted into repositories not using this extension gets disabled. That shape is
  the agent ceremony's responsibility, not the bridge's.
- **A ticket named only for context.** `IJT-40 see IJT-99 for background` puts `IJT-99`
  in the proposal too. That is not a defect: the operator declines it by naming what
  they meant — `--reuse yes --parent IJT-40` — and `IJT-99` is left alone. Being asked
  about an issue costs a glance; being silently bound to one costs the feature folder.
- **A Bug, or any type the hierarchy does not map.** Proposed in the story role, with
  its type named as declared for no role. It needs no Epic: accepted alone, nothing is
  created above it and nothing is re-parented. An operator who wants an Epic says so in
  the same answer, by key or by title. Refusing a Bug outright would be the same
  silence this feature exists to end, moved one type along.
- **The named issue turns out to be the whole feature.** An operator names a Bug, then
  drafting reveals it is really an epic's worth of work. The Bug cannot *become* the
  container — a Bug sits at the same level as a story in Jira, and this feature never
  changes an issue's type — but the shape they want is one answer away: create the
  parent from a title and name the Bug as a story beneath it. Every user story drafted
  beyond it becomes a new story-role issue under that same parent. Designating the Bug
  as the parent instead refuses, and the refusal carries this route rather than only the
  type mismatch (FR-039).
- **The agent drafts more user stories than were named.** Established behaviour, stated
  here because the operator must know it *before* answering: the issues they named are
  reused, and every drafted user story without one becomes a new story-role issue
  beneath the same parent — exactly, with no off-by-one and no duplicate. Naming two
  stories for a specification that drafts five creates three, not five and not seven
  (FR-040).

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: When the naming step resolves a mentioned issue key or URL and no
  designator is supplied, it MUST return a closed question to its caller instead of
  proceeding to name the feature.
- **FR-002**: The question MUST be a **concrete proposal, never an abstract choice**.
  For each detected issue it states the role it would be attached in — the role whose
  declared type matches the issue's own — so the operator confirms a placement rather
  than a principle. It MUST also state, in the same breath:
  - that the detected issues' content is the source material the specification will be
    written from, since that is what accepting routes into;
  - what declining produces, concretely: a new issue in the specification role, plus
    one issue in the story role per drafted user story. "Create new" is not an
    explanation an operator can act on; "a new Epic, plus one Story per drafted user
    story" is.

  The two accepted answers are unchanged, and no free-form answer exists. What changes
  is that each answer now names its consequence.
- **FR-003**: The question MUST identify **every** detected issue — one line each — by
  key, summary, type, and status, so the operator can tell whether they are the issues
  they meant before answering. Those four facts MUST come from the mentioned-key read
  of the same invocation, whose requested field set is widened to carry them — today it
  asks for the project alone and returns nothing else. The widening applies **only on
  the path that is about to ask** (FR-017), so every other path's request stays
  unchanged.
  Each line MUST also carry the role the issue would be attached in (FR-035).
- **FR-004**: Returning the question MUST perform zero writes of any kind — no Jira
  mutation, no branch, no folder, no file, no recorded state.
- **FR-005**: Returning the question MUST exit successfully. A question is not a
  failure, and the host command it runs inside must complete normally.
- **FR-006**: The question MUST NOT be returned when the naming step is given at
  least one designator: a designator already states the intent the question asks
  about.
- **FR-007**: The question MUST NOT be returned when the mentioned key could not be
  read reliably. The existing fail-closed outcome for an unreadable mentioned key
  applies unchanged.
- **FR-008**: The question MUST NOT be returned when no ticket is mentioned. A run
  naming nothing MUST be byte-identical to the current release in output, exit
  code, and Jira request sequence.
- **FR-009**: The caller MUST be able to convey either answer back to the naming
  step on a subsequent invocation.
- **FR-010**: An invocation carrying the answer "create new" MUST produce output,
  an exit code, and a ticket action byte-identical to the current release's result
  for the same mentioned key, and MUST issue the identical Jira request sequence —
  same count, same endpoints, same query strings. An answered invocation never asks,
  so FR-017's wider field set never applies to it.
- **FR-011**: An invocation carrying an answer MUST NOT return the question again.
- **FR-012**: The answer "reuse" MUST route into the established designator path,
  which then behaves exactly as it behaves today, with no residue of the question in
  the state it produces. The operator reaches it two ways, and both MUST be honoured:
  by accepting the proposal (FR-029), which supplies the designators the question
  itself derived, or by naming designators explicitly, which overrides the proposal
  issue by issue. An explicit designator always wins over a proposed one — the
  proposal is a convenience, never a constraint.
- **FR-013**: A caller declaring itself unattended MUST NOT be asked. Such a run
  MUST proceed as the "create new" answer would.
- **FR-014**: An unattended run whose question was suppressed MUST state that it was
  suppressed and which answer was assumed.
- **FR-015**: An answer that answers nothing, or that contradicts what it arrives
  with, MUST be reported as a usage error naming the conflict. Two cases, and only
  two:
  - an answer supplied with **neither** a mentioned ticket **nor** a designator
    answers a question that was never posed;
  - the answer "create new" supplied **together with designators** contradicts them —
    designators name issues to reuse, which FR-006 already treats as the very intent
    the question asks about, so the two cannot both be meant.

  The answer "reuse" supplied together with designators is **not** an error: it agrees
  with them and is accepted as a redundant restatement of the same intent. A
  mis-scripted invocation must be visible; a merely redundant one must not be
  punished.
- **FR-016**: An answer value that is neither accepted value MUST be reported as a
  usage error naming both accepted values.
- **FR-017**: Deciding to ask MUST NOT introduce any additional Jira request. The
  question is composed from the mentioned-key read the invocation performs anyway;
  what changes is the field set that read requests, never the number of reads. The
  wider field set MUST be requested **only** when the run has already established
  that it is about to ask — a mention present, no designator, no answer, not
  unattended. All four conditions are known before the read, so every path that
  does not ask keeps its request byte-identical, query string included: this is what
  keeps FR-008, FR-010 and FR-028 satisfiable at all.
- **FR-018**: The question, its answers, and every refusal introduced here MUST each
  name the problem, the issue involved, and a copy-pasteable next step.
- **FR-019**: Both implementations MUST produce byte-identical output, exit codes,
  and Jira request sequences on every path introduced here.
- **FR-020**: The prediction mode MUST predict the question — including that it
  would be asked, and for which issue — without performing it.
- **FR-021**: The naming step MUST NOT wait on input for the answer under any
  circumstance. It returns the question and exits; the answer arrives as a
  subsequent invocation.
- **FR-022**: When a detected issue's type equals the type declared for the **other**
  role — the misplaced case of FR-036 — the run MUST refuse with zero writes and name
  the issue, the type found, and the type that role declares. The refusal MUST be
  raised **at the question**, from the type the same read already returned, and never
  held back until after the operator has answered: a refusal that waits for an answer
  spends a round-trip to tell the operator something it already knew.
- **FR-023**: That refusal MUST state both ways forward: name a different issue for
  the role, or supply a title for the role instead of a key so that the missing
  issue is created. Both MUST be stated as copy-pasteable next steps, so an
  operator who has no parent-role issue at all is never left without one.
- **FR-024**: Supplying a title rather than a key for the parent role MUST create
  that parent and place the reused issues beneath it, within the same confirmed
  step that binds them. No pre-existing parent may be required in order to reuse a
  child-role issue.
- **FR-025**: When both the existing cross-team question and this question apply to
  one invocation, they MUST be asked in a fixed order — the team question first —
  across two round-trips, and MUST NEVER be merged into a single question.
- **FR-026**: When a ticket is mentioned and no team configuration applies to the
  operator, the run MUST report that no team configuration was found, name the
  configuration file consulted, and state the command that creates one.
- **FR-027**: That report MUST NOT fail the host command, and MUST be produced
  without issuing any Jira request.
- **FR-028**: When no ticket is mentioned and no team configuration applies, the
  result MUST stay byte-identical to the current release. The guidance of FR-026 is
  owed only to an operator who named something.
- **FR-029**: The answer "reuse" carrying no designator MUST be read as **acceptance of
  the proposal the question made** — every detected issue, in the role the question
  proposed for it. That is the ordinary answer, and it costs one re-invocation.

  It falls back to a question asking which issues to reuse in exactly one case: **no
  role could be derived at all**, because the routed project declares no hierarchy
  (FR-035). There is then no proposal to accept, and an answer that says yes with
  nothing to say yes to is incomplete, not wrong.
  A proposal holding story-role issues and no specification-role issue is **not**
  incomplete: the first question already carries the parent routes (FR-038).
- **FR-030**: That follow-up MUST perform zero writes and record no state, so
  repeating the same incomplete answer produces the same question and never
  accumulates anything. There is no limit on how many times it may be asked: each
  round costs nothing and leaves nothing behind.
- **FR-031**: A result carrying the question MUST omit the branch name and the folder
  short name. This is the structural guarantee that the question cannot be skipped:
  without a name, the caller **cannot** proceed to create the branch and the spec
  folder, so answering stops being a matter of the caller's diligence. Every other
  requirement here assumes a caller that follows instructions; this one holds when it
  does not, and it is the only one that does.
- **FR-032**: **Every** detected token MUST be recognised both as a bare issue key and
  as a browser URL, using the same reduction rules the designator grammar already
  applies — the `selectedIssue` parameter, the segment after `/browse/`, and the final
  path segment. An operator who pastes links and an operator who types keys MUST reach
  the same question, and the two forms may be mixed freely in one request. Today only
  the bare key is recognised, and only in the leading position, so a pasted link is
  silently swallowed into the feature description and no question can fire.
- **FR-033**: When the resolved issue's status is one the configuration declares
  halted for its project, the question MUST say so and state that the answer "reuse"
  will be refused for that issue, so the operator answers "create new", reopens the
  ticket, or names another — instead of spending a round-trip to be refused. The
  refusal itself already exists on the designator path and is unchanged; what is new
  is that the question no longer invites an answer the following step will reject.
  This is FR-007's reasoning applied one step further: FR-007 declines to ask about
  an issue that could not be **read**, and this declines to ask *silently* about an
  issue that cannot be **reused**. No status is halted by default: the run asserts
  nothing about which statuses end a workflow and reads the configured list only.
- **FR-034**: When the leading positional is a mention, **every** further issue-shaped
  token in the request is detected too, and each appears in the question as its own
  line with its own proposed role (FR-003, FR-035). An operator who pasted three
  tickets is answering about three tickets.

  Two constraints hold this in place:
  - **The leading positional alone computes the name.** The branch and the folder short
    name are derived from the first detected issue and from nothing else, so reordering
    the words of a request can never rename its branch.
  - **The gate is the first token.** When the leading positional is **not** a mention,
    nothing is detected, nothing is reported, and FR-008's byte-identity holds
    unchanged. The key shape matches ordinary words such as `COVID-19`, so a run that
    named nothing must never be handed Jira guidance it did not ask for.

  A token detected here is a *proposal*, never an adoption: a request citing a related
  ticket for context puts that ticket in the list, and the operator declines it by
  naming the ones they meant. Being asked about an issue costs a glance; being silently
  bound to one costs the feature folder.
- **FR-035**: Each detected issue MUST be presented with the role it would be attached
  in, derived by matching its type against the types the routed project's hierarchy
  declares for the specification and story roles. The derivation reads configuration
  the run has already loaded and issues no request. When the project declares no
  hierarchy at all, no role can be derived: the question names the issues without a
  proposed placement and asks for explicit designators. A missing hierarchy produces a
  plainer question, never a guess.
- **FR-036**: An issue whose type matches **no** declared role is *unmapped*, and MUST
  be distinguished from an issue that is *misplaced*:
  - the type equals the type declared for the **other** role — the operator named the
    specification-role issue as a story, or the reverse. That is a mix-up: it refuses
    (FR-022), naming both types.
  - the type matches **neither** role — a Bug where the project declares Epic and
    Story, say. Nothing is wrong here: the project simply declares no role for that
    type. The question MUST propose the issue in the **story role**, state plainly that
    its type is declared for no role, and let the operator confirm or redirect. It MUST
    NOT refuse, and it MUST NOT apply the proposal without confirmation — the proposal
    is the question, and the answer is the authority.

  **An unmapped issue does not require a parent.** Accepting it without naming a
  specification-role issue keeps the established meaning: nothing is created above it,
  and nothing is re-parented. Requiring an Epic for a Bug would be this specification
  inventing a workflow rule, which Principle VII forbids. An operator who wants one
  says so in the same answer, by key or by title.
- **FR-037**: Every refusal raised while evaluating detected issues for reuse MUST name
  its cause in the operator's own terms — which issue, which fact about it, and which
  configured expectation it did not meet — **and** MUST state the always-available
  alternative beside the cause-specific remediation: decline the reuse, and the
  extension creates a new issue in the specification role plus one issue in the story
  role per drafted user story. This binds every class reachable here: a type declared
  for the other role, an issue in a halted status, issues spanning two projects, the
  same issue named twice, an issue already claimed by another specification. No refusal
  on this path may leave the operator holding only a dead end — the operator who
  reaches one has already stated an intent this extension can satisfy another way.
- **FR-038**: A proposal containing story-role issues and no specification-role issue
  MUST NOT trigger a second question. The first question already carries the three
  routes: attach beneath an existing specification-role issue named by key, attach
  beneath one created from a title supplied in the same answer, or accept as-is —
  which creates nothing above them and re-parents nothing. One question, three
  answers, one re-invocation. A second round-trip here would be the extension asking
  for something its own first question could have collected, which is the cost this
  feature exists to remove rather than to relocate.

- **FR-039**: Designating an issue in the specification role when its type is declared
  for **no** role MUST refuse, and the refusal MUST explain the constraint rather than
  restate the mapping: the specification role is the container, the issue's type is
  declared for no role, and **this feature never changes an existing issue's type** —
  so the issue cannot be made into the container.

  The refusal MUST then state the route that achieves what the operator was reaching
  for, as a copy-pasteable step: create the parent from a title and name the issue as a
  story beneath it. An operator who discovers, mid-drafting, that their Bug is really a
  whole feature is not making a mistake — they are describing a shape this extension can
  build, and being told only "wrong type" leaves them to guess how.
- **FR-040**: The question MUST state, whenever it proposes at least one story-role
  issue, that user stories drafted beyond the named issues become **new** issues in the
  story role beneath the same parent. This is established behaviour, not new machinery,
  and it is the single fact that decides whether an operator accepts the proposal: an
  operator who believes the specification will be capped at the issues they named will
  decline a proposal that would have served them.

- **FR-041**: The non-blocking fallback message for an unresolvable mentioned ticket
  MUST stop promising a binding that never happens, and MUST name the cause it already
  holds. Today it reads *"could not resolve a ticket in Jira — proceeding without one
  (reconciliation will attach it later)"*, and the parenthesis is false: a mentioned
  ticket is a naming input, never a binding, so the following reconcile creates a new
  parent alongside it. That sentence tells the operator not to worry about precisely the
  thing this feature exists to fix, and it is plausibly one reason the reported incident
  went unnoticed until the dry run.

  The replacement MUST distinguish the causes the run already knows apart — credentials
  rejected, issue not found or not visible, Jira unreachable — because they have
  different fixes, and MUST state what will actually happen: new issues will be created,
  and naming the ticket as a designator is how to reuse it instead.

### Requirement → user story

Nine stories, forty-one requirements, and one requirement that deliberately belongs to
none. The table is the coverage proof: a requirement owned by no story is a requirement
no increment delivers, and it is how the six-story version of this specification came to
carry nine stories' worth of work under one heading.

| Story | Owns | Requirements |
| --- | --- | --- |
| **US1** — asked before anything is created (P1) | the question exists, costs nothing, cannot be walked past | FR-001, FR-004, FR-005, FR-006, FR-007, FR-017, FR-020, FR-025, FR-031 |
| **US7** — the question shows what it will do (P1) | its content: the per-ticket proposal | FR-002, FR-003, FR-032, FR-033, FR-034, FR-035, FR-038, FR-040 |
| **US2** — "create new" changes nothing but the asking (P1) | the answers, and the errors of answering badly | FR-009, FR-010, FR-011, FR-015, FR-016, FR-030 |
| **US3** — "reuse" reaches a bound specification (P2) | the routed path | FR-012, FR-024, FR-029 |
| **US8** — redirected, never dead-ended (P2) | every refusal and its route | FR-022, FR-023, FR-036, FR-037, FR-039 |
| **US4** — an unattended run never waits (P2) | suppression, and never blocking | FR-013, FR-014, FR-021 |
| **US6** — told what to configure (P2) | the missing-configuration report | FR-026, FR-027 |
| **US9** — messages say what the run knows (P2) | message quality as an outcome | FR-018, FR-041 |
| **US5** — a run naming nothing is untouched (P3) | the installed base | FR-008, FR-028 |
| *(none — deliberately)* | cross-port equality is a constraint on every path, not an increment anyone can ship | FR-019 |

**FR-019 has no story on purpose.** Byte equality between the two ports is a property of
every requirement above rather than a slice of value: it cannot be delivered, only
maintained. It is owned instead by the conformance obligations of Phase 9 and by the
per-story conformance tasks, and stating that here is what stops it from looking like an
oversight later.

**Priority reading**: P1 is US1 + US7 + US2 — the question, its content, and its answers.
Those three are one shippable increment and none of them is shippable alone. Everything
else refines what happens after an answer.

### Key Entities

- **Pending reuse decision**: the state of one invocation that resolved a mentioned
  issue, was given no designator, and has not been told which answer applies. It
  carries the resolved issue's identifying facts and the two accepted answers. It is
  returned, never stored: no file records it, and it does not survive the
  invocation.
- **Reuse answer**: the operator's choice, supplied to a subsequent invocation. It
  has exactly two accepted values and no default; its absence is what makes the
  question appear.

## Constitution Check _(mandatory)_

| #    | Principle                                                             | Proof of compliance                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ---- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| I    | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | This feature is the first controlled exception operating as written. That exception already provides that when the operator explicitly mentions an existing issue key, the extension may read and edit **that** ticket. Today the mention only names the feature; this feature asks whether the exception should be exercised. Nothing here widens the exception to any other ticket, and the answer "reuse" routes into the existing designator path, whose adoption is already logged in the run summary.                                                  |
| II   | Zero-Churn Idempotency                                                | No new write kind is introduced. The question performs zero writes (FR-004), and both answers route into paths whose idempotency is already established and tested.                                                                                                                                                                                                                                                                                                                                                                                          |
| III  | Fail-Closed on Writes, Non-Blocking on Hooks                          | An unreadable mentioned key keeps its fail-closed outcome and is never made into a question (FR-007). Returning a question exits successfully (FR-005), so the host command it runs inside is unaffected. The unattended path guarantees a hook never stalls (FR-013).                                                                                                                                                                                                                                                                                       |
| IV   | Credential Security — Zero Tokens in the Tree, Ever                   | No credential is read, written, or displayed by any path introduced here. The principle's rule that the bridge must never prompt or block inside a lifecycle hook is honoured literally: the script never prompts and never waits (FR-021) — it returns a question and exits, and the caller is what asks.                                                                                                                                                                                                                                                   |
| V    | Separation of Team Config / Local Binding / Secrets                   | No configuration key is added to any layer. The trigger is the mention itself, which is why an opt-in key was rejected during design (see Assumptions). FR-026 only _reads_ the committable team layer to report that it declares no applicable team, and names the file it consulted; it writes nothing to any layer.                                                                                                                                                                                                                                       |
| VI   | macOS / Linux / Windows Portability                                   | Both implementations, proven byte-identical on every path introduced here by the shared conformance corpus (FR-019). The question text and the refusals cross platforms as output and are therefore held to byte equality.                                                                                                                                                                                                                                                                                                                                   |
| VII  | No Hard-Coded Assumptions About the Jira Workflow                     | The question names the resolved issue's type and status as facts read from the instance; it asserts nothing about what they should be. FR-022's refusal quotes the type the _configured_ hierarchy declares for the role rather than any Atlassian default, and FR-024 creates a missing parent using that configured type — so a SAFe or renamed hierarchy is served identically.                                                                                                                                                                           |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface                 | The decision belongs entirely to the command and sink layers, where mentioned-key resolution already lives. No engine module learns about tickets, questions, or answers.                                                                                                                                                                                                                                                                                                                                                                                    |
| IX   | Two-Tier Privacy Guard, With an Allowlist                             | The question repeats issue facts already returned by an existing read and displayed by the current release, so it introduces no new content class. The existing pre-write guard is unaffected: this feature adds no write.                                                                                                                                                                                                                                                                                                                                   |
| X    | Self-Healing Automatic Mirror                                         | Hook registration is untouched. No event is added, removed, or re-registered; the manifest's declared set is unchanged.                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| XI   | Universal Dry-Run and Auditability                                    | The prediction mode predicts the question without performing it (FR-020). Every outcome is reported in the run summary, including the suppressed-question case (FR-014), so an audit distinguishes a question that was declined from one that never applied.                                                                                                                                                                                                                                                                                                 |
| XII  | Quality and Catalog Publication                                       | Version bump, CHANGELOG entry, green three-OS matrix, and a dogfood run against a real instance are release gates for this feature as for any other. The dogfood run must cover the reported scenario end to end, since that scenario is what motivated the work.                                                                                                                                                                                                                                                                                            |
| XIII | TDD With a Minimum 80% Coverage                                       | Every requirement here is expressed as an observable outcome, so each admits a failing test written first. The regression test for the reported defect — a mentioned key with no designator must not reach a silent naming — is written before any behaviour changes.                                                                                                                                                                                                                                                                                        |
| XIV  | KISS — The Simplest Solution That Satisfies the Spec                  | One closed question, two answers, one re-invocation. No wizard, no multi-step collection, no new mechanism: the question reuses the pattern the naming step already uses for its cross-team question and that two other commands already use. A multi-step wizard was considered and rejected — each extra round-trip is another agent decision, and the reported incident is evidence that agents drop chained follow-up steps.                                                                                                                             |
| XV   | YAGNI — Nothing Is Built Before a Spec Requires It                    | Every element traces to a requirement above: the question (FR-001), the answer (FR-009), the unattended suppression (FR-013). The opt-in configuration key considered during design is deliberately absent, and is recorded in Out of Scope rather than shipped as an unused option.                                                                                                                                                                                                                                                                         |
| XVI  | Human Readable — Readable by a Human Above All                        | The question names the issue in human terms — key, summary, type, status — and states both answers in the operator's language (FR-003, FR-018). Every refusal names the problem, the issue, and a copy-pasteable next step; FR-023 goes further by refusing to leave an operator without a way forward when they own no parent-role issue, and FR-026 replaces a silent pass-through with a message naming the file and the command. This principle is what the reported incident violated: the extension knew it had not bound the ticket and said nothing. |

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: In 100% of runs that mention an existing issue and supply no
  designator, the operator is presented with the choice before any branch, folder,
  or ticket exists.
- **SC-002**: The reported scenario — mention an existing issue, draft the
  specification, reconcile — produces zero duplicate parents when the operator
  answers "reuse", against four created issues today. Measured by an automated chain
  that spans the naming step and the reconcile, not by the dogfood run alone: this is
  the feature's headline outcome, and an outcome whose only witness is a human
  remembering to try it is not measured at all.
- **SC-003**: The number of re-invocations of the naming step equals the number of
  questions the operator was actually shown, and never exceeds three. **One is the
  ordinary case**, because the question proposes a placement the answer can simply
  accept (FR-029); two when the cross-team question applies first (FR-025) or when the
  project declares no hierarchy and the proposal cannot be built; three in the worst
  case, which is both. No path requires discarding a feature folder or a branch,
  and no round-trip exists that the operator was not shown a question for — a silent
  retry is the failure this criterion forbids, not a second question.
- **SC-004**: A run that mentions nothing and names nothing produces zero differing
  bytes against the current release across the whole conformance corpus, with
  identical exit codes and an identical request sequence.
- **SC-005**: A run answering "create new" produces zero differing bytes against
  the current release's result for the same mentioned key, from the answered
  invocation onward.
- **SC-006**: Zero unattended runs stall or wait: every invocation declaring itself
  unattended completes with the same outcome as the current release.
- **SC-007**: Deciding to ask adds zero Jira requests to the run compared with the
  current release.
- **SC-008**: Both implementations agree on every path introduced here — zero
  conformance divergences on a three-OS matrix.
- **SC-009**: An operator whose ticket does not fit the role they aimed it at
  reaches a bound specification without leaving the ceremony to create anything by
  hand in Jira: the refusal itself carries the step that gets them there.
- **SC-010**: An operator who names a ticket in an unconfigured repository is told
  what to configure in 100% of such runs, against zero messages today.
- **SC-011**: A pasted browser link and a typed key produce the same outcome in 100%
  of runs, with no assistant-side extraction required.
- **SC-012**: Zero runs reach a created branch or spec folder while the question is
  unanswered — the property is established structurally, not by inspecting caller
  behaviour.
- **SC-013**: Zero operators answer "reuse" for an issue in a configured halted
  status without having been told, at the question, that the answer would be refused
  — against a wasted round-trip on 100% of such runs today.
- **SC-014**: In 100% of runs whose leading positional is a ticket, every further
  issue-shaped token is presented with its own proposed role, against zero mentions of
  them today — and in 0% of runs whose leading positional is not a ticket, so the
  guidance never reaches a repository that named nothing.
- **SC-016**: An operator naming any number of issues that all map to a declared role
  reaches a bound specification in **one** re-invocation, with no "which issues?"
  round-trip — the proposal is the answer's content.
- **SC-017**: Zero refusals on the reuse path leave the operator without a stated way
  forward: 100% carry both the cause and the decline-and-create-fresh alternative
  (FR-037), against a refusal today that names only the cause.
- **SC-018**: An operator whose ticket is of a type the hierarchy maps to no role
  reaches a bound specification without editing configuration and without creating
  anything by hand in Jira, against a flat refusal today.
- **SC-019**: An operator who discovers their named issue is really a whole feature
  reaches the shape they want — a created parent with that issue and the drafted user
  stories beneath it — in one answer, from a refusal that names the route. Today the
  refusal names only the type mismatch, so the route is reachable but undiscoverable.
- **SC-020**: 100% of proposals containing a story-role issue state the arithmetic of
  what gets created beyond the named issues, so zero operators decline a proposal
  because they believed the specification would be capped at the issues they named.
- **SC-015**: Zero paths that do not ask the question change their Jira request in any
  byte, query string included — measured across the whole feature conformance corpus,
  which is what makes SC-004 and SC-005 provable rather than asserted.

## Assumptions

- The operator answers through the assistant that drives the ceremony; the script
  itself never prompts and never waits. This is the pattern the naming step already
  uses for its cross-team question and that two other commands already use for
  their own confirmations, and it is what the constitution's no-prompt-in-a-hook
  rule requires.
- The trigger is the mention alone. An opt-in configuration key was considered and
  rejected: a hand-edited key named in no template, README, or install document is
  never discovered, and the operator who needs this question is precisely the one
  who does not know it exists. Should evidence later appear of operators who seed
  from Jira without ever mentioning a ticket, the key can be added then, justified
  by that evidence.
- The question is asked after the mentioned key has been resolved, not before. An
  operator asked about an issue that turned out not to exist would be answering a
  question the following step could not honour, and the existing fail-closed
  outcome for an unreadable key is the better answer.
- Re-invoking the naming step with the answer repeats the reads a single run would
  have performed. This matches the existing cross-team confirmation, whose answered
  re-invocation likewise re-resolves the mentioned key, and is why FR-017 constrains
  the question path rather than the run total.
- When the answer is "reuse", the issues the operator names are supplied as
  designators. This specification adds no new way to name an issue; it routes to the
  established one.
- Creating a missing parent (FR-024) is an existing capability, not new machinery:
  the designator path already accepts a title in place of a key for the
  specification role and creates that issue at confirmation time. What this
  specification adds is that the role-mismatch refusal must _name_ that route, so an
  operator who owns only a child-role ticket discovers it instead of concluding they
  need an epic they do not have.
- Supplying only child-role issues, with nothing at all for the parent role, keeps
  its established meaning: no parent is created and no issue is re-parented. The way
  to ask for a parent is to name one — by key or by title.
- The mentioned ticket may be named among the reused issues or not, at the
  operator's discretion. Nothing requires the ticket that named the feature to also
  be part of it.

## Out of Scope

- **Retro-seeding a specification that already exists.** A feature created without
  designators cannot be bound afterwards; that refusal stays exactly as it is. This
  feature prevents the situation rather than repairing it.
- **Letting the ordinary reconcile adopt a ticket it did not create.** That guard is
  deliberate and unchanged.
- **Any change to the designator path itself**, beyond being the destination the
  "reuse" answer routes to.
- **A configuration key that makes the question unconditional.** Recorded here
  rather than shipped, per the Assumptions above.
- **A multi-step wizard** that collects the parent, then each story, in separate
  round-trips.
- **Changing the order in which lifecycle hooks run**, or how a consuming
  repository registers them.
