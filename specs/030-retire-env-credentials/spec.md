# Feature Specification: Retire the .env credential file

**Feature Branch**: `feat/improve-security`

**Created**: 2026-08-18

**Status**: Draft

**Input**: User description: "Stop using the `.env` file to reach the Jira PAT; adopt the technique used by the spec-kit-figma extension (OS credential store + a retrieval command exported from the shell profile, no plaintext token in the workspace). Also migrate the non-secret settings that live in `.env` today — the user's email address and the Jira base URL — out of it, so `.specify/jira/.env` can be deleted." Clarified 2026-08-18: the retrieval command **replaces** the fixed-service-name secret-manager probe; the Jira base URL goes to the shared `config.yml` rather than to `personal.yml`, because it is identical for every team; no migration path is required.

## Context

Three settings connect this bridge to Jira: a base URL, an operator email, and
an API token. Today all three can come from `.specify/jira/.env`, a gitignored
file that sits inside the workspace. The token additionally resolves through an
ordered chain: the `JIRA_API_TOKEN` environment variable, then an OS secret
manager probed under a fixed service name, then that `.env` file.

The `.env` rung is the exposure this feature removes. A plaintext file in the
workspace is readable by any agent with filesystem access and one careless
`git add -A` away from being committed — the gitignore entry is a convention,
not a boundary. Removing the rung leaves the token in the OS credential store,
where it is encrypted at rest and gated by the OS session, and reachable only
through a retrieval command the operator declares in their shell profile —
outside the workspace, where no pull request can alter it.

The fixed-service-name probe goes with it. It searches one hardcoded location
that nothing in the configuration declares, which makes it invisible to the
operator and impossible to point at a different store. The retrieval command
does the same job explicitly, and supports any credential manager rather than
the two that happened to be wired in.

The two non-secret settings then move to where each of them belongs:

- **The base URL is team-shared.** Every team working against the same Jira
  site uses the same value, so it belongs in the committed `config.yml`
  alongside the other settings a team agrees on once. This is a deliberate
  reversal of the current arrangement, in which the site identity lives in the
  gitignored local layer as `site_alias` and a committed `config.yml` is
  actively refused for holding a Jira host. The consequence is accepted with
  eyes open: the site hostname becomes part of the repository's history. It is
  not a secret, and it grants nothing on its own.
- **The email is per-operator.** It differs for every person on the team, so it
  belongs in `personal.yml`, the extension's existing per-operator, gitignored,
  never-committed surface — which the `config` command will create when it is
  absent instead of leaving the operator to author it by hand.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The token never touches a file in the workspace (Priority: P1)

An operator sets up the bridge on a new machine. They store their Jira API
token in their OS credential store and export one variable from their shell
profile telling the extension how to read it back. Nothing they do writes the
token anywhere inside the repository, and the extension authenticates on the
first run.

**Why this priority**: This is the security outcome the whole feature exists
for. Delivered alone, it removes the plaintext-token-in-the-workspace exposure
even if every other story slips.

**Independent Test**: With no token file anywhere in the workspace and no token
environment variable set, declare the retrieval command and confirm the bridge
authenticates; then confirm no file under the workspace contains the token.

**Acceptance Scenarios**:

1. **Given** the operator has declared a retrieval command and the credential
   store holds a valid token, **When** any command that contacts Jira runs,
   **Then** it authenticates successfully and no token value appears in any
   file, log line, error message, or process argument list.
2. **Given** the token environment variable is set **and** a retrieval command
   is also declared, **When** a command that contacts Jira runs, **Then** the
   environment variable is used and the retrieval command is never executed.
3. **Given** a `.env` file exists in the config directory containing a token,
   **When** a command that contacts Jira runs with no environment variable and
   no retrieval command, **Then** the command fails with an explicit
   credential error naming both supported sources; the `.env` token is not used
   and the file is not mentioned.
4. **Given** the credential-store tool the extension used to probe is present
   and would return a token under the old service name, and no retrieval
   command is declared, **When** a command that contacts Jira runs, **Then** it
   fails with the same credential error — the store is not searched on its own
   initiative. *(Stated in terms of the tool rather than of a populated store:
   no test may provision a real credential store, so what is observed is that
   the tool is never invoked and the token never reaches the run.)*
5. **Given** a retrieval command is declared but it fails, is not installed, or
   prints nothing, **When** a command that contacts Jira runs, **Then** the
   command reports that the retrieval command produced no token — naming the
   command that was run and how it failed — and fails; it never proceeds
   unauthenticated and never falls back to another source.
6. **Given** a retrieval command whose declared value contains shell
   metacharacters (a pipe, a semicolon, a command substitution), **When** it is
   executed, **Then** those characters are passed as literal arguments to the
   program and no shell interprets them.

---

### User Story 2 - The two non-secret settings each live where they belong (Priority: P1)

An operator declares the Jira base URL once in the team's committed
`config.yml`, where everyone on every team picks it up, and their own email
address in `personal.yml`, where it stays on their machine. Neither setting
needs a shell profile any more, so the agent's spawned shells — which do not
reliably load one — can see both.

**Why this priority**: Tied to P1 because `.env` cannot be retired while it is
still the home of two of the three connection settings.

**Independent Test**: Declare the base URL in `config.yml` and the email in
`personal.yml`, unset both corresponding environment variables, and confirm
that a command reaching Jira resolves the correct site and identity.

**Acceptance Scenarios**:

1. **Given** `config.yml` declares a base URL, `personal.yml` declares an
   email, and neither environment variable is set, **When** a command that
   contacts Jira runs, **Then** it uses both file-declared values.
2. **Given** both files declare their setting **and** the corresponding
   environment variables are also set to different values, **When** a command
   runs, **Then** the environment variables win and the run is not refused.
3. **Given** `config.yml` declares a base URL that is not well-formed — a
   trailing slash, a path, no scheme, or an unencrypted scheme to a host that is
   not on the loopback interface — or `personal.yml` declares an email that is
   not a well-formed address, **When** any command loads the configuration,
   **Then** the run is refused with a located error naming the file and the
   offending key, before any network call.
4. **Given** either file holds a value shaped like an API token, **When** the
   configuration is loaded, **Then** the run is refused without echoing that
   value — the token-shape refusal is unchanged on every configuration surface.
5. **Given** `config.yml` declares an email address at any key, or
   `personal.yml` declares a Jira host at any key, **When** the configuration is
   loaded, **Then** the run is still refused — each file is permitted exactly
   one new shape, at exactly one new key.
6. **Given** neither the files nor the environment supply a base URL or an
   email, **When** a command that contacts Jira runs, **Then** it fails with an
   error naming, for each missing setting, both the file and the environment
   variable that can declare it.

---

### User Story 3 - `config` creates personal.yml (Priority: P2)

An operator runs the config ceremony in a repository that has no
`personal.yml`. The command creates the file for them, pre-filled with whatever
it can already resolve, with a commented placeholder for every choice that is
theirs to make — their email and their team selection — and tells them plainly
what is left to fill in, for `personal.yml` and for the team's `config.yml`
alike.

**Why this priority**: Without it, US2 hands the operator a hand-authored YAML
file and a schema to learn. It raises the floor on setup but is not required
for the security outcome.

**Independent Test**: Run the config ceremony in a repository with no
`personal.yml`, and confirm the file is created, is covered by the repository
gitignore, is accepted by a subsequent run, and reports its own state in the
command's structured output.

**Acceptance Scenarios**:

1. **Given** `personal.yml` does not exist, **When** the config ceremony runs,
   **Then** the file is created with the email filled in when it can be
   resolved from the environment, and present as a commented placeholder
   documenting the expected shape when it cannot.
2. **Given** `personal.yml` does not exist and the committed catalogue offers
   teams, **When** the config ceremony creates the file, **Then** it contains a
   commented team placeholder listing those team ids, and no team is selected.
3. **Given** the config ceremony has just created `personal.yml` with the team
   placeholder left commented, **When** any command loads the configuration,
   **Then** the run succeeds with no team selected — the created file is never
   the cause of a refusal.
4. **Given** the committed catalogue offers no teams at all, **When** the config
   ceremony creates `personal.yml`, **Then** the team placeholder says the
   catalogue declares none rather than listing an empty set.
5. **Given** `personal.yml` does not exist and the config ceremony runs with
   the dry-run flag, **When** it completes, **Then** it reports that it would
   create the file and no file is written.
6. **Given** `personal.yml` already exists, **When** the config ceremony runs,
   **Then** the file is left byte-identical — existing values, comments, key
   order, and any keys the extension does not recognise are all preserved.
7. **Given** `config.yml` declares no base URL, **When** the config ceremony
   runs, **Then** it reports that the team's `config.yml` must declare one,
   naming the key and the expected shape — and it does not write `config.yml`.
8. **Given** the config ceremony left a placeholder unfilled or reported a
   missing base URL, **When** it reports its result, **Then** it states which
   settings the operator still has to supply and in which file.
9. **Given** the config ceremony creates `personal.yml`, **When** it completes,
   **Then** the repository gitignore covers the file, exactly as it does today.
10. **Given** the config ceremony has created `personal.yml` once, **When** it
    runs again with no other change, **Then** it writes nothing and reports no
    change — the run is byte-identical to a no-op.

---

### User Story 4 - Unattended and CI runs (Priority: P3)

A run with no operator present — a CI job, or an agent-hosted session — reaches
Jira using secrets injected as environment variables by the platform, with no
credential store and no shell profile available.

**Why this priority**: It is already how CI works today and the environment
variable rung is unchanged, so this story mostly asserts that the feature does
not break it. Low risk, low effort, still worth an explicit test.

**Independent Test**: With only the three environment variables set, no
`personal.yml`, no `.env`, and no retrieval command, confirm a command reaching
Jira succeeds.

**Acceptance Scenarios**:

1. **Given** all three connection settings arrive as environment variables and
   no configuration file declares any of them, **When** a command that contacts
   Jira runs, **Then** it succeeds and prompts for nothing.
2. **Given** a retrieval command is declared in an environment where the
   credential store cannot be unlocked without a human — so the command blocks
   until it exceeds the bound — **When** a command runs, **Then** the failure it
   reports names the retrieval command and the bound it exceeded, not "no token
   configured", and the run ends rather than hanging.

---

### Edge Cases

- **A retrieval command that hangs.** A credential store waiting on an
  interactive unlock must not stall a run indefinitely; the wait is bounded and
  the timeout is reported as a retrieval-command failure.
- **A retrieval command that succeeds noisily.** Trailing newlines and
  surrounding whitespace on the retrieved token are stripped; diagnostic output
  the command writes to its error stream does not become part of the token.
- **The retrieval command is declared inside the workspace.** The retrieval
  command is read only from the operator's environment, never from any
  committed or workspace file, so no pull request can introduce one.
- **Many Jira calls in one run.** The retrieval command is executed at most
  once per run regardless of how many requests follow, preserving the existing
  single-lookup guarantee.
- **A base URL with a trailing slash, or without a scheme.** Refused with a
  located error rather than silently normalised into a URL that 404s later.
- **A base URL on the loopback interface.** Accepted with an unencrypted scheme,
  because nothing crosses a network. The same scheme aimed at any other host —
  including one on a private network — is refused. The check is on the literal
  loopback addresses, so a hostname that merely resolves to one is refused too:
  validation stays a pure string test with no name lookup.
- **A base URL that works as an environment variable but not in the file.**
  Possible by design — the variable is not validated and the file is. The error
  says which key it refused and why, so the difference is diagnosable rather
  than mysterious.
- **A repository whose `config.yml` predates this feature.** It declares no
  base URL, so the setting must come from the environment or the run is refused
  with an error naming the key to add.
- **`personal.yml` is unreadable or malformed.** The run is refused with a
  located error, exactly as any other configuration surface is today.
- **`personal.yml` exists but declares no email.** Legitimate — the email then
  comes from the environment, and the file is not rewritten.
- **`personal.yml` exists but declares no team.** Legitimate, and the state
  every freshly created file starts in: no team is selected, exactly as when
  the file is absent. This reverses today's rule, under which the file's mere
  existence made a team selection mandatory.
- **The team ids listed in the placeholder go stale.** They are a snapshot
  taken when the file was created, and the ceremony never rewrites an existing
  file. A team added to the catalogue later does not appear in that comment;
  the authoritative list is the error message raised when an unknown team is
  selected.
- **A workspace where the config directory does not exist yet.** The config
  ceremony creates what it needs; the absence of the directory is not an error.
- **An operator on Windows whose retrieval command is a PowerShell cmdlet.**
  Documented explicitly, because a cmdlet is not an executable and cannot be
  launched as one from a POSIX shell.

## Requirements *(mandatory)*

### Functional Requirements

#### Token resolution

- **FR-001**: The system MUST resolve the Jira API token from exactly two
  sources, in this order: the token environment variable, then a
  retrieval-command environment variable whose value names a program to run.
- **FR-002**: The system MUST NOT read the token from `.specify/jira/.env`, or
  from any other file inside the workspace.
- **FR-003**: The system MUST NOT probe an OS secret manager under a fixed
  service name of its own; a credential store is reached only through a
  retrieval command the operator declares.
- **FR-004**: The system MUST execute the retrieval command without a shell, so
  that shell metacharacters in its declared value are inert. The declared value
  is split into a program and its arguments on whitespace; a single argument
  that must itself contain whitespace is not expressible, and the documentation
  points such an operator at a wrapper script instead.
- **FR-005**: The system MUST read the retrieval command only from the process
  environment, never from `config.yml`, `config.local.yml`, `personal.yml`, or
  any other file in the workspace.
- **FR-006**: The system MUST treat the retrieval command's standard output,
  with surrounding whitespace removed, as the token. Nothing the command writes
  to its error stream may contribute to the token's value — that stream is
  diagnostic output, and FR-007 requires it to be reported when the command
  fails. "Not part of the token" and "not reported" are different things; only
  the first applies here.
- **FR-007**: When the retrieval command fails, is absent from the system, or
  produces an empty token, the system MUST fail with an error that names the
  command, states how it failed, and points to the credential documentation —
  and MUST NOT continue unauthenticated.
- **FR-008**: When neither source is configured, the system MUST fail with an
  error naming both, and MUST NOT mention `.env` as an option.
- **FR-009**: The system MUST bound the time it waits for the retrieval command
  and report exceeding that bound as a retrieval-command failure, naming the
  bound. The bound is a fixed value, identical in both ports and not
  configurable, so that the two ports report the same sentence.
- **FR-010**: The system MUST continue to execute credential resolution at most
  once per run, and MUST NOT expose the resolved token in any log line, error
  message, execution trace, process argument list, or file.
- **FR-011**: The retrieval command's own failure output MUST be reported
  without echoing anything the command printed on its standard output, since
  that stream may hold a partially-retrieved secret.
- **FR-038**: Every place the system tests for a token MUST obey FR-007,
  including the config ceremony's degraded-mode check. When no retrieval command
  is declared, that check stays silent and the ceremony enters degraded mode as
  it does today. When a retrieval command **is** declared and fails, the reason
  MUST be reported — on the error stream and in the ceremony's structured
  output — and the ceremony MUST still complete in degraded mode rather than
  refuse, because the operator running it is the one who has no working
  credentials yet. Commands that need Jira in order to do anything at all
  continue to fail (FR-007).

#### The base URL, in the shared config

- **FR-012**: `config.yml` MUST accept a Jira base URL as a new top-level key,
  shared by every team the file describes.
- **FR-013**: The system MUST resolve the base URL from its environment
  variable when set, and otherwise from `config.yml`.
- **FR-014**: The system MUST validate the base URL when loading `config.yml`
  and refuse the run with a located error — naming the file and the key — when
  it is malformed, before any network call.
- **FR-039**: The base URL declared in `config.yml` MUST use a scheme that
  protects the credentials sent with every request. An unencrypted scheme MUST
  be refused, **except** when the host is a loopback address, where the request
  never leaves the machine — which is also what makes the file-sourced base URL
  testable against a local test double. The exception MUST NOT extend to any
  other address, including addresses on a private network.
- **FR-040**: The corresponding environment variable is **not** validated, and
  the documentation MUST say so: a value that works when exported may be refused
  when moved into `config.yml`, and the refusal names the key and the reason.
- **FR-015**: The system MUST NOT write `config.yml`; a missing base URL is
  reported to the operator, never filled in.

#### The email, in the per-operator config

- **FR-016**: `personal.yml` MUST accept an operator email address as a new
  key, in addition to the keys it accepts today.
- **FR-017**: The system MUST resolve the email from its environment variable
  when set, and otherwise from `personal.yml`.
- **FR-018**: The system MUST validate the email when loading `personal.yml`
  and refuse the run with a located error — naming the file and the key — when
  it is malformed, before any network call.
- **FR-019**: `personal.yml` MUST remain optional: a run whose email comes from
  the environment and which has no such file MUST succeed.

#### The credential-shape guard

- **FR-020**: The system MUST NOT accept an API token in any configuration
  file, and MUST refuse a run whose configuration holds a token-shaped value,
  without echoing that value. This refusal is unchanged on every surface.
- **FR-021**: The existing refusal of Jira-host-shaped values MUST be relaxed
  for exactly the new base-URL key of `config.yml`, and MUST continue to apply
  at every other key of that file and at every key of `config.local.yml` and
  `personal.yml`.
- **FR-022**: The existing refusal of email-shaped values MUST be relaxed for
  exactly the new email key of `personal.yml`, and MUST continue to apply at
  every other key of that file and at every key of `config.yml` and
  `config.local.yml`.
- **FR-023**: When a setting is missing from both its file and its environment
  variable, the system MUST fail with an error naming both places it can be
  declared.

#### Creating personal.yml

- **FR-024**: The config ceremony MUST create `personal.yml` when it is absent,
  pre-filled with the email when it can resolve one, and MUST represent an
  unresolvable email as a commented placeholder documenting its shape.
- **FR-025**: The created `personal.yml` MUST include a commented placeholder
  for the team selection, documenting its shape and listing the team ids the
  committed catalogue offers, so the file explains its own primary purpose
  without the operator consulting documentation.
- **FR-026**: The config ceremony MUST NOT select a team on the operator's
  behalf — the team placeholder is always commented out, even when the
  catalogue offers exactly one team.
- **FR-027**: A `personal.yml` that declares no team MUST be valid, and MUST
  yield the same inactive team selection an absent file yields today; the run
  MUST NOT be refused. Declaring the file MUST NOT imply declaring a team.
- **FR-028**: The config ceremony MUST leave an existing `personal.yml`
  byte-identical, preserving its values, comments, key order, and any keys the
  extension does not recognise.
- **FR-029**: Creating `personal.yml` MUST honour the dry-run flag: the
  intended creation is reported and nothing is written.
- **FR-030**: The config ceremony MUST report the outcome for `personal.yml`
  (created, unchanged, or would-be-created) in its structured output, and MUST
  name any setting the operator still has to supply and the file it belongs in
  — including a base URL missing from `config.yml`.
- **FR-031**: Re-running the config ceremony after it has created
  `personal.yml`, with nothing else changed, MUST write nothing and report no
  change.
- **FR-032**: The config ceremony MUST continue to ensure the repository
  gitignore covers `personal.yml`.
- **FR-041**: The ignore rule covering `.env` MUST be kept even though nothing
  reads that file any more. An installation predating this feature still has one
  on disk holding a real token, and removing the rule would un-ignore it —
  retiring a reader must not be the change that commits a secret. Documentation
  and comments MUST describe the rule as covering a leftover file, never as part
  of a supported configuration layer.

#### Behaviour preserved

- **FR-033**: The environment-first ordering MUST keep unattended and CI runs
  working with all three settings injected as environment variables and no
  configuration files and no credential store present.

#### Documentation

- **FR-034**: The extension MUST ship credential documentation covering, for
  macOS, Linux, and Windows: storing the token in the OS credential store,
  declaring the retrieval command from a shell profile, the unattended/CI
  arrangement, and the note that a PowerShell cmdlet cannot be launched from a
  POSIX shell without a wrapper.
- **FR-035**: Every document that instructs an operator to create or populate
  `.env`, or that describes the removed secret-manager probe, MUST be updated
  to the new arrangement.
- **FR-036**: The documentation MUST show how to deny an agent access to the
  credential-store commands at the harness level, so the token is unreachable
  from the agent as well as absent from the workspace.
- **FR-037**: The documentation MUST state that the base URL is committed with
  the team's `config.yml`, so an operator chooses knowingly whether their Jira
  site hostname belongs in that repository's history.

### Key Entities

- **Jira API token**: the one secret. Lives in the OS credential store or a
  platform secret store; reachable only through the environment variable or the
  retrieval command; never written to the workspace.
- **Retrieval command**: an operator-declared, environment-only instruction
  naming a program that prints the token on its standard output. Executed at
  call time, without a shell.
- **Jira base URL**: not secret, identical for every team on the site. Resolved
  from the environment or the committed `config.yml`.
- **Operator email**: not secret, different for every person. Resolved from the
  environment or the gitignored `personal.yml`.
- **`personal.yml`**: the per-operator, gitignored configuration surface. Holds
  an optional team selection and overrides today; gains the email; never holds
  a token; created by the config ceremony when absent, with every operator
  choice present as a commented placeholder.
- **`.env`**: retired. Read by nothing after this feature. Its ignore rule
  survives it (FR-041), covering whatever an older installation left on disk.

## Constitution Check *(mandatory)*

| # | Principle | Proof of compliance |
| --- | --- | --- |
| I | The Filesystem Is the Source of Truth, With Two Controlled Exceptions | Adds no exception. `config.yml` and `personal.yml` are existing filesystem surfaces; the token moves *out* of the filesystem into the OS credential store, which is not state the extension owns or reconciles. |
| II | Zero-Churn Idempotency | FR-028 and FR-031 make `personal.yml` creation a one-shot: an existing file is left byte-identical and a second ceremony writes nothing. The commented team placeholder is written once and never refreshed, so it cannot churn either. FR-015 keeps `config.yml` unwritten, so it cannot churn at all. |
| III | Fail-Closed on Writes, Non-Blocking on Hooks | FR-007, FR-008, FR-014, FR-018, FR-023 and FR-039 all refuse before any write or network call. Hook non-blocking behaviour is unchanged: a missing credential fails the bridge command, which the hook contract already tolerates. FR-038 is the one deliberate softening — the config ceremony reports a declared command's failure and continues in degraded mode, because refusing there would withhold the file in which the operator declares their settings. |
| IV | Credential Security — Zero Tokens in the Tree, Ever | **CONFLICT — requires a constitutional amendment before implementation.** In spirit the feature strengthens this principle: FR-002 removes the last in-workspace token file, FR-010 preserves the no-argv/no-log guarantee, FR-011 and FR-020 close the two remaining ways a token could surface. In letter it contradicts three clauses of v1.3.0: (a) "No token, authentication email, real site URL … may ever enter a tracked file" — FR-012 puts the real site URL in the tracked `config.yml`; (b) "Credentials MUST be resolved in this order: environment variables → OS secret manager → gitignored `.env`" — FR-001 keeps two rungs; (c) the secret-manager rung is "SOFT-OPTIONAL … MUST fall through silently" — FR-007 fails loudly when a *declared* retrieval command fails. Replacing the hardcoded probe with an operator-declared command is **not** a conflict: the principle already permits a mechanism swap that satisfies the same requirement. See plan.md §Constitution Check and the Complexity Tracking table. |
| V | Separation of Team Config / Local Binding / Secrets | **Deliberately narrowed by operator decision; the tracked-file half of the narrowing is covered by the Principle IV amendment above.** The secret leaves the tree entirely and the per-operator email lands in the per-operator layer — both strengthen the separation. Against that, the Jira host moves *into* the committed layer, which today refuses it and which stores only a `site_alias` in the gitignored layer instead. The rationale is that the base URL is a team-wide, non-secret setting that every team resolves identically, so the committed layer is where a team agrees it once. FR-021 keeps the relaxation to a single named key, and FR-037 makes the consequence explicit to whoever adopts it. |
| VI | macOS / Linux / Windows Portability | Both ports implement the same two-rung resolution and the same schema additions, proven by the shared conformance corpus. FR-034 documents the Windows credential store and the cmdlet-is-not-an-executable trap explicitly. |
| VII | No Hard-Coded Assumptions About the Jira Workflow | Unaffected — this feature touches connection and credentials only, never issue types, statuses, or transitions. |
| VIII | Neutral Engine / Jira Sink, Separated by an Interface | Preserved. Credential resolution stays generic port infrastructure with no Jira knowledge; the Jira-specific email and base URL stay on the sink side of the interface, exactly where they sit today. |
| IX | Two-Tier Privacy Guard, With an Allowlist | Unaffected — no ticket content is read or written. The separate credential-shape refusal on config surfaces is preserved and narrowed only as FR-021 and FR-022 state. |
| X | Self-Healing Automatic Mirror | Preserved and extended. FR-024 makes the ceremony repair a missing `personal.yml` rather than refuse, and FR-027 stops the repaired file from becoming a new refusal — today a `personal.yml` without a team is fatal, which would make the ceremony's own output break the next run. FR-033 keeps unattended runs self-sufficient. |
| XI | Universal Dry-Run and Auditability | FR-029 puts the new write behind the existing dry-run flag; FR-030 reports the outcome in the structured output like every other effect. |
| XII | Quality and Catalog Publication | Both suites, the conformance corpus, `shellcheck` and `actionlint` stay green; FR-034 through FR-037 keep the published documentation truthful about setup. |
| XIII | TDD With a Minimum 80% Coverage | Every acceptance scenario above is written to be executable, and the cross-port ones belong in the conformance corpus rather than in per-port unit tests. Coverage is asserted at implementation. |
| XIV | KISS — The Simplest Solution That Satisfies the Spec | The token chain gets *shorter*: three rungs become two, and a hardcoded probe with two hardwired backends becomes one variable naming a program the operator already has. No new file, no new command, no credential-store integration code. |
| XV | YAGNI — Nothing Is Built Before a Spec Requires It | Scope is bounded to the three settings and the two files. Deliberately excluded: a migration path (no other installation exists), token rotation, credential-store provisioning, OAuth, multi-account profiles, and any encryption the extension would perform itself. |
| XVI | Human Readable — Readable by a Human Above All | Both files stay hand-editable YAML, and the created `personal.yml` documents its own schema in comments — including the team ids on offer (FR-024, FR-025) — so an operator edits it without opening a manual. Every failure names the file, the key, or the command that caused it (FR-007, FR-014, FR-018, FR-030). |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a fresh setup, no file anywhere in the workspace — tracked,
  untracked, or ignored — contains the token. Verified by searching the whole
  working tree for the token value and finding zero matches.
- **SC-002**: An operator sets up credentials on a new machine in three
  documented steps or fewer, and the first command reaching Jira succeeds.
- **SC-003**: Every failure mode of credential resolution produces a distinct
  message that names the source at fault. There are **five**: no source declared,
  and the four ways a declared retrieval command fails — it does not exist, it
  exits non-zero, it exceeds the bound, it prints nothing. "Does not exist" and
  "exits non-zero" are separate modes because they send the operator to
  different places. An operator can tell which of the five occurred from the
  message alone, without re-running with extra flags.
- **SC-004**: Every failure mode of the two non-secret settings — missing,
  malformed, wrong file — names the file, the key, and the environment variable
  that could supply it instead.
- **SC-005**: Running the config ceremony twice in a row on the same repository
  produces byte-identical results, and the second run writes nothing.
- **SC-006**: A `personal.yml` created by the ceremony and left entirely
  untouched is accepted by every command: the ceremony never produces a file
  that refuses the next run.
- **SC-007**: An unattended run with all three settings injected as environment
  variables succeeds with no configuration files present and no credential
  store available.
- **SC-008**: Both ports produce byte-identical output for every scenario above,
  proven by the shared conformance corpus.
- **SC-009**: No document shipped by the extension instructs an operator to put
  a token in a file inside the workspace, or describes the removed
  secret-manager probe. Verified by a full sweep of the shipped documentation
  and command prompts.
- **SC-010**: Deleting `.env` from an installation changes the behaviour of no
  command.

## Assumptions

- **The environment variable outranks the file, for all three settings.** It
  matches the ordering the token already uses, and it is what lets an
  unattended run override a developer machine's files without editing them.
- **Existing environment-variable names are kept** for the token, the email,
  and the base URL, so no working setup breaks on names alone. The retrieval
  command is a new variable in the extension's existing naming style.
- **The new keys are named for what they hold**, following each file's existing
  key conventions rather than mirroring the environment variable names.
- **No migration path is built.** The operator who requested this feature is
  the only user of the extension today, so `.env` support is removed outright:
  no carry-over of old values, no leftover-file warning, no deprecation window.
  A future adopter starts from the new arrangement.
- **The base URL in `config.yml` is accepted as committed data.** The hostname
  enters the repository's history and cannot be retracted from it later. It is
  not a secret and grants nothing without a token.
- **An encrypted scheme is required except on loopback.** The reason to require
  it is that credentials accompany every request; that reason is absent when the
  request never leaves the machine, so the rule is lifted there and nowhere
  else. This is also what makes the file-sourced base URL exercisable against a
  local test double — a rule that refused it would have made its own happy path
  untestable.
- **Only the file is validated, not the environment variable.** The variable is
  set by whoever launched the process and has never been checked; the file is
  committed and shared, and is where a typo outlives its author. The visible
  consequence — a value that worked when exported can be refused once moved into
  the file — is documented rather than smoothed over.
- **`config.yml` stays human-owned.** The tool has never written it and does
  not start here; a missing base URL is reported, not filled in.
- **`personal.yml` stays gitignored and is never committed**, which is what
  makes it an acceptable home for an email address.
- **Choosing a team stays the operator's act.** The existing rule that a team
  selection is never required is preserved, so the ceremony offers the choice
  in a comment and never makes it — not even when the catalogue holds a single
  team. Making `team` optional-when-absent (rather than optional-only-when-the-
  file-is-absent) is the smallest change that lets a created file exist without
  forcing that choice.
- **The existing `site_alias` in `config.local.yml` is left untouched.**
  Reconciling it with the new base-URL key is a separate question this feature
  does not open.
- **No credential store is bundled or provisioned.** The extension executes a
  command the operator supplies; supporting a specific store is documentation,
  not code — so 1Password, `pass`, `secret-tool`, the macOS keychain, and
  PowerShell SecretManagement all work with no extension change.
- **The retrieval command is trusted input.** It comes from the operator's own
  environment; the no-shell execution rule exists to prevent accidents and to
  keep a workspace file from ever becoming a command source, not to sandbox a
  command the operator deliberately declared.
- **The proxy-versus-auth diagnosis work described for the Figma extension is
  out of scope here.** It is a separate concern from credential storage and
  this extension's transport error mapping is unchanged by this feature.
