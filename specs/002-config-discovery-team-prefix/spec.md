# Feature Specification: Reliable Automatic Jira Discovery & Team-Based Feature Prefix

**Feature Branch**: `002-config-discovery-team-prefix`

**Created**: 2026-07-26

**Status**: Draft

**Input**: User description: "Improve the automatic Jira introspection when running the config command: on a team_managed project it defaulted to company_managed, and it apparently relied on my branch prefix to determine the Jira prefix to use. Also, is it possible with Spec Kit to automatically add a prefix to feature names based on the team working on the ticket? It might be worth adding a per-developer personal file, gitignored, to define the developer's team prefix."

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Accurate automatic project style detection (Priority: P1)

An operator runs the configuration ceremony against a team-managed Jira project.
The ceremony detects the project style from Jira itself and records
`team_managed`. If Jira's answer is ambiguous or incomplete, the ceremony asks
the operator to choose the style from the two possible values instead of
silently writing a default — a wrong style produces an invalid hierarchy
mapping and broken mirroring later, which is far more expensive to diagnose
than one extra question at setup time.

**Why this priority**: This is the reported defect. A team-managed project
recorded as `company_managed` invalidates the capability check, the hierarchy
mapping, and the estimation-field choice — every downstream effect of the
bridge is wrong.

**Independent Test**: Can be fully tested by running the configuration ceremony
against a team-managed project (or a recorded team-managed discovery payload)
and verifying the persisted style is `team_managed`; and against an ambiguous
payload, verifying the operator is asked rather than a default being written.

**Acceptance Scenarios**:

1. **Given** a Jira project whose discovery payload identifies it as
   team-managed, **When** the operator runs the configuration ceremony,
   **Then** the persisted style is `team_managed` with no operator question
   needed.
2. **Given** a Jira project whose discovery payload identifies it as
   company-managed, **When** the operator runs the configuration ceremony,
   **Then** the persisted style is `company_managed`.
3. **Given** a discovery payload that carries no usable style signal,
   **When** the ceremony reaches style detection in interactive mode,
   **Then** the operator is asked a closed question with exactly the two style
   values, and the chosen value is persisted.
4. **Given** the same ambiguous payload in a non-interactive run (e.g. a
   machine-readable or unattended invocation), **When** style detection cannot
   be resolved, **Then** the run fails closed with a configuration-refusal
   error naming the project and the missing signal — nothing is written.

---

### User Story 2 - Jira-first discovery, with a transparent branch-based fallback (Priority: P2)

An operator runs the configuration ceremony. When the Jira connection
parameters are defined, discovery is performed exclusively against Jira: the
project key comes from the command argument, the committed team configuration,
or a closed question over the projects the operator's credentials can actually
see — the current branch name plays no role. When the connection parameters
are not yet defined, the ceremony does not guess silently: it warns the
operator explicitly that, without a Jira connection, it will fall back to
scanning existing branch names to propose team names, it marks every value
obtained this way as provisional, and it tells the operator that re-running
the command once the environment variables are defined will replace the
provisional values with authoritative discovery.

**Why this priority**: The reported behaviour — deriving the Jira key from the
operator's branch prefix — happened silently and was presented as
authoritative. The defect is not the fallback itself but its silence:
connected discovery must always win, and a degraded run must say it is
degraded, mark its output as provisional, and point to the path back to
correctness.

**Independent Test**: Can be fully tested by running the ceremony twice — once
without connection parameters, verifying the explicit warning, the provisional
marking, and the re-run guidance; then once with them, verifying the
provisional values are replaced by Jira-discovered ones and that branch names
play no role.

**Acceptance Scenarios**:

1. **Given** defined connection parameters, a repository checked out on a
   branch named with an arbitrary prefix, and no project key in the
   configuration, **When** the operator runs the ceremony without an argument,
   **Then** the ceremony presents the list of Jira projects accessible to the
   operator's credentials and asks the operator to pick one — the branch name
   is never offered, suggested, or used.
2. **Given** connection parameters not yet defined, **When** the operator runs
   the ceremony, **Then** it warns explicitly that Jira introspection is
   unavailable, states that team names will be proposed from existing branch
   names, marks every branch-derived value as provisional, and tells the
   operator to re-run the command once the environment variables are defined —
   and nothing provisional is written into the authoritative resolved-id
   binding.
3. **Given** a previous degraded run and connection parameters now defined,
   **When** the operator re-runs the ceremony, **Then** authoritative Jira
   discovery validates or replaces every provisional value and surfaces every
   mismatch (e.g. a proposed team name matching no accessible project).
4. **Given** a project key supplied as a command argument in a connected run,
   **When** the ceremony runs, **Then** that key is validated against Jira and
   used, and an unknown key produces a fail-closed error rather than a
   fallback guess.
5. **Given** a placeholder key (e.g. the template's example value) still
   present in the team configuration, **When** the ceremony runs, **Then** it
   is treated as unset — the ceremony asks the closed question instead of
   attempting discovery against the placeholder.

---

### User Story 3 - Team naming conventions with a personal team selection (Priority: P3)

The repository commits a catalogue of team naming conventions: each team is
declared once, with its folder prefix and its branch-name pattern — for
example team `ijt` → branches `ijt-<ID>/<FEATURE_NAME>`, team `wex` →
branches `wex-<ID>/<FEATURE_NAME>` — where `<ID>` is the Jira ticket number
stripped of its project-key prefix. Each developer selects their team once in
a personal, gitignored file. From then on, when the developer creates a
feature, the Jira ticket is resolved first — attached when the developer
mentioned an existing ticket, created automatically otherwise — and the
branch and feature folder are named according to the selected team's
convention. Because every team's convention lives in the same shared,
reviewable catalogue, the project adapts to all teams without any team
imposing its convention on another.

**Why this priority**: This is an enhancement request rather than a defect. It
removes a manual, error-prone step, guarantees convention consistency within a
team, and makes the existing folder-prefix routing rules effective by
construction — but the bridge functions without it.

**Independent Test**: Can be fully tested by committing a two-team catalogue,
selecting one team in the personal file, creating a feature with and without a
mentioned ticket, and verifying branch and folder names follow the selected
team's convention; and by removing the selection and verifying feature
creation behaves exactly as today.

**Acceptance Scenarios**:

1. **Given** a catalogue declaring team `ijt` with pattern
   `ijt-<ID>/<FEATURE_NAME>`, a personal file selecting `ijt`, and a developer
   mentioning existing ticket `IJT-42`, **When** they create a feature
   described as "invoice export", **Then** the branch is named
   `ijt-42/invoice-export`, the feature folder is `NNN-ijt-invoice-export`,
   and the feature is attached to `IJT-42`.
2. **Given** a personal file selecting `ijt` and a developer mentioning
   ticket `WEX-7`, which belongs to catalogue team `wex`, **When** they create
   a feature, **Then** a closed question offers the `wex` convention for this
   feature only; on confirmation the branch is named `wex-7/…`, the feature
   folder carries the `wex` prefix, the feature is routed to `wex`'s project,
   and the personal file is left unchanged.
3. **Given** the same catalogue and selection but no ticket mentioned,
   **When** the developer creates the feature, **Then** a ticket is created
   automatically in the team's Jira project and its number is used in the
   branch name.
4. **Given** no personal file (or no team selected in it), **When** the
   developer creates a feature, **Then** the feature name and branch are
   generated exactly as they are today, with no prompt and no warning.
5. **Given** a personal file selecting a team absent from the committed
   catalogue, **When** the developer creates a feature, **Then** creation
   stops with a located error naming the file and listing the valid teams.
6. **Given** a team's folder prefix matching a committed routing rule,
   **When** a feature is created under that team, **Then** it is routed to the
   team's Jira project without any manual configuration edit.
7. **Given** a freshly installed extension, **When** the personal file is
   created, **Then** it is covered by the repository's gitignore rules so it
   can never be committed.

### Edge Cases

- Discovery payload contains contradictory style signals (e.g. one field says
  team-managed, another says company-managed): treat as ambiguous — ask in
  interactive mode, fail closed otherwise.
- The operator's credentials can see zero Jira projects: fail closed with an
  error explaining that no project is visible, rather than asking an empty
  question.
- Connection parameters are defined but wrong (bad token, unreachable host):
  this is an authentication/read failure, NOT the degraded mode — the run
  fails with the corresponding error instead of silently falling back to
  branch scanning, so a typo in the credentials cannot masquerade as a
  legitimate degraded run.
- The personal file or a catalogue entry contains an invalid value (illegal
  folder characters, unknown placeholders, credential-shaped content): refuse
  the value with a clear error naming the file; never sanitise silently and
  never echo a credential-shaped value.
- The developer mentions a ticket whose project does not match the selected
  team's project (e.g. ticket `WEX-7` while team `ijt` is selected): if the
  ticket's project maps to another catalogue team, the per-feature override
  question applies (US3 scenario 2); if it maps to no catalogue team, a closed
  confirmation asks whether to proceed with the selected team's convention.
  Nothing is ever inferred silently.
- Jira is unreachable (or ticket creation is refused) at feature-creation
  time: feature creation is not blocked — it falls back to the default naming
  with an explicit warning, and the ticket is attached later by
  reconciliation.
- The branch pattern contains `/`: this creates git branch hierarchy only —
  it never produces nested spec folders.
- The feature description already starts with the team prefix: the prefix is
  not duplicated (`ijt-ijt-…` never occurs).
- Two developers on different teams work in the same clone at different times:
  each personal file is per-clone and gitignored, so the last writer of that
  clone's file wins — no shared state is affected.
- Re-running the ceremony on an unchanged project after this change: the
  persisted local binding remains byte-identical across runs and ports.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The configuration ceremony MUST determine the project style
  exclusively from the project's own discovery payload; the style value written
  to the local binding MUST be traceable to either an explicit API signal or an
  explicit operator answer.
- **FR-002**: When the discovery payload carries no unambiguous style signal,
  the ceremony MUST NOT write a default style. In interactive mode it MUST ask
  a closed question offering exactly `company_managed` and `team_managed`; in
  non-interactive mode it MUST fail closed with a configuration-refusal error
  naming the project and the missing signal.
- **FR-003**: The run summary MUST state, per project, how the style was
  resolved (detected from the API vs confirmed by the operator), so a wrong
  binding can be audited after the fact.
- **FR-004**: When the Jira connection parameters are defined, the ceremony
  MUST obtain the Jira project key only from: (a) the command argument, (b)
  the committed team configuration, or (c) a closed question over the list of
  projects the operator's credentials can access in Jira. In a connected run,
  git state — branch name, branch prefix, folder names, remote names — MUST
  NOT be read, suggested, or used as a source for the project key.
- **FR-005**: A project key equal to the template's placeholder value MUST be
  treated as unset and trigger the closed question of FR-004(c).
- **FR-006**: A supplied or configured project key that does not resolve in
  Jira MUST produce a fail-closed error; the ceremony MUST NOT substitute an
  alternative key.
- **FR-007**: The agent-facing command definition MUST state explicitly that
  in a connected run the project key and project style are never inferred
  from git state, and that any branch-derived fallback output is provisional
  — so a model-driven run has no latitude to guess silently.
- **FR-008**: When the Jira connection parameters are not defined, the
  ceremony MUST NOT proceed silently or write any authoritative binding: it
  MUST warn the operator that Jira introspection is unavailable, state that
  team names will be proposed from existing branch names, mark every
  branch-derived value as provisional, and tell the operator that re-running
  the command once the environment variables are defined will replace the
  provisional values with authoritative discovery.
- **FR-009**: A run with a working Jira connection MUST take precedence over
  any provisional, branch-derived values: it MUST validate or replace them
  and surface every mismatch. Provisional values MUST never be written into
  the authoritative resolved-id binding.
- **FR-010**: The committed team configuration MUST support a catalogue of
  team naming conventions: for each team, a unique folder-safe team prefix and
  a branch-name pattern whose only placeholders are the ticket number and the
  feature short name.
- **FR-011**: Developers MUST be able to select their team in a per-developer
  file inside the repository clone that is ignored by version control and is
  never required for any workflow to function. The selection MUST be validated
  against the committed catalogue; an unknown team MUST produce a located
  error listing the valid teams.
- **FR-012**: The personal file MAY declare an explicit convention override
  for exceptional cases; overrides MUST pass the same validation as catalogue
  entries and MUST be reported in the feature-creation output so their use is
  auditable.
- **FR-013**: When a team is selected, feature creation MUST resolve the Jira
  ticket before naming the branch: a ticket reference supplied by the
  developer MUST be validated against Jira and attached; when none is
  supplied, a ticket MUST be created automatically in the selected team's
  project.
- **FR-014**: The effective team of a feature MUST default to the personally
  selected team. When the mentioned ticket belongs to a different team
  declared in the catalogue, the developer MUST be asked a closed confirmation
  question offering that team's convention for this feature only; on
  confirmation the effective team is the ticket's team, the personal selection
  is left untouched, and the decision MUST be reported in the feature-creation
  output. On refusal, creation MUST stop rather than produce a branch whose
  prefix contradicts the ticket.
- **FR-015**: The branch name MUST follow the effective team's pattern, with
  the ticket number stripped of its project-key prefix; the feature folder
  name MUST remain a flat, single-level name carrying the effective team's
  folder prefix after the numbering component and before the descriptive
  short name. Pattern separators MUST never create nested spec folders, and
  prefixes MUST NOT be duplicated when the short name already begins with one.
- **FR-016**: When the ticket cannot be resolved or created at
  feature-creation time (Jira unreachable, creation refused), feature
  creation MUST NOT be blocked: it MUST fall back to the default naming with
  an explicit warning, and later reconciliation MUST be able to attach the
  feature to a ticket.
- **FR-017**: When no team is selected, feature creation MUST behave exactly
  as it does today (no prefix, no prompt, no warning).
- **FR-018**: Every declared value (team prefix, branch pattern, override)
  MUST be validated as folder- and branch-safe and refused with a clear,
  located error otherwise. Credential-shaped values MUST be refused without
  echoing the value.
- **FR-019**: The extension's installation/setup MUST ensure the personal file
  is covered by gitignore rules so it cannot be committed accidentally.
- **FR-020**: The behaviour of FR-001 through FR-019 MUST be identical on both
  supported platforms (the two script ports), with identical exit codes and
  byte-identical persisted output for identical inputs.

### Key Entities

- **Project style**: The management model of a Jira project
  (`company_managed` or `team_managed`); determines the valid hierarchy and
  estimation-field rules. Resolved at configuration time; persisted in the
  local binding together with its resolution provenance.
- **Project binding**: The association between this repository and a Jira
  project key; sourced only from argument, team configuration, or operator
  choice among discovered projects.
- **Team convention catalogue**: The committed declaration of every team's
  naming convention — team identifier, folder-safe prefix, and branch-name
  pattern. The single shared source of truth for how each team names its work.
- **Personal team selection**: A gitignored, per-clone file declaring which
  catalogue team the developer belongs to, with an optional explicit override
  for exceptional cases. Optional, never committed, never containing
  credentials.
- **Ticket reference**: The Jira ticket a feature is attached to — either
  mentioned by the developer at creation time or created automatically in the
  team's project. Its number (without the project-key prefix) feeds the
  branch-name pattern, and when it belongs to another catalogue team it can,
  after confirmation, set the feature's effective team for that feature only.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: Running the configuration ceremony against a team-managed
  project records `team_managed` in 100% of runs where Jira reports the style;
  zero silent defaults are written in any run.
- **SC-002**: In every connected ceremony run, the bound project key is
  traceable to an explicit source (argument, configuration, or operator
  answer), with zero keys originating from git state; every degraded run
  explicitly announces its fallback, marks its output as provisional, and
  includes the re-run guidance — zero provisional values ever reach the
  authoritative binding.
- **SC-003**: A developer who selects their team once creates any number of
  subsequent features whose branch and folder names follow the team's
  convention and whose Jira ticket is attached or created automatically, with
  zero manual renames; a developer with no selection sees zero change in
  behaviour.
- **SC-006**: Onboarding a new team's convention requires exactly one
  committed catalogue entry and zero changes for existing teams or their
  developers.
- **SC-004**: Re-running the ceremony against an unchanged project still
  produces a byte-identical local binding on both ports, including the new
  provenance information.
- **SC-005**: Setup-related misconfiguration reports caused by wrong style or
  wrong project key drop to zero for projects configured after this change.

## Assumptions

- The catalogue of team conventions lives in the committed team-configuration
  layer (reviewable in PR, one definition per team); the personal
  per-developer file holds only the team selection and an exceptional
  override, following the established three-layer separation of team config /
  local binding / secrets.
- `<ID>` in a branch pattern is the Jira ticket number stripped of its
  project-key prefix (e.g. `42` from `IJT-42`), as clarified by the operator.
- Ticket resolution at feature-creation time builds on the extension's
  existing behaviour: attach to a ticket the developer mentions, otherwise
  create it automatically.
- Branch-name patterns may contain `/` (git branch hierarchy); the spec folder
  always stays a flat, single-level name so tooling that scans `specs/` is
  unaffected. The team prefix sits after the numbering component (`NNN-` or
  timestamp) so existing ordering conventions are unchanged
  (e.g. `003-ijt-invoice-export`).
- When Jira cannot be reached at feature-creation time, degrading to the
  default naming with a warning (rather than blocking) follows the project's
  established principle that lifecycle hooks are non-blocking.
- Existing features and branches are not renamed; conventions apply only to
  features created after the developer selects a team.
- "Automatic mode" in the user's report refers to the ceremony's discovery
  steps being driven by an agent; the fix therefore covers both the
  deterministic scripts and the agent-facing command definition that
  constrains model behaviour.
- The list of accessible projects offered in the closed question of FR-004(c)
  comes from the operator's own credentials; no elevated permissions are
  assumed.
- The branch-based fallback triggers only when the connection parameters are
  absent — never on an authentication or network failure — and only proposes
  names (team prefixes and the project keys they imply) as provisional
  suggestions; it performs no Jira interaction and produces no authoritative
  binding.
