#!/usr/bin/env bats
# T046 [US4, P3, droppable] — the duplicate probe (017,
# contracts/duplicate-probe.md §6): before creating a parent the
# specification holds no marker for, look for tickets already carrying its
# provenance label and refuse rather than duplicating. Read-only,
# best-effort — its false negative leaves today's behaviour unchanged.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="test-token-value"
}

teardown() {
  mock_stop 2> /dev/null || true
}

# --- T1, T2, T5 — the sink primitive directly -------------------------------

@test "T1, T2 — hit: zero writes, exit 4, message names sorted keys; found tickets untouched" {
  local cfg="${BATS_TEST_TMPDIR}/cfg.json"
  printf '{"labelSearch":{"speckit-001-x":["COMP-9","COMP-2"]}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1

  run duplicate_probe_check "${MOCK_BASE_URL}" "COMP" "speckit-001-x"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' <<< "$output")" = "hit" ]
  [ "$(jq -r '.keys | join(",")' <<< "$output")" = "COMP-2,COMP-9" ]
}

@test "T5 — no labelled ticket: clear, creation proceeds" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  run duplicate_probe_check "${MOCK_BASE_URL}" "COMP" "speckit-001-nothing-here"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.verdict' <<< "$output")" = "clear" ]
}

@test "T4 — 400/403/404 on the probe: unavailable, never propagated as an error" {
  for code in 400 403 404; do
    local cfg="${BATS_TEST_TMPDIR}/fault-${code}.json"
    printf '{"faults":{"rest/api/3/search/jql":{"status":%s}}}' "${code}" > "${cfg}"
    mock_start "${cfg}"
    export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
    run duplicate_probe_check "${MOCK_BASE_URL}" "COMP" "speckit-001-x"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.verdict' <<< "$output")" = "unavailable" ]
    mock_stop
  done
}

# --- Full pipeline: T1, T3, T6, T7, T9 --------------------------------------

_setup_fresh() {
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="COMP"
  # A COPY of the fixture's config, never the fixture itself: 021's
  # run_state_record writes ${JIRA_CONFIG_DIR}/state/<feature>.json on every
  # successful reconcile, and this test reaches one. Pointed at the source
  # tree it deposits a machine-specific document (absolute paths, the live
  # mock port, the real extension version) inside tests/conformance/fixtures,
  # where the state/.gitignore's `*` then hides it from git status.
  export JIRA_CONFIG_DIR="${BATS_TEST_TMPDIR}/jira-config"
  mkdir -p "${JIRA_CONFIG_DIR}"
  cp "${ROOT}/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira/"*.yml "${JIRA_CONFIG_DIR}/"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT

  mkdir -p "${BATS_TEST_TMPDIR}/fresh"
  SPEC="${BATS_TEST_TMPDIR}/fresh/spec.md"
  printf '%s\n' \
    '# Feature Specification: Billing Invoices' '' 'We need a reconcile bridge for specs.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${SPEC}"
}

@test "T1 — full pipeline: a hit refuses before creating the parent, zero writes, exit 4" {
  local cfg="${BATS_TEST_TMPDIR}/cfg.json"
  printf '{"labelSearch":{"speckit-001-billing-invoices":["COMP-9","COMP-2"]}}' > "${cfg}"
  mock_start "${cfg}"
  _setup_fresh

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"COMP-2, COMP-9"* ]]
  [[ "$output" == *"mention <issue-key>"* ]]
  [ "$(grep -cE '^(POST|PUT) ' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "T3 — markers present, binding those very tickets: the probe never fires, no request" {
  mock_start "${MOCK}/configs/default.json"
  _setup_fresh
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c 'search/jql' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "T6 — a settled re-run issues no probe request at all" {
  mock_start "${MOCK}/configs/default.json"
  _setup_fresh
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(grep -c 'search/jql' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "T7 — --dry-run predicts the refusal" {
  local cfg="${BATS_TEST_TMPDIR}/cfg.json"
  printf '{"labelSearch":{"speckit-001-billing-invoices":["COMP-9"]}}' > "${cfg}"
  mock_start "${cfg}"
  _setup_fresh
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"COMP-9"* ]]
}

@test "T9 — under a hook context, the hit refusal returns 0 wrapped in the standard WARNING form" {
  local cfg="${BATS_TEST_TMPDIR}/cfg.json"
  printf '{"labelSearch":{"speckit-001-billing-invoices":["COMP-9"]}}' > "${cfg}"
  mock_start "${cfg}"
  _setup_fresh
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$output" == "WARNING: "*"(exit 4)"* ]]
  [[ "$output" == *"This spec-kit command completed normally."* ]]
}

@test "unavailable: 400 on the probe lets the run complete as it does with the probe absent, plus one warning" {
  local cfg="${BATS_TEST_TMPDIR}/cfg.json"
  printf '{"faults":{"rest/api/3/search/jql":{"status":400}}}' > "${cfg}"
  mock_start "${cfg}"
  _setup_fresh
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
  [[ "$(jq -r '.warnings | join(" ")' <<< "$output")" == *"duplicate-label check could not be performed"* ]]
}
