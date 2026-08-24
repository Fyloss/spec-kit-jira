# Phase 1 — Data model

Three entities, none persisted. All exist for the duration of one feature
command and are observable only through its output.

---

## 1. Resolution state

The single fact today's pass-through omits. Exactly one applies to any run that
emits `active: false` for want of a team.

| Id | Condition | Default output | Verbose output | Requirement |
| --- | --- | --- | --- | --- |
| `no-config-file` | No `config.yml` at the resolved directory | silent | names the state and the resolved path | FR-004 |
| `config-unloadable` | `config.yml` present, load failed | **reports** file + located reason | same, plus the resolved path | FR-001, FR-002 |
| `no-teams` | `config.yml` valid, `teams:` empty | silent | names the state and the resolved path | FR-017 |
| `no-personal-file` | No `personal.yml` | silent | names the state and the resolved path | FR-005 |
| `no-team-key` | `personal.yml` present, no `team` key | silent | names the state and the resolved path | FR-005 |
| `personal-unloadable` | `personal.yml` present, load failed | **reports** file + located reason | same, plus the resolved path | FR-013 |
| `no-repository` | No ancestor carries `.specify/` | **reports** that no project was located | same, plus the directory walked from | FR-008 |

Two of the seven speak by default; five stay silent. The line between them is
not severity but authorship: a file that exists is a statement its author is
owed an answer about, and a file that does not exist is not a statement.

Note that the specification's Context table counts **five** states because it
describes today's behaviour, where an unloadable file is indistinguishable from
an absent one and no repository failure is distinguishable at all. This table
is the post-feature set: the two states this feature creates are exactly the
two it makes visible.

### Transitions

None. A resolution state is determined once, from the filesystem, and does not
change within a run. It is not persisted, not cached, and not carried between
runs — the next run re-determines it from scratch.

---

## 2. Consulted path

The absolute directory configuration was actually read from.

- **Derived from**: `SPECIFY_INIT_DIR` when set; otherwise the nearest ancestor
  of the working directory that contains `.specify/`; then `/jira` beneath it.
  An explicitly set `JIRA_CONFIG_DIR` supersedes the whole derivation (FR-015).
- **Validation**: must be absolute by the time it appears in any message
  (FR-009). The relative form it is written as never reaches an operator.
- **Why it is an entity at all**: it is the one value whose absence made the
  reported defect undiagnosable. Two developers with identical repositories and
  different working directories got different results, and nothing in either
  output named the difference.

The path also governs `state/`, which the same directory holds (FR-016).
Relocating the anchor relocates the run-state; a run whose previous state is no
longer found re-derives recognition and creates no duplicate.

---

## 3. Load failure

A file that exists and could not be turned into usable configuration.

- **Fields**: the file (absolute), and the located reason as the loader already
  phrases it — `config: <label> (<file>): <detail>`.
- **Distinct from** an absent file (no author to answer) and from a valid file
  declaring nothing (`no-teams`, `no-team-key` — an author who said "nothing",
  which is a complete statement).
- **Constraint**: the reason is reproduced as the loader produced it and is
  never summarised into "invalid" (FR-002). It is equally never enriched: a
  credential-shaped value is refused by the loader *without echoing the value*,
  and nothing in this feature may widen that (Constitution IV).
- **Lifetime**: reported, then discarded. No failure is recorded to disk.
