# Changelog

All notable changes to the spec-kit-jira extension are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  in the refusal. The check applies to recorded *text* only: a value an
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

[Unreleased]: https://github.com/Fyloss/spec-kit-jira/compare/v0.10.1...HEAD
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
