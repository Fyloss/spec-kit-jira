#!/usr/bin/env bats
# T059 [US3] — The reconcile command: engine -> sink -> summary, BLOCK-guarded.
# Every created Story has a ladder title and a non-empty structured description,
# and Gherkin criteria whenever the spec has any — including specs with no
# `## Summary` section (SC-002). The estimation is create-only (FR-018). The
# --dry-run report is exactly the planned action set (FR-033); the PowerShell
# port emits an identical summary (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  PS_CMD="${ROOT}/scripts/powershell/commands"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  # 004 T014b: migrated off the placeholder key, which config resolution
  # (FR-005) now refuses outright. Both the project key and epic strategy are
  # overridden here, so config.yml is never read (contract "Precedence"); the
  # fixture's config.local.yml supplies the persisted binding this suite's
  # creation-context assertions (issue type, estimation) now resolve through.
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export JIRA_CONFIG_DIR="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-legacy/.specify/jira"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT

  mkdir -p "${BATS_TEST_TMPDIR}/with"
  SPEC_WITH="${BATS_TEST_TMPDIR}/with/spec.md"
  printf '%s\n' \
    '# Feature Specification: Rich Tickets' '' 'We need a reconcile bridge for specs.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' 'Estimation: 5' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${SPEC_WITH}"

  mkdir -p "${BATS_TEST_TMPDIR}/nosummary"
  SPEC_NOSUMMARY="${BATS_TEST_TMPDIR}/nosummary/spec.md"
  printf '%s\n' '# Only A Title' > "${SPEC_NOSUMMARY}"
}

@test "dry-run plans a create with a ladder title and rich ADF description" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  # actions[0] is the parent (Phase 5, US2); the story creation follows it.
  [ "$(jq -r '.actions[0].role' <<< "$output")" = "parent" ]
  [ "$(jq -r '.actions[1].method' <<< "$output")" = "POST" ]
  [ "$(jq -r '.actions[1].body.fields.summary' <<< "$output")" = "The core story" ]
  # Non-empty structured description as an ADF doc with the Gherkin panel.
  [ "$(jq -r '.actions[1].body.fields.description.type' <<< "$output")" = "doc" ]
  [ "$(jq '[.actions[1].body.fields.description.content[] | select(.type=="panel")] | length' <<< "$output")" -eq 1 ]
}

@test "a spec with NO ## Summary still yields a non-empty description (SC-002)" {
  run cmd_reconcile reconcile --dry-run --json "${SPEC_NOSUMMARY}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[1].body.fields.summary' <<< "$output")" = "Only A Title" ]
  [ "$(jq '[.actions[1].body.fields.description.content[] | select(.type=="paragraph")] | length' <<< "$output")" -ge 1 ]
}

@test "an update never re-sends the estimation (FR-018)" {
  # T018: the durable identifier is pinned via SPEC_KIT_JIRA_ID_SOURCE
  # (research R4) rather than the retired positional "s1", since a
  # marker-less story is now assigned a fresh identifier before parsing.
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"estimation_field_id":"customfield_30044","tickets":{"1111111111111111":"ABC-1"},"parent_type_id":"10101","parent_local_id":"aaaaaaaaaaaaaaaa"}'
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[1].method' <<< "$output")" = "PUT" ]
  [ "$(jq 'has("customfield_30044") | not' <<< "$(jq -c '.actions[1].body.fields' <<< "$output")")" = "true" ]
}

@test "a create writes the estimation to the discovered field (FR-018)" {
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"estimation_field_id":"customfield_30044","story_type_id":"10004","parent_type_id":"10101","parent_local_id":"aaaaaaaaaaaaaaaa"}'
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$(jq -r '.actions[1].body.fields.customfield_30044' <<< "$output")" = "5" ]
}

@test "an override equal to the shipped placeholder is refused, zero writes (004 FR-005)" {
  export SPEC_KIT_JIRA_PROJECT_KEY="PROJ"
  run cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"placeholder"* ]]
}

@test "an invalid SPEC_KIT_JIRA_LIFECYCLE maps to the config exit code with an actionable error (FR-032)" {
  # Through the REAL dispatcher (live `set -euo pipefail`): an unguarded jq
  # failure used to kill the process with a raw exit code and no error message.
  SPEC_KIT_JIRA_LIFECYCLE='{not json' \
    run bash "${ROOT}/scripts/bash/spec-kit-jira.sh" reconcile --dry-run --json "${SPEC_WITH}"
  [ "$status" -eq 4 ]
  [[ "$output" == *"SPEC_KIT_JIRA_LIFECYCLE"* ]]
}

@test "the PowerShell port emits an identical dry-run summary (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(cmd_reconcile reconcile --dry-run --json "${SPEC_WITH}")"
  p="$(SPEC_KIT_JIRA_BASE_URL='https://mock' SPEC_KIT_JIRA_SPEC_SLUG='001-feature' \
       SPEC_KIT_JIRA_REPO='acme/app' SPEC_KIT_JIRA_PROJECT_KEY='TEST' \
       pwsh -NoProfile -Command "
        Import-Module '${PS_CMD}/Reconcile.psm1' -Force
        \$null = Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','${SPEC_WITH}')")"
  [ "${b}" = "${p}" ]
}

@test "a bare relative spec filename resolves from the cwd in both ports (NFR-1)" {
  # dirname of a bare filename is '.' in the Bash port; the PowerShell port's
  # Split-Path -Parent yields '' for the same input (and for a root-level path),
  # which must resolve identically instead of failing the interchange schema.
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(cd "${BATS_TEST_TMPDIR}/with" && cmd_reconcile reconcile --dry-run --json spec.md)"
  p="$(cd "${BATS_TEST_TMPDIR}/with" && \
       SPEC_KIT_JIRA_BASE_URL='https://mock' SPEC_KIT_JIRA_SPEC_SLUG='001-feature' \
       SPEC_KIT_JIRA_REPO='acme/app' SPEC_KIT_JIRA_PROJECT_KEY='TEST' \
       pwsh -NoProfile -Command "
        Import-Module '${PS_CMD}/Reconcile.psm1' -Force
        \$null = Invoke-JiraReconcile -Arguments @('reconcile','--dry-run','--json','spec.md')")"
  [ -n "${b}" ]
  [ "${b}" = "${p}" ]
}

# =============================================================================
# T048 / T087 [003 US5] — Message discipline (FR-016 – FR-020, FR-030)
# =============================================================================
#
# Under `optional: false` the assistant PERFORMS this step inside every lifecycle
# command, so whatever it says is said seven times a feature. Two limits follow,
# and neither is cosmetic: at most one message per run (FR-016), and the
# not-yet-configured notice — the state of every repository for its first hour —
# capped at three lines (FR-019, US5 scenario 3).
#
# The causes must also be told apart. The reported defect's message named a
# machine-wide CLI that was never how this extension is delivered, which sent the
# developer to install something that does not exist. FR-017 lists seven causes and
# requires the message to name the true one; the sixth — the entry point missing
# — is the one the bridge cannot report from inside a run that never started, so
# what is testable here is the half-broken install it CAN detect.

_md_work() {
  MDWORK="$(mktemp -d)"
  mkdir -p "${MDWORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${MDWORK}/.specify/jira"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${MDWORK}/.specify/extensions.yml"
  export JIRA_NO_SLEEP=1
  export JIRA_MAX_ATTEMPTS=1
}

@test "not yet configured: exit 0, one notice, at most THREE lines (FR-019)" {
  _md_work
  unset SPEC_KIT_JIRA_BASE_URL
  run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output" | tr -d ' ')" -le 3 ]
  [[ "$output" == *"not bound to a Jira project yet"* ]]
  # It names the configuration command, spelled as it is registered (FR-018).
  [[ "$output" == *"/speckit.jira.config"* ]]
  # And it does NOT read as a failure: the host command succeeded.
  [[ "$output" == *"completed normally"* ]]
  rm -rf "${MDWORK}"
}

@test "not yet configured is NOT reported as a missing CLI (FR-017)" {
  # The exact wording of the reported defect. It was wrong twice: the cause was
  # not a missing CLI, and this extension is not delivered as one.
  _md_work
  unset SPEC_KIT_JIRA_BASE_URL
  run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [[ "$output" != *"CLI not installed"* ]]
  [[ "$output" != *"not installed"* ]]
  rm -rf "${MDWORK}"
}

@test "bridge unavailable is its OWN cause, never folded into 'not configured' (T090, FR-017)" {
  # A half-broken install: this port running while its twin is missing. The
  # remedy is an install, not a configuration — so saying "not configured" here
  # would send the operator to the wrong place entirely.
  _md_work
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  local fake="${MDWORK}/fake-root"
  mkdir -p "${fake}/scripts/bash"
  cp "${ROOT}/scripts/bash/spec-kit-jira.sh" "${fake}/scripts/bash/"
  # ...and no scripts/powershell/spec-kit-jira.ps1.
  SPEC_KIT_JIRA_EXTENSION_ROOT="${fake}" run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bridge entry point"* ]]
  [[ "$output" == *"powershell/spec-kit-jira.ps1"* ]]
  [[ "$output" == *"install is incomplete"* ]]
  # Distinguished from the not-configured cause...
  [[ "$output" != *"not bound to a Jira project"* ]]
  # ...and from the generic prerequisite gate.
  [[ "$output" != *"missing required command"* ]]
  # The remedy is the official install, in its runnable form (FR-018).
  [[ "$output" == *"specify extension add --dev <path-to-spec-kit-jira> --force"* ]]
  rm -rf "${MDWORK}"
}

@test "a bridge-unavailable run still completes the host command successfully (FR-015)" {
  _md_work
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  local fake="${MDWORK}/fake-root"
  mkdir -p "${fake}/scripts/bash"
  SPEC_KIT_JIRA_EXTENSION_ROOT="${fake}" run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  rm -rf "${MDWORK}"
}

@test "at most ONE message per host command run (FR-016)" {
  # Every degraded path emits its notice and stops. Counting the distinct notice
  # prefixes is the check that a second one has not crept in beside the first.
  _md_work
  unset SPEC_KIT_JIRA_BASE_URL
  run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [ "$(grep -c 'Jira mirror skipped' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'WARNING:' <<< "$output" || true)" -eq 0 ]
  rm -rf "${MDWORK}"
}

@test "a hook-context failure emits exactly one WARNING naming the true cause (FR-016, FR-017)" {
  _md_work
  export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  # This test is about hook-context WARNING behaviour on a network failure, not
  # about the config-resolved binding (_md_work's dir has none) — bypass it
  # with a minimal override supplying the issue type the assembly guard needs.
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004"}'
  run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
  [[ "$output" == *"Jira mirror not completed"* ]]
  [[ "$output" == *"This spec-kit command completed normally"* ]]
  # And it names only commands runnable as spelled — never the removed flag.
  [[ "$output" != *"repair-hooks"* ]]
  [[ "$output" == *"/speckit.jira.config"* ]]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
  rm -rf "${MDWORK}"
}

@test "a disabled event says NOTHING — not even that it was skipped (FR-020)" {
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  _md_work
  unset SPEC_KIT_JIRA_BASE_URL
  config_hooks_disabled_add after_plan "${JIRA_CONFIG_DIR}" > /dev/null
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan
  run cmd_reconcile reconcile --json "${SPEC_WITH}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  unset SPEC_KIT_JIRA_HOOK_EVENT
  rm -rf "${MDWORK}"
}
