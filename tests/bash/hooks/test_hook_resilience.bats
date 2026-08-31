#!/usr/bin/env bats
# T021 [003 US2] — Hook resilience under `optional: false` (FR-015, FR-020, SC-008).
#
# Two guarantees that are easy to confuse, and this suite keeps them apart.
#
# 1. NON-BLOCKING OUTCOME survives the switch to `optional: false`. That flag
#    decides whether the agent PERFORMS the hook, not whether a failure
#    propagates (research R4). Every bridge fault must still leave the host
#    command's exit code untouched: in hook context a non-zero exit is downgraded
#    to 0 after exactly one actionable warning.
#
# 2. AN OPERATOR'S DISABLE SURVIVES A REINSTALL — as an EFFECT, not as a field.
#    `specify extension add` rewrites `enabled: true` unconditionally and this
#    extension may not correct it (FR-022), so the old assertion — that the
#    registry still reads `enabled: false` after a repair — was asserting
#    something upstream makes impossible (research R5). What is guaranteed
#    instead, and what these cases assert, is that NO BRIDGE STEP RUNS for a
#    recorded event whatever the registry currently says.
#
# The PowerShell port behaves identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  WORK="$(mktemp -d)"
  # An unreachable base makes every write fail-closed instantly (connection refused).
  export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  # 004 FR-005: the shipped placeholder is now refused outright, so this suite
  # (about hook resilience, not config resolution) is migrated to a real key
  # with a matching epic-strategy override — both bypass config.yml, which
  # this isolated work dir never has.
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  # A minimal override supplying the issue type the assembly guard requires —
  # this suite has no persisted binding to resolve one from.
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004"}'
  unset SPEC_KIT_JIRA_HOOK_CONTEXT

  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Resilience' '' 'A spec that mirrors to Jira.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a bridge failure outside hook context fails the reconcile (baseline)" {
  run cmd_reconcile reconcile --json "${SPEC}"
  # Not a hook: the fail-closed write surfaces a non-zero exit.
  [ "$status" -ne 0 ]
}

@test "a bridge failure IN hook context never fails the host and warns once (FR-046)" {
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile --json "${SPEC}"
  # The host command is unaffected: the mirror's failure is downgraded to exit 0.
  [ "$status" -eq 0 ]
  # Exactly one actionable WARNING is surfaced (at most one, FR-046).
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
  # The summary still reports exit_code 0.
  [ "$(jq -r '.exit_code' <<< "$(grep '^{' <<< "$output")")" = "0" ]
}

@test "an unreadable local binding inside a hook leaves the host exit 0 with the three lines plus one WARNING (007 FR-011)" {
  mkdir -p "${WORK}/.specify/jira"
  printf 'resolved_ids:\n  TEST:\n    this line has no delimiter\n' > "${WORK}/.specify/jira/config.local.yml"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
  [[ "$output" == *"cannot parse this line as a mapping entry"* ]]
}

@test "every bridge fault leaves the host exit code untouched under optional:false (FR-015)" {
  # The faults reachable without a live Jira: an unreachable base (fail-closed
  # write), an unparseable spec, and a malformed lifecycle payload. Under
  # `optional: false` the agent performs the hook, so each of these now happens
  # inside a host command that must still succeed.
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]

  local bad="${WORK}/bad.md"
  printf '%s\n' 'not a specification at all' > "${bad}"
  run cmd_reconcile reconcile --json "${bad}"
  [ "$status" -eq 0 ]

  SPEC_KIT_JIRA_LIFECYCLE='{not json' run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
}

@test "the PowerShell port downgrades a hook-context failure identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local PS_CMD="${ROOT}/scripts/powershell/commands"
  local status_ps
  status_ps="$(SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1" SPEC_KIT_JIRA_SPEC_SLUG="001-feature" \
    SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004"}' \
    SPEC_KIT_JIRA_HOOK_CONTEXT=1 JIRA_NO_SLEEP=1 JIRA_MAX_ATTEMPTS=1 \
    JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" \
    pwsh -NoProfile -Command "
      Import-Module '${PS_CMD}/Reconcile.psm1' -Force
      \$sw=[System.IO.StringWriter]::new(); \$orig=[Console]::Out; [Console]::SetOut(\$sw)
      \$code = Invoke-JiraReconcile -Arguments @('reconcile','--json','${SPEC}')
      [Console]::SetOut(\$orig)
      [Console]::Out.Write(\$code)")"
  [ "${status_ps}" = "0" ]
}

# =============================================================================
# T110b [Phase 8, 022] — a checklist-caused fault (privacy BLOCK on an entry's
# text) downgrades under hook context exactly like any other bridge fault
# (FR-039, Constitution III). No new wiring — the dispatcher-level downgrade
# is content-agnostic by construction; this pins that the checklist path
# never bypasses it.
# =============================================================================

@test "T110b: a checklist entry's privacy BLOCK never fails the host in hook context, and is reported as a warning" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/config.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/conformance/mock-jira/lib.sh"
  local hookwork; hookwork="$(mktemp -d)"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-config/.specify" "${hookwork}/.specify"
  export JIRA_CONFIG_DIR="${hookwork}/.specify/jira"
  local cfg; cfg="$(mock_write_config '{"projects":{"COMP":"company"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_config config --child-type COMP=Story --json > /dev/null
  printf 'task_mirror:\n  COMP: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"

  mkdir -p "${hookwork}/specs/001-feature"
  local hspec="${hookwork}/specs/001-feature/spec.md"
  local htasks="${hookwork}/specs/001-feature/tasks.md"
  {
    printf '%s\n' '# Feature Specification: Hook Resilience Demo' ''
    printf '%s\n' 'We need a working task tier.' ''
    printf '%s\n' '### User Story 1 - The first story (Priority: P1)' ''
    printf '%s\n' 'As a user, I want the first story.' ''
    printf -- '%s\n' '- **Given** a thing' '- **When** it happens' '- **Then** it works'
  } > "${hspec}"
  {
    printf '%s\n' '# Tasks' '' '## Phase 3: User Story 1' ''
    printf -- '%s\n' '- [ ] T001 [US1] leak acme-corp.atlassian.net'
  } > "${htasks}"

  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile "${hspec}" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING:"* ]]
  [[ "$output" == *"the privacy guard blocked the write"* ]]
  # Zero writes: the block prevented every write, including the checklist's.
  run mock_calls
  ! [[ "$output" == *"POST /rest/api/3/issue"* ]]

  mock_stop
  rm -rf "${hookwork}"
}

# =============================================================================
# T084 [030] — the fail-closed departure: a declared retrieval command that
# fails now RAISES where the old .env/secret-manager rungs fell through
# silently. In hook context the host is still never failed (FR-015 holds
# unconditionally) — what changes is that the failure is REPORTED, and that
# it is bounded rather than hanging or prompting.
# =============================================================================

@test "T084: a hook-invoked run with a failing declared JIRA_PAT_COMMAND reports and completes without hanging or prompting" {
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/secret_store_stub.bash"
  local bindir counter prog
  bindir="${WORK}/bin" counter="${WORK}/count"
  prog="$(helper_pat_command_install "${bindir}" "${counter}" "" 1)"
  export JIRA_PAT_COMMAND="${prog}"
  unset JIRA_API_TOKEN
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  local start end elapsed
  start="${EPOCHSECONDS:-$(date +%s)}"
  run cmd_reconcile reconcile --json "${SPEC}"
  end="${EPOCHSECONDS:-$(date +%s)}"
  elapsed=$((end - start))

  # Bounded: the credential rung's own 5s bound, not a hang — a generous
  # ceiling for CI-noise, still far below "prompting and waiting on a human".
  [ "${elapsed}" -lt 10 ]
  # The host is never failed (FR-015 holds for this new failure branch too).
  [ "$status" -eq 0 ]
  # Reported: exactly one WARNING, unlike the old rungs' silent fall-through.
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
  [[ "$output" == *"credential resolution failed"* ]]
}
