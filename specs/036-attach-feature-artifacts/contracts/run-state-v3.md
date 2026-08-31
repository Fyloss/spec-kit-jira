# Contract: Run state, schema 2 → 3

**Feature**: `036-attach-feature-artifacts` | **Binds**: FR-011
**Supersedes**: `specs/023-advance-board-position/contracts/run-state-v2.md`

---

## C1. Why it bumps

`_RUN_STATE_SCHEMA` goes 2 → 3 because the **set** of recorded inputs changes —
the rule the module's own comment already states. Every existing state file is
invalidated. The first run after upgrade therefore does work, which is correct:
it has artifacts to publish and no record of having published them.

## C2. What changes

`inputs` stops being three fixed keys and becomes the artifact set's full
path → hash map.

**v2** (three keys, two of them conditional):

```json
"inputs": { "spec.md": "<oid>", "tasks.md": "<oid>", "plan.md": "<oid>" }
```

**v3** (every publishable artifact):

```json
"inputs": {
  "spec.md": "<oid>", "plan.md": "<oid>", "tasks.md": "<oid>",
  "research.md": "<oid>", "data-model.md": "<oid>",
  "contracts/api.md": "<oid>", "checklists/requirements.md": "<oid>"
}
```

Every other field — `base_url`, `email`, `on_drift`, `hook_event`,
`field_values`, `extension_version` — is unchanged, as is the canonical-JSON
serialisation and the byte-comparison match rule.

## C3. Rules

| # | Rule |
|---|------|
| C3.1 | The key set is **exactly** the artifact set's paths (data-model §1), after the ignore rules are applied. |
| C3.2 | The v2 "key omitted when the file is absent" rule disappears. An absent file is not in the artifact set, so there is no key to omit. `spec.md` remains required — a run without it is refused before this module is reached. |
| C3.3 | Paths are relative to the feature directory, `/`-separated on every host. Never absolute: the document is compared byte-for-byte across ports and machines. |
| C3.4 | Hashing is **one** `git hash-object --no-filters --stdin-paths` call for the whole set, paths on stdin (research R4). Not one call per input, and not paths on argv. |
| C3.5 | Keys are sorted canonically, as today via `json_canonical` / its PowerShell twin. |
| C3.6 | A file that cannot be hashed still returns 1 with no output, unchanged from v2. |

## C4. The consequence this exists for

Under v2, a run fired after only `research.md` changed found three matching
hashes and short-circuited: zero Jira calls, and the artifact never published.
Under v3 the run proceeds, because `research.md`'s hash is part of the compared
document.

**Regression test** (written before the change, must fail against v2):
publish a feature directory, modify **only** `research.md`, run again, and
assert the run does **not** short-circuit and that `research.md` is published.

## C5. Cost check

The short-circuit exists to make an unchanged re-run cheap. v3 adds one
`git ls-files` and replaces N `git hash-object` calls with one — so the state
phase spawns **two** processes regardless of artifact count, against v2's one to
three. The comparison itself is still a byte comparison of one canonical
document.

This is inside the process budget by construction, and it is measurable: the
`state` phase already reports its own duration and request count through the
timing report, so the tasks can assert the spawn count directly rather than
inferring it from wall-clock time.
