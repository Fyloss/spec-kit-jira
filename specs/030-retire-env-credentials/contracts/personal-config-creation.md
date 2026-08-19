# Contract: The config ceremony creates `personal.yml`

**Feature**: 030 | **Applies to**: `commands/config.sh` and
`commands/Config.psm1`.

---

## §1 Placement

**C1.1** — The new effect runs **after `config_load`** (it needs the team
catalogue) and **before the degraded-mode early return** (the fresh-setup case
*is* degraded mode).

Measured order in `scripts/bash/commands/config.sh` today:

| Line | Step |
| --- | --- |
| 925 | `_config_hooks_effect` |
| 932 | `config_load` |
| 939–950 | degraded-mode trigger → early return |
| 1271 | `_config_gitignore_effect` |

**C1.2** — `_config_gitignore_effect` moves to the same position, before the
degraded return. Creating a gitignored file requires its ignore rule to exist.

**C1.3** — Consequence, stated so it is not discovered as a surprise:
`us2-degraded-mode` currently expects `gitignore: {status: "skipped"}` and must
be updated. Degraded mode now genuinely applies gitignore coverage, and reports
the true status — the same argument the existing code already makes in its own
comment for the hooks effect.

**C1.4** — The PowerShell port mirrors this ordering exactly.

---

## §2 Creation

**C2.1** — When `personal.yml` is absent, the ceremony creates it.

**C2.2** — `email` is written **uncommented** when it resolves from the
environment; otherwise it appears as a commented placeholder documenting the
expected shape.

**C2.3** — `team` is **always** written as a commented placeholder. The ceremony
never selects a team, not even when the catalogue offers exactly one.

**C2.4** — The team placeholder lists the team ids the catalogue offers. When
the catalogue declares none, it says so — it does not print an empty list.

**C2.5** — The listed ids are a snapshot taken at creation. They are never
refreshed, because C3.1 forbids rewriting the file.

**C2.6** — The created file MUST load cleanly and select no team. Restated as a
hard invariant: **the ceremony never produces a file that refuses the next
run.** This depends on `connection-settings.md` §4.

**C2.7** — Both ports emit the created file **byte-identically**, including
comment text, key order, and the trailing newline.

---

## §3 Non-creation

**C3.1** — An existing `personal.yml` is left **byte-identical**: values,
comments, key order, and any keys the extension does not recognise are all
preserved. The ceremony does not normalise, reformat, or reorder it.

**C3.2** — Re-running the ceremony after it created the file, with nothing else
changed, writes nothing and reports no change.

**C3.3** — `--dry-run` reports the intended creation and writes nothing.

---

## §4 Reporting

**C4.1** — The effects JSON gains a `personal` key alongside `discovery`,
`hooks`, `readme`, `gitignore`.

| Status | When |
| --- | --- |
| `created` | absent, and written |
| `unchanged` | already existed |
| `would_create` | `--dry-run` and absent |

**C4.2** — `detail` names every setting the operator must still supply, and the
file each belongs in — including a `base_url` missing from `config.yml`, which
belongs to no other effect.

**C4.3** — The `personal` key is present in the **degraded-mode** effects object
too, with its true status. Reporting it as skipped when the file was in fact
created would be false.

**C4.4** — The `gitignore` key in degraded mode now carries its true status
rather than `skipped` (see C1.3).

**C4.5** — Both ports emit byte-identical effects JSON.

---

## §5 Gitignore

**C5.1** — Coverage of `personal.yml` is ensured exactly as today — the rule set
does not change, only when it is applied (C1.2).

**C5.2** — Coverage is in place before or in the same run as the file's
creation, never after it.

**C5.3** — **`.specify/jira/.env` stays in the ignore rule set**, and this is a
decision rather than an oversight. The bridge no longer reads that file
(`credential-resolution.md` C1.2), but an installation that predates this
feature still has one on disk holding a real token, and dropping the rule would
un-ignore it — retiring a reader must not be the thing that commits a secret.
The rule costs one line and guards a file the tool will never create again.

Two consequences to carry into implementation:

- The comment above the rule set (`scripts/bash/commands/config.sh:745`, and its
  PowerShell twin) MUST stop describing `.env` as part of "the gitignored config
  layer" and say what it now is: a rule kept for files left over from before the
  feature.
- FR-035 and SC-009 are about **documentation instructing an operator to use**
  `.env`. A defensive ignore rule instructs nobody, so it is not a straggler for
  the T098 sweep to remove — the sweep records it as deliberate and moves on.

---

## §6 Test obligations

| Contract | Where |
| --- | --- |
| C2.1–C2.5 file content | **Conformance** — byte equality of the created file |
| C2.6 (created file loads) | **Conformance** — create, then run a command in the same fixture |
| C3.1 (existing file untouched) | **Conformance** — byte comparison before/after |
| C3.2 (idempotent re-run) | **Conformance** |
| C3.3 (dry-run) | **Conformance** |
| C4.1–C4.5 effects JSON | **Conformance** |
| C1.3 (`us2-degraded-mode` update) | Existing scenario, expectations revised |
| C1.2 reordering, per-port | The two **existing** gitignore tests — `tests/bash/commands/test_config_gitignore.bats` and `tests/powershell/commands/Config.Gitignore.Tests.ps1` — assert the effect at its old position and must move with it |
| C5.3 (`.env` rule kept) | Per-port assertion in those same two files, so the decision is defended by a test rather than by a comment |

C2.7 and C4.5 make byte equality the requirement throughout, so every row above
lands in the corpus rather than in a per-port unit test.
