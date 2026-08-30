# Quickstart: validating the retirement of the hook registry report

**Feature**: `034-retire-hook-report` | **Date**: 2026-08-30

Runnable checks that prove the feature end to end. Contract detail lives in
`contracts/`; what falls and why lives in `data-model.md` and `research.md`.

**Prerequisites**: `bats`, `jq`, `pwsh` 7+, `shellcheck`, `actionlint`. Run from
the repository root.

---

## 0. Before anything — prove the widened guard red (FR-010)

This runs **first**, against the pre-change code. A guard nobody has watched fail is
not known to work; this project has previously shipped guards that were inert.

```bash
# Stage the pre-change port into a scratch tree.
PRE=$(mktemp -d) && git archive HEAD scripts | tar -x -C "$PRE"

# Point the new guard at it and run.
SPEC_KIT_JIRA_GUARD_ROOT="$PRE" bats tests/bash/ci/test_no_registry_write.bats
```

**Expected**: FAIL, on the absence test, the deleted-module test and the read-verb
test. Record the output in `tasks.md`.

**Also check the instrument itself**: `grep -rc 'extensions\.yml' "$PRE/scripts"`
must print a non-zero count. A guard whose search root reads nothing passes
vacuously — that is how an inert guard looks from the outside.

After the deletion, the same command against the working tree must PASS, and the
guard must still FAIL against `$PRE`.

---

## 1. SC-001 — three registry states, one summary (US1)

```bash
for state in correct absent malformed; do
  # correct   → fixture registry untouched
  # absent    → rm .specify/extensions.yml from a copy of the fixture
  # malformed → write unparseable bytes into it
  ./scripts/bash/spec-kit-jira.sh config --json > "/tmp/ceremony-$state.json"
done

# Identical in hook-related content, which now means: containing none.
for state in correct absent malformed; do
  jq -e 'has("hook_health") | not' "/tmp/ceremony-$state.json"
  jq -e '.effects | has("hooks") | not'  "/tmp/ceremony-$state.json"
  jq -e '.exit_code == 0'                "/tmp/ceremony-$state.json"
done
```

**Expected**: all nine assertions pass. The malformed case is the one that matters —
a file the extension never opens cannot affect it, so there is no parse warning and
no exit-code difference (US1 AC3).

Then confirm the other three effects are unchanged in shape (US1 AC4):

```bash
jq -S '.effects' /tmp/ceremony-correct.json
# → exactly {discovery, gitignore, readme}, each with a write-outcome status
```

---

## 2. FR-003 — reconcile carries no verdict (US2)

```bash
./scripts/bash/spec-kit-jira.sh reconcile --json specs/…/spec.md \
  | jq -e 'has("hook_health") | not'
```

**Expected**: passes against a correct, an absent and a malformed registry alike.

---

## 3. FR-007 — hook-context failure is unchanged (US2 AC2, SC-003)

```bash
SPEC_KIT_JIRA_HOOK_CONTEXT=1 SPEC_KIT_JIRA_HOOK_EVENT=after_specify \
  ./scripts/bash/spec-kit-jira.sh reconcile --json <a spec that will fail> ; echo "exit=$?"
```

**Expected**: `exit=0`, and **exactly one** `WARNING: Jira mirror not completed —`
line on stderr. This is the half of the hooks behaviour the feature must not touch.

The standing proof is `tests/bash/hooks/test_hook_resilience.bats` and
`tests/powershell/hooks/HookResilience.Tests.ps1` — they must pass **unmodified**.
If a task needs to edit them, the deletion has reached further than the spec allows.

---

## 4. FR-004 — the withdrawn flag (US3 AC1)

```bash
./scripts/bash/spec-kit-jira.sh config --enable-hook after_specify ; echo "exit=$?"
```

**Expected**: refused through the existing unknown-flag path, naming
`--enable-hook`, with that path's usual exit code. Not a bespoke "retired" message.

---

## 5. SC-004 — the withdrawn key (US3 AC2/AC3)

```bash
printf 'hooks:\n  disabled:\n    - after_specify\n' >> .specify/jira/config.local.yml
./scripts/bash/spec-kit-jira.sh config --json ; echo "exit=$?"
```

**Expected**: `exit=4`, and a message carrying **both** `hooks` and the full path of
`config.local.yml`. Assert the text, not just the code — a refactor dropping the
path would keep the code green and lose the only part an operator can act on.

Removing those three lines must restore a clean validation (US3 AC3).

---

## 6. FR-012 / SC-005 — both ports, byte for byte

```bash
bash tests/conformance/ci-conformance.sh
```

**Expected**: exit 0 with zero `conformance divergence` lines. Success is silent —
there is no pass banner, and the temp paths in the output are harness noise.

Scenario disposition for this feature (research R9):

- `us9-hook-registration` — retired with its subject.
- `us021b-disabled-event` — re-pointed: the fixture stays, the expectation becomes
  the exit-4 located refusal of §5. This is what makes SC-004 a cross-port claim
  rather than two unit tests.
- `us4-port-selection` — description reworded only.

**Do not** run this concurrently with `tests/run-bash.sh`; they share fixtures and
will invent a divergence in an unrelated scenario.

---

## 7. SC-006 — no surviving claim about registration

```bash
git grep -nE 'enable-hook|hook_health|held_disabled|SPEC_KIT_JIRA_EXTENSIONS_YML|hooks\.disabled' \
  -- scripts/ tests/ docs/ commands/ templates/ README.md INSTALL.md
```

**Expected**: no output.

```bash
git grep -n 'extensions\.yml' -- scripts/
```

**Expected**: no output, or only the guard's own explanatory comment.

`specs/**` and `CHANGELOG.md` are **excluded on purpose** — they are the historical
record, and earlier specifications correctly describe the world they were written
in.

---

## 8. Suites and linters

```bash
tests/run-bash.sh                          # ~190s locally
pwsh -c 'Invoke-Pester tests/powershell'
find scripts/bash -name '*.sh' -exec shellcheck -x -P scripts/bash {} +
actionlint
```

**Expected**: green, with the deleted tests gone rather than skipped — a retired
test is deleted with its behaviour or re-pointed, never left passing vacuously
(Constitution XIII).

Re-pointed rather than deleted:

- `test_manifest_hooks.bats` / `Manifest.Hooks.Tests.ps1` — their last test now reads
  `JIRA_HOOK_EVENT_NAMES` from `lib/config.sh` instead of `HOOK_EVENTS` from the
  deleted module.
- `NoRegistryWrite` guards — widened to absence (§0).
- `test_config_three_effects.bats` / `Config.ThreeEffects.Tests.ps1` — the count
  stays three but the membership changes. Its "three" was
  discovery/hooks/readme, written before the gitignore effect existed; it becomes
  discovery/readme/gitignore.
- The two consumer-docs CI scans (`test_consumer_docs_invocation.bats`,
  `test_consumer_docs_naming_surface.bats`) if they hold the retired text.

The README idempotency and edge-case tests assert mechanism, not literals, and
should pass **unmodified** despite the template rewrite.

---

## 9. Release

```bash
grep -n 'version:' extension.yml     # → 0.24.0
head -40 CHANGELOG.md                # → a BREAKING entry
```

The CHANGELOG entry names, individually: the removed `--enable-hook` flag, the
removed `hooks.disabled` key, the removed `effects.hooks` and `hook_health` summary
fields, the five removed effect-status values, and the removed silent dispatch hold
for a hand-disabled event.

`0.24.0` and not `1.0.0`: below 1.0.0 the minor position is where a breaking change
goes, which is what the three preceding breaking features on `main` each did. The
literal appears in exactly two files, and CI greps to prove it.
