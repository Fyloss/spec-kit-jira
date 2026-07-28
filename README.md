# spec-kit-jira

Enterprise Spec Kit ↔ Jira Cloud bridge: mirrors a repository's spec-kit
artifacts (`spec.md`, `plan.md`, `tasks.md`) into Jira as a self-healing,
idempotent, fail-closed bridge. Configurable workflows and hierarchies
(Scrum/SAFe), multi-project routing, Gherkin-rich stories, team-shareable
config. Twin native ports: Bash (macOS/Linux) and PowerShell 7+ (Windows) —
no build step, no download step.

## Install

This repository is a [Spec Kit extension](https://github.com/github/spec-kit/tree/main/extensions).
Install it into a consuming repository with the official Spec Kit command,
which creates `.specify/extensions/jira/` there automatically:

```sh
specify extension add jira --from https://github.com/Fyloss/spec-kit-jira/archive/refs/heads/main.zip
# or, while developing:
specify extension add --dev /path/to/spec-kit-jira
```

Then run the one-command install ceremony in the consuming repository:

```text
/speckit.jira.config
```

See [INSTALL.md](INSTALL.md) for prerequisites (Bash ≥ 4 or PowerShell 7+,
`curl`, `jq`, `git`) and credential setup — the API token never enters the
tree, argv, logs, or traces.

## Adopting a backlog you already have

Normally the specs on disk are the source of truth and the bridge only mirrors
them. `adopt` is the one deliberate exception: it binds tickets a human already
wrote to the spec folders they belong to. **The only thing it ever writes is the
marker that records the binding** — it never creates, deletes, re-parents,
re-labels, transitions, or rewrites a ticket, and it never touches a word of
what someone typed into the description.

It is off by default. Turn it on in the committed team config:

```yaml
# .specify/jira/config.yml
adoption:
  enabled: true
  label_prefix: "speckit-adopt:"
```

Then label the tickets in Jira so each label **names** the spec it belongs to.
Three forms are understood, shown with the default prefix:

| Label | Binds |
|-------|-------|
| `speckit-adopt:007-invoice-export` | the spec's own top-level ticket |
| `speckit-adopt:007-invoice-export:us2` | user story 2 of that spec |
| `speckit-adopt:007` | short form — the spec numbered `007`, accepted only while exactly one spec folder carries that number |

A label carrying the prefix alone adopts nothing: the bridge never guesses which
spec a ticket belongs to. Labels are case-sensitive and may not contain
whitespace.

Then run it — always in two phases, and always read-only until you say yes:

```sh
spec-kit-jira adopt --dry-run          # see the plan; writes nothing
spec-kit-jira adopt                    # print the plan, then ask
spec-kit-jira adopt --yes              # pre-confirm (scripts, CI-less automation)
```

| Flag | Effect |
|------|--------|
| `--spec <folder>` | Restrict the run to these spec folders; everything else is reported *out of scope* and is never even read. Repeatable. |
| `--bind <folder>[:us<N>]=<KEY>` | Pin a target to a specific ticket, replacing label discovery for it. Validated exactly like a discovered candidate. Repeatable. |
| `--yes` | Pre-confirm the apply phase. The plan is still printed first. |
| `--dry-run` | Print the plan and the exact action set the real run would perform. |
| `--json` | Emit the run summary as JSON instead of the default prose. |

When anything is ambiguous the binding is **refused rather than guessed**, with
zero writes for it, while the unambiguous bindings in the same run still apply.
Every refusal names the spec folder, every ticket involved, and a
copy-pasteable command that resolves it — usually a `--bind`:

```text
  005-audit-trail                     —           REFUSED         (several candidates: ADO-61, ADO-62)
      remediation: spec-kit-jira adopt --bind 005-audit-trail=ADO-61
```

Adopted tickets are marked as human-authored for the rest of their life, so the
first `reconcile` afterwards **adds** its managed panel below whatever prose is
already there, leaving every pre-existing byte untouched, and the reconcile
after that writes nothing at all. Re-running `adopt` on an already-adopted
backlog also writes nothing, which is what makes an interrupted run safe to
resume.

## Repository layout

This is the extension's SOURCE repository, following the official extension
layout: the manifest (`extension.yml`), `commands/`, `scripts/`, and
`templates/` live at the root and are what `specify extension add` copies;
`specs/`, `tests/`, `.specify/`, and `.github/` are development-only and are
excluded from installation by `.extensionignore`.

| Path | Role |
|------|------|
| `extension.yml` | Manifest — the single source of truth for the version |
| `commands/` | Agent command definitions (`/speckit.jira.config`) |
| `scripts/bash/`, `scripts/powershell/` | The twin ports (module-for-module mirrors) |
| `templates/` | Config scaffold and managed README block template |
| `specs/`, `tests/`, `.specify/`, `.github/` | Development only — never installed |

## Development

The project is built spec-first with Spec Kit itself: the active feature lives
in `specs/001-jira-reconcile-engine/` and the governance rules in
`.specify/memory/constitution.md`. Both ports are proven behaviourally
equivalent by a language-agnostic conformance corpus (`tests/conformance/`);
`bats` and `Pester` cover each port, with lint (`shellcheck`,
`PSScriptAnalyzer`) and CI gates (engine/sink boundary, module parity,
coverage, single-sourced version) blocking on the three-OS matrix.

## License

[MIT](LICENSE)
