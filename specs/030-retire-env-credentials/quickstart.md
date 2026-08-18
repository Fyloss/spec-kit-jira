# Quickstart: validating 030 — retire the .env credential file

**Feature**: 030-retire-env-credentials | **Date**: 2026-08-18

How to prove the feature works end to end. Read
[contracts/](./contracts/) for the clauses each step exercises.

---

## Prerequisite — the constitutional amendment

Constitution v2.0.0 was ratified 2026-08-18 and unblocks this feature (see
`plan.md` §Constitution Check and `research.md` §R9). Confirm it is present in
your working tree before starting:

```bash
grep -c 'Version.*2\.0\.0' .specify/memory/constitution.md
```

Expect `1`. If Principle IV still reads *"environment variables → OS secret
manager → gitignored `.env`"*, you are on a branch that predates the amendment
and implementation must not begin there.

---

## Setup — a working credential, the new way

macOS:

```bash
security add-generic-password -s spec-kit-jira -a "$USER" -w 'ATATT-your-token'
echo 'export JIRA_PAT_COMMAND="security find-generic-password -s spec-kit-jira -w"' >> ~/.zshrc
source ~/.zshrc
```

Linux:

```bash
secret-tool store --label='spec-kit-jira' service spec-kit-jira
export JIRA_PAT_COMMAND="secret-tool lookup service spec-kit-jira"
```

Windows (PowerShell 7+):

```powershell
Set-Secret -Name spec-kit-jira -Secret 'ATATT-your-token'
Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false
Add-Content $PROFILE "`n`$env:JIRA_PAT_COMMAND = 'Get-Secret spec-kit-jira -AsPlainText'"
. $PROFILE
```

Then the two non-secret settings — `config.yml` (committed, shared):

```yaml
base_url: https://your-site.atlassian.net
```

and `personal.yml`, which the ceremony creates for you (see step 3).

---

## Step 1 — the token never touches the workspace (US1, SC-001)

```bash
unset JIRA_API_TOKEN
./scripts/bash/spec-kit-jira.sh config --json
```

Expected: the ceremony authenticates. Then, the proof:

```bash
TOKEN="$(eval "$JIRA_PAT_COMMAND")"
grep -rIl --fixed-strings "$TOKEN" . 2>/dev/null | grep -v '^\./\.git/' || echo "CLEAN — token in no file"
```

Expected: `CLEAN`. Use `grep -rIl` and check for zero hits; per
`AGENTS.md`, do not verify this through a `grep` pipeline whose output another
tool may rewrite.

---

## Step 2 — the five failure modes are distinguishable (SC-003)

Five, not four: "the command does not exist" and "the command exited non-zero"
are separate modes, because they send you to different places. Each must produce
a *different* message naming the source at fault:

```bash
# 2a — nothing declared
env -u JIRA_API_TOKEN -u JIRA_PAT_COMMAND ./scripts/bash/spec-kit-jira.sh config --json

# 2b — command not found
env -u JIRA_API_TOKEN JIRA_PAT_COMMAND="definitely-not-installed --x" \
  ./scripts/bash/spec-kit-jira.sh config --json

# 2c — command fails
env -u JIRA_API_TOKEN JIRA_PAT_COMMAND="false" \
  ./scripts/bash/spec-kit-jira.sh config --json

# 2d — command prints nothing
env -u JIRA_API_TOKEN JIRA_PAT_COMMAND="true" \
  ./scripts/bash/spec-kit-jira.sh config --json

# 2e — command exceeds the 5 s bound  (expect this one to take ~5 s, not 30)
time env -u JIRA_API_TOKEN JIRA_PAT_COMMAND="sleep 30" \
  ./scripts/bash/spec-kit-jira.sh config --json
```

Expected: 2a names both variables; 2b–2e each name the command and how it
failed, 2e naming the bound it exceeded. None mentions `.env`. None prints a
token, and none echoes what the command wrote on **stdout** (C4.4).

**Read 2b–2e carefully — this is `config`, and `config` does not refuse.**
Per FR-038 the ceremony *reports* a declared command's failure and then
continues in degraded mode: exit **0**, the reason on stderr and in the
degraded run's `detail`. That is the point of the requirement — the operator
running `config` is the one who has no working credentials yet, and refusing
would withhold the file in which they declare them. To see the fail-closed half,
run the same five against a command that needs Jira — **not** `--dry-run`: a
dry-run previews writes without needing a real credential at all (it never
reaches the auth check for a fresh feature with nothing already recognised),
so it exits 0 regardless of what `JIRA_PAT_COMMAND` does; walked and confirmed
2026-08-18):

```bash
env -u JIRA_API_TOKEN JIRA_PAT_COMMAND="false" \
  ./scripts/bash/spec-kit-jira.sh reconcile path/to/your/spec.md
```

Expected: a non-zero auth exit, the same message — and, unlike today, a message
at all (C6.1).

Also confirm the silent half of C6.4: with **no** `JIRA_PAT_COMMAND` declared
(2a), degraded mode says the token is missing and says nothing about a retrieval
command. Absence is silent; declared failure is loud.

**Metacharacter inertness** (C2.2):

```bash
env -u JIRA_API_TOKEN JIRA_PAT_COMMAND='echo tok | tee /tmp/leak-030' \
  ./scripts/bash/spec-kit-jira.sh config --json
test -e /tmp/leak-030 && echo "FAIL — a shell interpreted the value" || echo "OK — inert"
```

**`.env` is inert** (US1 AC3):

```bash
printf 'JIRA_API_TOKEN=ATATT-should-be-ignored\n' > .specify/jira/.env
env -u JIRA_API_TOKEN -u JIRA_PAT_COMMAND ./scripts/bash/spec-kit-jira.sh config --json
```

Expected: the same failure as 2a. The `.env` token is not used and the file is
not mentioned.

**The old probe is gone** (US1 AC4): with the token in the keychain under
`spec-kit-jira` and `JIRA_PAT_COMMAND` unset, expect the 2a failure — not a
successful run.

---

## Step 3 — the ceremony creates `personal.yml` (US3)

```bash
rm -f .specify/jira/personal.yml   # use `trash` on a real workspace
./scripts/bash/spec-kit-jira.sh config --dry-run --json | jq '.effects.personal'
```

Expected: `status: "would_create"`, and no file on disk.

```bash
./scripts/bash/spec-kit-jira.sh config --json | jq '.effects.personal'
cat .specify/jira/personal.yml
```

Expected: `status: "created"`; the file carries an `email` (filled if
`JIRA_EMAIL` was set, commented otherwise) and a **commented** `team`
placeholder listing the catalogue's ids.

**The created file must not break the next run** (C2.6, SC-006) — this is the
step that catches the `team is invalid` defect:

```bash
./scripts/bash/spec-kit-jira.sh config --json | jq -r '.effects.personal.status'
```

Expected: `unchanged`, exit 0. A `config: personal (…): team is invalid` here
means `connection-settings.md` §4 was not implemented.

**Idempotency** (C3.1, C3.2):

```bash
cp .specify/jira/personal.yml /tmp/before-030
./scripts/bash/spec-kit-jira.sh config --json > /dev/null
diff /tmp/before-030 .specify/jira/personal.yml && echo "OK — byte-identical"
```

**Fresh setup / degraded mode** (C1.1, C4.3) — the case that motivated the
ordering:

```bash
rm -f .specify/jira/personal.yml
env -u JIRA_API_TOKEN -u JIRA_PAT_COMMAND SPEC_KIT_JIRA_BASE_URL= \
  ./scripts/bash/spec-kit-jira.sh config --json | jq '.effects | {personal, gitignore}'
test -f .specify/jira/personal.yml && echo "OK — created in degraded mode"
```

Expected: the file exists, `personal.status == "created"`, and `gitignore`
reports its true status rather than `skipped`.

---

## Step 4 — settings resolve from the files (US2)

```bash
env -u SPEC_KIT_JIRA_BASE_URL -u JIRA_EMAIL \
  ./scripts/bash/spec-kit-jira.sh config --json | jq -r '.status'
```

Expected: success, using `config.yml`'s `base_url` and `personal.yml`'s `email`.

**Environment wins** (C1.2):

```bash
SPEC_KIT_JIRA_BASE_URL=https://override.example.com \
  ./scripts/bash/spec-kit-jira.sh config --json
```

Expected: the override is used and the run is not refused.

**Located refusals** (C2.3, C3.3):

```bash
# trailing slash
sed -i.bak 's|^base_url:.*|base_url: https://your-site.atlassian.net/|' .specify/jira/config.yml
env -u SPEC_KIT_JIRA_BASE_URL ./scripts/bash/spec-kit-jira.sh config --json; echo "exit=$?"
mv .specify/jira/config.yml.bak .specify/jira/config.yml
```

Expected: exit 4 and `config: config (…): base_url is invalid`, before any
network call.

**The scheme rule and its one exception** (C2.6, FR-039). Repeat the refusal
above with `http://your-site.atlassian.net` — same exit 4. Then confirm the
exception loopback earns, which is also what makes the conformance mock loadable
from a fixture:

```bash
sed -i.bak 's|^base_url:.*|base_url: http://127.0.0.1:8080|' .specify/jira/config.yml
env -u SPEC_KIT_JIRA_BASE_URL ./scripts/bash/spec-kit-jira.sh config --json; echo "exit=$?"
mv .specify/jira/config.yml.bak .specify/jira/config.yml
```

Expected: **not** a `base_url is invalid` refusal — the value loads. `http` is
refused because credentials would cross the network in clear text, and on
loopback they cross nothing. `http://192.168.1.10:8080` is still refused: a
private address is not a loopback address.

**The variable is not validated** (C2.7, FR-040) — deliberate, and the one
asymmetry to expect:

```bash
SPEC_KIT_JIRA_BASE_URL='http://not-validated.example.com/' \
  ./scripts/bash/spec-kit-jira.sh config --json; echo "exit=$?"
```

Expected: **no** `base_url is invalid` refusal. A value that works when exported
can be refused once moved into `config.yml`; the located error says which key
and why.

**The exemption is not a hole** (C5.4) — each of these must still be refused:

| Put this | Here | Expect |
| --- | --- | --- |
| an email address | any `config.yml` key | refused, `email address` |
| a `*.atlassian.net` host | any `personal.yml` key | refused, `Atlassian Cloud host` |
| `ATATT…` | any key, any file | refused, `Atlassian API token` |
| an email address | `config.yml` → `base_url` | refused by field validation |

---

## Step 5 — the suites

```bash
tests/run-bash.sh                        # ~190s; --since <ref> for the inner loop
bash tests/conformance/ci-conformance.sh # cross-port byte equivalence
shellcheck -x -P scripts/bash $(find scripts/bash -name '*.sh')
```

Conformance success is **silent**: exit 0 and zero `conformance divergence`
lines. There is no pass banner, and the temp paths it prints are harness noise.

Never run the bash suite and conformance concurrently — they share fixtures and
invent a spurious divergence.

---

## Step 6 — Windows

The Windows runner is the only place a Windows-only divergence is diagnosed.
Push to `ci/windows-probe` (~11 min; results arrive as check-run annotations,
not logs) and read them there. Note that both the Windows Pester job on `main`
and the probe baseline are already red for unrelated reasons — compare against
that baseline rather than against green, and stop after one retry.

---

## Success checklist

| # | Criterion | Step |
| --- | --- | --- |
| SC-001 | No workspace file holds the token | 1 |
| SC-002 | Setup in ≤3 documented steps | Setup |
| SC-003 | Five distinguishable failure modes | 2 |
| SC-004 | Setting failures name file, key, variable | 4 |
| SC-005 | Ceremony is byte-identical on re-run | 3 |
| SC-006 | Created file never refuses the next run | 3 |
| SC-007 | Unattended run, env only | 4 |
| SC-008 | Both ports byte-identical | 5 |
| SC-009 | No doc tells you to file a token | doc sweep |
| SC-010 | Deleting `.env` changes nothing | 2 |
