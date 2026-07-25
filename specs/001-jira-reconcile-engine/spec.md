# Feature Specification: Jira Reconcile Engine (Twin Bash / PowerShell Ports)

**Feature Branch**: `001-jira-reconcile-engine`

**Created**: 2026-07-23

**Status**: Draft

**Input**: User description: "Create the specification for the founding feature of spec-kit-jira: a reconcile engine, implemented natively as twin bash and PowerShell ports, that mirrors a repository's spec-kit artifacts (spec.md, plan.md, tasks.md) into Jira Cloud — adaptable to any enterprise workflow, supporting both company-managed and team-managed projects, multi-project, multi-team, and running on macOS, Linux and Windows."

## Overview

spec-kit-jira mirrors a repository's spec-kit artifacts (`spec.md`, `plan.md`, `tasks.md`) into Jira Cloud so that a team's Jira board reflects the specs with no manual action. It is delivered natively in shell as two behaviourally identical ports — a Bash implementation for macOS/Linux and a PowerShell 7+ implementation for Windows — following spec-kit's own `sh` / `ps` command convention.

The predecessor extension (`spec-kit-jira-sync`) proved the concept but is unusable in an enterprise: one Epic per repository with a fixed hierarchy, content extraction that depends on a `## Summary` section often absent (producing empty tickets), configuration stored inside the extension folder (destroyed on reinstall, not shareable), auto-sync hooks silently stripped on upgrade, a privacy guard that false-positives on ordinary Confluence links, a single Jira project per repository, and no Windows support. This feature delivers the corrected bridge that fixes each of those defects.

### Target Users

- **Developer on a product team** — works in a spec-kit repo and wants the Jira board to reflect the specs with no manual action.
- **Tech lead / Scrum Master** — configures the workflow mapping once for the team and shares it through git.
- **Multi-team organization** — several teams, distinct Jira projects (different key prefixes), contributing to one repository.

## Clarifications

### Session 2026-07-23

- Q: What is the name of the configuration command? → A: The command is `/speckit.jira.config` (renamed from `/speckit.jira.setup`); the spec refers to it canonically as "the config command". Rationale: the command's job is to produce and maintain `.specify/jira/config.yml`, and it is idempotent and incrementally re-runnable (US1 byte-identical re-run, US8 per-project re-binding), so `config` describes it more honestly than the one-shot connotation of `setup`, echoing the `git config` precedent.
- Q: Which command registers the `after_*` hooks and writes the managed README block? → A: The configuration command — it is the single installation ceremony, performing API discovery, hook registration, and README block management in one deterministic run.
- Q: May the extension place any file in `.specify/scripts/` or `.specify/templates/`? → A: Never — those directories are Spec Kit core's and are overwritten on core upgrade. The extension's scripts and templates live under `.specify/extensions/jira/`; only the agent command files (outside `.specify/`) and the hook registration in `.specify/extensions.yml` are written elsewhere.
- Q: Which line endings does the generated README block content use? → A: The dominant line-ending convention of the host README (CRLF if the file is predominantly CRLF, LF otherwise); a new README created by the extension uses LF.
- Q: Is the privacy guard's BLOCK tier deliverable after the P1/P2 increment? → A: No — the BLOCK tier is constitution-mandated on every write (Principle IV) and ships with the first increment; only the WARN tier and the allowlist refinements remain P3.
- **RESOLVED (operator-confirmed 2026-07-23, before `/speckit.plan`): command name is `/speckit.jira.config`.** The prior concern was that `config` under-describes a command that also registers hooks and edits the consuming README (`setup` was the prior name), since FR-054 shows the command's scope is discovery **plus** hook registration **plus** README block management, not configuration-file production alone. The operator confirmed `/speckit.jira.config` on the rationale that it follows spec-kit's `git config` precedent for idempotent, incrementally re-runnable commands, and that the run summary reports the three effects (discovery / hooks / README) separately (FR-054), surfacing the extra scope at runtime rather than in the command name. This name is now authoritative across the plan, command files, README block, and hook documentation.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Deterministic, model-independent configuration (Priority: P1)

As a tech lead, I run `/speckit.jira.config` and the configuration is fully deterministic: the slash command delegates every decision to the extension's own scripts, so the assisting model never guesses, infers, or improvises a step. The command file contains an exact, ordered algorithm — not guidance — where each step either (a) reads a value from the Jira API, (b) reads a value from the existing configuration, or (c) asks the operator an explicit closed question with enumerated options. Nothing is left to model judgement: no inferred project keys, no invented field names, no "figure out which status corresponds to which phase" instructions. Every script step emits machine-readable output (a documented key/value or JSON form) so the next step consumes data, never prose. The command is the single installation ceremony: its scope is metadata discovery **plus** idempotent registration of the `after_*` lifecycle hooks **plus** management of the consuming README's managed block — not configuration-file production alone — and each of the three effects is reported separately in the run summary.

**Why this priority**: The config command is the entry point; without a deterministic, model-independent configuration step the whole feature is unreliable and unreproducible. It is the precondition for every other story.

**Independent Test**: Run the config command twice against an unchanged project on both ports and diff the produced configuration files; byte-identical output proves determinism. Inspect the command file to confirm every step is API-read, config-read, or a closed enumerated question. Assert one deterministic run performs all three effects — discovery, hook registration, and README block management — and reports each separately in the run summary.

**Acceptance Scenarios**:

1. **Given** a project with a fixed metadata set, **When** the config command runs twice with no intervening change, **Then** the produced `config.yml` is byte-identical on the second run.
2. **Given** the same project, **When** the config command runs on the Bash port and on the PowerShell port, **Then** both produce the identical configuration file.
3. **Given** a step that requires an operator decision, **When** the config command reaches it, **Then** it presents an explicit closed question with enumerated options and never proceeds on an inferred value.
4. **Given** any step of the config command, **When** it completes, **Then** it emits a documented machine-readable key/value or JSON form consumed by the next step, never free prose.

---

### User Story 2 - Workflow-adaptable mapping, company-managed AND team-managed (Priority: P1)

As a tech lead, I map spec-kit artifacts onto MY Jira hierarchy, whichever project style the organization uses. Project-style detection is mandatory and first: the config command reads the project's style attribute (`classic` = company-managed, `next-gen` = team-managed) and follows the discovery path appropriate to that style — never assuming the scheme-based model. Style-dependent capabilities are declared, never silently degraded. The operator's configured workflow is authoritative — no "ideal" workflow is ever recommended, defaulted to, or shipped.

**Why this priority**: Enterprises run heterogeneous Jira projects; a bridge that assumes one project style or one hierarchy is unusable. This story is what makes the engine adaptable rather than a fixed template.

**Independent Test**: Run discovery against a company-managed fixture and a team-managed fixture; assert each follows its own discovery path and produces a valid mapping. Configure a hierarchy level above Epic on a team-managed project and assert the config command refuses at configuration time with the limitation named.

**Acceptance Scenarios**:

1. **Given** a company-managed (`classic`) project, **When** the config command discovers metadata, **Then** issue types, statuses, transitions, priorities and fields are read through the site-level, scheme-based endpoints.
2. **Given** a team-managed (`next-gen`) project, **When** the config command discovers metadata, **Then** the same values are read from the project-scoped endpoints, the estimation field is located by a documented discovery heuristic over the project's own fields and confirmed by the operator (not by a literal field name, and not the global Story Points custom field), workflows are read per issue type, and the hierarchy is treated as limited to the Epic parent level and Sub-task child level.
3. **Given** a team-managed project and a configured mapping requiring a level above Epic (e.g. a SAFe Capability), **When** the config command validates the mapping, **Then** it refuses at configuration time with a message naming the limitation and the project style, and never accepts it to fail later at reconcile.
4. **Given** the operator chooses an Epic strategy, **When** the config command records it, **Then** it is one of `epic_per_repo` (one Epic for the repository) or `epic_per_feature` (one Epic per `specs/NNN-feature/` folder), with each user story in `spec.md` becoming its own Story under that Epic.
5. **Given** the operator chooses a task strategy, **When** the config command records it, **Then** tasks from `tasks.md` become either Sub-tasks of their Story or linked Stories related by a configurable link type — chosen explicitly, never guessed, and persisted in the team config.
6. **Given** any issue type in a mapping, **When** it is written to config, **Then** it is referenced by logical name and resolved to an id through the API, with no literal Atlassian default in any script.
7. **Given** a project's workflow, **When** the config command classifies statuses, **Then** every status is classified per project into exactly one of four categories — `mapped`, `post-scope`, `halted`, `unknown` — and the phase→status mapping is many-to-one (two consecutive phases on one status produce no transition).

---

### User Story 3 - Rich, reliable ticket content (Priority: P1)

As a developer, tickets are actionable without returning to the repo. The title comes from a deterministic source ladder; the description is structured and never empty; acceptance criteria render as Given/When/Then blocks in a dedicated panel; Figma links and UX/UI guidance surface in a distinct "Design" section; the spec's P1/P2/P3 priority maps to the project's priority field by logical name; and a declared estimation is written to the project's estimation field on create only.

**Why this priority**: Empty or useless ticket descriptions were the predecessor's most visible failure. Rich, reliable content is the core value proposition for the developer persona.

**Independent Test**: Feed a corpus that includes specs with and without a `## Summary` section; assert every created Story has a non-empty title from the source ladder, a non-empty structured description, and Gherkin criteria whenever the source contains any. Update a ticket and assert the estimation field is not re-sent.

**Acceptance Scenarios**:

1. **Given** a spec, **When** the title is derived, **Then** it follows the ladder: explicit `Title:` line → H1 → user-story section title → first non-empty paragraph → folder slug, and never depends on a `## Summary` section.
2. **Given** a spec with no `## Summary` section, **When** the description is synthesized, **Then** it is structured and non-empty, built from the need statement and its context.
3. **Given** a spec containing acceptance criteria, **When** the ticket is rendered, **Then** the criteria appear as Given/When/Then blocks in a dedicated panel.
4. **Given** a spec containing Figma links or UX/UI guidance, **When** the ticket is rendered, **Then** they appear in a distinct "Design" section.
5. **Given** a spec priority of P1/P2/P3, **When** the ticket is written, **Then** it maps to the project's priority field by logical name.
6. **Given** a declared estimation, **When** a ticket is created, **Then** the estimation is written to the project's estimation field (the correct one for the project style, per US2); **When** the same ticket is later updated, **Then** the estimation is never re-sent, so the team's own re-estimation survives.

---

### User Story 4 - Committable team config, secrets separated, version single-sourced (Priority: P1)

As a tech lead, I commit `.specify/jira/config.yml` (workflow mapping, hierarchy, project style, generation options, multi-project routing, privacy allowlist — zero credentials) so the whole team shares one configuration; personal overrides live in a gitignored `.specify/jira/config.local.yml`. The configuration lives at the repository root under `.specify/jira/`, never inside the extension's own folder. The extension's version has exactly one source of truth: the metadata already shipped under `.specify/extensions/jira/`.

**Why this priority**: Sharing configuration through git and surviving reinstall/upgrade are the enterprise adoption blockers the predecessor failed. Single-sourcing the version prevents a whole class of drift and stale-marker bugs.

**Independent Test**: Reinstall the extension and assert `config.yml` and hooks survive intact. Grep the consuming repository for any version string outside `.specify/extensions/jira/` and assert none exists. Attempt to put a credential-shaped value in either YAML layer and assert schema validation rejects it.

**Acceptance Scenarios**:

1. **Given** a team configuration, **When** it is written, **Then** it lives at `.specify/jira/config.yml` at the repo root and contains zero credentials.
2. **Given** personal overrides, **When** they are written, **Then** they live in a gitignored `.specify/jira/config.local.yml`.
3. **Given** an extension reinstall or upgrade, **When** it completes, **Then** neither `config.yml` nor the personal override file is destroyed, because configuration never lives inside the extension folder.
4. **Given** any consumer of the version (the config command, README block, run summary, upgrade check), **When** it needs the version, **Then** it reads it from the single source under `.specify/extensions/jira/` and there is no `.specify/jira/VERSION` file or any other hand-maintained version marker.
5. **Given** the consuming repository, **When** it is scanned, **Then** no script writes, updates, or depends on a duplicated version string anywhere in it.

---

### User Story 5 - Version-marked managed block in the consuming README (Priority: P1)

As a developer of a consuming project, the extension documents itself in my repository's `README.md` inside a clearly delimited, version-marked block, and updates replace exactly that block, byte-for-byte, with no possibility of touching anything outside it.

**Why this priority**: The README block is the ownership-boundary discipline (bridge-owned vs user-owned) applied to files, mirroring the same guarantee applied to ticket descriptions (US7). Getting byte-exact, CRLF-safe editing right is a P1 correctness requirement.

**Independent Test**: Run the README update on files with the block present, absent, malformed, and with CRLF endings; diff every byte outside the block and assert it is unchanged; assert a malformed marker pair produces zero writes and a located error.

**Acceptance Scenarios**:

1. **Given** a README with a well-formed managed block, **When** the extension updates it, **Then** only the content strictly between the markers is replaced, and every byte before the start marker and after the end marker is preserved exactly, including user text, trailing whitespace, and line endings (CRLF-safe on Windows).
2. **Given** the block is delimited, **When** markers are written, **Then** they carry the extension version read from the single source of US4 (e.g. `<!-- spec-kit-jira:start v<version> -->` … `<!-- spec-kit-jira:end -->`).
3. **Given** a README with no managed block, **When** the extension runs, **Then** the block is appended once, at a documented position, without reformatting the rest of the file.
4. **Given** malformed markers (start without end, nested, duplicated), **When** the extension runs, **Then** it makes no write and reports the problem with the line numbers and the fix, never guessing the intended boundaries.
5. **Given** a repository with no README, **When** the extension runs, **Then** a README is created containing only the block.
6. **Given** an unchanged version and unchanged content, **When** the extension re-runs, **Then** nothing is rewritten and the run reports zero changes.
7. **Given** a managed block hand-edited by a user, **When** the extension runs, **Then** the block is regenerated (bridge-owned), everything outside is untouched, and the summary states the block was replaced.

---

### User Story 6 - Idempotency, drift, and Jira-side lifecycle safety (Priority: P2)

As an operator, a re-run on an unchanged corpus produces zero Jira writes of any kind; a ticket advanced on the Jira side raises a named drift warning, never a silent overwrite; an unreliable Jira read causes zero writes for that spec and exits with a documented, monotonically escalating code; every write-capable operation has a `--dry-run` twin whose report lists exactly the actions the real run performs. Drift evaluation is status-category aware.

**Why this priority**: Idempotency and fail-closed safety are what make automatic mirroring trustworthy. They build on the P1 stories (configuration, mapping, content) and can be validated once those exist.

**Independent Test**: Run against an unchanged corpus and assert zero writes of every kind. Inject each fault (auth, network, 404, 429-exhausted) and assert zero writes for the affected spec and the documented exit code. Advance a ticket in each status category and assert the category-appropriate drift behaviour.

**Acceptance Scenarios**:

1. **Given** an unchanged corpus, **When** reconcile re-runs, **Then** it produces zero Jira writes of any kind (create, update, transition, comment, link, label).
2. **Given** a ticket advanced on the Jira side, **When** reconcile runs, **Then** it raises a named drift warning and never silently overwrites.
3. **Given** an unreliable Jira read (auth failure, network error, 404, exhausted 429 retries), **When** reconcile runs, **Then** it causes zero writes for that spec and exits with a documented, monotonically escalating code.
4. **Given** any write-capable operation, **When** run with `--dry-run`, **Then** the report lists exactly the actions the real run performs.
5. **Given** a ticket in a `post-scope` status, **When** drift is evaluated, **Then** it is never treated as backward drift; **Given** an `unknown` status, **Then** drift is named with a suggestion to classify it; **Given** a `halted` status, **Then** all writes to that ticket stop and the orphaned spec surfaces with two remediations (archive the spec, or reopen the ticket) for a human to resolve.
6. **Given** the disk-inferred phase regresses while the ticket sits in a `post-scope` status, **When** reconcile runs, **Then** the status transition aborts by default (content-only updates may still reconcile), and `--on-drift=proceed` or an explicit confirmation is required to pull it backward.
7. **Given** a ticket carrying Jira's Flagged (impediment) marker, **When** reconcile runs, **Then** its transitions are withheld by default, the flag is surfaced in the summary, and the bridge never sets or removes the flag.
8. **Given** a transition advancing a ticket with open blocking links, **When** reconcile runs, **Then** human-created issue links are never modified or removed, and the summary carries an info note naming the blockers without preventing the transition.

---

### User Story 7 - Human-written content is never overwritten (Priority: P2)

As a Product Owner, my own words survive forever. On any ticket of human origin, the bridge writes description content only inside a visually delimited managed panel ("Synced from spec-kit — do not edit below this line"); every pre-existing human-written line is preserved verbatim above it, permanently, including when the human edits it later.

**Why this priority**: Trust that human content is never destroyed is the counterpart to US5's README ownership boundary, applied to Jira descriptions. Without it, no Product Owner will allow automatic mirroring on their tickets.

**Independent Test**: On a human-origin ticket, write a description with human text above the panel, run reconcile repeatedly, and assert the human text is byte-preserved and the idempotency diff is computed only on the managed section. On a bridge-created ticket, assert the whole description is the managed section with no delimiters.

**Acceptance Scenarios**:

1. **Given** a ticket of human origin, **When** the bridge writes description content, **Then** it writes only inside the delimited managed panel, and every pre-existing human-written line is preserved verbatim above it.
2. **Given** a human later edits the text above the panel, **When** reconcile runs again, **Then** that edited text is still preserved verbatim.
3. **Given** a human-origin ticket, **When** idempotency is evaluated for the description, **Then** the diff is computed on the managed section alone.
4. **Given** a ticket the bridge created, **When** its description is written, **Then** the whole description is the managed section and no delimiters are needed; the discriminator is the ticket's recorded origin.

---

### User Story 8 - Multi-project / multi-team on one repository (Priority: P2)

As an organization, several teams with distinct Jira projects work from one repository. The team config routes `specs/<pattern>` to a Jira project by folder prefix, by a label declared in the spec, or by a configured default. Each spec reconciles exclusively to its assigned project, with that project's own style, discovery results, and workflow mapping.

**Why this priority**: Multi-project routing removes the predecessor's one-project-per-repo limit. It composes the per-project discovery of US2 across many projects and is needed for the enterprise multi-team target user.

**Independent Test**: Configure a repo routing one spec to a company-managed project and another to a team-managed project; assert each reconciles with its own discovery results. Re-run the config command adding a new project and assert only that project's mapping is bound, leaving existing mappings untouched.

**Acceptance Scenarios**:

1. **Given** a repo with multiple mapped projects, **When** a spec is reconciled, **Then** it routes to a Jira project by folder prefix, a spec-declared label, or a configured default, and reconciles exclusively to that project.
2. **Given** a repo mixing a company-managed and a team-managed project, **When** reconcile runs, **Then** each spec reconciles with its assigned project's own style, discovery results, and workflow mapping.
3. **Given** the config command over multiple mapped projects, **When** it runs, **Then** it iterates over every mapped project and is incrementally re-runnable: adding a project binds only that project and leaves existing mappings untouched.
4. **Given** two teams on distinct projects, **When** identities are assigned, **Then** they are scoped per project so the two teams can never collide.

---

### User Story 9 - Self-healing automatic mirror (Priority: P2)

As a developer, every spec-kit lifecycle command (specify, clarify, plan, tasks, implement, analyze) triggers a non-blocking reconcile through an `after_*` hook: a bridge failure surfaces at most one actionable WARNING and never fails the host command. Hook installation is idempotent and resilient.

**Why this priority**: Automatic, self-healing mirroring is the "no manual action" promise for the developer persona, and it fixes the predecessor's silently-stripped-hooks defect.

**Independent Test**: Fire each lifecycle hook with a forced bridge failure and assert the host command's exit code is unaffected and at most one WARNING appears. Upgrade/reinstall the extension and assert missing hooks are detected and repaired, while an explicitly disabled hook stays disabled.

**Acceptance Scenarios**:

1. **Given** a spec-kit lifecycle command, **When** it completes, **Then** an `after_*` hook triggers a non-blocking reconcile.
2. **Given** the bridge fails during a hook, **When** the hook returns, **Then** it surfaces at most one actionable WARNING and never fails the host command.
3. **Given** an upgrade or reinstall that leaves hooks missing, **When** the extension next runs, **Then** the missing hooks are detected and reinstalled (or repaired with one command).
4. **Given** a hook the operator explicitly disabled, **When** any upgrade, reinstall, or repair runs, **Then** the hook stays disabled forever.
5. **Given** any command execution, **When** it runs, **Then** it checks hook health and reports it in the run summary; **Given** a missing hook is detected this way, **Then** it is repairable in one command and is reinstalled automatically by the configuration command.

---

### User Story 10 - Editing an existing mentioned ticket (Priority: P3)

As a developer, mentioning an issue key in a command (`/speckit.specify PROJ-123 …`) makes the bridge read that ticket, stamp it with the spec's identity, and update only that ticket thereafter, logging every mutation. A read-only fetch returns the ticket's content and context so the drafted `spec.md` starts informed.

**Why this priority**: Editing a mentioned ticket is a convenience flow that enriches spec drafting; it depends on the core read/write and identity machinery of the P1/P2 stories.

**Independent Test**: Mention an unclaimed ticket key and assert the bridge fetches its content (description, acceptance criteria, priority, labels, status, flag, links), its linked Confluence pages (title and URL only), its parent context, and a one-line sibling list, then stamps identity and updates only that ticket. Mention a ticket already claimed by another spec and assert zero writes and the actionable refusal.

**Acceptance Scenarios**:

1. **Given** a mentioned issue key, **When** the bridge processes it, **Then** it reads that ticket, stamps it with the spec's identity, updates only that ticket thereafter, and logs every mutation.
2. **Given** a read-only fetch of the mentioned ticket, **When** it returns, **Then** it includes the ticket's content (description, acceptance criteria, priority, labels, status, flag, links), its linked Confluence pages (title and URL only — page content not fetched), its parent issue's context one level up, and a one-line list of sibling tickets (key, title, status).
3. **Given** a mentioned ticket already carrying another spec's identity, **When** the bridge processes it, **Then** it makes zero writes and refuses with an actionable message offering to reopen the original spec or to proceed with a new ticket linked to the mentioned one.

---

### User Story 11 - Privacy guard BLOCK tier (Priority: P1)

As a security reviewer, before every write the pre-write guard blocks on any exact match of a known coordinate — a known site/project coordinate, the ATATT token prefix, or a real non-documentation Atlassian host — producing zero writes and a dedicated exit code, so the first live dogfooding from a public repository can never leak a known coordinate.

**Why this priority**: Principle IV requires a pre-write guard that blocks on any leak of a known coordinate before every write, unconditionally. Shipping the P1/P2 increment without the BLOCK tier would mean the first live dogfooding runs with no guard at all, so the BLOCK tier is constitution-mandated and ships with the first increment.

**Independent Test**: Feed fixtures with a known coordinate, the ATATT prefix, and a real non-documentation Atlassian host; assert each blocks with the dedicated exit code and zero writes. Assert the BLOCK tier is present in the P1/P2 increment, not deferred.

**Acceptance Scenarios**:

1. **Given** an exact match (known coordinate, ATATT token prefix, real non-documentation Atlassian host), **When** the guard scans before a write, **Then** it blocks, performs zero writes, and exits with a dedicated exit code.
2. **Given** the P1/P2 increment, **When** it runs a live reconcile from a public repository, **Then** the BLOCK tier is active on every write with no gap.

---

### User Story 12 - Privacy guard WARN tier and allowlist without false positives (Priority: P3)

As a security reviewer, on top of the BLOCK tier (US11) the guard merely warns on generic shapes (emails, UUIDs) and never false-positives: Confluence links and domains declared in `.extensionignore` or the config's `privacy.allowlist` produce neither block nor warning.

**Why this priority**: The WARN tier and allowlist refinements fix the predecessor's false-positive defect. They refine the pre-write safety already required by US4/US6/US11 and are a P3 hardening of an existing gate.

**Independent Test**: Feed fixtures covering the WARN tier and allowlist — a generic email warns, an allowlisted Confluence link passes silently — and assert a BLOCK-tier false positive on allowlisted content is a failing test. Assert `.extensionignore` paths are excluded from both parsing and scanning.

**Acceptance Scenarios**:

1. **Given** a generic shape (email, UUID), **When** the guard scans, **Then** it warns but does not block.
2. **Given** a Confluence link or domain in `.extensionignore` (gitignore syntax) or `privacy.allowlist`, **When** the guard scans, **Then** it produces neither block nor warning.
3. **Given** paths declared in `.extensionignore`, **When** the bridge runs, **Then** those paths are excluded from both parsing and scanning.

---

### Edge Cases

- **Team-managed hierarchy above Epic** — a team-managed project whose configured hierarchy requires a level above Epic is refused by the config command with the limitation named (never accepted to fail later at reconcile).
- **Mixed-style routing** — a repository routing one spec to a company-managed project and another to a team-managed one; each reconciles with its own discovery results.
- **Hand-edited README block** — the block is regenerated (bridge-owned), everything outside is untouched, and the summary states the block was replaced.
- **README with start marker but no end marker** — zero writes, error naming the line numbers.
- **CRLF line endings in the consuming README on Windows** — preserved exactly outside the block.
- **Spec folder renamed after its tickets exist** — identity resolves from the stored marker, not the path.
- **Jira rate-limiting mid-run** — bounded retry with backoff; exhaustion fails that spec closed, never a partial write.
- **Two developers reconciling the same instance concurrently** — idempotency converges to zero duplicate tickets.
- **Extension upgraded while a hook was explicitly disabled** — the hook stays disabled.
- **macOS ships Bash 3.2** — the Bash port's prerequisite check detects and names this case explicitly before any Jira interaction.

## Requirements *(mandatory)*

### Functional Requirements

**Configuration command and determinism (US1)**

- **FR-001**: The `/speckit.jira.config` command file MUST contain an exact, ordered algorithm in which every step either reads a value from the Jira API, reads a value from the existing configuration, or asks the operator an explicit closed question with enumerated options — no step left to model judgement.
- **FR-002**: Every step of the config command MUST emit machine-readable output (a documented key/value or JSON form) that the next step consumes; no step MUST pass prose to a subsequent step.
- **FR-003**: Re-running the config command on an unchanged project MUST produce a byte-identical configuration; running the config command on the same project on either port MUST produce the identical configuration file.

**Project-style detection and workflow mapping (US2)**

- **FR-004**: The config command MUST detect the project style first, reading the project's style attribute (`classic` = company-managed, `next-gen` = team-managed), and MUST follow the discovery path appropriate to that style rather than assuming the scheme-based model.
- **FR-005**: For a company-managed project, the config command MUST discover issue types, statuses, transitions, priorities and fields through the site-level, scheme-based endpoints.
- **FR-006**: For a team-managed project, the config command MUST discover the same values from the project-scoped endpoints, treating issue types and fields as project-owned (not the site-level objects of the same name), locating the team-managed estimation field through a documented discovery heuristic over the project's own fields — confirmed by the operator through US1's closed-question mechanism, never by a literal field name compiled into a script (the heuristic MAY propose the conventional name as a candidate but MUST NOT assume it) — so it resolves to the project's own estimation field rather than the global Story Points custom field, reading workflows per issue type, and treating the hierarchy as limited to the Epic parent level and the Sub-task child level.
- **FR-007**: Where a configured mapping is impossible in a team-managed project (e.g. a level above Epic), the config command MUST refuse it at configuration time with a message naming the limitation and the project style, and MUST NOT accept it to fail later at reconcile.
- **FR-008**: The config command MUST persist a configurable Epic strategy of either `epic_per_repo` or `epic_per_feature`, with each user story identified in `spec.md` becoming its own Story under that Epic.
- **FR-009**: The config command MUST persist a task strategy, chosen explicitly (never guessed), of either "tasks become Sub-tasks of their Story" or "tasks become linked Stories related by a configurable link type".
- **FR-010**: Issue types MUST be referenced by logical name and resolved to ids through the API; no script MUST contain a literal Atlassian default type name, status name, or field id.
- **FR-011**: The config command MUST classify every status of a project's workflow, per project, into exactly one of four categories — `mapped`, `post-scope`, `halted`, `unknown` — and the phase→status mapping MUST be many-to-one (two consecutive phases on one status produce no transition).
- **FR-012**: No "ideal" workflow MUST be recommended, defaulted to, or shipped; the operator's configured workflow is authoritative.

**Ticket content (US3)**

- **FR-013**: The ticket title MUST be derived from the deterministic ladder: explicit `Title:` line → H1 → user-story section title → first non-empty paragraph → folder slug, and MUST NOT depend on a `## Summary` section.
- **FR-014**: The ticket description MUST be structured and never empty, synthesized from the need statement and its context, including for specs with no `## Summary` section.
- **FR-015**: Acceptance criteria MUST be rendered as Given/When/Then blocks in a dedicated panel.
- **FR-016**: Figma links and UX/UI guidance MUST be surfaced in a distinct "Design" section.
- **FR-017**: The spec's P1/P2/P3 priority MUST be mapped to the project's priority field by logical name.
- **FR-018**: A declared estimation MUST be written to the project's estimation field (the correct one for the project style) on create only and MUST NEVER be re-sent on update.

**Configuration, secrets, and version single-sourcing (US4)**

- **FR-019**: The committable team config MUST live at `.specify/jira/config.yml` at the repo root and MUST contain zero credentials; personal overrides MUST live in a gitignored `.specify/jira/config.local.yml`.
- **FR-020**: Configuration MUST NEVER live inside the extension folder; a reinstall or upgrade of the extension MUST NOT be able to destroy the configuration.
- **FR-021**: The extension version MUST have exactly one source of truth — the metadata already shipped under `.specify/extensions/jira/` — and every consumer (the config command, README block, run summary, upgrade check) MUST read it from there.
- **FR-022**: No script MUST write, update, or depend on a duplicated version string anywhere in the consuming repository; there MUST be no `.specify/jira/VERSION` file or any other hand-maintained version marker.
- **FR-023**: Schema validation MUST reject any credential-shaped value in either the committable or the local YAML layer.

**Managed README block (US5)**

- **FR-024**: The extension MUST document itself in the consuming `README.md` inside a version-marked block delimited by explicit start and end markers carrying the extension version read from the single source (FR-021), e.g. `<!-- spec-kit-jira:start v<version> -->` … `<!-- spec-kit-jira:end -->`.
- **FR-025**: On update, only the content strictly between the markers MUST be replaced; every byte before the start marker and after the end marker MUST be preserved exactly, including user text, trailing whitespace, and line endings (CRLF-safe). The generated content inside the markers MUST adopt the host file's dominant line-ending convention (CRLF if the README is predominantly CRLF, LF otherwise), so the file never becomes mixed-ending; when the extension creates the README itself, it uses LF. Both ports MUST produce byte-identical block content for identical inputs on identical hosts.
- **FR-026**: If the block is absent, it MUST be appended once, at a documented position, without reformatting the rest of the file; if the README is absent, one MUST be created containing only the block.
- **FR-027**: If the markers are malformed (start without end, nested, duplicated), the extension MUST make no write and MUST report the problem with the line numbers and the fix, never guessing the intended boundaries.
- **FR-028**: The README operation MUST be idempotent: re-running with an unchanged version and unchanged content MUST rewrite nothing and report zero changes.
- **FR-029**: Content inside the block is bridge-owned and regenerated; content outside is user-owned and untouchable — a hand-edited block MUST be regenerated and the summary MUST state the block was replaced.

**Idempotency, drift, and lifecycle safety (US6)**

- **FR-030**: A re-run on an unchanged corpus MUST produce zero Jira writes of any kind (create, update, transition, comment, link, label).
- **FR-031**: A ticket advanced on the Jira side MUST raise a named drift warning and MUST NEVER be silently overwritten.
- **FR-032**: An unreliable Jira read (auth failure, network error, 404, exhausted 429 retries) MUST cause zero writes for the affected spec and MUST exit with a documented, monotonically escalating code.
- **FR-033**: Every write-capable operation MUST have a `--dry-run` twin whose report lists exactly the actions the real run performs.
- **FR-034**: Drift evaluation MUST be status-category aware: a `post-scope` status is never backward drift; an `unknown` status is named drift with a suggestion to classify it; a `halted` status stops all writes to that ticket and surfaces the orphaned spec with two remediations (archive the spec, or reopen the ticket) for a human to resolve.
- **FR-035**: When the disk-inferred phase regresses while the ticket sits in a `post-scope` status, the status transition MUST abort by default (content-only updates may still reconcile); `--on-drift=proceed` or an explicit confirmation MUST be required to pull it backward.
- **FR-036**: A ticket carrying Jira's Flagged (impediment) marker MUST have its transitions withheld by default, MUST have the flag surfaced in the summary, and the bridge MUST NEVER set or remove the flag.
- **FR-037**: Human-created issue links MUST NEVER be modified or removed; when a transition advances a ticket with open blocking links, the summary MUST carry an info note naming the blockers without preventing the transition.

**Human-content preservation (US7)**

- **FR-038**: On a ticket of human origin, the bridge MUST write description content only inside a visually delimited managed panel ("Synced from spec-kit — do not edit below this line") and MUST preserve every pre-existing human-written line verbatim above it, permanently, including after the human later edits it.
- **FR-039**: For a human-origin ticket, the description idempotency diff MUST be computed on the managed section alone.
- **FR-040**: On a ticket the bridge created, the whole description MUST be the managed section with no delimiters; the discriminator between the two cases MUST be the ticket's recorded origin.

**Multi-project / multi-team (US8)**

- **FR-041**: The team config MUST route `specs/<pattern>` to a Jira project by folder prefix, by a label declared in the spec, or by a configured default, and each spec MUST reconcile exclusively to its assigned project.
- **FR-042**: Each spec MUST reconcile with its assigned project's own style, discovery results, and workflow mapping, allowing one repository to mix company-managed and team-managed projects.
- **FR-043**: The config command MUST iterate over every mapped project and MUST be incrementally re-runnable: adding a project binds only that project and leaves existing mappings untouched.
- **FR-044**: Ticket identities MUST be scoped per project so two teams on distinct projects can never collide.

**Self-healing hooks (US9)**

- **FR-045**: Every spec-kit lifecycle command (specify, clarify, plan, tasks, implement, analyze) MUST trigger a non-blocking reconcile through an `after_*` hook.
- **FR-046**: A bridge failure during a hook MUST surface at most one actionable WARNING and MUST NEVER fail the host command.
- **FR-047**: Hook installation MUST be idempotent and resilient. Every command execution MUST check hook health and report it in the run summary; missing hooks MUST be repairable in one command and MUST be reinstalled automatically by the configuration command (per FR-054). Hook repair MUST therefore be reachable both from the configuration command and from any run.
- **FR-048**: A hook the operator explicitly disabled MUST stay disabled forever; no upgrade, reinstall, or repair MUST re-enable it.

**Mentioned-ticket editing (US10)**

- **FR-049**: When an issue key is mentioned in a command, the bridge MUST read that ticket, stamp it with the spec's identity, update only that ticket thereafter, and log every mutation.
- **FR-050**: A read-only fetch of a mentioned ticket MUST return its content (description, acceptance criteria, priority, labels, status, flag, links), its linked Confluence pages (title and URL only — page content not fetched), its parent issue's context one level up, and a one-line list of sibling tickets (key, title, status).
- **FR-051**: If a mentioned ticket already carries another spec's identity, the bridge MUST make zero writes and MUST refuse with an actionable message offering to reopen the original spec or to proceed with a new ticket linked to the mentioned one.

**Privacy guard — BLOCK tier (US11, P1)**

- **FR-052**: Before every write, the pre-write guard MUST block on any exact match of a known coordinate (a known site/project coordinate, the ATATT token prefix, or a real non-documentation Atlassian host), producing zero writes and a dedicated exit code. This BLOCK tier is constitution-mandated (Principle IV) and ships with the first (P1/P2) increment.

**Privacy guard — WARN tier and allowlist (US12, P3)**

- **FR-053**: The pre-write guard MUST merely warn on generic shapes (emails, UUIDs), and Confluence links and domains declared in `.extensionignore` (gitignore syntax) or the config's `privacy.allowlist` MUST produce neither block nor warning; `.extensionignore` paths MUST be excluded from both parsing and scanning. The WARN tier and allowlist refinements are P3.

**Installation ceremony and Spec Kit directory ownership (US1, US4, US5, US9)**

- **FR-054**: The configuration command MUST, in the same deterministic run as metadata discovery, (a) register the `after_*` lifecycle hooks idempotently in `.specify/extensions.yml`, and (b) create or update the managed README block per FR-024–FR-029. Each of the three effects — discovery, hooks, README — MUST be reported separately in the run summary so the operator sees exactly what was written.
- **FR-055**: Installation and every command MUST NOT create, modify, or delete any file under `.specify/scripts/` or `.specify/templates/` — those directories belong to Spec Kit core and are overwritten on core upgrade. The extension's own scripts, templates, and version metadata live exclusively under `.specify/extensions/jira/`; the only files written outside that folder are the team configuration (`.specify/jira/`), the hook registration entries in `.specify/extensions.yml`, the agent command files (outside `.specify/`), and the managed README block.

### Non-Functional Requirements

- **NFR-1 (Twin-port parity)**: Every command MUST ship a Bash implementation and a PowerShell implementation with identical observable behaviour — same action plan, same exit codes, same summary content. Parity MUST be verified by a shared fixture corpus exercised by both suites; a divergence is a failing test, not a documented quirk.
- **NFR-2 (Windows)**: PowerShell 7 (`pwsh`) is the Windows implementation; the Bash port is not expected to run there. Every command MUST exist in PowerShell — no command may be Bash-only.
- **NFR-3 (Credential security — eliminatory)**: The token MUST be resolved through environment variables → OS secret manager (macOS Keychain, Linux libsecret, Windows Credential Manager) → gitignored `.env`, and MUST be wired into every authenticated request. The token MUST NEVER appear in a process argument list: in Bash the Authorization header MUST be passed to `curl` through a mechanism that keeps it out of argv (e.g. `--config` fed on stdin), never as a literal `-H` argument; in PowerShell it stays in-process. It MUST NEVER be logged, echoed in an error, or visible under `set -x` or `-Verbose` at any level. This requirement is eliminatory: any occurrence of the resolved token in argv, a log, an error, or a trace is a failing test, not a best-effort target.
- **NFR-4 (Dependencies declared)**: Each port's runtime prerequisites MUST be documented and checked at startup with an actionable message when missing (Bash: bash ≥ 4, curl, jq, git; PowerShell: pwsh 7+, git). Because macOS ships Bash 3.2, the Bash port's prerequisite check MUST detect and name that case explicitly.
- **NFR-5 (Observability)**: Every run MUST produce a structured summary (created / updated / skipped / warnings / errors, plus flags and open blockers), human-readable prose by default, with an opt-in machine-readable form for CI.
- **NFR-6 (Testability)**: Both ports MUST be verifiable against a shared mocked Jira double covering both project styles (company-managed and team-managed discovery responses) and fault injection (401 / 404 / 429-exhausted / network), plus an opt-in live suite verifying zero-churn on a real instance.

### Key Entities

- **Team config (`config.yml`)**: the committable, credential-free configuration at `.specify/jira/config.yml` — workflow mapping, issue-type hierarchy, project style, generation options, multi-project routing, privacy allowlist.
- **Local binding (`config.local.yml`)**: gitignored personal overrides and instance-specific resolved ids.
- **Project binding**: per-project record of style (`classic`/`next-gen`), discovered issue types/statuses/transitions/priorities/fields (by logical name and resolved id), estimation field, phase→status mapping, and status classification (`mapped`/`post-scope`/`halted`/`unknown`).
- **Spec artifact set**: the `spec.md`/`plan.md`/`tasks.md` of a `specs/NNN-feature/` folder — the disk source of truth.
- **Ticket identity marker**: the stable label/entity property that binds a Jira ticket to a spec, scoped per project, resolving through rename; records ticket origin (bridge-created vs human).
- **Managed section**: the delimited, bridge-owned region of a Jira description (or the whole description for bridge-created tickets); the unit on which the description idempotency diff is computed.
- **Managed README block**: the version-marked, bridge-owned region of the consuming `README.md`.
- **Run summary**: the structured report (created / updated / skipped / warnings / errors, flags, open blockers) in prose by default with an opt-in machine-readable form.
- **Version source**: the single source-of-truth metadata under `.specify/extensions/jira/`.

## Constitution Check *(mandatory)*

Each of the sixteen ratified principles (constitution v1.0.1) is addressed below with this feature's proof of compliance.

- **I. Filesystem is the source of truth, with two controlled exceptions** — Reconcile treats specs on disk as the reference and Jira as a derived mirror; drift raises a named warning before any overwrite (FR-031, FR-034). The mentioned-issue-key exception is scoped to exactly that ticket and logs every mutation (FR-049, US10); label-based adoption (the second controlled exception) is out of scope for this feature (see Out of Scope), so no adoption path is introduced here.
- **II. Zero-churn idempotency** — A re-run on an unchanged corpus produces zero writes of every kind (FR-030), verified against a live instance (SC-001, NFR-6); ticket identity relies on a stable marker, never a title (Ticket identity marker entity, FR-044).
- **III. Fail-closed on writes, non-blocking on hooks** — An unreliable read causes zero writes and a documented, monotonically escalating exit code (FR-032); `after_*` hooks never fail the host command and emit at most one WARNING (FR-046).
- **IV. Credential security — zero tokens in the tree** — NFR-3 mandates the resolution order and the argv-exclusion rule, treated as eliminatory; the privacy guard's BLOCK tier blocks on any known coordinate before every write and ships in the first (P1/P2) increment, not deferred (FR-052, US11 at P1), so the first live dogfooding from a public repository runs with the guard active; SC-007 verifies the token never appears in argv, logs, errors, or traces at maximum verbosity.
- **V. Separation of team config / local binding / secrets** — The committable `config.yml` is credential-free at the repo root, personal overrides are gitignored, secrets resolve only via NFR-3, and config never lives in the extension folder (FR-019, FR-020, FR-023); the extension writes nothing into Spec Kit core's own `.specify/scripts/` or `.specify/templates/` — its files live under `.specify/extensions/jira/` — so a core upgrade cannot silently erase them (FR-055, SC-009); reinstall preserves config and hooks (SC-008).
- **VI. macOS / Linux / Windows portability** — Two native ports with identical observable behaviour (NFR-1, NFR-2), no build/download step; the Bash port declares its minimum version and names the macOS Bash 3.2 case explicitly (NFR-4); action plans are byte-identical across OSes (SC-003), and any output written into the repository is byte-identical between the two ports — including the managed README block content for identical inputs on identical hosts (FR-025, SC-005). *Portability principle given PowerShell is the sole Windows implementation*: the constitution guarantees portability through two native ports proven equivalent by a shared conformance suite, not a single portable runtime. NFR-2 makes PowerShell 7 the sole Windows implementation and forbids any Bash-only command, so every behaviour is reachable on Windows; NFR-1's shared fixture corpus is the equivalence proof, and any divergence is a failing test (SC-003).
- **VII. No hard-coded assumptions about the Jira workflow** — Everything workflow-varying is discovered via the API and configurable; issue types resolve by logical name to ids with no literal Atlassian default in any script (FR-010); the operator's workflow is authoritative and no "ideal" workflow is shipped (FR-012); both company-managed and team-managed non-default fixtures are covered (US2, NFR-6).
- **VIII. Neutral engine / Jira sink, separated by an interface** — The reconcile engine (parse, drift, diff, decision) carries zero Jira knowledge; all Jira knowledge lives behind the sink interface, and the neutral interchange document is schema-validated before any write. This spec keeps content synthesis, drift classification, and idempotency (engine concerns) described independently of Jira discovery/write mechanics (sink concerns); the plan MUST realise the separation the constitution's grep-based enforcement checks.
- **IX. Two-tier privacy guard, with an allowlist** — BLOCK on exact matches (the constitution-mandated tier shipping in the first increment, US11/FR-052), WARN on generic shapes, and an allowlist (`.extensionignore` + `privacy.allowlist`) that produces neither block nor warning (US12/FR-053); false positives on allowlisted Confluence links are eliminated.
- **X. Self-healing automatic mirror** — The configuration command registers the `after_*` hooks idempotently in `.specify/extensions.yml` as one of the three effects of its single installation run (FR-054); hook health is checked and reported on every command execution and is one-command repairable, hooks survive upgrade/reinstall and are reinstalled automatically by the configuration command, and a disabled hook stays disabled forever (FR-045–FR-048, FR-054, SC-008).
- **XI. Universal dry-run and auditability** — Every write-capable operation has a `--dry-run` twin whose report predicts the real run exactly (FR-033), and every run produces a structured summary (NFR-5). The only destructive operation, the guarded re-mode prune, is out of scope for this feature and not introduced here.
- **XII. Quality and catalog publication** — The mocked unit suite plus the opt-in live suite run on all three OSes (NFR-1, NFR-6); the live zero-churn suite is verified on a real instance (SC-001) and is not a fork-PR blocking gate. Versioning is single-sourced (FR-021). CHANGELOG, catalog-id verification, and release gating are governance/release concerns realised in the plan.
- **XIII. TDD with minimum 80% coverage** — NFR-6's shared mocked double and fault injection make every requirement testable; the plan MUST order every test task before its implementation task. *Coverage principle as amended for a shell runtime*: statement coverage is measured per port — Pester's built-in CodeCoverage for PowerShell, kcov for Bash as the PRIMARY gate — computed on the mocked unit suites, at the CI merge gate, with the 80% minimum blocking. Where kcov is unviable on a CI platform, the documented FALLBACK is requirement→scenario traceability (every functional requirement of this spec exercised by at least one bats or conformance scenario), activated only on recorded kcov unviability. Critical paths (drift decision, idempotency, fail-closed, privacy guard, credential resolution) target coverage close to 100%.
- **XIV. KISS** — Two ports and one engine/sink interface (the single justified abstraction of Principle VIII); no framework, no speculative genericity; the plan's Complexity Tracking MUST justify any dependency beyond NFR-4's declared prerequisites.
- **XV. YAGNI** — Every config key, flag, and schema field is tied to a functional requirement above and exercised by a test; anticipated features (adoption, re-mode prune, CI/headless execution, attachments, Xray, PI planning) are listed in Out of Scope, never built as dead branches.
- **XVI. Human readable** — `config.yml` is self-documenting with business-language keys (FR-019, `epic_strategy: per_feature`); error messages name the problem, the file/ticket, and a copy-pasteable remediation (FR-027, FR-032); run summaries are prose by default with `--json` opt-in (NFR-5); ticket descriptions are written for a human reader with named sections and formatted Gherkin (FR-014–FR-016).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A demo repository with 3 features mirrored across one company-managed and one team-managed project completes in a single run; an immediate re-run produces 0 writes, verified against a live instance.
- **SC-002**: 100% of created Stories have a readable title, a non-empty description, and Gherkin criteria whenever the source spec contains any — including specs with no `## Summary` section.
- **SC-003**: The same committed team config drives an identical run on macOS (Bash), Linux (Bash) and Windows (PowerShell); the action plans are byte-identical.
- **SC-004**: The config command run twice on an unchanged project produces a byte-identical configuration, and running it on both shells produces the same file.
- **SC-005**: Updating the extension replaces the README managed block and leaves every byte outside it unchanged (verified by diff); a malformed marker pair produces zero writes and a located error; and the generated block content's line endings match the host file's dominant convention — CRLF on a CRLF fixture, LF on an LF fixture — so the file never becomes mixed-ending.
- **SC-006**: No version string exists anywhere in the consuming repository outside `.specify/extensions/jira/`'s own metadata (verified by a repository grep in the test suite).
- **SC-007**: The resolved token never appears in any process argument list, log line, error message, or trace output at maximum verbosity, on either port (verified by dedicated tests).
- **SC-008**: A forced reinstall of the extension loses neither the team configuration nor the registered hooks; self-repair is observed on the next run with no operator intervention.
- **SC-009**: After a full installation and a configuration run, `git diff` over `.specify/scripts/` and `.specify/templates/` is empty (verified by a test), proving the extension writes nothing into Spec Kit core's own directories.

## Out of Scope

- Team-managed hierarchies beyond the platform's limits (levels above Epic): declared unsupported, not emulated.
- Label-based adoption of manually created tickets; the guarded re-mode destructive prune; attachments/screenshot upload; Xray test management; PI planning and goal linking; git-tag → Jira version release management; the interactive assistant for missing information.
- CI execution and hosted-agent (headless) execution: a later feature — this one targets local developer and configuration usage.
- Jira Data Center / Server (on-premise): Jira Cloud only.
- Any non-Jira tracker.

## Assumptions

- The target is Jira Cloud only; project styles are exactly the two Atlassian styles (`classic` = company-managed, `next-gen` = team-managed).
- Operators run the port native to their OS: Bash on macOS/Linux (with a qualifying Bash ≥ 4 installed, since macOS ships 3.2), PowerShell 7+ on Windows; installing a qualifying interpreter is a one-time documented environment prerequisite, not a build step.
- The extension is installed under `.specify/extensions/jira/`, and its shipped metadata is the single source of the version.
- The consuming repository is a spec-kit repository with `specs/NNN-feature/` folders containing `spec.md` (and optionally `plan.md`, `tasks.md`).
- Real Jira credentials are available only for the opt-in live suite; the mocked Jira double covers both project styles and the four fault injections for all other tests.
- This feature targets local developer and configuration usage; CI/headless execution and the destructive re-mode are deferred to later features and are not exercised here.
