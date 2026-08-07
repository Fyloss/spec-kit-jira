#!/usr/bin/env bats
# T022a/T047a [Phase 9, T081] — FR-026 and Constitution XI's dry-run
# enforcement test for the role mapping (010, contracts/role-mapping.md).
# Nothing else in this feature exercises `reconcile --dry-run` outside the
# mandatory-field-gate parity already covered in test_reconcile_hierarchy.bats
# (§5, checks 5/6). This file covers the other two dry-run claims FR-026
# makes: the resolved type of the parent and of every child is named, with
# an action set identical to the real run's; and the §6.7 ordering refusal
# (the only §6 refusal reconcile's own §8 re-validation can raise — checks
# 1-3/§6.2-§6.6 are config-time-only, since by the time a binding reaches
# reconcile it has already resolved) is predicted byte-for-byte.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

boot_declared_hierarchy() {
  WORK="${BATS_TEST_TMPDIR}/repo-declared-hierarchy-dry"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-declared-hierarchy" "${WORK}"
  SPEC="${WORK}/specs/001-consumer-onboarding/spec.md"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-consumer-onboarding"
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222"
  mock_start "${MOCK}/configs/consumer-hierarchy.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "T022a — --dry-run over the declared-hierarchy fixture names the resolved type of the parent and of every child" {
  boot_declared_hierarchy

  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dry_run' <<< "$output")" = "true" ]
  [ "$(jq -r '.actions[0].role' <<< "$output")" = "parent" ]
  [ "$(jq -r '.actions[0].body.fields.issuetype.id' <<< "$output")" = "10701" ]
  [ "$(jq -r '[.actions[] | select(.role=="story")] | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.actions[] | select(.role=="story")][0].body.fields.issuetype.id' <<< "$output")" = "10704" ]
  [ "$(jq -r '[.actions[] | select(.role=="story")][1].body.fields.issuetype.id' <<< "$output")" = "10704" ]

  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

@test "T022a — the dry-run action set is identical to the real run's over the same starting state" {
  boot_declared_hierarchy
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  local dry_types dry_count
  dry_types="$(jq -cS '[.actions[].body.fields.issuetype.id] | sort' <<< "$output")"
  dry_count="$(jq -r '.actions | length' <<< "$output")"

  # A fresh copy at the SAME starting state, run for real.
  local work2="${BATS_TEST_TMPDIR}/repo-declared-hierarchy-dry-real"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-declared-hierarchy" "${work2}"
  export JIRA_CONFIG_DIR="${work2}/.specify/jira"
  run cmd_reconcile reconcile "${work2}/specs/001-consumer-onboarding/spec.md" --json
  [ "$status" -eq 0 ]
  local real_count
  real_count="$(jq -r '.counts.created' <<< "$output")"
  [ "${dry_count}" -eq "${real_count}" ]
  [ "${dry_types}" = '["10701","10704","10704"]' ]
}

@test "T047a — a §6.7 ordering refusal is predicted by --dry-run exactly as the real run — same exit code, same bytes, zero writes" {
  boot_declared_hierarchy
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null

  local localf="${JIRA_CONFIG_DIR}/config.local.yml"
  local injected
  injected="$(jq -cS '.resolved_ids.CONSUMER.roles = {
      specification: {logical_name: "Story", id: "10704", hierarchy_level: "0", subtask: false, source: "declared"},
      story: {logical_name: "Epic", id: "10701", hierarchy_level: "1", subtask: false, source: "declared"}
    }' <<< "$(config_yaml_to_json "${localf}")")"
  printf '%s' "${injected}" | config_to_yaml > "${localf}"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  local dry_status="$status" dry_output="$output"
  [ "${dry_status}" -eq 4 ]
  [[ "${dry_output}" == *"reconcile: project CONSUMER: specification names"* ]]
  [[ "${dry_output}" == *"is not above story"* ]]

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq "${dry_status}" ]
  [ "$output" = "${dry_output}" ]

  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

@test "the PowerShell port predicts the parent's and every child's resolved type identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local pswork="${BATS_TEST_TMPDIR}/repo-declared-hierarchy-dry-ps"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-declared-hierarchy" "${pswork}"
  mock_start "${MOCK}/configs/consumer-hierarchy.json" powershell
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local ps_out
  ps_out="$(SPEC_KIT_JIRA_REPO="acme/app" SPEC_KIT_JIRA_SPEC_SLUG="001-consumer-onboarding" \
    JIRA_CONFIG_DIR="${pswork}/.specify/jira" JIRA_EMAIL="${JIRA_EMAIL}" JIRA_API_TOKEN="${JIRA_API_TOKEN}" JIRA_NO_SLEEP=1 \
    pwsh -NoProfile -Command "
      Import-Module '${ROOT}/scripts/powershell/commands/Reconcile.psm1' -Force
      [void](Invoke-JiraReconcile -Arguments @('reconcile','${pswork}/specs/001-consumer-onboarding/spec.md','--dry-run','--json'))
    " 2>/dev/null)"
  [ "$(jq -r '.actions[0].body.fields.issuetype.id' <<< "${ps_out}")" = "10701" ]
  [ "$(jq -r '[.actions[] | select(.role=="story")] | length' <<< "${ps_out}")" -eq 2 ]
}

# --- 019, T043: FR-017 on the origin-bridge, no-boundary payload -----------
@test "019, T043 — --dry-run predicts exactly the description payload and the (now empty) warning set an origin-bridge, no-boundary ticket produces, and issues zero writes (FR-017)" {
  local work="${BATS_TEST_TMPDIR}/repo-pre-release-migration-dry"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-pre-release-migration" "${work}"
  local spec="${work}/specs/001-feature/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_ID_SOURCE
  mock_start "${MOCK}/configs/preserve-pre-release.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${spec}" --dry-run --json
  local dry_status="$status" dry_output="$output"
  [ "${dry_status}" -eq 0 ]
  local pre1_dry; pre1_dry="$(jq -c '.actions[] | select(.url | endswith("PRE-1"))' <<< "${dry_output}")"
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre1_dry}")" = "$(adf_managed_marker)" ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-1"))) | length' <<< "${dry_output}")" -eq 0 ]

  local real_work="${BATS_TEST_TMPDIR}/repo-pre-release-migration-dry-real"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-pre-release-migration" "${real_work}"
  export JIRA_CONFIG_DIR="${real_work}/.specify/jira"
  run cmd_reconcile reconcile "${real_work}/specs/001-feature/spec.md" --json
  local real_status="$status" real_output="$output"
  [ "${real_status}" -eq "${dry_status}" ]
  local pre1_real; pre1_real="$(jq -c '.actions[] | select(.url | endswith("PRE-1"))' <<< "${real_output}")"
  [ "$(jq -c '.body.fields.description' <<< "${pre1_dry}")" = "$(jq -c '.body.fields.description' <<< "${pre1_real}")" ]
}

# --- T060 [016, US3] — the rendered description in the dry-run preview -----
@test "T060 [016, US3] — the rendered description appears in the dry-run preview with no write issued (FR-014)" {
  local work="${BATS_TEST_TMPDIR}/repo-markdown-prose-dry"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-markdown-prose" "${work}"
  local spec="${work}/specs/001-markdown-prose/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-markdown-prose"
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${spec}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dry_run' <<< "$output")" = "true" ]

  local desc
  desc="$(jq -c '[.actions[] | select(.role=="story")][0].body.fields.description' <<< "$output")"
  [[ "${desc}" == *'"type":"strong"'* ]]
  [[ "${desc}" != *'**FR-012**'* ]]

  # 017's duplicate-probe search runs even under --dry-run (T022a establishes
  # this pattern) — FR-014's "no write issued" means no POST/PUT, not zero
  # calls.
  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

# --- T061 [US2] — dry-run/real-run agreement for field defaults (011, ------
# contract §4.3, FR-023) --------------------------------------------------
@test "FR-023 — the preview predicts every defaulted value and its source, asks no question, and writes nothing" {
  local work="${BATS_TEST_TMPDIR}/repo-field-defaults-dry"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${work}"
  local spec="${work}/specs/001-reporting/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  cmd_config config PM --issue-type "PM=story=Story" \
    --field-default 'PM=Deliverable=Business Owner=Platform Team' \
    --field-default 'PM=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null

  run cmd_reconcile reconcile "${spec}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dry_run' <<< "$output")" = "true" ]
  # No question, ever, from a preview (§4.3) — even though ask defaults to
  # true and neither --accept-defaults nor a --field-value was given.
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
  [ "$(jq -r '[.actions[] | select(.role=="parent")][0].body.fields.customfield_40011' <<< "$output")" = "Platform Team" ]
  [ "$(jq -r '[.actions[] | select(.role=="parent")][0].body.fields.customfield_40012' <<< "$output")" = "PI-2026-Q3" ]
  [[ "$output" == *"sent from team-config"* ]]

  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}
