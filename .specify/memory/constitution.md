<!--
Sync Impact Report
==================
Version change: 1.2.0 → 1.3.0 (MINOR — materially expanded guidance: the OS secret-manager
rung is described by the property it must satisfy rather than by three product names, and
one new rule is added to an existing principle. No principle added, removed, renumbered, or
redefined; nothing existing weakened or restated.)
Modified principles:
  IV. Credential Security — Zero Tokens in the Tree, Ever — the second rung is now defined
      by its requirement (a store encrypted at rest by the operating system, read at run
      time) with the per-platform mechanisms listed as how that requirement is met today:
      macOS Keychain (`security`), Linux libsecret (`secret-tool`), and — replacing
      "Windows Credential Manager" — PowerShell SecretManagement (`Get-Secret`) against the
      operator's registered default vault. A platform's mechanism may be replaced by another
      satisfying the same requirement without a further amendment. A new rule states that
      the rung is SOFT-OPTIONAL on every platform: an absent tool or module, an unregistered
      or locked store, and a missing entry each fall through silently; the rung is never a
      prerequisite check, never raises an error, and never prompts or blocks. The
      enforcement test gains a per-platform fall-through clause. The rest of Principle IV
      (nothing secret in a tracked file, the three-rung order itself, the CI note, never
      logged / never in argv, the pre-write guard) is unchanged.
Rationale: surfaced by feature 021's Constitution Check. The principle named Windows
Credential Manager, but PowerShell 7 cannot read a value out of it without a compiled
interop shim — `cmdkey` enumerates credentials and cannot return one — and Principle VI
forbids a build or download step at runtime. The port therefore shipped
`Get-JiraSecretManagerToken` as a deliberate no-op, and the documentation had to tell
Windows operators that no OS secret-manager rung existed for them: the constitution named a
door nobody could open, so Windows alone lost the encrypted-store rung the principle exists
to require. PowerShell SecretManagement, with a SecretStore or CredMan-backed vault, is
encrypted at rest by the OS, needs no build step, and restores the three-rung shape on all
three platforms. Naming the requirement rather than the product is what stops the next host
difference from needing another amendment. The soft-optional rule was already how the Bash
port behaves (`|| true`, fall through) but was nowhere written down, and SecretStore adds a
new way to get it wrong: a lockable vault can prompt, and a prompt inside a lifecycle hook
is a hang.
Added sections: none
Removed sections: none
Templates: re-verified — no template changes required
  - ✅ .specify/templates/plan-template.md — no reference to Principle IV wording
  - ✅ .specify/templates/spec-template.md — no reference to Principle IV wording
  - ✅ .specify/templates/tasks-template.md — no reference to Principle IV wording
  - ✅ .specify/templates/checklist-template.md — no changes required
Runtime documentation: deliberately NOT updated in this amendment
  - ⚠ README.md §Windows, docs/07-configuration-and-secrets.md ("there is no OS
    secret-manager rung on Windows") — these describe SHIPPED behaviour, which is still
    accurate. They are updated by the change that implements the rung
    (specs/021-reconcile-performance FR-040), never ahead of it: documenting a rung the
    code does not have would be worse than the asymmetry it describes.
  - ⚠ specs/001-jira-reconcile-engine NFR-3 names Windows Credential Manager — a shipped
    historical spec, not amended retroactively. Feature 021's spec supersedes it.
Follow-up TODOs: none

Prior report (1.2.0)
--------------------
Version change: 1.1.0 → 1.2.0 (MINOR — materially expanded guidance: one new rule added
to an existing principle. No principle added, removed, renumbered, or redefined; nothing
existing weakened or restated.)
Modified principles:
  VI. macOS / Linux / Windows Portability — added a measurement-over-emulation rule: a
      divergence that manifests on only one operating system MUST be diagnosed by
      measurement on a real runner of that OS, never by emulating its toolchain on
      another host; a platform-specific fix is unproven until a run on the affected
      platform is green; for a single-OS defect the conformance suite on that OS's
      runner IS the failing test Principle XIII requires first, because the other hosts
      cannot reproduce the behavior being fixed; quirks established by such measurement
      MUST be recorded in the repository documentation. The enforcement test gains two
      clauses: a platform-specific fix without a green run on the affected platform is
      a failing gate, and a single-OS divergence closed on the strength of an emulation
      alone is a review rejection. The rest of Principle VI (two native ports, the
      conformance suite, the three-OS matrix gate, byte-identical outputs, interpreter
      minimums) is unchanged.
Rationale: surfaced by a real defect. Fifteen conformance scenarios diverged on
windows-latest only (bash=0d pwsh=0a — the Bash port wrote CRLF on every line it
authored). A faithful emulation — a stub jq on PATH appending CR exactly as jq.exe's
text-mode stdout does — passed the entire corpus while the real runner kept failing,
and three plausible Windows hypotheses (checkout line endings, cygpath -w spelling,
bash version) were each disproved by measurement on the runner. The root cause was
measurable only there: the MSYS bash pattern matcher lets a CRLF inside a glob pattern
match a bare LF, so the line-ending detector counted every LF as a CRLF and called
every LF host CRLF (fixed by the CR-by-CR walk _ms_count_crlf in
scripts/bash/engine/managed_section.sh, proven by a green probe run; quirks catalog in
docs/10-windows-portability.md; probe loop in .github/workflows/windows-conformance.yml).
The rule generalizes the method that worked: a model of Windows is not Windows, and a
fix claimed without a run on the affected platform is a hypothesis, not a fix.
Added sections: none
Removed sections: none
Templates: re-verified — no template changes required
  - ✅ .specify/templates/plan-template.md — no reference to Principle VI wording
  - ✅ .specify/templates/spec-template.md — no reference to Principle VI wording
  - ✅ .specify/templates/tasks-template.md — no reference to Principle VI wording
  - ✅ .specify/templates/checklist-template.md — no changes required
Follow-up TODOs: none

Prior report (1.1.0)
--------------------
Version change: 1.0.1 → 1.1.0 (MINOR — materially expanded guidance: one new rule added
to an existing principle. No principle added, removed, renumbered, or redefined; nothing
existing weakened or restated.)
Modified principles:
  XIII. TDD With a Minimum 80% Coverage — added a test-isolation rule: tests MUST identify
      the state they observe, assert on, or clean up (processes, files, directories, ports)
      by an identifier the test itself recorded from what it spawned or created, never by a
      name pattern or any other global/process-wide/machine-wide scan; where a harness owns
      the spawn, it MUST publish that identifier into run-scoped output. The enforcement
      test gains two clauses: every suite stays green under parallel execution, and any test
      locating a process, file, or port by name pattern is a review rejection. The rest of
      Principle XIII (Red-Green-Refactor, the 80% statement-coverage gate and its
      per-implementation tooling, critical-path targets, regression tests) is unchanged.
Rationale: surfaced by a real defect. The conformance harness test "harness stops the mock
when the run aborts after the mock started" (tests/bash/conformance/test_run_scenario.bats)
detected leaked mock processes with `pgrep -f mock-server.ps1` — a name-pattern scan across
the whole machine. Under `bats --jobs` it matched OTHER scenarios' mock servers running
concurrently and failed a passing test with no real leak. Fixed by having the harness
(tests/conformance/run-scenario.sh) record its own mock's PID to a run-scoped file and
having the test assert on that PID specifically. The rule generalizes the fix: a test that
assumes exclusive access to machine-wide state is correct only by the accident of running
alone, and breaks the moment the suite is parallelized.
Added sections: none
Removed sections: none
Templates: re-verified — no template changes required
  - ✅ .specify/templates/plan-template.md — no testing-discipline or coverage wording
    affected by this amendment
  - ✅ .specify/templates/spec-template.md — Constitution Check rows reference principle
    titles only; Principle XIII's title is unchanged
  - ✅ .specify/templates/tasks-template.md — no reference to test-isolation or coverage
    wording
  - ✅ .specify/templates/checklist-template.md — no changes required
Follow-up TODOs: none

Prior report (1.0.1)
--------------------
Version change: 1.0.0 → 1.0.1 (PATCH — clarifications making existing enforcement
mechanically verifiable in the ratified script-native design; no principle added,
removed, renumbered, or materially expanded.)
Modified principles:
  VI. macOS / Linux / Windows Portability — clarified: names the macOS Bash 3.2
      prerequisite explicitly in the body and extends the enforcement test to require
      the installation documentation to state each implementation's minimum interpreter
      version and that macOS's OS-shipped Bash does not qualify.
  VIII. Neutral Engine / Jira Sink, Separated by an Interface — enforcement test
      restated in script terms: replaces the compiled-language "package/import" wording
      with a script-native CI-greppable test (no engine script sources/dot-sources or
      Import-Modules a sink file; no engine script contains an Atlassian-specific
      identifier). The two body bullets and the principle's intent are unchanged.
Rationale: make ratified enforcement mechanically verifiable in the Bash/PowerShell
design and surface the macOS Bash prerequisite as documentation. No guarantee is
weakened: Principle VIII's zero-Jira-knowledge-in-the-engine intent and Principle VI's
no-build/no-download rule both stand unchanged.
Added sections: none
Removed sections: none
Templates: re-verified — no template changes required
  - ✅ .specify/templates/plan-template.md — no reference to the old Principle VIII
    enforcement wording; testing line remains a generic multi-language placeholder
  - ✅ .specify/templates/spec-template.md — Constitution Check rows reference principle
    titles only, unchanged by this amendment
  - ✅ .specify/templates/tasks-template.md — no reference to the old wording
  - ✅ .specify/templates/checklist-template.md — no changes required
Follow-up TODOs: none

Prior report (1.0.0)
--------------------
Version change: (none) → 1.0.0 (INITIAL — first ratification of the
spec-kit-jira constitution. The project starts from scratch as a script-native
extension: a Bash implementation for macOS/Linux and a PowerShell 7+
implementation for Windows. No compiled binary, no download step, and no build
step are part of the design at any point.)
Principles ratified (sixteen):
  I. The Filesystem Is the Source of Truth, With Two Controlled Exceptions
  II. Zero-Churn Idempotency
  III. Fail-Closed on Writes, Non-Blocking on Hooks
  IV. Credential Security — Zero Tokens in the Tree, Ever
  V. Separation of Team Config / Local Binding / Secrets
  VI. macOS / Linux / Windows Portability
  VII. No Hard-Coded Assumptions About the Jira Workflow
  VIII. Neutral Engine / Jira Sink, Separated by an Interface
  IX. Two-Tier Privacy Guard, With an Allowlist
  X. Self-Healing Automatic Mirror
  XI. Universal Dry-Run and Auditability
  XII. Quality and Catalog Publication
  XIII. TDD With a Minimum 80% Coverage
  XIV. KISS — The Simplest Solution That Satisfies the Spec
  XV. YAGNI — Nothing Is Built Before a Spec Requires It
  XVI. Human Readable — Readable by a Human Above All
Added sections: all Core Principles and the Governance section (initial authorship)
Removed sections: none
Templates: no template changes required
  - ✅ .specify/templates/plan-template.md — testing line is a generic
    multi-language placeholder, compatible with the Bash/PowerShell design
  - ✅ .specify/templates/spec-template.md — Constitution Check table rows
    remain accurate against the ratified principle titles
  - ✅ .specify/templates/tasks-template.md — "80% coverage gate" reference is
    percentage-only, not tooling-specific; remains accurate
  - ✅ .specify/templates/checklist-template.md — no changes required
Rationale: portability is guaranteed by two native implementations proven
behaviorally equivalent by a shared conformance suite on a three-OS CI matrix
(Principle VI). The coverage gate names concrete per-implementation tooling —
Pester's built-in CodeCoverage for PowerShell, kcov for Bash — with a single,
justified, development-time-only dependency exception and a documented
requirement→scenario traceability fallback (Principle XIII).
Follow-up TODOs: none
-->

# spec-kit-jira Constitution

spec-kit-jira is an enterprise-grade Spec Kit extension that mirrors spec-kit artifacts
(`spec.md`, `plan.md`, `tasks.md`) into Jira Cloud. It is inspired by spec-kit-jira-sync
(ashbrener) and fixes that extension's identified limitations. Its target audience is
large enterprises: multiple teams, heterogeneous Jira workflows (Scrum, Kanban, SAFe —
Scaled Agile Framework).

Every principle below is NON-NEGOTIABLE. Every principle is written to be testable and
enforceable against any future spec, plan, or pull request.

## Core Principles

### I. The Filesystem Is the Source of Truth, With Two Controlled Exceptions

Specs on disk are the reference; Jira is by default a derived mirror.

- The ordinary reconcile MUST NEVER delete a Jira artifact and MUST NEVER silently
  regress a ticket. When Jira-side changes diverge from the filesystem, drift detection
  MUST report a named warning identifying the ticket and the divergent field before any
  overwrite decision is made.
- First controlled exception — operator-mentioned issue key: when the operator
  explicitly mentions an existing Jira issue key in a command (e.g.
  `/speckit.specify PROJ-123 ...`), the extension MAY read and edit THAT specific
  ticket — never any other — and MUST log the mutation in the run summary.
- Second controlled exception — label-based adoption (opt-in): when ALL of the
  following conditions hold, the extension MAY adopt and subsequently edit a Jira
  ticket that was created manually by a user:
  1. **Config opt-in**: adoption is enabled in the committable team config
     (`adoption.enabled: true`); the default is `false`. Enabling it is a deliberate,
     PR-reviewable team decision.
  2. **Spec-naming label**: a user has placed an adoption label that NAMES the target
     spec (e.g. `speckit-adopt:001` or the feature slug) on the ticket. A bare
     "managed/editable" label with no spec reference MUST NOT trigger adoption — the
     extension must never guess which spec a ticket belongs to.
  3. **Collision-free**: the named spec has no existing bridge-created ticket, and no
     other ticket claims the same spec. Any collision MUST fail closed for that spec:
     zero writes, a named warning identifying both tickets, and the operator resolves.

  Adoption is a one-time transition, logged in the run summary: the extension stamps
  its own identity marker on the ticket, records the ticket's human origin, and from
  then on reconciles it like any bridge-managed artifact.
- Human-origin protection: a ticket recorded as adopted (human-created) MUST NEVER be
  hard-deleted by any destructive operation (including the guarded re-mode of
  Principle XI); the most destructive action permitted on it is detaching the bridge
  identity — leaving the ticket, its comments, and its links intact.

**Enforcement test**: no code path outside the two controlled-exception flows and the
guarded re-mode of Principle XI may issue a Jira delete; no code path outside the two
controlled-exception flows may issue an unwarned overwrite; a reconcile against a
drifted ticket without a named warning in the summary is a failing test. For adoption: with
`adoption.enabled: false`, a labeled ticket is never written to; with adoption enabled,
a bare non-spec-naming label never triggers adoption; a collision (an existing
bridge-created ticket for the same spec, or two tickets claiming one spec) produces
zero writes and a named warning; a re-mode prune over an adopted ticket detaches
identity but never deletes; every adoption event appears in the run summary.

### II. Zero-Churn Idempotency

Any operation re-run against an unchanged state MUST produce zero Jira writes of any
kind: 0 created / 0 updated / 0 transitioned / 0 commented / 0 linked / 0 labeled.

- Idempotency MUST be verified by tests against a real Jira instance; mocks are NOT
  sufficient (three live-only bugs were found in the original extension that mocks
  never caught). This live verification runs on push to the default branch, on a
  schedule, and on a maintainer-applied label — it is NEVER a blocking gate on pull
  requests from forks (see Principle XII).
- Ticket identity MUST rely on stable labels/entity properties, never on titles,
  summaries, or any operator-editable display name.

**Enforcement test**: the live integration suite runs every write operation twice and
asserts the second run issues zero writes of every kind the sink can perform (create,
update, transition, comment, link, label); this assertion list MUST be extended in the
same change that adds any new write kind to the sink interface, so it stays exhaustive.
Any identity lookup keyed on a mutable field is a review rejection.

### III. Fail-Closed on Writes, Non-Blocking on Hooks

- If Jira cannot be read reliably (authentication failure, network error, 404,
  exhausted 429 retries), NO write may be attempted for the affected spec, and the run
  MUST exit non-zero with a documented error code. Error codes escalate monotonically:
  a more severe failure never maps to a lower code.
- Conversely, an `after_*` hook fired by a spec-kit command MUST NEVER fail the host
  command: at worst it emits a single actionable WARNING and returns success to the
  host.

**Enforcement test**: fault-injection tests (auth, network, 404, 429) assert zero write
calls and the documented exit code; hook tests assert the host command's exit code is
unaffected by any bridge failure.

### IV. Credential Security — Zero Tokens in the Tree, Ever

No token, authentication email, real site URL, or accountId may ever enter a tracked
file, including test fixtures.

- Credentials MUST be resolved in this order: environment variables → OS secret manager
  → gitignored `.env`. The second rung requires a store that the operating system
  encrypts at rest and that the bridge reads at run time; it is realized today by the
  macOS Keychain (`security`), Linux libsecret (`secret-tool`), and, on Windows,
  PowerShell SecretManagement (`Get-Secret`) against the operator's registered default
  vault. A platform's mechanism MAY be replaced by another satisfying that same
  requirement without amending this principle — the requirement is the rule, the
  mechanisms are how it is met. In CI (GitHub Actions), secrets are injected as
  environment variables and therefore resolve via the first rung; no separate mechanism
  exists or is needed.
- The OS secret manager rung is SOFT-OPTIONAL on every platform: an absent tool or
  module, an unregistered or locked store, and a missing entry MUST each fall through
  silently to the next rung. That rung MUST NEVER be tested by the prerequisite check,
  MUST NEVER raise an error, and MUST NEVER prompt or block — the bridge runs inside
  lifecycle hooks, where there is nobody to answer a prompt and a wait is
  indistinguishable from a hang.
- The token MUST NEVER be logged, never echoed in an error message, and never passed as
  a command-line argument (visible in `ps`).
- A pre-write guard MUST scan the tracked tree and block — with a dedicated exit code
  and zero Jira writes — on any leak of a known coordinate.

**Enforcement test**: a repository scan for known coordinates runs in CI and locally
before every write; a test asserts the token never appears in any log or error output,
including at maximum verbosity; each platform's secret-manager rung has a test proving
that every unavailability path — tool or module absent, store unregistered, store locked,
entry missing — falls through silently and without prompting, and a rung that fails a run
or waits on input is a review rejection.

### V. Separation of Team Config / Local Binding / Secrets

Three strictly separate layers:

1. **Team config, COMMITTABLE** — `.specify/jira/config.yml` at the repo root, outside
   the extension folder: workflow mappings, issue-type hierarchy, phase→status mapping
   by logical name, generation options, multi-project mapping. It MUST contain NO
   sensitive identifier and NO credential — only project keys and type names/ids that
   are public within the organization.
2. **Local binding, GITIGNORED** — `.specify/jira/config.local.yml`: personal
   overrides, instance-specific resolved ids when the team chooses not to commit them.
3. **Secrets** — never in any YAML; resolved only via Principle IV.

Configuration MUST NEVER live inside the extension folder (`.specify/extensions/...`):
a reinstall or upgrade of the extension must never be able to destroy the user's
configuration or hooks.

**Enforcement test**: an upgrade/reinstall test asserts config and hooks survive intact;
schema validation rejects any credential-shaped value in either YAML layer.

### VI. macOS / Linux / Windows Portability

Portability is guaranteed by two native implementations proven equivalent — not by a
single portable runtime.

- The bridge MUST run natively on all three operating systems through exactly two
  implementations: a Bash implementation for macOS and Linux, and a PowerShell 7+
  implementation for Windows. No compiled binary, no download step, and no build step
  may be required at runtime.
- The two implementations MUST be proven behaviorally equivalent by a shared,
  language-agnostic conformance suite asserting identical outputs, identical exit
  codes, and identical Jira API call sequences against a mocked endpoint.
- CI MUST run the full suite — including the conformance suite against the
  implementation native to each runner — on all three operating systems (GitHub
  Actions matrix: ubuntu / macos / windows). A green three-OS matrix is a merge gate.
- Paths, line endings, and process-invocation differences MUST be handled deliberately
  inside each implementation; any output that crosses platforms (files written into
  the repository, run summaries, the neutral interchange document) MUST be
  byte-identical between the two implementations.
- **Measurement over emulation**: a divergence that manifests on only one operating
  system MUST be diagnosed by measurement on a real runner of that OS — never by
  emulating its toolchain on another host. An emulation can pass where the real host
  fails; only the real host's answer counts. A platform-specific fix is unproven until
  a run on the affected platform is green: for a single-OS defect, the conformance
  suite on that OS's runner IS the failing test that Principle XIII requires first,
  because the other hosts cannot reproduce the behavior being fixed. Every host quirk
  established by such measurement MUST be recorded in the repository documentation
  (the Windows catalog lives in `docs/10-windows-portability.md`) so the next feature
  inherits the measurement instead of rediscovering the divergence.
- The Bash implementation MUST declare its minimum Bash version and check it as an
  explicit prerequisite before any other action; the PowerShell implementation MUST
  declare and check PowerShell 7+ the same way. A host below the declared minimum
  fails up front with a named prerequisite error, never mid-operation. Installing a
  shell interpreter that meets the declared minimum is a documented, one-time
  environment prerequisite, not a build or download step of the extension: macOS ships
  Bash 3.2, below the declared minimum, so macOS users MUST install a qualifying Bash
  (or run the PowerShell implementation); this prerequisite MUST be stated in the
  installation documentation, not merely reported at first failure.

**Enforcement test**: any behavior present in one implementation and absent or
divergent in the other, or any conformance scenario passing on one implementation and
failing on the other, is a failing gate; a run on a host below the declared minimum
shell version must fail before any Jira interaction with a named, remediable error;
the installation documentation states each implementation's minimum interpreter version
and, for macOS, that the OS-shipped Bash does not qualify; the three-OS matrix green is
a merge gate; a platform-specific fix merged without a green run on the affected
platform is a failing gate, and a single-OS divergence closed on the strength of an
emulation alone is a review rejection.

### VII. No Hard-Coded Assumptions About the Jira Workflow

Everything that varies between companies MUST be configurable: issue-type hierarchy
(Epic/Story/Sub-task, or Capability/Feature/Story for SAFe, or custom types), status
names and ids, transitions, priority fields, custom fields (story points, Program
Increment, sprint).

- The extension MUST discover metadata via the API (`createmeta`, workflows,
  priorities) during binding and MUST NEVER assume the default Atlassian schema.
- Mappings reference logical names on the spec-kit side, resolved to ids on the Jira
  side.

**Enforcement test**: the test suite includes at least one non-default workflow fixture
(e.g. SAFe hierarchy, renamed statuses); any literal Atlassian default (type name,
status name, field id) in engine code is a review rejection.

### VIII. Neutral Engine / Jira Sink, Separated by an Interface

- The reconcile engine (parse, drift, diff, decision) MUST contain zero Jira knowledge;
  all Jira knowledge lives in a sink behind a fixed interface.
- The internal interchange format is a neutral document that MUST be validated against
  a schema before any write.

**Enforcement test**: no engine script sources or imports any sink file — a CI check
greps every engine script for `source`/`.` (Bash) and `Import-Module`/dot-sourcing
(PowerShell) statements referencing the sink directory and fails the build on any match;
no engine script contains any Atlassian-specific identifier (issue key patterns,
`atlassian.net`, `createmeta`, ADF node names, Jira field ids or type names) — a second
CI grep enforces this; the engine communicates with the sink exclusively by passing the
neutral interchange document across the documented interface. Schema validation failures
block the write and surface as errors.

### IX. Two-Tier Privacy Guard, With an Allowlist

The pre-write scan distinguishes two tiers:

- **BLOCK**: exact coordinates known to the bridge, Atlassian token prefixes,
  non-documentation `*.atlassian.net` hosts.
- **WARN**: generic shapes (emails, UUIDs).

Confluence links and corporate domains declared in a committable allowlist
(`.extensionignore` plus the team config's `privacy.allowlist` section) MUST produce
NEITHER a block NOR a warn. The original extension generated false positives on these
links; this is a defect fixed by design. A blocking control with false positives ends
up disabled: precision wins over recall at the BLOCK tier.

**Enforcement test**: fixtures cover each tier — a known coordinate blocks, a generic
email warns, an allowlisted Confluence link passes silently; a BLOCK-tier false
positive on allowlisted content is a failing test.

### X. Self-Healing Automatic Mirror

- Installation MUST register the `after_*` hooks idempotently and resiliently to
  reinstalls/upgrades: an extension update must never silently strip the hooks (a known
  defect in the ecosystem).
- On every execution the extension MUST check its hooks' health, report it, and offer a
  one-command repair.
- A hook the operator explicitly disabled (`enabled: false`) MUST be respected forever —
  no repair or upgrade may re-enable it.

**Enforcement test**: install→upgrade→verify tests assert hooks survive; repeated
installs assert no duplicate hook entries; a disabled hook stays disabled across
repair and upgrade.

### XI. Universal Dry-Run and Auditability

- Every write operation (reconcile, mentioned-ticket edit, re-hierarchization, CI run)
  MUST have a `--dry-run` mode whose report predicts exactly the actions of the real
  run.
- Every run MUST produce a structured summary (created / updated / skipped / warnings /
  errors) usable by a human and by CI.
- The only destructive operation — a guarded re-mode that prunes bridge-owned
  artifacts after a mapping-shape change (e.g. switching epic or task strategy) — is
  explicitly opt-in via a dedicated flag, never fired by a hook, previewable via
  `--dry-run`, and structurally limited to artifacts carrying the bridge's identity
  marker; issues without that marker can never be deleted, relabeled, or edited by it.
  Tickets recorded as adopted (human-created, per Principle I) are additionally
  excluded from hard deletion: on them the re-mode may at most detach the bridge
  identity, never delete the ticket, its comments, or its links.

**Enforcement test**: for each write operation, a test runs `--dry-run` then the real
run against the same state and asserts the predicted and actual action sets are
identical; destructive-operation tests assert refusal on any artifact lacking the
bridge's identity marker.

### XII. Quality and Catalog Publication

- SemVer versioning and a maintained CHANGELOG are mandatory.
- The automated test suite (mocked unit tests + live integration) MUST run on all
  three operating systems; linting MUST be complete and blocking.
- The live integration suite (which requires real Jira credentials) runs on push to
  the default branch, on a schedule, and on a maintainer-applied label — it is NEVER
  a blocking gate on pull requests from forks (GitHub Actions does not expose
  repository secrets to workflows triggered by fork PRs). Pull requests from forks
  are gated by the mocked unit suite, linting, and the coverage gate only.
- Installation MUST be documented via `specify extension add`.
- Naming MUST respect the spec-kit community catalog constraints, and the catalog id
  MUST be verified available before publication.
- Every shipped feature MUST be dogfooded against a real Jira instance before release.

**Enforcement test**: release checklist items (version bump, CHANGELOG entry, green
three-OS CI, a green live-integration run on the release commit, lint pass, dogfood
record) are verifiable gates; a release missing any of them is invalid. The fork
exemption applies to PR gating only, never to shipping.

### XIII. TDD With a Minimum 80% Coverage

Development is test-driven, strictly Red-Green-Refactor:

- For any feature or fix, tests are written first, validated by the operator, observed
  to FAIL, then the implementation turns them green before any refactoring.
- No implementation task may be planned without its test task preceding it in
  `tasks.md`.
- Code coverage MUST be measured on every CI run; the 80% minimum STATEMENT coverage
  threshold is a blocking gate — a PR that drops coverage below this threshold is
  rejected. Coverage is computed on the mocked unit suites only, so the gate remains
  verifiable on fork PRs without credentials (see Principle XII). Measurement is
  defined per implementation:
  - **PowerShell**: statement coverage measured by Pester's built-in CodeCoverage —
    no third-party dependency.
  - **Bash (PRIMARY gate)**: statement coverage measured by kcov. kcov is a named,
    justified, development-time-only exception to Principle XIV's minimal-dependency
    rule: no native Bash coverage tooling exists, and kcov is never a runtime
    dependency of the shipped scripts.
  - **Bash (FALLBACK gate)**: if kcov proves unviable on any CI platform, the
    documented fallback is scenario coverage — every functional requirement of the
    active spec MUST be exercised by at least one bats or conformance scenario,
    verified by a requirement→scenario traceability check in CI. The fallback
    activates only on recorded kcov unviability, never by convenience.
- Because statement coverage does not by itself prove branch-level testing, the strict
  Red-Green-Refactor discipline (every behavior originates from a failing test) and the
  near-100% target on critical paths (drift decision, idempotency, fail-closed, privacy
  guard, credential resolution) are the mechanisms that ensure decision branches are
  exercised.
- Critical paths — drift decision, idempotency, fail-closed, privacy guard, credential
  resolution — target coverage close to 100%.
- **Test isolation — identify state by recorded identity, never by pattern**: a test MUST
  identify every piece of state it observes, asserts on, or cleans up — processes, files,
  directories, ports — by an identifier the test itself recorded from what it spawned or
  created (a PID captured at launch, a path it generated, a port it bound), and MUST NEVER
  identify it by a name pattern or any other global, process-wide, or machine-wide scan
  (`pgrep -f`, a fixed well-known port, a shared temporary path). A test that scans
  machine-wide state assumes exclusive access to the machine: it is correct only by the
  accident of running alone, and it breaks the moment the suite is parallelized or another
  test happens to run concurrently. Where a harness owns the spawn, the harness MUST
  publish the identifier into run-scoped output (e.g. write the PID it started to a file
  under the run's output directory) so the test can assert against that identifier alone.
- Every fixed bug MUST ship with a regression test written before the fix.

**Enforcement test**: CI publishes statement coverage for both implementations
(Pester CodeCoverage for PowerShell; kcov for Bash, or the requirement→scenario
traceability check while the documented fallback is active) computed on the mocked
unit suites, and fails below 80%; `tasks.md` review rejects any implementation task
not preceded by its test task; every suite MUST stay green under parallel execution
(e.g. `bats --jobs`), and any test that locates a process, file, or port by name pattern
or machine-wide scan rather than by a recorded identifier is a review rejection.

### XIV. KISS — The Simplest Solution That Satisfies the Spec

Every design MUST retain the simplest solution that satisfies the requirements and the
principles of this constitution. Concretely:

- No abstraction layer without at least two real implementations — the engine/sink
  interface of Principle VIII is the one justified-by-design exception.
- No framework when the standard library suffices; no speculative genericity.
- Minimal external dependencies, each justified individually in the plan.
- A plan that introduces complexity MUST document in its "Complexity Tracking" section
  why the simple alternative was rejected; without that justification, review rejects
  the plan.

**Enforcement test**: plan review checks every dependency and abstraction against its
written justification; an unjustified entry fails the Constitution Check gate.

### XV. YAGNI — Nothing Is Built Before a Spec Requires It

No code, no configuration option, no schema field may be added "for later": every
shipped artifact MUST be required by a functional requirement of the current spec and
exercised by at least one test.

- Anticipated features live in the specs' "Out of Scope" sections or in the backlog —
  never in the code as dead branches, unused flags, or unconsumed parameters.
- Extension points (new sinks, new mappings) are preserved by the cleanliness of
  existing interfaces, not by speculative code.
- Every PR review MUST check for the absence of dead code and orphaned configuration.

**Enforcement test**: for each shipped flag, config key, and schema field, a reviewer
can point to the functional requirement that demands it and the test that exercises
it; anything unaccounted for is removed before merge.

### XVI. Human Readable — Readable by a Human Above All

Everything the extension produces or exposes MUST be optimized for human reading:

- **Code**: explicit, pronounceable names for variables, functions, and modules; no
  cryptic abbreviations; a function reads top to bottom like an explanation; comments
  explain the why, never the obvious what.
- **Configuration**: `config.yml` is self-documenting — every section carries a comment
  explaining its role and possible values; keys use business-language names
  (`epic_strategy: per_feature`) and never opaque ids when a logical name exists; a
  tech lead must be able to review their team's config without opening the
  documentation.
- **Error messages and warnings**: every message names the problem, the file or ticket
  involved, and a copy-pasteable remediation — never a bare error code or a raw stack
  trace as the only output.
- **Run summaries**: the default report is structured prose readable in a terminal;
  machine-readable JSON is a `--json` option, never the default.
- **Jira ticket content**: generated descriptions are written for a human reader
  (Product Owner, QA) — complete sentences, named sections, formatted Gherkin — never
  a raw dump of markdown or front-matter.
- **Documentation and spec-kit artifacts**: specs, plans, and the CHANGELOG favor clear
  prose over jargon tables; every acronym is defined at its first occurrence.

**Enforcement test**: a developer discovering the project must understand a config
file, an error message, or a run report without consulting the documentation. A PR
whose review requires verbal explanations to be understood fails this principle.

## Governance

- This constitution supersedes all other practices in this repository. When a feature
  request conflicts with a principle, the principle wins; the feature is redesigned or
  rejected.
- Every spec (`/speckit.specify`) and every plan MUST include a "Constitution Check"
  section listing each principle with its proof of compliance. A spec or plan without
  this section, or with an unaddressed principle, is rejected at review.
- A principle may only be amended through a versioned modification of this document:
  a semantic version bump plus a justification recorded in this constitution's
  changelog (the Sync Impact Report at the top of this file).
  - **MAJOR**: backward-incompatible governance or principle removals/redefinitions.
  - **MINOR**: a new principle or section added, or materially expanded guidance.
  - **PATCH**: clarifications, wording, and non-semantic refinements.
- Every PR review verifies compliance with all sixteen principles; any deviation MUST
  be justified in the plan's "Complexity Tracking" section or the PR is rejected.

**Version**: 1.3.0 | **Ratified**: 2026-07-23 | **Last Amended**: 2026-08-07
