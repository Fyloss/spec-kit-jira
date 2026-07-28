# Phase 0 Research: Reconcile Resolves Its Own Routing and Plan Context From Config

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Date**: 2026-07-28

The Technical Context carried no NEEDS CLARIFICATION markers: the language, dependencies, testing tooling and platform targets are all fixed by the constitution and by the existing repository. Research therefore concentrated on the eight design decisions the implementation rests on, each resolved against the code as it stands today.

---

## R1 — Which layer resolves routing

**Decision**: Resolution lives in the command layer, in `scripts/bash/commands/reconcile.sh` (and `Reconcile.psm1`), as two private helpers: one that produces the routing decision, one that produces the creation context.

**Rationale**: The command layer is already the only layer that sources both the engine and the sink (`reconcile.sh:24-38` sources `engine/parse.sh`, `engine/interchange.sh`, `sink/jira/plan_apply.sh` and `lib/config.sh`). It is where the seam was designed to be — the file's own header calls the plan context "the seam that US2/US8 config integration fills from the discovered binding". Putting resolution there needs no new file and crosses no boundary.

Placing it in the engine would put config-file and Jira-identifier knowledge into a layer Principle VIII requires to hold none. Placing it in the sink would make the sink read the repository's configuration, which is the command layer's job.

**Alternatives considered**:

- *Resolve in the dispatcher (`spec-kit-jira.sh`) and export environment variables.* Rejected: it would make every command pay for a config read, and it would keep the environment variable as the mechanism rather than the override — the precise design the report asks to be rid of.
- *Resolve in a new `lib/routing.sh`.* Rejected under Principle XIV: `routing_resolve` already exists and is tested (`tests/bash/engine/test_routing.bats`, `test_routing_team.bats`); a second home for it would be an abstraction with one implementation.

---

## R2 — Where the creation payload gets its project

**Decision**: `plan_writes` reads the project from the neutral document it is already given — `$doc.routing.project_key` — not from a new field in the plan context.

**Rationale**: The neutral document already carries the routing decision, and `interchange_build` already *validates* it: `interchange.sh:33-34` rejects any document whose `routing.project_key` does not match `^[A-Z][A-Z0-9_]+$`. Sourcing the payload's project from the validated document means the payload's project and the run summary's project cannot disagree — which is exactly FR-023 — and it means the schema validation that already blocks every write also guards the payload's project. No plan-context field is added, so nothing new crosses the engine/sink interface.

The plan context remains what its header says it is: the reconcile-time facts the engine cannot know (base URL, resolved ids, existing ticket refs).

**Alternatives considered**:

- *Add `project_key` to the plan context.* Rejected: it would duplicate a value the document already holds and creates a second place for the two to diverge — the failure mode FR-023 exists to prevent.
- *Pass the project as a separate argument to `plan_writes`.* Rejected: widens the sink interface for a value already inside its input.

---

## R3 — Guaranteeing the two creation paths agree (FR-025)

**Decision**: Extract the mandatory-fields builder into `jira_create_fields_base <project> <summary> <issue-type-id>` in `sink/jira/ticket.sh`, returning the `{project, issuetype, summary}` object. `_ticket_create_body` wraps it; `plan_writes` extends it with description, priority and estimation.

**Rationale**: This is the one extraction in the plan, and it is justified by the defect itself. Today `_ticket_create_body` (`ticket.sh:56`) builds a correct payload while `plan_writes` (`plan_apply.sh:78-79`) builds one missing the project — two hand-written builders that already drifted apart in production. FR-025 requires that they cannot disagree. A shared builder makes that structural; a test alone would only make it observable after the next drift.

The sourcing direction is safe: `ticket.sh` does not source `plan_apply.sh` (verified), so `plan_apply.sh` may source `ticket.sh` with no cycle, and both modules already carry `_JIRA_SINK_*` re-entry sentinels.

**Alternatives considered**:

- *Leave both builders and add a conformance test asserting they agree.* Rejected: it detects the next divergence instead of preventing it, and Principle XIV prefers the design where the invariant cannot be broken.
- *Put the builder in `lib/`.* Rejected: `{fields:{project:…}}` is Jira-shaped and belongs on the sink side of the Principle VIII boundary.

---

## R4 — Per-project priority availability

**Decision**: `discover_binding` continues to call `GET /rest/api/3/priority` for the identifier catalogue, and additionally consults the project's own create metadata (already fetched) to decide what the project accepts:

1. The `priority` field is **absent** from the project's create metadata → record `priorities: {}`. The project does not accept a priority.
2. The `priority` field is **present with `allowedValues`** → record only those, resolved against the catalogue.
3. The `priority` field is **present without `allowedValues`** → record the site-wide catalogue, which is today's behaviour.

An empty priority map then flows through the path FR-011 already defines: an unresolvable priority is omitted and never blocks the run. No new schema key is required — `resolved_ids.<KEY>.priorities` already exists.

**Rationale**: This is the correction FR-030 and FR-031 ask for. Today `discovery.sh:186` stores the *site-wide* priority list under a *per-project* key, which misrepresents any project that scopes priorities privately or has them switched off. The repository's own mock fixtures already encode the reality that motivates this: `createmeta-fields-company.json` contains a `priority` field and `createmeta-fields-team.json` does not. Branch 1 is therefore testable against a fixture that already exists, and it is the branch that prevents the "field cannot be set / not on the appropriate screen" rejection class (SC-012).

Branch 3 is what keeps this from being a regression. Removing the site-wide call outright would have been simpler, but any site whose create metadata omits `allowedValues` would silently lose all priorities. Keeping the catalogue also leaves the API call sequence unchanged, so no existing conformance capture churns.

Create metadata is read for the first issue type only, consistent with how `estimation_candidates` is already derived (`discovery.sh:189`). Per-issue-type priority variation is not modelled — no requirement asks for it (Principle XV).

**Alternatives considered**:

- *Drop `GET /priority` entirely and use `allowedValues` alone.* Rejected as described: a real regression risk for sites that do not populate `allowedValues`, in exchange for one fewer call.
- *Branch on `style == team_managed` to decide whether to send a priority.* Rejected outright — this is the hard-coded workflow assumption Principle VII forbids, and it would be wrong for a company-managed project with priorities removed from the create screen. FR-028 encodes the rejection.

---

## R5 — Precedence between environment and config

**Decision**: For each value independently — project key, epic strategy, creation context — an explicitly set and non-empty environment variable wins; otherwise the config-derived value is used; the placeholder fallback is deleted outright.

**Rationale**: FR-013 requires the override to keep working, and the existing bats and Pester suites set these variables directly. Per-value precedence (rather than all-or-nothing) means a test that overrides only `SPEC_KIT_JIRA_PROJECT_KEY` still receives a config-derived creation context, which is what makes the existing suites pass unchanged.

The `PROJ` fallback at `reconcile.sh:174` is removed rather than demoted. `config_key_is_placeholder` (`lib/config.sh:34`) already exists for the refusal, and `JIRA_CONFIG_PLACEHOLDER_KEY` is already the single source for the literal.

**Alternatives considered**:

- *Config always wins.* Rejected: it would break existing tests and remove the escape hatch advanced users rely on, going beyond the reported defect.
- *Environment wins only when config is absent.* Rejected: it makes the override useless in exactly the configured repositories where a user would need it.

---

## R6 — The diagnostics catalogue and exit mapping

**Decision**: Five named causes, each with one remedy, routed through the existing `_reconcile_fault` / `_reconcile_notice` pair. Full text and matrix in [contracts/resolution-contract.md](./contracts/resolution-contract.md).

**Rationale**: `_reconcile_fault` (`reconcile.sh:81`) already implements exactly the behaviour FR-015 and FR-016 require — `EXIT_CONFIG` on a direct invocation, downgraded to 0 with one warning under `SPEC_KIT_JIRA_HOOK_CONTEXT`. Reusing it means the new failures inherit the hook-safety guarantee rather than re-implementing it, and no new exit code is introduced (the constitution requires codes to escalate monotonically; adding none preserves that).

The "never bound at all" state deliberately keeps its existing notice-and-exit-0 path (`reconcile.sh:146-152`) rather than becoming a fault: it is the normal state of a fresh install, and turning it into a failure would regress every unconfigured repository.

**Alternatives considered**:

- *A dedicated exit code per cause.* Rejected under Principle XV: no requirement distinguishes them by code, and the message is what an operator acts on.

---

## R7 — Test strategy and ordering

**Decision**: Three new bats suites per port plus two conformance scenarios, with every test written and observed failing before the corresponding fix, per the repository's bug-fix policy and Principle XIII.

The reported defect is fully reproducible without Jira: `--dry-run` emits the planned action set, so a test asserting `.actions[0].body.fields.project.key` fails today and passes after the fix, with no network involved. That property makes every acceptance scenario in the spec expressible as a unit test on the planned write set.

**Verified during planning**, against the tree as it stands, using the `repo-with-config` fixture and no extension environment variables:

```json
{"fields_present":["description","summary"],"n_creates":4,"summary_has_project":false}
```

Four creations planned, each declaring only `description` and `summary`. This is the reported failure, reproduced locally with no Jira instance and no credentials — confirming the defect analysis rather than inferring it, and confirming that the whole feature is testable at the unit level.

**Coverage**: the four changed modules are already exercised by existing suites; the new paths are branch-dense (five diagnostics, three priority branches, two precedence branches), so they need explicit per-branch cases to hold the 80% statement gate and the near-100% target on the fail-closed path.

**Fixtures**: one new repository fixture bound to two projects of different styles serves US4 directly — it is the only way to assert SC-013 (no identifier crossing between projects).

---

## R8 — Open verification item

**Decision**: Proceed on the basis that `fields.project` is mandatory for item creation in both company-managed and team-managed projects, and confirm against current vendor documentation during implementation.

**Status**: **Unverified in the authoring session** — no network access was available to check the vendor's current API reference. This is recorded here rather than left implicit.

**Why it does not block**: the design is robust either way. FR-028 makes payload contents follow what the project's create metadata reports it accepts, so a project that somehow did not require `project` would still receive a valid payload. Every mock fixture and every real-world report is consistent with the field being required, and the reported symptom is itself evidence of it.

**How to close it**: one call against a team-managed project on a real site — `GET /rest/api/3/issue/createmeta/{key}/issuetypes/{typeId}` and check the `project` entry's `required` flag — or the vendor's create-issue reference. This is a first task in `tasks.md`, not a release gate.
