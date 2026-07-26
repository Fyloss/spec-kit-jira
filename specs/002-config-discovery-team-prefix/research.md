# Phase 0 Research — Reliable Automatic Jira Discovery & Team-Based Feature Prefix

All Technical Context unknowns are resolved. Each decision below records what
was chosen, why, and what was rejected.

## §1 Where the reported defects actually live

**Finding**: The deterministic scripts never read git state — `grep` over
`scripts/` finds no branch access. The two defects have two distinct homes:

- **Silent style default**: `_disc_style` (`scripts/bash/sink/jira/discovery.sh:61-72`)
  and its twin `Discovery.psm1` return `company_managed` when the
  `GET /project/{key}` payload carries neither `style` nor `simplified`; the
  template additionally pre-fills `style: company_managed`
  (`templates/config.yml.template`). A team-managed project whose payload was
  incomplete (or a ceremony driven from the template default) therefore
  recorded the wrong style with no question asked.
- **Branch-prefix inference**: it happened at the *agent* level. The command
  definition `commands/speckit.jira.config.md` requires a project key but gives
  the model no key source when `config.yml` holds the `PROJ` placeholder — so
  the model improvised from the branch name. The fix must therefore cover both
  the deterministic scripts (new closed-question inputs, placeholder rule) and
  the agent command definition (explicit prohibition, FR-007).

**Decision**: fix both layers; regression tests target the script layer
(failing-first, per Constitution XIII), and the command definition gains
assertion-friendly MUST/NEVER wording checked by a docs test.

## §2 Style ambiguity contract (US1, FR-001/FR-002/FR-003)

**Decision**:
- `_disc_style` / the PS twin return a style **only** on an explicit,
  non-contradictory signal: `style: "next-gen"` or `simplified: true` ⇒
  `team_managed`; `style: "classic"` or `simplified: false` ⇒
  `company_managed`. Absent both, or **contradictory** (e.g. `style: "classic"`
  with `simplified: true`) ⇒ empty result; the binding carries `style: null`.
- `cmd_config` gains a repeatable `--style KEY=VALUE` flag (values restricted to
  the two enum members). Resolution per project:
  1. unambiguous API signal ⇒ persisted with `style_source: "api"`;
  2. `--style` supplied for that project ⇒ persisted with
     `style_source: "operator"` (the agent asks the closed question and
     re-invokes with the answer — the script itself never prompts);
  3. neither ⇒ **fail closed**, exit 4 (`EXIT_CONFIG`), error naming the
     project key and the missing signal, zero writes.
- A committed `config.yml` `style:` value (now optional in the schema) is an
  operator declaration: it satisfies resolution as `operator` provenance, but a
  *conflict* with an unambiguous API signal is treated as ambiguity (question /
  fail closed) — never silently overridden in either direction.
- The run summary reports, per project, `style` + `style_source` (FR-003).

**Rationale**: keeps the deterministic entry point non-interactive (the
established division: scripts are deterministic, the agent asks closed
questions) while making the unattended path fail closed. Provenance makes a
wrong binding auditable.

**Alternatives rejected**: an interactive `read` prompt inside the script
(breaks `--json`/CI use and the twin-port byte-parity model); keeping a default
with a warning (violates FR-002 — the wrong style poisons every downstream
mapping).

## §3 Project-key sources and the accessible-projects list (US2, FR-004/005/006)

**Decision**:
- New sink read `discovery_list_projects` / `Get-JiraDiscoveryProjectList`:
  paginated `GET /rest/api/3/project/search` (fields: `key`, `name`, `style`,
  `simplified`), canonical array output. Zero results ⇒ fail-closed error
  explaining that the credentials see no project (edge case in spec).
- `cmd_config` accepts an optional positional `<PROJECT_KEY>`; the key is
  validated by the existing `GET /project/{key}` first read — a 404 propagates
  the transport's fail-closed code, no substitution (FR-006).
- The placeholder rule: a configured key equal to the template's literal
  `PROJ` is treated as unset (FR-005). Constant lives beside the template
  consumer, both ports.
- With no key from argument or config in a connected interactive run, the agent
  asks a closed question over the `discovery_list_projects` output, persists
  the choice into `config.yml` (the ceremony already owns config-creation via
  the template), and re-invokes with the key. Unattended with no key ⇒ fail
  closed exit 4.

**Rationale**: `project/search` returns exactly the projects the credentials
can browse — matching the spec's "projects the operator's credentials can
actually see" — and its payload already carries the style fields, letting the
closed question display style for free.

**Alternatives rejected**: `GET /project` (deprecated in Jira Cloud v3);
letting the agent browse Jira itself (violates FR-001's closed-step model).

## §4 Degraded mode — absent connection parameters only (US2, FR-008/FR-009)

**Decision**:
- Trigger test runs **before any Jira call**: `SPEC_KIT_JIRA_BASE_URL` unset
  **or** token unresolvable through the three-rung resolution. Only then does
  the ceremony enter degraded mode. Defined-but-wrong parameters keep today's
  fail-closed behaviour (auth/network exit codes) — a typo can never
  masquerade as a degraded run (edge case in spec).
- Degraded behaviour (command layer, not engine — commands may read git):
  scan local branch names (`git for-each-ref refs/heads
  --format='%(refname:short)'`) for `<prefix>-<number>/…` shapes; propose the
  distinct prefixes as **provisional** team-name candidates in the summary
  (`provisional: true` on each), print one explicit warning naming the missing
  variables, and print the copy-pasteable re-run command. **Zero writes** to
  `config.local.yml` (`resolved_ids` untouched); exit 0 with
  `counts.warnings ≥ 1`.
- A later connected run performs authoritative discovery and reports any
  mismatch between a proposed team name and the accessible projects (FR-009);
  since provisional values were never persisted into the binding, "replace"
  reduces to normal authoritative discovery plus mismatch surfacing against
  the catalogue/config values the operator may have accepted.

**Rationale**: FR-008 requires the fallback to be loud, provisional, and
non-authoritative; making it a report-only path is the simplest satisfying
design and preserves zero-churn (nothing written ⇒ nothing to reconcile).

**Alternatives rejected**: writing provisional values with a marker field into
`config.local.yml` (violates FR-009's "never written into the authoritative
resolved-id binding" and complicates byte-parity); failing the degraded run
(the spec demands guidance, not refusal).

## §5 Personal team selection file (US3, FR-011/FR-012/FR-019)

**Decision**: a **new** human-owned, gitignored file
`.specify/jira/personal.yml`:

```yaml
team: ijt          # must match a catalogue team id
# optional, exceptional — reported in every feature-creation output:
override:
  branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
  folder_prefix: "ijt-"
```

- Validated on load: unknown `team` ⇒ located error naming the file and
  listing the valid catalogue ids; `override` passes the same validation as a
  catalogue entry; credential-shaped values refused without echoing (reuses
  the existing scan).
- FR-019: the config ceremony gains a **gitignore effect** — it verifies the
  repository `.gitignore` covers `.specify/jira/personal.yml` (alongside the
  existing `config.local.yml` / `.env` lines) and appends the missing lines
  idempotently, reported as its own effect (`created|written|unchanged`).

**Rationale for a separate file** (vs. keys inside `config.local.yml`):
`config.local.yml` is *machine-owned* — the ceremony rewrites it through the
canonical serialiser and its schema rejects unknown top-level keys; a
hand-edited personal selection does not belong in a machine-rewritten file,
and "never required for any workflow" (FR-011) is easiest to prove for a file
no script writes. Both files sit in the same gitignored layer 2 of
Constitution V, so the three-layer separation is preserved.

**Alternatives rejected**: `config.local.yml` keys (machine-owned rewrite +
closed schema); an environment variable (not durable, not discoverable, not
listable in an error message); a dotfile at repo root (config must live under
`.specify/jira/`, Constitution V).

## §6 Team catalogue shape (US3, FR-010/FR-018)

**Decision**: new optional `teams:` section in committed `config.yml`:

```yaml
teams:
  - id: ijt                              # unique, [a-z][a-z0-9]* — the team identifier
    project: IJT                         # the team's Jira project key
    folder_prefix: "ijt-"                # unique, folder-safe, trailing '-'
    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"
```

Validation (both ports, load time): unique `id` and `folder_prefix`;
`folder_prefix` matches `^[a-z0-9][a-z0-9-]*-$`; `branch_pattern` contains
each of `<ID>` and `<FEATURE_NAME>` exactly once and otherwise only
git-branch-safe literals (`[a-z0-9/_-]`); no other placeholder accepted;
credential-shape refusal applies. `project` uses the existing `projectKey`
schema type — a team's folder prefix combined with the existing `routing`
rules (or an implicit team→project route, see data-model) routes features to
the team's project with no extra configuration (US3 scenario 6).

**Rationale**: one reviewable entry per team (SC-006); the two-placeholder
grammar is the smallest language satisfying FR-010 and keeps expansion a pure
string operation (engine-safe).

## §7 Ticket-first feature creation and spec-kit integration (US3, FR-013…FR-017)

**Finding**: spec-kit's `create-new-feature.sh` couples folder name to branch
name at creation time, but nothing downstream depends on that coupling — the
feature directory is persisted in `.specify/feature.json`, and the host
tolerates branch ≠ folder afterwards. Moreover the host `speckit-specify`
skill already executes `hooks.before_specify` entries and explicitly expects
such a hook to "have created/switched to a git branch and output JSON
containing `BRANCH_NAME`" — a first-class integration point.

**Decision**:
- New deterministic command (both ports): `spec-kit-jira feature
  [TICKET-KEY] [--use-team <id>] [--json] [--dry-run] <description>`
  (`commands/feature.sh` `cmd_feature` / `commands/Feature.psm1`
  `Invoke-JiraFeature`). Flow:
  1. Load catalogue + personal file. **No team selected ⇒ emit
     `{active: false}` and exit 0** — the specify flow proceeds exactly as
     today (FR-017; no prompt, no warning).
  2. Resolve the effective team: personal selection by default; if a mentioned
     ticket's project maps to a *different* catalogue team and `--use-team`
     was not given, emit a `confirmation_required` result naming that team
     (the agent asks the closed question and re-invokes with
     `--use-team <id>`, or stops on refusal — FR-014). A ticket whose project
     maps to *no* catalogue team triggers the analogous proceed/stop closed
     confirmation.
  3. Resolve the ticket **before naming** (FR-013): a mentioned key is
     validated via the sink read (`GET /issue/{key}`); with none, a ticket is
     created in the effective team's project via a guarded sink write
     (`POST /issue`, PASS-1 privacy guard first, resolved story-type id from
     the binding). Jira unreachable or creation refused ⇒ **non-blocking
     fallback**: `{active: false}` plus one explicit warning; reconciliation
     attaches later (FR-016).
  4. Compute names (pure engine): ticket number = key stripped of
     `^[A-Z][A-Z0-9_]+-`; `branch_name` = pattern with `<ID>`/`<FEATURE_NAME>`
     substituted; folder short-name = `folder_prefix + short-name` with the
     prefix **not duplicated** when the short name already begins with it;
     pattern `/` creates git hierarchy only — the folder stays flat (FR-015).
  5. Output canonical JSON: effective team, ticket
     (`attached|created|none`), `branch_name`, `short_name`, `override_used`,
     warnings. `--dry-run` predicts the ticket action without writing.
- **Registration**: `register_hooks` additionally registers
  `hooks.before_specify` → `speckit.jira.feature` (`optional: true`,
  set-not-append, disabled-stays-disabled — same merge as the six `after_*`
  events). New agent command file `commands/speckit.jira.feature.md`
  documents the ordered ceremony: run the deterministic command, ask only its
  closed questions, then drive `create-new-feature.sh --short-name
  "<short_name>"` and create/switch to `branch_name`.

**Rationale**: reuses the host's own extension point (no fork of
`create-new-feature.sh`), keeps every naming computation deterministic and
twin-ported, and makes the no-selection path structurally identical to today.

**Alternatives rejected**: patching/wrapping `create-new-feature.sh` (host
file, overwritten on spec-kit upgrade — violates upgrade-survival, Principle
V); doing naming purely in the agent command file (model latitude —
exactly what US2 removes); blocking feature creation on Jira failure
(violates the non-blocking-hooks principle and FR-016).

## §8 Persistence, parity, and idempotency of the new data

**Decision**:
- Style + provenance persist per project inside the existing
  `resolved_ids.<KEY>` entry of `config.local.yml` as `style` and
  `style_source` — written through the existing canonical YAML writer, so
  re-runs stay byte-identical on both ports (SC-004). The local schema's
  known-key list is extended accordingly.
- All new command outputs pass `json_canonical` / `ConvertTo-JiraJsonValue`;
  conformance scenarios cover: team-managed detection, ambiguous ⇒ refusal
  (unattended) and ⇒ `--style` acceptance, list-projects output, degraded
  mode (no base URL in env), placeholder-key refusal, feature naming
  (attach / create / no-team / unreachable-fallback), and the gitignore
  effect — each asserting byte-identical stdout, exit codes, call sequences,
  and written files across ports.
- Exit codes are reused, not extended: ambiguity/refusal ⇒ 4
  (`EXIT_CONFIG`), unreachable/unknown key ⇒ the transport's fail-closed
  codes (2/3). Monotonic escalation is untouched.
