# Changelog

All notable changes to the spec-kit-jira extension are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- On Windows, a reconcile pointed at the wrong file in a feature folder now
  names the correct target in the caller's own spelling. The refusal used to
  answer `specs\001-example/spec.md` for a target spelled
  `specs/001-example/plan.md`, because the parent folder was taken through a
  path primitive that rewrites every separator to the host's native one. The
  PowerShell port now cuts the parent out of the argument's own bytes, as the
  Bash port's `dirname` already did, so both ports emit the same message on
  every host.

## [0.20.1] - 2026-08-19

### Fixed

- **A feature seeded from a mentioned ticket now reaches its `seed` step.**
  `feature --reuse yes` records the seeded-not-bound state under the short
  name it resolved, but spec-kit's own `create-new-feature.sh` always creates
  `specs/<FEATURE_NUM>-<short-name>` — and truncates that suffix past its
  branch-length cap. The record was therefore written under one name and
  looked up under another, so `seed` refused every handoff with `REF-EXISTS:
  retro-seeding is out of scope` and the reconcile that followed created a
  duplicate parent beside the ticket the operator had just named. Reads (and
  the delete that follows a successful seed) now resolve the record by
  stripping the host's numbering and matching the remainder as a prefix of the
  recorded keys; an ambiguous match resolves to nothing rather than to the
  wrong record, and writes are unchanged. The seed material file, a sibling
  keyed the same way, was affected identically and is resolved the same way.

  This is why 0.19.0's reuse question did not close the reported incident:
  answering it `yes` led straight into this second defect. The conformance
  chain that was meant to prove the whole flow placed its drafted `spec.md` at
  the un-numbered path, which is the shape no host produces, and so proved the
  flow only for a directory layout that never occurs.

- **`mention <issue-key>` now stamps a parent-role identity.** It wrote the
  identity property with no `role` field, and recognition blocks any parent
  whose marker does not carry `role: "parent"` — so the command bound nothing,
  and the remedy `reconcile` itself names ("bind each with the bridge's
  `mention <issue-key>` command") could not be followed. The seeding path has
  always stamped the role; this one predates roles and was never updated.

- **The suppressed-question warning now names the consequence.** Under
  `--accept-defaults` the reuse question is suppressed and the run reported
  `assumed answer: create new` — while going on to *attach* the ticket and bind
  nothing. It now states that the mentioned ticket names the feature without
  being bound to it, and that the next reconcile creates a new parent beside
  it.

## [0.20.0] - 2026-08-19

### ⚠ BREAKING CHANGES

- **`.specify/jira/.env` support is removed.** The token is no longer read
  from that file, or from any other file in the workspace. Credential
  resolution is now two rungs, not three: `JIRA_API_TOKEN` in the
  environment, then a retrieval command you declare in `JIRA_PAT_COMMAND`,
  run without a shell and bounded at 5 seconds. The old hardcoded probe of an
  OS secret manager under a fixed service name — the macOS Keychain, the
  Linux libsecret keyring, a PowerShell SecretManagement vault — is deleted
  outright; a credential store is reached only through a `JIRA_PAT_COMMAND`
  you declare yourself. See [`docs/CREDENTIALS.md`](docs/CREDENTIALS.md) for
  how to declare one on each platform.

  A declared `JIRA_PAT_COMMAND` that fails is now a **reported** failure — a
  WARNING in a lifecycle hook, an error everywhere else — where the old three
  rungs fell through to the next one silently. An operator who had a working
  Keychain/keyring/vault entry under the old scheme needs to export
  `JIRA_API_TOKEN` directly or declare `JIRA_PAT_COMMAND` explicitly; there is
  no automatic migration, and none is possible, since nothing was ever read
  from a fixed service name to begin with in the new scheme.

  The `.gitignore` rule covering `.specify/jira/.env` is kept even though
  nothing reads that file any more — an installation predating this release
  may still have one on disk holding a real token, and removing the rule
  would un-ignore it.

- **`config.yml` gains a `base_url` key.** The Jira site URL can now be
  committed with the team's config instead of living only in each
  developer's shell profile. This is opt-in — `SPEC_KIT_JIRA_BASE_URL` still
  takes precedence when set, and an unset `base_url` changes nothing — but a
  team that does commit it should read
  [`docs/07-configuration-and-secrets.md`](docs/07-configuration-and-secrets.md#the-three-connection-settings)
  first: the value enters the repository's git history irreversibly, and the
  committed form (unlike the environment variable) is validated for scheme at
  load time — `https://`, except at a loopback address.

### Added

- **`personal.yml` gains an `email` key, and its `team` key becomes
  optional** (`specs/030-retire-env-credentials/`). The config ceremony now
  creates `personal.yml` when it is absent — pre-filled with the resolved
  email when one is available, and a commented team placeholder — and reports
  it as a sixth effect (`personal`), computed ahead of the degraded-mode
  check so an operator with no working credentials yet still gets the file
  created and gitignored.
- New credential-resolution chokepoint (`config_resolve_connection` /
  `Resolve-JiraConnection`), called from every command entry point, seeds
  `SPEC_KIT_JIRA_BASE_URL`/`JIRA_EMAIL` from `config.yml`/`personal.yml` into
  the process environment once, only when not already set.
- New [`docs/CREDENTIALS.md`](docs/CREDENTIALS.md): per-platform
  `JIRA_PAT_COMMAND` setup, the CI/unattended arrangement, and the harness
  deny-rule pattern for keeping a coding agent out of the credential store.

### Fixed

- A `JIRA_PAT_COMMAND` that exceeds its 5-second bound is now reaped, and
  both of its redirected pipe ends released, before the failure is reported
  (PowerShell port). Each timed-out attempt previously held two file
  descriptors until the runtime's finalizer happened to run — invisible in a
  one-shot command, but accumulating in a long-lived host. Every wait on that
  path is bounded, so a retrieval command that leaves a background child
  holding the pipe open can no longer stall a run.

## [0.19.0] - 2026-08-18

### ⚠ BREAKING CHANGES

- **A mentioned ticket no longer names the feature on its own.** Naming a
  ticket with no `--parent`/`--story` designator now returns a question and
  **deliberately withholds `branch_name` and `short_name`**, so a caller
  cannot create the branch or the spec folder until the question is answered.
  That omission is the point — it is what makes the question impossible to
  skip — but it changes the result shape on a path that previously always
  carried both names.

  Nothing changes for a run that mentions no ticket, or that already supplies
  designators. To migrate an automated caller that relied on the old
  behaviour, pick one:

  - add `--reuse no` — output is byte-identical to the current release from
    that invocation onward;
  - add `--accept-defaults` if the caller is unattended — the question is
    suppressed, `no` is assumed, and the result says so;
  - or handle the new `reuse_required` / `reuse_issues_required` key, answer
    with `--reuse yes|no`, and re-invoke.

  Agent-driven callers that follow `commands/speckit.jira.feature.md` need no
  change: the ceremony there was updated with the question and its answers.

### Added

- **Ask once whether an existing ticket should be reused**
  (`specs/029-confirm-ticket-reuse/`). A mentioned ticket with no designator
  now returns a closed question instead of silently naming the feature. The
  question is a proposal rather than an abstract choice: it names every
  detected issue by key, summary, type and status, and states the role each
  would be attached in using the project's **own configured type names**,
  never an internal label or an Atlassian default. Two answers, no third and
  no free-form one. It writes nothing, creates nothing, issues no Jira
  request beyond the resolution the run already performed, and exits `0` —
  a question is not a failure, and the host command it runs inside completes
  normally.
- **`--reuse yes|no`** conveys the answer on a second invocation. `--reuse
  yes` accepts the proposal and routes straight into 027's seeding flow,
  deriving the `--parent`/`--story` designators from the roles the question
  already computed — no extra round-trip, and byte-identical to typing those
  designators by hand. `--reuse no` proceeds exactly as the previous release
  did. Absence means unanswered: no default is substituted for the one
  question this feature exists to ask, and a terminal is never probed, since
  the bridge runs inside lifecycle hooks and never has one.
- **A type the configured hierarchy maps to no role is proposed, not
  refused.** A `Bug` where the project declares Epic and Story is offered in
  the story role and needs no parent; only an issue carrying the *other*
  role's declared type refuses, at the question, before any answer. Every
  refusal reachable on this path also states the escape that always exists —
  decline, and the extension creates the specification-role issue plus one
  story-role issue per drafted user story.
- **A pasted browser URL now counts as naming a ticket**, not only a bare
  key, and every further key-shaped token in the same request is detected
  too, in the order it was typed. The leading positional alone still computes
  the branch and folder names, so reordering the words cannot rename a
  feature.
- **Guidance instead of silence when no team configuration applies.** Naming
  a ticket in a repository whose configuration declares no applicable team
  now names the file to fix (`.specify/jira/config.yml` or
  `.specify/jira/personal.yml`) and the command that fixes it. Neither report
  issues a Jira request nor fails the host command; a run naming nothing
  keeps the previous release's exact output.

### Fixed

- **A mentioned ticket was named but never bound, so the next reconcile
  created a duplicate parent beside it.** This is the incident the release is
  built around: `speckit.jira.feature` wrote no marker for the ticket it had
  just used to name the feature, leaving nothing for reconcile to recognise.
  Answering the new question with `--reuse yes` binds the ticket instead, and
  the reconcile that follows reuses it and creates zero parents.
- **The non-blocking fallback promised the opposite of what happens.** It
  claimed reconciliation "will attach it later" when nothing had been bound —
  reassurance about exactly the defect above. It now names the real cause
  (credentials rejected, the issue not found or not visible, Jira
  unreachable, or the error status returned) and states the real outcome:
  the next reconcile creates a new issue for this specification.

## [0.18.1] - 2026-08-17

### Fixed

- A scenario written the spec-kit template's own way —
  `1. **Given** …, **When** …, **Then** …` on one line — reached the ticket as
  three copies of the whole unsplit line, each opening with a stuttered
  `Given **Given** …`/`When **When** …`/`Then **Then** …` keyword. The
  clause recogniser accepted the emphasis wrapper (`**`/`__`/`*`/`_`) only
  *after* each keyword and never *before* it, and only on the one-clause-
  per-line path; the single-line triple recogniser's delimiter-free fallback
  then fell back to a glob strip that silently returns its input unchanged
  when it fails to match, assigning the entire line to `given`, `when`, and
  `then` alike. The two ports diverged on the same input: the bash port
  triplicated the line, the PowerShell port dropped the scenario and
  returned an empty panel — a live Constitution VI divergence, since no
  existing conformance fixture exercised the template's own default form.
  Fixed identically in both ports: the wrapper is now optional on both sides
  of every keyword, and a line that cannot be split cleanly emits no
  scenario rather than guessing (fail-closed). A scenario wrapped across
  several indented lines — the form every specification in this repository
  actually uses — is now also read as one scenario instead of an empty
  panel. The renderer (`_adf_gherkin_panel` and its PowerShell twin) was not
  touched; the stutter was entirely a parser defect.
- A scenario wrapped just before its own `**Then**` — a wrap the previous
  fix correctly refuses to join into one logical line, since the
  continuation itself opens with a keyword — reached the ticket either with
  an empty `When` clause carrying a stray `**When**` swallowed into `Given`,
  or, when a well-formed scenario followed it, silently merged into that
  next scenario's clauses, collapsing two authored scenarios into one.
  Measured across this repository's own specifications: 59 of 554 emitted
  scenarios (10.6%) carried an empty `given` or `when`, in 22 of 24
  specification files. Both ports now refuse to emit a scenario unless
  `given`, `when` and `then` are all non-empty, and discard an incomplete
  scenario's state before a new `Given` starts rather than merging into it.

- The test harness gave a starting PowerShell mock exactly 10 seconds to bind
  its socket and write its readiness file. Feature 009 measured that cold
  start at 0.5–1.0s locally, but a contended CI runner is an order of
  magnitude slower, so the ceiling was close enough to fire: when it did, the
  harness reddened whichever unrelated test had called `mock_start` next —
  on one run `test_config_child_type.bats`'s "the PowerShell port resolves the
  child type identically (NFR-1)", a message that reads like a port
  divergence although the assertion never ran. The budget only ever bounded a
  *live* child (a mock that exits is detected separately and immediately), so
  it is now 60 seconds in both ports, costing a genuine failure nothing. Both
  ports read the value from a named constant and interpolate it into the
  failure message, and a new guard fails if the two drift apart or if the
  reported budget stops matching the enforced one.

## [0.18.0] - 2026-08-15

### Added

- **Seed a specification from existing Jira issues** (`specs/027-seed-spec-from-jira/`).
  `/speckit.jira.feature` accepts repeatable `--parent`/`--story` designators —
  a key, a full issue URL, or (for the specification role only) free text — and
  resolves the whole set in one bulk read before anything is named, handing the
  drafting agent each issue's own summary, description, status, and current
  parent. A new agent-invoked command, `/speckit.jira.seed` — declared in
  `extension.yml`'s `provides.commands` and bound to no lifecycle hook, since a
  confirmation prompt cannot live in one — validates the drafted `spec.md`'s
  pinning markers, renders the write plan and provenance report, and only after
  an explicit `--confirm` binds each named story, adopts or creates the named
  parent, and re-parents a story only onto the parent the operator designated.
  Declining, or running unattended, leaves a **seeded-not-bound** state: the
  draft and the recorded designator set persist, nothing is written to Jira,
  and re-invoking resumes at the same gate. A resume re-reads Jira and
  re-evaluates every refusal class, but never re-drafts `spec.md`; a different
  designator set than the one recorded refuses `REF-RESEED`. A partially
  completed `--confirm` run resumes from exactly what it finished, per issue,
  never retried into a duplicate.
- **Fourteen new refusal classes**, each zero-write, each naming the offending
  designator or marker with a copy-pasteable remediation:
  `REF-DESIGNATOR`, `REF-HOST`, `REF-DUPLICATE`, `REF-EXISTS`,
  `REF-UNRESOLVED`, `REF-ROLE`, `REF-ROUTING`, `REF-MULTIPROJECT`,
  `REF-TERMINAL`, `REF-CLAIMED`, `REF-THIN`, `REF-DECOMP`, `REF-DRAFT-EDIT`,
  and `REF-RESEED`.
- **Re-parenting disclosure.** A named story already parented under a
  different issue than the one the operator designated is moved only on
  explicit confirmation, with a write-plan line rendered `! ` in column 1 —
  the only line that starts there — naming the current parent's key, summary,
  and status, and the number of named stories it will lose (stated even when
  it is one). When no specification-role designator is named at all, an
  already-parented story is disclosed instead — a **scatter note**, in both
  the provenance report and the run's warnings, at exit `0` and zero writes.
- The one-way-read guarantee (FR-009/FR-010) now extends explicitly to this
  feature: the human-authored content that seeded `spec.md` is never read
  again to rewrite it, on the seeding run or on any later reconcile — proven
  by a dedicated regression against a full reconcile with every named issue's
  content rewritten in Jira between seeding and reconciling.

### Fixed

- `ticket_create`'s identity stamp now records the summary it sent, so a later
  reconcile compares against the recorded value rather than reverting a
  human's rename — a gap this feature's own parent-creation path exposed and
  closed for every caller of `ticket_create`, not only this feature's own.
- (PowerShell) `Resolve-JiraDesignatorSet` threw `PropertyNotFoundException`
  under `Set-StrictMode` when the specification-role designator was free text
  (no `.key` at all) — a divergence bash's forgiving `jq .key` never hit,
  first exposed by this feature's own free-text parent-creation path.
- (PowerShell) An empty JSON array round-tripped through the platform's own
  `ConvertFrom-Json`/`ConvertTo-Json` collapsed to `null` rather than staying
  `[]` — bash's `jq` has no such collapse. `Invoke-JiraSeed`'s
  `confirmation_required` payload is now built by direct concatenation of
  already-canonical JSON fragments, sidestepping the round-trip entirely.

### Notes

- The double-run live-zero-churn assertion this feature adds — the identity
  stamp on an adopted issue, the parent-link write, and the parent create —
  is Bash-only (`tests/live/test_live_zero_churn.bats`). There is no
  PowerShell live twin in this repository yet; the asymmetry is recorded here
  rather than silently left uncovered.

## [0.17.0] - 2026-08-15

### Added

- The board-position mapping a team declares — `phase_status_map`, and the
  `halted_statuses` beside it — is now reachable from the files a consuming
  team actually opens. `templates/config.yml.template` documents both keys as
  comments (both accepted shapes, the exact-status-name rule, and the
  single-ungated-transition rule), and the README gains a section naming them.
  Neither key is pre-declared: a template that declared one would move a board
  on the strength of a placeholder nobody chose. No runtime behaviour changes —
  a project that declares nothing is still never moved.
- `/speckit.jira.config` gains two documented steps for the two questions a run
  produces: relaying the task-mirroring question the entry point already prints
  for every project with no `task_mirror` recorded (022, with the
  previously-undocumented `--task-mirror` flag), and proposing a draft
  board-position mapping over the statuses discovered in the operator's own
  project (023). The proposal is the ceremony's one stated exception to
  model-independence, and it is bounded: every status name comes from the
  project's discovered list, a project that already declares a mapping is never
  re-asked, and declining writes nothing.
- `packaging/` — development-only release tooling (excluded from every
  install): `build-artifact.sh` derives the installable surface from
  `.extensionignore` via git's own ignore engine and writes a deterministic
  archive; `verify-artifact.sh` gates it (entry/size/path bounds,
  completeness, purity, Windows-hostile names); `publish-artifact.sh`
  cross-checks a release tag against `extension.yml`'s version and attaches
  both asset names, refusing to overwrite an existing one silently.
- `.github/workflows/release.yml` publishes a gated artifact on every
  version tag; `.github/workflows/install-e2e.yml` proves a real install on
  all three operating systems, on both the floor and current `specify`
  host; the cheap gates run on every pull request in `gates.yml`.

### Fixed

- The documented install command (`specify extension add jira --from
  …/archive/refs/heads/main.zip`) never worked: the repository's source
  archive carries 1 638 zip entries against the host's pre-extraction
  ceiling of 512. Releases now attach a purpose-built archive of exactly the
  87-file installable surface — `spec-kit-jira.zip` (version-free, always
  the latest) and `spec-kit-jira-<version>.zip` (pinned) — and `README.md`
  / `INSTALL.md` point at it instead.
- A zip install on a `specify` host below 0.14.3 (the declared floor,
  `>=0.13.0`) left the Bash entry point at `0644`; the prerequisite gate
  then rejected it as missing and advised `--dev`, a route a URL-installing
  consumer does not have. The gate no longer treats a present-but-non-
  executable entry point as fatal, and every documented invocation now
  goes through the interpreter (`bash <path>`), which does not depend on
  the bit having survived.
- `specify extension add --dev` copied this repository's `.git` directory
  (6 165 files, 38 MB) into every consuming repository's
  `.specify/extensions/jira/`. `.extensionignore` now excludes `.git/`.

## [0.16.0] - 2026-08-14

### Added

- `reconcile` now advances a recognised ticket's board position at the
  specification and story tiers, not only the sub-task tier: when a
  dispatched lifecycle event's declared step names exactly one of the
  ticket's real available transitions, the bridge issues it. Any other
  shape — two transitions landing on the declared step, one gated on a
  field the bridge does not hold, or none reaching it at all — withholds
  the move instead, with one warning naming the ticket and the reason; the
  move is never guessed or forced through an intermediate step.
- `phase_status_map` may now be declared once per hierarchy role
  (`specification`, `story`, `task`) instead of once per project, so an
  Epic and a Story on genuinely different workflows each advance on their
  own — a ticket of one role is never compared against another role's step
  name. The existing role-blind shape keeps routing wholesale to `story`,
  unchanged.
- `--dry-run` predicts a resolved move exactly: the preview's action set
  and warnings are identical to the real run's, and the preview itself
  issues no transition request.

### Changed

- The process budget (feature 024's per-item spawn discipline and its argument-routing companion)
  now has a durable, contributor-facing home: `docs/11-process-budget.md`, pointed to from
  `AGENTS.md`. An oversized-argument regression is now caught on every host — including macOS,
  where the equivalent Linux-only symptom previously gave the maintainer's own machine no signal
  at all — via a portable byte-length check (`tests/bash/sink/test_argv_size.bats`).

## [0.15.0] - 2026-08-12

### Fixed

- `SPEC_KIT_JIRA_TIMING=1` no longer crashes on a comma-decimal locale
  (`fr_FR`, `de_DE`, and most of continental Europe and Latin America) —
  under the previous locale-dependent clock read, the failure mode was
  silent on 9 readings in 10 and a hard crash on the tenth. A malformed
  clock reading now degrades the instrument rather than the run.
- The timing report's per-phase request counts, previously always `0` on
  both ports regardless of how many requests a run actually issued, are now
  real: a 61-item reference run correctly attributes all 123 of its
  requests across the phases that issued them. On the PowerShell port this
  was a separate defect from the Bash port's (seven sink modules each
  independently `-Force`-reimporting the module holding the counter, tearing
  it out from under whichever caller had it), not a shared root cause.
- `reconcile` no longer opens and parses `config.local.yml` more than once
  per run; on the machine that motivated this work, the parse of a real,
  large (proportional to portfolio size) `config.local.yml` was measured at
  ~31s, so removing every redundant read and per-line fork it forced
  measurably tightened the run.

### Changed

- Local processing (parsing, gating, planning) no longer forks one external
  process per story, task, or configuration line — reconciling the
  reference specification a second time with double the stories and tasks
  spawns the same number of processes, not twice as many. On unmanaged
  hardware the reference scenario's total time fell from 91.5s to ~58s;
  the phases now dominated by irreducible per-request work (one Jira ticket
  per story) still scale with item count, as expected — only the local,
  spawn-bound cost was the target. On the machine this work was motivated
  by, a real `reconcile` run fell from 154.9s to 17.1s (-89%), with every
  phase but `parse` now under 3.6s.

## [0.14.0] - 2026-08-10

### Added

- A new `task_mirror` setting controls how a story's `tasks.md` list reaches
  Jira: `subtask` (the existing tier, one issue per task) or `checklist`,
  which embeds the same list as a single checklist inside the story's own
  ticket instead. It stays editable afterwards in `config.yml`, and
  `--task-mirror '<project-key>=checklist'` offers the choice on
  `specify jira config`.
- Under `checklist` mode, reconcile keeps the embedded list current exactly
  as the sub-task tier does — a task checked off in `tasks.md` ticks the
  matching entry on the next run — and a switch between the two modes is
  detected and reported rather than silently mixing the representations.

## [0.13.0] - 2026-09-07

### Added

- Windows now shares the same three-rung credential order as macOS and Linux:
  the environment, then a PowerShell SecretManagement vault
  (`Get-Secret -Name spec-kit-jira`), then the gitignored `.specify/jira/.env`.
  Every unavailability path — the module absent, no vault registered, no
  entry named `spec-kit-jira`, a locked vault — falls through silently.
- `SPEC_KIT_JIRA_TIMING=1` prints a per-phase timing report on stderr.

### Changed

- **An unchanged reconcile now performs no tracker read.** A run whose
  `spec.md`, `tasks.md`, `config.yml`, `config.local.yml`, and flags are
  byte-identical to the last fully successful run exits immediately with zero
  Jira requests and zero secret-store consultations. The trade: a change made
  only on the Jira side (a deleted ticket, an edited description, a stripped
  label) is not detected or healed until a local edit, or `--force`, forces a
  full reconcile.
- A changed reconcile now issues one bulk-fetch request ahead of recognition's
  per-key reads instead of one request per recorded ticket, and resolves the
  credential once per run instead of once per request.

## [0.12.1] - 2026-08-07

### Fixed

- Re-running reconcile against an edited specification could leave a ticket
  carrying two Acceptance Criteria sections — the previous run's scenarios,
  then a boundary line, then the current specification's, with no way to
  tell which the team was meant to build. The mirror now decides whose text
  an unbounded description is by the ticket's recorded origin rather than by
  guessing from content: a ticket the mirror created has its region replaced
  in full on every update, and a ticket a human created and handed over still
  has its prose preserved exactly as before. `plan.md` and `tasks.md` updates
  are fixed identically on the parent and the sub-task tier. A ticket already
  carrying a duplicate from before this fix is not repaired automatically —
  it is cleaned up by hand or by recreating the ticket.

## [0.12.0] - 2026-08-06

### Added

- Ticket descriptions now render Markdown as native Jira formatting instead of
  leaving the raw syntax visible. Bold, italic, inline code, strikethrough,
  links, autolinks, headings, bullet and ordered lists, and fenced code blocks
  all convert; anything outside that subset degrades to plain text rather than
  failing the run. Tickets synced by an earlier version carry a one-off
  corrective description rewrite on their next reconcile — after that, an
  unchanged spec produces zero further writes.
- All three tiers are covered: specification, story, **and** the sub-task tier
  added in 0.11.0 (`specs/016-jira-markdown-rendering/`, FR-017). A `tasks.md`
  line names its files in backticks, so a mirrored sub-task previously showed
  those backticks to the reader verbatim. Summaries stay plain on every tier —
  a Jira summary is a plain-text field — as do the identifier, phase,
  attribution, parallel-safety, files and dependency bullets the bridge itself
  composes under a sub-task's body (FR-018).

### Fixed

- A description paragraph carrying a raw string instead of marked spans is now
  refused by interchange validation on every tier rather than rendering
  silently (FR-019). The sub-task tier was the one description position not
  checked, which is how the raw-syntax defect reached it unnoticed.

## [0.11.2] - 2026-08-06

### Fixed

- A description update could overwrite a human's own text added directly in
  Jira, and a Product Owner's rename of a mirrored ticket's title was silently
  undone on the next run. Every managed description now carries a boundary
  marker: content the mirror owns lives below it and is rewritten in full,
  content above it — a human's prose, or a `plan.md` section added inside the
  mirror's own region — is preserved verbatim. A rename that no longer
  matches the mirror's own last-written title is left alone and warned about
  by default (`--on-drift=proceed` to overwrite it deliberately, as before).
  A ticket a previous release wrote gains the boundary on its next ordinary
  write, without losing a word under any circumstance; an existing consumer
  will see this one-time transition as ordinary `updated` counts, with a
  named warning only where the mirror's own former output could not be
  identified unambiguously — see INSTALL.md.

## [0.11.1] - 2026-08-05

### Fixed

- A lifecycle hook that mirrored the wrong artifact (`plan.md` instead of the
  active feature's `spec.md`) created duplicate tickets: `reconcile` now
  refuses before any request when its target's basename is not `spec.md`,
  naming the correct file when one exists in the same folder, and reports
  stray `speckit-jira` marker comments left behind in sibling artifacts by the
  earlier defect (never touching them).
- Every ticket the mirror creates or manages now carries a `speckit-<slug>`
  label naming its specification folder, back-filled once on tickets that
  predate this release and merged with any labels an operator already added.
  An existing consumer will see this back-fill as ordinary `updated` counts on
  its next run — and, where a `task` role is declared, as
  `counts.tasks.updated` for the sub-tasks feature 012 mirrors — see INSTALL.md.
- Before creating a parent a specification holds no marker for, `reconcile`
  now looks for tickets already carrying that specification's provenance
  label and refuses rather than risking a duplicate — a best-effort,
  read-only mitigation on top of the marker-line fix above, droppable
  independently of it.

## [0.11.0] - 2026-08-04

### Added

- Every checked and unchecked line in `tasks.md` mirrors as a Jira sub-task
  nested under its user story's issue (`specs/012-jira-task-subtasks/`). A
  durable task identifier is spliced into `tasks.md` the same way a story
  identifier is spliced into `spec.md`, story attribution follows the
  enclosing `## Phase … User Story <N>` heading (or an explicit `[US<N>]`
  tag, which wins over the heading), and the sub-task's description carries
  the task's own text, referenced files, and `depends-on` list.
- Checking a task off in `tasks.md` transitions its recognised sub-task to a
  done-category status on the next reconcile run — never guessed: the run
  reports when no destination transition exists, or more than one does
  (FR-033). A sub-task already completed in Jira never re-checks the box the
  other direction.
- The sub-task type joins the field-defaults mechanism feature 011 scoped to
  `specification` and `story` (FR-025/FR-026): a project whose sub-task type
  requires a custom field beyond what the bridge supplies now records a
  default for it through the same config-ceremony question and the same
  `--field-default` / `--field-value` / `--accept-defaults` flags, rather
  than being refused or silently skipped.
- `counts.tasks` (created, updated, transitioned, unchanged, skipped,
  withheld) appears in the run summary only when a `task` role is declared —
  its absence keeps a run with no task tier byte-for-byte identical to
  before this feature (FR-011). A completed transition is never folded into
  `counts.updated`.

### Changed

- `commands/speckit.jira.config.md` and `commands/speckit.jira.reconcile.md`
  document the task tier: sub-task creation, completion transitions, and the
  sub-task's own field-default questions.

## [0.10.2] - 2026-08-04

### Fixed

- A recorded field default on a select-list (or other non-free-text) custom
  field is now sent in the shape its field accepts, instead of the bare
  string the operator typed. Jira's `createmeta` reports a field's declared
  type at discovery time; the resolver that joins a recorded default to its
  field id now reads that type too, and shapes the value for the wire — an
  `option` field as `{"value": ...}`, a `priority`/`resolution`/`version`/
  `component`/`group` field as `{"name": ...}`. Previously the bare string
  made Jira refuse the very first creation, so a project with one mandatory
  single-select field mirrored nothing at all
  (`specs/015-fix-field-default-encoding/`). Every operator-facing surface —
  the confirmation question, the provenance note, and the `--field-default`
  promotion command — keeps showing the plain recorded value; only the
  payload sent to Jira changes.
- The run summary's `counts.created` now reports the number of tickets Jira
  actually confirmed, never the number merely planned: a refused creation no
  longer inflates the count, and a fully successful run is unaffected.
- `/speckit.jira.config` now refuses a recorded field default that falls
  outside its field's enumerated allowed values at configuration time,
  naming the field and the accepted values — the same rule the
  `--field-default` flag already enforced, now also applied to values
  already sitting in `config.yml`. The recorded value itself never appears
  in the refusal. The check applies to recorded _text_ only: a value an
  operator wrote by hand as a structure — the escape hatch for a field
  shape the bridge does not derive — is still obeyed literally.

### Fixed (incidental)

- A parent (epic) creation's `creating`/bound marker write, in the Bash
  port's `apply_writes_with_recognition`, called two functions
  (`spec_marker_mark_creating`, `spec_marker_record_ticket`) from a module no
  caller ever sourced — silently swallowed until now, since nothing
  previously depended on this function's stdout being clean JSON. Fixed by
  sourcing `engine/spec_marker.sh` from `sink/jira/plan_apply.sh`, alongside
  the sibling `engine/story_marker.sh` it already sources.
- The PowerShell port's confirmation-question type ordering (`Invoke-JiraReconcile`)
  diverged from the Bash port whenever more than one issue type had a
  creation pending in the same run: the Bash port's `jq unique` sorts, while
  `Select-Object -Unique` only deduplicates, preserving first-seen order.
  Both ports now sort ordinally.

## [0.10.1] - 2026-08-04

### Fixed

- A Jira label, option name, or other string value containing `"` or `\` no
  longer refuses the whole configuration write with `EXIT_CONFIG`
  (`specs/013-fix-yaml-string-escaping/`). The writer now escapes both
  characters (`\"`, `\\`) inside the double-quoted scalars it already emits,
  and the reader undoes exactly those two sequences on the next run — a
  backslash forming no recognised escape is kept literally, so every
  hand-maintained `config.yml` that loads today keeps loading. **Behaviour
  change**: a double-quoted scalar containing a recognised escape sequence now
  decodes to the text it denotes; a deployment that was reading such a value
  with the backslash still in it will see it disappear on the next run. The
  refusal itself narrows to the one case this dialect genuinely cannot
  represent — a string value containing a line break — which previously wrote
  successfully with `EXIT_SUCCESS` and produced a `config.local.yml` that
  failed to parse on the next read.

## [0.10.0] - 2026-08-03

### Added

- Recorded field defaults, so a project whose written issue types require a
  custom field beyond what the bridge supplies is no longer refused outright
  (`specs/011-jira-field-defaults/`). The config ceremony asks about every
  field Jira's create metadata marks required, once per project, for the
  `specification` and `story` types; the answer is spliced into `config.yml`'s
  new `field_defaults` managed region and survives every later run
  byte-for-byte. An optional defaultable field is recorded the same way
  through the new repeatable `--field-default <KEY>=<Type>=<Label>=<Value>`
  flag, or by hand, without ever being asked about.
- A consolidated confirmation before a creating reconcile run sends a
  recorded default or still leaves a required field unsatisfiable: the run
  stops before any write and reports every such field once. The new
  `--accept-defaults` flag proceeds with the recorded values (also the
  non-interactive answer for CI and unattended runs); the new repeatable
  `--field-value <KEY>=<Type>=<Label>=<Value>` flag overrides one for that
  run only. `--dry-run` predicts the same values through the same code path.
- When nothing is recorded and no answer can be obtained, the pre-existing
  refusal now names each unsatisfiable field by its Jira label and carries a
  copy-pasteable `speckit.jira.config --field-default …` remedy line.

### Changed

- `commands/speckit.jira.config.md` and `commands/speckit.jira.reconcile.md`
  document the new closed field-default questions, the consolidated
  confirmation, and the unreachable-operator contract (a caller that cannot
  reach an operator must pass `--accept-defaults` on its first invocation;
  the entry point never sniffs a TTY).

### Fixed

- `.extensionignore` now also excludes `docs/`, `AGENTS.md`, `CLAUDE.md`,
  `.gitattributes`, and `testResults.xml` from `specify extension add`.
  `docs/` and the two instruction files describe how this repository builds
  the extension — the engine/sink boundary, the Windows probe loop, the
  contributor conventions — none of which a consuming repository needs, and
  `docs/` cites `.specify/memory/constitution.md`, itself development-only, so
  shipping either would plant broken links or hand a coding agent working in
  the consumer's repository marching orders that do not apply there.
  `.gitattributes`' `* text=auto eol=lf` is unanchored and would impose this
  repository's line-ending policy — which exists to protect its own Windows
  test fixtures — on the consumer's tree. `testResults.xml` is the same class
  of local-only test artifact `coverage.xml` was already excluded for.

## [0.9.0] - 2026-08-02

### Added

- A committed `hierarchy` mapping under `projects[]` in `config.yml`
  (`specification` / `story` / `task` → issue type name), and a repeatable
  `--issue-type <PROJECT_KEY>=<specification|story|task>=<name>` config flag,
  for an instance whose hierarchy is ambiguous at more than one tier — e.g. a
  project offering both `Epic` and `Service Category` at the level above
  `Story`. The resolver evaluates all three roles in one pass (declared →
  operator → derived) and reports every unresolved tier together, instead of
  refusing on the first one and hiding the rest. `--child-type KEY=<name>`
  is kept as the accepted alias for `--issue-type KEY=story=<name>`. A
  repository that declares no `hierarchy` key and offers exactly one
  candidate at each tier is unaffected — same derivation, same output, byte
  for byte.
- `tests/conformance/mock-jira/curl-shim.sh` — a scripted `curl` replacement
  (pure `bash` + `jq`, no process, no port) that backs the Bash port's mock
  Jira double, reached through the unchanged `mock_start`/`mock_stop`/
  `mock_calls` contract. Replaces spawning a fresh PowerShell mock server per
  test across all 35 mock-dependent Bash test files. The PowerShell port's
  conformance runs still use the real `mock-server.ps1`, and the two are
  continuously cross-checked by the conformance corpus.
- `tests/run-bash.sh` — a dependency-free parallel Bash test runner. Shards
  across cores via `xargs -P` (POSIX, always present) instead of `bats --jobs`
  (which needs GNU `parallel` and silently runs 0 tests without it). Never
  reports success while executing 0 tests or 0 files. Supports `--since <ref>`
  for a change-scoped local inner loop (fail-open to the full suite on any
  doubt; never used in CI).
- CI caching for the Pester module and the `uv`-installed `specify-cli`
  (`.github/workflows/ci.yml`), and a 15-minute budget on the `coverage-bash`
  gate (`.github/workflows/gates.yml`).
- CI caching for the pinned `bats-core` install and apt package downloads on
  the `coverage-bash` gate, and for the Pester module on `coverage-pwsh`
  (`.github/workflows/gates.yml`).
- `.github/workflows/bash-suite-stability.yml` — a scheduled, non-blocking job
  that runs `tests/run-bash.sh` 20 consecutive times nightly and reports, as
  ongoing evidence the parallel suite never flakes.

### Changed

- The Bash test suite no longer requires PowerShell or GNU `parallel` to run
  locally — only `bats` and `jq`.
- `tests/conformance/run-scenario.sh` selects the mock backend by port: the
  curl shim for `bash`, the real PowerShell server for `powershell`.

### Fixed

- `tests/run-bash.sh` silently executed 0 tests per file on Debian/Ubuntu when
  invoked from inside another bats run (as its own meta-tests do on CI): the
  outer bats prepends its private libexec directory to `PATH`, and
  Debian's packaging ships that libexec `bats` without the wrapper environment
  it needs, so it discovers no tests (`1..0`, exit 0). Each worker now strips
  the injected libexec directory from `PATH` and scrubs the outer run's
  exported `BATS_*` state before starting the inner bats. Covered by a
  regression test that simulates the Debian split on any host.
- The runner meta-tests themselves carried two Linux-only defects: their
  fixture suites were written through heredocs whose column-0 `@test` lines
  bats 1.10 (Debian/Ubuntu's package) preprocesses away before bash ever runs
  the file, and their "GNU-parallel-free PATH" dropped `/usr/bin` wholesale on
  images where the bats package pulls GNU `parallel` in as a Recommends.
  Fixtures are now assembled at run time and `parallel`-carrying directories
  are shadowed rather than removed. The shadow cleanup also failed the whole
  file on hosts with no GNU `parallel` anywhere on PATH (the GitHub macOS
  runner): an `[ -n ] && rm` last line in `teardown` exits 1 on the empty
  case and a non-zero teardown fails every test in the file.
- `tests/run-bash.sh` now reprints a failing file's `#` diagnostic lines (not
  just its `not ok` verdicts) and names the `bats` version in its banner — a
  failure that only reproduces on a CI host was undebuggable from the summary
  alone.
- The `coverage-bash` gate's traced suite and its suite-green rescue check now
  run through the parallel `tests/run-bash.sh` instead of a serial `bats -r`,
  which had outgrown every wall clock the job owns (the gate had been red on
  `main` since the suite passed ~900 tests).
- A latent race in `scripts/bash/engine/story_marker.sh`: the
  `SPEC_KIT_JIRA_ID_SOURCE` test-determinism cursor was keyed only by the
  owning process's PID, so a PID reused by an unrelated, already-dead process
  could inherit a stale cursor under heavy parallelism (observed as an
  intermittent conformance divergence). The cursor is now keyed by PID plus
  that process's own start time.
- The PowerShell port's role-mapping resolver matched a declared or answered
  issue-type name with `-ceq`, which is case-sensitive but still
  culture-aware: it treated an NFD name (a base letter plus a combining
  accent) as equal to the project's NFC form of the same name, silently
  accepting a byte-different declaration the Bash port's `jq ==` would
  correctly refuse as unknown. Matching now uses an ordinal
  `[string]::Equals`, restoring the contract's byte-equal matching rule
  (contracts/role-mapping.md §3.3) and cross-port parity.

## [0.8.0] - 2026-08-01

### Added

- Every specification now mirrors as one parent Jira issue plus its children,
  not just the children on their own. The parent is created first, before any
  child, and every child's creation carries the parent's key. Its own durable
  identifier is recorded in an HTML comment line beside the document's title,
  read back on every later run so the parent is recognised rather than
  recreated.
- The parent's description carries the specification's overview prose, a
  named Success Criteria section, and a named Out of Scope section — never a
  list of user stories, since Jira already shows the children under their
  parent in its own issue view.
- When the feature folder holds an implementation plan, the parent also
  carries a named Implementation Plan section built from `plan.md`'s
  `## Summary` prose. A later run replaces that section in place; an
  unchanged plan is not rewritten.
- The child issue type is the operator-recorded (or unambiguously derived)
  answer already in use; the parent type is now derived from the project's
  own issue-type hierarchy — the level immediately above the child's, when
  exactly one type occupies it. A project with no such level, or two or more
  candidates at that level, refuses before any write, naming every candidate
  by its own Jira name — no Atlassian default name is ever assumed.
- A project whose parent type declares a required field this bridge cannot
  supply, or whose child type's create metadata offers no `parent` field at
  all, refuses before any write, naming every unsatisfiable field of every
  affected type in one message. Both refusals are reported as their own
  named cause, never a transport or rejected-request error, and `--dry-run`
  predicts them exactly as a real run would.
- A child ticket that already carries a parent link, but the WRONG one, is
  re-linked to the correct parent on a later run, counted as a write; an
  already-correct link is left untouched, and a child carrying no parent
  link at all (a flat mirror from before this release) is never touched —
  see the Migration note below.
- CI now runs `shellcheck` over the Bash port and `Invoke-ScriptAnalyzer`
  over the PowerShell port as a blocking lint gate, per the repository's own
  `.shellcheckrc` and `PSScriptAnalyzerSettings.psd1`.

### Fixed

- On Windows, the Bash port and the PowerShell port disagreed byte for byte
  whenever a command handled more than one of something — two project keys,
  three stories, a multi-line configuration document. The native `jq.exe`
  writes its stdout as a text-mode stream, so every line but the last carried a
  stray carriage return: `config.local.yml` came out CRLF-terminated where the
  PowerShell twin wrote LF, a second project key was read as an unknown key,
  and a hook-health repair hint came out truncated. The Bash port now strips
  that terminator artefact — once, around `jq` itself, and only on a host whose
  `jq` actually emits CRLF — and the two ports produce identical bytes again.

### Removed

- Three configuration keys from an earlier, never-built mechanism —
  `epic_strategy`, `task_strategy`, `link_type` — are now refused wherever
  they appear in `config.yml`, naming the project and the retired key.

### Migration note

Mirrors created before this release carry no parent. Reconciling one of them
again does not retroactively attach a child that carries no parent link at
all to a newly created parent — that flat-mirror case is never touched — so a
full hierarchy for an existing specification is only available by
re-mirroring it from a clean state, or by creating the parent by hand in
Jira and recording its key in `spec.md` under the same marker grammar
reconcile uses for its own writes. A child that already carries A parent
link, just the wrong one, is a different case and IS corrected on a later
run (see Added, above).

Every repository already bound to a Jira project (every installation that
ran `/speckit.jira.config` before this release) will see its first
`reconcile` after upgrading refuse once, before any read, naming the
project and saying its local binding "predates parent support". This is
expected — the project is already bound, its binding is simply a version
behind — and it costs nothing: zero writes, and running
`/speckit.jira.config` once resolves it permanently. See INSTALL.md,
"Upgrading to the parent-hierarchy release".

## [0.7.0] - 2026-07-31

### Fixed

- A local binding whose issue types, priorities, or statuses carried the
  Jira instance's own language or ordinary punctuation (accented or
  non-Latin names, parentheses, slashes) was silently truncated on read —
  the configuration reader accepted a mapping key only from a short
  enumerated character set, and stopped parsing at the first line outside
  it. The reader now recognises a mapping entry by line structure instead,
  and the writer quotes every key unconditionally so the round trip stays
  closed.
- A configuration line the reader could not interpret was discarded
  silently, with exit 0 and a truncated document reaching every caller. The
  parser now fails closed with a located, actionable message (file, line,
  content, remediation) and `EXIT_CONFIG` (4); reconcile performs zero Jira
  writes and a lifecycle hook downgrades to one `WARNING:` line rather than
  failing the host command.

## [0.6.0] - 2026-07-30

Reconcile recognises the tickets it already created (005).

`plan_writes` decided create-versus-update from a `tickets` map that only an
explicit test override ever filled, so on a normal run the map was always
empty and every user story was planned as a creation — running any lifecycle
command twice mirrored every story again, duplicating every ticket it had
already created seconds earlier.

- **Each user story now carries a durable identifier**, recorded in one HTML
  comment line immediately after its heading in `spec.md` and stamped on the
  ticket's own identity property. The identifier is assigned once, survives a
  retitle, a reorder, and a specification-folder rename, and is never
  recomputed.
- **A recognition step now runs before every write**: one direct read per
  recorded ticket (never a search — Jira's search index is eventually
  consistent, and the reported defect happened between two lifecycle
  commands seconds apart) verifies the ticket's identity marker and decides
  create-versus-update accordingly. A second run over an unchanged
  specification now writes **nothing** to Jira at all.
- **The run summary gains `recognised`, `assigned`, and a populated
  `skipped`** (previously hard-coded to `0`), in both `--json` and the default
  prose, so a reader can confirm an unchanged re-run did nothing rather than
  mirrored nothing.
- **The drift, Flagged, and blocker safety rules now engage** against real
  recognised ticket state — a ticket advanced beyond its expected phase is
  named in a warning and never silently overwritten, and a Flagged ticket's
  transition is withheld — while this release still never moves a ticket's
  status: no transition request is ever issued.
- **A marker naming a ticket outside the routed project is mirrored into the
  routed project** rather than blocked; the former ticket is left untouched.
- **Existing tickets are not migrated.** A ticket created before this release
  carries no marker and cannot be recognised: the first reconcile after
  upgrading will mirror its specification afresh, producing one duplicate
  generation. This is the one user-visible cost of the fix — after that first
  run, every subsequent run is idempotent as described above.

## [0.5.0] - 2026-07-29

Documented first-time setup, per platform.

The install ceremony was documented; the environment it needs was not. A new
user reached `/speckit.jira.config` with no token stored anywhere and no site
URL exported, and the degraded run was the first thing that told them so.

- **The README carries a per-platform walkthrough** — macOS, Linux, and Windows
  each get the ordered steps from prerequisites to the first mirrored spec,
  naming the three connection settings and where each one is resolved from.
- **The managed README block carries the same walkthrough in condensed form**,
  so a consuming repository documents its own setup without linking out.
- **The hook-environment caveat is stated**: the agent's shell does not always
  load a profile, so the two non-secret settings can be declared per project in
  `.claude/settings.json`.
- **The command-literal gate now covers the shipped documentation** —
  `README.md`, `INSTALL.md`, and `templates/*.template` join the scripts and
  command documents already checked, and it accepts both runnable forms of the
  install: the archive install an operator runs and the dev install with
  `--force`.

## [0.4.0] - 2026-07-29

Reconcile resolves its own routing and plan context from config (004).

`reconcile` never read the repository's own configuration. It took the project
key from an environment variable nothing set, fell back to the placeholder
`PROJ`, built an empty creation context, and then assembled a creation payload
that declared no project at all — the destination service's "the project field
is required" rejection. Four defects sat on one failure path; the last of them
produced the reported symptom.

This release wires the mirror to the config it already reads for every other
purpose:

- **Routing** now resolves from the team config's routing rules and
  `routing_default` — no environment variable required for a bound repository.
  A resolved key that is absent, syntactically invalid, or equal to the shipped
  placeholder is refused before any write; the removed built-in `PROJ` fallback
  is the only behaviour change for callers who override the project key.
- **The creation context** (issue type, priority, estimation field) now builds
  itself from the persisted binding for the resolved project, with the
  machine-owned layer winning over the committed one.
- **Every planned creation now declares its project and issue type in the
  payload itself**, guarded before dispatch — the mirror path and the feature
  ceremony's single-item creation path now agree on what a valid creation
  contains.
- **Team-managed projects mirror exactly as correctly as company-managed
  ones**: payload contents follow what the resolved project's own create
  metadata reports it accepts, never a rule keyed on project style. Priorities,
  previously discovered site-wide and stored per project, are now derived per
  project from its own create metadata.
- **Four new diagnostic causes** — unresolvable routing, a placeholder
  binding, a routing rule naming an undeclared project, and a project with no
  persisted binding — each name their own remedy, make zero Jira requests, fail
  closed on direct invocation, and downgrade to a single warning under a
  lifecycle hook.

Both ports carry identical changes; the conformance suite proves it with two
new golden scenarios (company-managed and team-managed routing).

## [0.3.0] - 2026-07-28

Hooks active from installation (003).

The extension registered no lifecycle hook at install, registered them itself as
_optional_ (which the host reads as "offer this", not "perform it"), pointed them
at a `speckit.jira.reconcile` command that did not exist, and told the assistant
to invoke a bare `spec-kit-jira` executable the install never provides. Four
independent breaks, each sufficient on its own to make the extension inert. This
release closes all four.

### ⚠ Behaviour changes for existing users

- **`reconcile --repair-hooks` is REMOVED.** It existed only to write the hook
  registry, which this release makes read-only to the extension. Passing it is now
  a usage error (exit `1`) rather than a silent no-op: a flag named "repair" that
  no longer repairs would be worse than none. Nothing replaces it — a genuinely
  missing entry is restored by re-running the official install:
  `specify extension add --dev <path-to-spec-kit-jira> --force`.

- **A registry written by 0.2.0 or earlier needs a ONE-TIME MANUAL CLEANUP.**
  Earlier versions wrote four-field hook entries carrying no owning-extension
  field. The official install purges its own entries by matching on that field,
  so it does not recognise them: instead of replacing each one it adds a second
  entry beside it, and every lifecycle step fires twice. Neither the host nor this
  extension can remove them.

  The configuration ceremony reports this as `duplicated` and names every affected
  event. The edit is: open `.specify/extensions.yml` and, under each named event,
  delete the entry that has **no** `extension: jira` line. For example —

  ```yaml
  hooks:
    after_plan:
      - command: speckit.jira.reconcile # ← DELETE this entry (no `extension:` field)
        description: Mirror the updated spec-kit artifacts into Jira Cloud (non-blocking).
        enabled: true
        optional: true
      - extension: jira # ← KEEP this one (written by the install)
        command: speckit.jira.reconcile
        enabled: true
        optional: false
        priority: 10
        prompt: Execute speckit.jira.reconcile?
        description: Mirror the implementation plan into Jira Cloud.
        condition: null
  ```

### Added

- The extension manifest declares all seven lifecycle events (`before_specify`
  plus the six `after_*`) as a **top-level `hooks:` block**, so `specify extension
add` registers and activates them with no configuration ceremony. A block nested
  under `provides:` validates and registers nothing, which is what shipped before.
- `speckit.jira.reconcile` now **exists**: a declared, installed, assistant-
  invocable command with an ordered procedure. Six `after_*` hooks had named it
  since 0.1.0 without it ever being created.
- Every hook entry is registered `optional: false`, so the assistant **performs**
  the mirroring step as part of the host command instead of offering it. This
  changes dispatch only — a hook failure still never fails a spec-kit command.
- An operator disable record in the gitignored `.specify/jira/config.local.yml`
  (`hooks.disabled`), honoured at dispatch. It exists because `specify extension
add` rewrites `enabled: true` unconditionally, so the registry cannot remember
  the decision across a reinstall.
- `/speckit.jira.config --enable-hook <event>` (repeatable) releases a held event.
- The hook health report gains `held_disabled`, `duplicated` and `unreadable`, and
  the ceremony reports its hook effect as `healthy` / `incomplete` /
  `held_disabled` / `duplicated` / `unreadable` — a verification vocabulary,
  because it no longer writes anything.
- A scratch-repository install harness and conformance suites that drive the REAL
  `specify extension add`, so what the install actually writes is verified rather
  than assumed.

### Changed

- **The hook registry is read-only to this extension, in every state, from every
  command.** `.specify/extensions.yml` is never created, modified, truncated,
  reordered or reformatted; the operator's comments survive every run. The
  registrar's writer is deleted rather than guarded — this extension's YAML reader
  models a restricted subset and drops comments, so every write it performed
  damaged a file it neither owns nor can faithfully reproduce.
- Every documented procedure invokes the bridge by its **repository-relative
  per-port path** (`.specify/extensions/jira/scripts/bash/spec-kit-jira.sh`, or
  the `powershell/spec-kit-jira.ps1` twin) instead of a bare `spec-kit-jira`
  name. The install places nothing on `PATH`, so the bare name resolved to nothing
  — the source of the reported "spec-kit-jira CLI not installed" message.
- Degraded runs name the true cause among six distinguished states, emit at most
  one message per host command run, and cap the not-yet-configured notice at three
  lines. Every command literal in every message is now checked mechanically to be
  runnable exactly as spelled.
- All three command documents carry a verbatim fallback block for the one state
  the bridge cannot report on — its own entry point missing — with an instruction
  to emit it exactly rather than improvise.
- `INSTALL.md` and the managed README block state the corrected sequence: the
  install registers and activates the hooks; the ceremony binds the project and
  verifies the registration.

### Fixed

- **The bridge entry point ships executable.** `scripts/bash/spec-kit-jira.sh` was
  committed `0644`, so every documented invocation by path failed with "permission
  denied" in a freshly installed repository — indistinguishable, from the
  developer's side, from "not installed".
- **The YAML reader could not read the registry the install writes.** PyYAML emits
  block sequences at their parent key's indentation; the reader required a greater
  indent and stopped at the key. Every real installation's `.specify/extensions.yml`
  parsed as `{"installed": null}`, so hook health reported a perfectly healthy
  repository unreadable. Both ports fixed.
- **The YAML writer was not a fixed point of the reader.** `key: []` and `key: {}`
  were written for empty collections and read back as the strings `"[]"` and
  `"{}"`. Both ports fixed.
- A bridge fault that returned early — an unparseable spec, an invalid lifecycle
  payload — failed the host command in hook context, because the non-blocking
  downgrade only applied to faults reaching the end of the run. Every failure path
  now goes through it.
- An empty local binding (the state left by releasing the last held event) threw
  on the PowerShell port where the Bash port tolerated it.

## [0.2.0] - 2026-07-27

Reliable automatic Jira discovery & team-based feature prefix (002).

### Added

- Three-valued project-style detection: style comes exclusively from an
  unambiguous API signal (`style_source: api`) or an explicit operator answer
  via the repeatable `--style KEY=VALUE` flag (`style_source: operator`);
  ambiguity fails closed with exit 4 and zero writes — the silent
  `company_managed` default is gone.
- Jira-first project-key sourcing: argument → committed config (the literal
  `PROJ` placeholder counts as unset) → closed question over the paginated
  `GET /project/search` accessible-projects list. Git state is never a source
  in a connected run; undefined connection parameters trigger a loud,
  provisional, write-free degraded mode, and the next connected run surfaces
  catalogue/project mismatches as warnings.
- Team naming conventions: committed `teams:` catalogue, human-owned
  gitignored `.specify/jira/personal.yml` selection, and the new twin-ported
  `feature` command (`speckit.jira.feature`, registered as a non-blocking
  `before_specify` hook) that resolves the ticket first (validate or
  guarded-create), then emits `branch_name` per team pattern and a flat
  deduped `short_name`. No selection ⇒ byte-for-byte previous behaviour.
- Config ceremony gitignore effect: idempotent `.gitignore` coverage of
  `config.local.yml`, `.env`, and `personal.yml`, reported as its own effect.
- Implicit team→project routing fallback: a team-prefixed spec folder routes
  to the team's project when no explicit routing rule matches.
- Bash statement-coverage gate: `tests/coverage/bash-coverage.sh` plus a
  `bash-coverage` CI job on Linux, the twin of Pester's CodeCoverage
  (Constitution XIII). It measures the mocked unit suites the way that
  constitution requires, using two collectors: kcov owns the denominator and
  drives the conformance corpus, while the bats suite is traced on a dedicated
  descriptor — kcov cannot run bats, because it instruments bats-core's own
  DEBUG-trap tracing and the two never terminate. `--mode bats` reports traced
  hit counts on hosts where kcov cannot run the port at all, macOS included.

### Fixed

- The default (prose) run summary now states how each project's style was
  resolved — `    <KEY>: <style> (<style_source>)`, nested under the discovery
  effect and ordered by project key. It was previously visible only under
  `--json`, so the FR-003 audit trail was missing from the default output.
- The literal `\{}` defaults in `feature.sh` and `lib/config.sh` no longer
  kill the bash entry point under `errexit` when `SPEC_KIT_JIRA_PLAN_CONTEXT`
  is unset, and no longer pollute `config_personal_load` stderr; the
  redundant `mktemp` capture around `ticket_create` is gone.
- `feature` command prose output (non-`--json`) no longer renders run-summary
  nulls on bash or raw JSON on PowerShell — both ports now share a dedicated
  twin prose renderer (`_feat_render_prose` / `ConvertTo-JiraFeatureProse`).
- PowerShell discovery no longer fabricates a phantom project from a
  `values`-less page, bypassing the zero-results fail-closed; style-switch
  comparisons are case-sensitive and `simplified` follows `tostring`
  semantics like bash.
- Routing: an empty-string `folder_prefix`/`spec_label` rule condition now
  counts as undeclared, so the shipped template's catch-all rule no longer
  shadows the implicit team route; a `teams` entry without `folder_prefix`
  no longer aborts bash `routing_resolve`.
- The bash `.gitignore` idempotency probe now strips CR, so a CRLF checkout
  no longer causes endless duplicate appends (FR-019); PowerShell repo-root
  derivation no longer throws on a single-component `JIRA_CONFIG_DIR`.
- The prose run summary now renders the `gitignore` effect and the degraded
  run's provisional teams plus rerun guidance; degraded effects gain
  `gitignore: skipped`.
- Hook health now covers the `before_specify` feature hook
  (present/missing/disabled), so a deleted entry is reported instead of
  silently re-added; PowerShell command comparisons in the hook merge are
  case-sensitive like bash.
- `quickstart.md` now documents `trash` instead of `rm -f` for cleanup, per
  the project's file-deletion policy.

## [0.1.0] - 2026-07-25

First public release.

### Added

- Initial twin-port skeleton (Bash + PowerShell 7+), engine/sink separation,
  test tree, lint configuration, and CI shell.
- Deterministic, model-independent `config` install ceremony: byte-identical
  re-run, dual-style (company-managed + team-managed) metadata discovery, and the
  three reported effects — discovery, `after_*` hook registration, and the managed
  README block (US1, US2, US4, US5, US9).
- `reconcile` command: title ladder, never-empty structured description, Gherkin
  panel, distinct Design section, priority by logical name, estimation on create
  only, rendered to ADF and written idempotently through the pre-write privacy
  guard (US3).
- Privacy guard — BLOCK tier (known coordinate / ATATT prefix / real
  `*.atlassian.net` host → exit 9, zero writes) and WARN tier + allowlist
  (`.extensionignore` + `config.privacy.allowlist`, no false positives) (US11, US12).
- Idempotency, status-category drift, fail-closed reads, `--dry-run` twin,
  Flagged withholding, and human-link preservation (US6); origin-discriminated
  managed-panel splice that never overwrites human-authored content (US7).
- Multi-project / multi-team routing with per-project identity scope (US8);
  self-healing `after_*` hooks with `--repair-hooks` and per-run hook health (US9).
- `mention` command: read-only fetch of an existing ticket (content, acceptance
  criteria, priority, labels, status, flag, links, Confluence title+url, parent
  context, siblings), identity stamping, and claimed-by-other refusal (US10).

### Changed

- The SOURCE repository now follows the official Spec Kit extension layout:
  `extension.yml` (official manifest schema with the nested `extension:` block),
  `commands/`, `scripts/`, and `templates/` live at the repository root, and
  `specify extension add` creates `.specify/extensions/jira/` in the consuming
  repository automatically; development-only material (`tests/`, `specs/`,
  `.specify/`, `.github/`, lint configs) is excluded from installation by
  `.extensionignore`. The installed (consumer-side) layout is unchanged.

### Fixed

- Privacy guard fail-open defects: the allowlist now exempts individual matches
  only (the payload is never rewritten, so an overlapping entry can never disable
  detection of unrelated tokens, hosts, or coordinates), `*.atlassian.net` hosts
  are matched case-insensitively, and the PowerShell port de-duplicates known
  coordinates and allowlist entries ordinally like `jq unique` — case variants
  are kept distinct (FR-052, FR-053).
- Cross-port parity: PowerShell enum, label, and config-key comparisons are now
  case-sensitive like the Bash port, so routing and validation decisions no
  longer diverge between ports (NFR-1).
- Flagged/impediment field discovery is locale-independent: the English name is
  only a first-chance match; a localized site resolves the field by shape, so
  flagged-withholding lifecycle safety stays active (FR-036).
- A `config.local.yml` override touching one project no longer drops the other
  projects from the merged configuration (`projects` merges per entry, by key).
- `reconcile` guards every pipeline step: a malformed spec or an invalid
  `SPEC_KIT_JIRA_LIFECYCLE` value now exits with the documented configuration
  code and an actionable error instead of a raw interpreter failure (FR-032).
- `.env` token parsing follows dotenv conventions (`export ` prefix, surrounding
  quotes, CRLF), so a conventional file no longer yields a corrupted token and
  an unexplained authentication failure.
- An inline Given/When/Then triple whose Given clause contains the word "when"
  now splits at the explicit clause boundaries and survives intact (FR-015).
- The `--json` run summary now conforms to `run-summary.schema.json`: hook
  health is reported under `hook_health` as `{present, missing, disabled,
repair_hint?}`, and the contract documents the `actions`, `warnings`, and
  `notes` fields the summary carries (FR-033, FR-047).

[Unreleased]: https://github.com/Fyloss/spec-kit-jira/compare/v0.20.1...HEAD
[0.20.1]: https://github.com/Fyloss/spec-kit-jira/compare/v0.20.0...v0.20.1
[0.20.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/Fyloss/spec-kit-jira/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/Fyloss/spec-kit-jira/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.11.2...v0.12.0
[0.11.2]: https://github.com/Fyloss/spec-kit-jira/compare/v0.11.1...v0.11.2
[0.11.1]: https://github.com/Fyloss/spec-kit-jira/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.10.2...v0.11.0
[0.10.2]: https://github.com/Fyloss/spec-kit-jira/compare/v0.10.1...v0.10.2
[0.10.1]: https://github.com/Fyloss/spec-kit-jira/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Fyloss/spec-kit-jira/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Fyloss/spec-kit-jira/releases/tag/v0.1.0
