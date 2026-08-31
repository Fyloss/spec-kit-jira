# Contract: the retired flag and the retired local-binding key

**Feature**: `034-retire-hook-report` | **Status**: normative

Amends `specs/002-config-discovery-team-prefix/contracts/config-cli-contract.md`
and `specs/001-jira-reconcile-engine/contracts/config.local.schema.json`.

The governing constraint on both halves is the same, and it is a constraint on how
*little* is written: neither refusal gets a bespoke message, a retired-key rule, or
a migration. Each falls to a path that already exists and already says the right
thing. Spec Assumptions and SC-004 make this explicit; the extension has one
operator and there is no installed base for machinery to spare.

---

## §1 — `--enable-hook <event>` is no longer accepted

**Removed from**: the `config` command's option table.

**Behaviour on encounter**: the existing unknown-flag path, unmodified. It refuses,
names the offending flag, and returns the exit code that path already uses for an
unrecognised option.

**Not permitted**: a dedicated "this flag was retired in 0.24.0" message. Adding
one would be a line of code justified by a population of zero.

**Also removed**: `reconcile`'s tolerance of `--enable-hook` as a pass-through flag
(`commands/speckit.jira-mirror.reconcile.md`). A flag no command accepts cannot be
tolerated by another.

**Acceptance** — US3 AC1: invoking the configuration command with the flag refuses
with the unknown-flag exit code, naming the flag.

---

## §2 — `hooks` is no longer an accepted `config.local.yml` key

**Accepted key set before**: `site_alias`, `bound_site`, `resolved_ids`,
`overrides`, `hooks`.

**Accepted key set after**: `site_alias`, `bound_site`, `resolved_ids`,
`overrides`.

The `hooks` sub-schema — `hooks` must be a mapping, its only key is `disabled`,
`disabled` must be a list of lifecycle event names — is deleted whole. There is
nothing left for it to validate.

**Behaviour on encounter**: the schema's pre-existing unknown-key path.

| Property | Value |
| --- | --- |
| Exit code | `4` (`EXIT_CONFIG`) |
| Message | `unknown config.local key: hooks` |
| Located | yes — reported against the full path of the offending file |
| New code required | none |

The location is not added by this feature: the error reporter is already handed the
file path at the call site. The remedy is deleting the two lines.

**Acceptance** — US3 AC2 and AC3: a local binding declaring the key is refused as
above; one declaring none of the withdrawn keys validates exactly as before.

**Verification obligation**: the test asserts the **message text**, not only the
exit code. Asserting the code alone would stay green if a refactor dropped the file
path from the report, which is the half of SC-004 that matters to an operator.

---

## §3 — `SPEC_KIT_JIRA_EXTENSIONS_YML` is retired

The environment override that redirected the registry path is removed from both
ports, from the conformance and install harnesses, and from documentation. Nothing
reads the registry, so nothing can be redirected to it.

---

## §4 — What the operator loses, stated plainly

Two capabilities disappear and are **not** replaced. FR-011 requires each to be
documented where the operator would look for it, rather than discovered in a diff.

1. **Reporting whether the hooks are registered.** A repository whose hooks are
   absent will simply see nothing happen. The signal is the silence; the remedy is
   the host's own install command.
2. **The permanence of a hand-disabled hook.** The disable record is gone and the
   dispatch hold with it. Setting `enabled: false` in `.specify/extensions.yml`
   still stops the hook — until a reinstall rewrites it to `true`, which this
   extension will neither prevent nor report.

Both belong to the host. Constitution 4.0.0 gives them up knowingly and says so.
