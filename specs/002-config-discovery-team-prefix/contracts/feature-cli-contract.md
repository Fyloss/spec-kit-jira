# Contract — `feature` command (new, both ports)

The deterministic ticket-first naming step, registered as the
`hooks.before_specify` → `speckit.jira.feature` hook (`optional: true`,
non-blocking). Behaviour, exit codes, and output bytes identical across ports
(FR-020).

## Invocation

```text
spec-kit-jira feature [TICKET-KEY] [--use-team <id>] [--json] [--dry-run] <description>
```

- `TICKET-KEY` (optional positional, issue-key shape): a ticket the developer
  mentioned. Validated against Jira before use (FR-013).
- `--use-team <id>`: the answer to the cross-team closed confirmation
  (FR-014) — accepts only catalogue ids; per-feature effect only, the
  personal file is never modified.
- `--dry-run`: predicts the ticket action (`would create` / `would attach`)
  and computes all names; performs zero Jira writes.

## Output (canonical JSON on `--json`; prose otherwise)

```jsonc
// Pass-through — no catalogue, no personal selection, or FR-016 fallback:
{ "active": false, "warnings": [ /* present only in the fallback case */ ] }

// Cross-team confirmation needed (interactive agents re-invoke with --use-team):
{ "active": true, "confirmation_required": {
    "ticket": "WEX-7", "ticket_team": "wex", "selected_team": "ijt" } }

// Nominal:
{
  "active": true,
  "team": "ijt",                        // effective team (FR-014)
  "ticket": { "key": "IJT-42", "number": "42", "action": "attached|created" },
  "branch_name": "ijt-42/invoice-export",
  "short_name": "ijt-invoice-export",   // flat folder component, prefix never duplicated
  "override_used": false,               // true when personal override applied (FR-012)
  "warnings": []
}
```

## Behaviour rules

1. **No team selected** (no catalogue, no personal file, or no `team` key) ⇒
   `{active:false}`, exit 0, zero output side effects — the host specify flow
   is byte-for-byte today's behaviour (FR-017).
2. **Personal file invalid** (unknown team, bad override, credential-shaped
   value) ⇒ exit 4, located error naming `.specify/jira/personal.yml`; valid
   team ids listed; credential-shaped values never echoed (FR-011/FR-018).
3. **Ticket resolution precedes naming** (FR-013). Mentioned key ⇒ sink read;
   its project mapped to another catalogue team without `--use-team` ⇒
   `confirmation_required` output, exit 0, zero writes (unattended callers
   treat it as a stop). Mapped to no catalogue team ⇒ analogous proceed/stop
   closed confirmation. No key ⇒ guarded create (`POST /issue`) in the
   effective team's project using the binding's resolved story-type id; the
   PASS-1 privacy guard runs before the write.
4. **Non-blocking fallback** (FR-016): Jira unreachable or create refused ⇒
   `{active:false}` + exactly one warning; exit 0. Reconciliation attaches the
   ticket later. This never blocks feature creation.
5. **Naming** (FR-015): `number` = key minus `^[A-Z][A-Z0-9_]+-`;
   `branch_name` = pattern expansion; `short_name` = `folder_prefix` +
   descriptive short name with prefix dedup (`ijt-ijt-…` never occurs);
   `/` in the pattern creates git hierarchy only — the folder component stays
   flat and single-level.

## Exit codes

`0` success, pass-through, fallback, or `confirmation_required` ·
`1` usage · `2` fail-closed read on a mentioned key (never for auto-create —
that path falls back per rule 4) · `3` auth on a mentioned-key read ·
`4` personal-file/catalogue refusal · `9` privacy BLOCK on the create payload.

## Agent command definition (`commands/speckit.jira.feature.md`)

Documents the ordered ceremony: run this command; on
`confirmation_required` ask the closed question and re-invoke with
`--use-team` (or stop on refusal); on `{active:false}` proceed exactly as
today; otherwise drive `create-new-feature.sh --short-name "<short_name>"`,
then create/switch to `branch_name`, and report `override_used` and the
ticket action in the feature-creation output. The host `speckit-specify` skill
already consumes a `before_specify` hook's `BRANCH_NAME` JSON — the branch
name does not dictate the spec directory name.

## Hook registration delta (`register_hooks`)

`HOOK_EVENTS` gains `before_specify` mapped to command `speckit.jira.feature`
(`enabled: true`, `optional: true`), merged set-not-append; an
operator-disabled entry is never re-added or re-enabled; all six existing
`after_*` registrations are unchanged.
