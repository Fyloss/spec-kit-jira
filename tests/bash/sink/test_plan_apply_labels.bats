#!/usr/bin/env bats
# T019 [US2] — the provenance label (017, contracts/provenance-label.md §6):
# both mirror creation roles carry speckit-<slug>; a recorded labels default
# survives alongside it; a recognised ticket missing the label is updated
# exactly once; operator labels are preserved; a differently-ordered current
# label list still compares unchanged (the R4 regression); a halted ticket is
# neither labelled nor written; --dry-run bodies equal the real run's.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
}

teardown() {
  mock_stop 2> /dev/null || true
}

# --- T1, T2 — creation payloads (no recognised ticket, no mock needed: a
# brand-new story issues no read before its create is planned) ------------

_setup_fresh_spec() {
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  export JIRA_CONFIG_DIR="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-legacy/.specify/jira"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT

  mkdir -p "${BATS_TEST_TMPDIR}/fresh"
  SPEC_FRESH="${BATS_TEST_TMPDIR}/fresh/spec.md"
  printf '%s\n' \
    '# Feature Specification: Rich Tickets' '' 'We need a reconcile bridge for specs.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a signed-in user' '- **When** they open the board' '- **Then** the widgets load' \
    > "${SPEC_FRESH}"
}

@test "T1 — parent and child creation payloads carry speckit-<slug>" {
  _setup_fresh_spec
  run cmd_reconcile reconcile --dry-run --json "${SPEC_FRESH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].role' <<< "$output")" = "parent" ]
  [ "$(jq -r '.actions[0].body.fields.labels | join(",")' <<< "$output")" = "speckit-001-feature" ]
  [ "$(jq -r '.actions[1].role' <<< "$output")" = "story" ]
  [ "$(jq -r '.actions[1].body.fields.labels | join(",")' <<< "$output")" = "speckit-001-feature" ]
}

@test "T2 — a recorded labels field default survives alongside the provenance label" {
  _setup_fresh_spec
  export SPEC_KIT_JIRA_PLAN_CONTEXT='{"story_type_id":"10004","parent_type_id":"10003","field_defaults":{"10004":{"labels":["team-x"]},"10003":{"labels":["team-x"]}}}'
  run cmd_reconcile reconcile --dry-run --json "${SPEC_FRESH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actions[0].body.fields.labels | sort | join(",")' <<< "$output")" = "speckit-001-feature,team-x" ]
  [ "$(jq -r '.actions[1].body.fields.labels | sort | join(",")' <<< "$output")" = "speckit-001-feature,team-x" ]
}

# --- T3, T5, T6, T8, T9, T14 — a mirrored corpus (real recognised tickets
# through the curl-shim mock) ------------------------------------------------

_setup_mirrored() {
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-billing-invoices/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT

  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Prime: create COMP-1/2/3 and write their markers into SPEC. The shim's
  # CREATE handler does not persist `labels` into its issue store (an
  # allowlisted subset of fields — contracts/curl-shim.md), so the primed
  # tickets land exactly where an existing consumer's pre-017 tickets would:
  # recognised, marker-bound, and carrying no provenance label yet.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
}

@test "T3 — a recognised ticket missing the label is updated exactly once; counts.updated reflects it" {
  _setup_mirrored
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # Every recognised ticket (the parent plus its 3 stories) lacks a label
  # going in — this run's ONLY change is the back-fill, one PUT per ticket,
  # counted as an update.
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 4 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]

  local body
  body="$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2")"
  [ "$(jq -r '.fields.labels | join(",")' <<< "${body}")" = "speckit-001-billing-invoices" ]
}

@test "T5 — a ticket carrying operator labels keeps every one of them after the update" {
  _setup_mirrored
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"labels":["priority-review"]}}' > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local body
  body="$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2")"
  [ "$(jq -r '.fields.labels | sort | join(",")' <<< "${body}")" = "priority-review,speckit-001-billing-invoices" ]
}

@test "T6 — current labels in a different order than ours still compare unchanged (the R4 regression)" {
  _setup_mirrored
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null # back-fills the label once

  # Simulate a real Jira returning the label array in its own order — swap
  # the two labels the first run left on COMP-3's neighbour COMP-2 by adding
  # a second label then re-ordering both through a direct PUT, exactly as a
  # human editing labels in the Jira UI would produce.
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"labels":["priority-review","speckit-001-billing-invoices"]}}' > /dev/null
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"labels":["speckit-001-billing-invoices","priority-review"]}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "T8 — a halted ticket is not labelled and no write is issued for it" {
  _setup_mirrored
  # phase_status_map is load-bearing here: without a target status to compare
  # against, drift_evaluate never runs and the halted branch never fires
  # (mirrors tests/bash/commands/test_reconcile_lifecycle.bats's own halted
  # test setup).
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
    phase_status_map:
      after_specify: "To Do"
    halted_statuses:
      - "Blocked"
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML
  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"status":{"name":"Blocked","statusCategory":{"key":"indeterminate"}}}}' > /dev/null

  : > "${MOCK_CALLLOG}"
  export SPEC_KIT_JIRA_HOOK_EVENT=after_specify
  run cmd_reconcile reconcile "${SPEC}" --json
  unset SPEC_KIT_JIRA_HOOK_EVENT
  [ "$status" -eq 0 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/COMP-2$' "${MOCK_CALLLOG}")" -eq 0 ]
  local body
  body="$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2")"
  [ "$(jq -r '.fields.labels // [] | length' <<< "${body}")" -eq 0 ]
}

@test "T9 — --dry-run action bodies equal the real run's, labels included" {
  _setup_mirrored
  # Both branches predict the SAME back-fill: a second copy of the ALREADY
  # PRIMED work tree (markers written, labels not yet back-filled), one run
  # --dry-run, the other for real.
  local dry_out
  dry_out="$(cmd_reconcile reconcile "${SPEC}" --dry-run --json)"

  local work2 spec2
  work2="${BATS_TEST_TMPDIR}/repo-real"
  cp -R "${WORK}" "${work2}"
  spec2="${work2}/specs/001-billing-invoices/spec.md"
  JIRA_CONFIG_DIR="${work2}/.specify/jira" run cmd_reconcile reconcile "${spec2}" --json
  [ "$status" -eq 0 ]

  local dry_labels real_labels
  dry_labels="$(jq -c '[.actions[].body.fields.labels] | sort' <<< "${dry_out}")"
  real_labels="$(jq -c '[.actions[].body.fields.labels] | sort' <<< "$output")"
  [ "${dry_labels}" = "${real_labels}" ]
}

@test "T14 — a ticket adopted through mention gains the label additively, the human's own labels survive" {
  _setup_mirrored
  local story_id
  story_id="$(grep -oE 'story=[0-9a-f]{16} ticket=COMP-2' "${SPEC}" | grep -oE '^story=[0-9a-f]{16}' | cut -d= -f2)"
  local spec_ref='{"repo":"local/repo","spec_slug":"001-billing-invoices","folder":"x"}'
  identity_write "COMP-2" "${spec_ref}" mention "${story_id}" > /dev/null

  curl -s -X PUT "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2" \
    -H 'Content-Type: application/json' \
    -d '{"fields":{"labels":["a-humans-own-label"]}}' > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local body
  body="$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-2")"
  [ "$(jq -r '.fields.labels | sort | join(",")' <<< "${body}")" = "a-humans-own-label,speckit-001-billing-invoices" ]
}
