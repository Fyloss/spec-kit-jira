#!/usr/bin/env bats
# T014/T020/T022/T023 [Phase 3+4, US1/US2, 035] — the command layer's use of the
# specification's own record (contracts/marker-routing.md C2.1, C3.1-C3.6).
#
# The defect this reproduces: at /speckit-specify the specification is unbound,
# rank 4 places it in the operator's team project, and its keys are recorded in
# spec.md. At /speckit-plan the same specification is bound, 033's guard fires
# BECAUSE the first run succeeded, and resolution falls to routing_default — a
# different project. Story recognition then classifies every bound story as NEW.
#
# The two refusals are message-level here; end-to-end equivalence is the
# conformance corpus's job (C6.2).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"

  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT

  CFG='{
    "projects": [{"key": "ALPHA"}, {"key": "BETA"}],
    "routing_default": "BETA",
    "teams": [
      {"id": "alpha", "project": "ALPHA", "folder_prefix": "alpha-"},
      {"id": "beta", "project": "BETA", "folder_prefix": "beta-"}
    ]
  }'
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_HOOK_CONTEXT SPEC_KIT_JIRA_HOOK_EVENT SPEC_KIT_JIRA_PROJECT_KEY
}

# _mirrored_repo <marker-lines...> — the shipped mirrored-spec fixture, with
# this test's own marker set spliced into its specification. Every end-to-end
# case below drives the REAL command against the mock, because the facts they
# assert — zero requests, the hook downgrade, one project per run — are
# properties of the run, not of a message builder.
#
# It SETS `SPEC_PATH` rather than printing it: called as `$(_mirrored_repo …)`
# the export below would land in a subshell and never reach the caller, and the
# run would silently use the repository's own .specify/jira instead of the
# fixture's — passing for the wrong reason, or failing for a reason that has
# nothing to do with what is under test.
_mirrored_repo() {
  local work="${BATS_TEST_TMPDIR}/repo_$$_${RANDOM}"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  { printf '%s\n' '# Feature Specification: Billing Invoices' ''
    printf '%s\n' "$@"
    printf '%s\n' '' '### User Story 1 - Export an invoice (Priority: P1)' ''
    printf '%s\n' 'As a customer, I want to export one invoice as a PDF.' ''
    printf '%s\n' '- **Given** a signed-in customer viewing an invoice' \
      '- **When** they choose Export' '- **Then** a PDF download starts'
  } > "${spec}"
  SPEC_PATH="${spec}"
}

_bound_spec() {
  # A specification whose parent and stories are recorded in ALPHA, in a folder
  # carrying no team-specific prefix — the observed shape exactly.
  printf '%s\n' \
    '# Feature Specification: Test feature' \
    '' \
    '<!-- speckit-jira spec=0000000000000001 ticket=ALPHA-66 -->' \
    '' \
    '### User Story 1 - core story (Priority: P1)' \
    '' \
    '<!-- speckit-jira story=1111111111111111 ticket=ALPHA-67 -->' \
    '' \
    '- **Given** a signed-in user'
}

@test "C2.1 a bound specification routes to its own project, not routing_default" {
  local proj
  proj="$(marker_bound_projects "$(_bound_spec)")"
  run _reconcile_resolve_routing "031-test-feature" "${CFG}" "" "${proj}"
  [ "$status" -eq 0 ]
  [ "$output" = "ALPHA" ]
}

@test "C2.1 it routes to its own project whichever team the operator selected" {
  local proj
  proj="$(marker_bound_projects "$(_bound_spec)")"
  run _reconcile_resolve_routing "031-test-feature" "${CFG}" "beta" "${proj}"
  [ "$output" = "ALPHA" ]
}

@test "C2.5 an unbound specification is routed exactly as it is today" {
  # The regression that matters most: every existing repository untouched.
  run _reconcile_resolve_routing "031-test-feature" "${CFG}" "" ""
  [ "$output" = "BETA" ]
}

@test "C3.1 markers naming two projects: the refusal names the spec and EVERY project" {
  local out
  out="$(_reconcile_markers_split_refusal "specs/031-test-feature/spec.md" "$(printf 'ALPHA\nBETA\n')")"
  [[ "${out}" == *"specs/031-test-feature/spec.md"* ]]
  [[ "${out}" == *"ALPHA"* ]]
  [[ "${out}" == *"BETA"* ]]
  [[ "${out}" == *"zero writes"* ]]
}

@test "C3.6 the split refusal tells the operator what to do next" {
  local out
  out="$(_reconcile_markers_split_refusal "specs/031-test-feature/spec.md" "$(printf 'ALPHA\nBETA\n')")"
  [[ "${out}" == *"ticket="* ]]
}

@test "C3.2 the mismatch refusal names recorded, routed, and where routed came from (override)" {
  local out
  out="$(_reconcile_project_mismatch_refusal "specs/031-test-feature/spec.md" "ALPHA" "BETA" "override")"
  [[ "${out}" == *"specs/031-test-feature/spec.md"* ]]
  [[ "${out}" == *"ALPHA"* ]]
  [[ "${out}" == *"BETA"* ]]
  [[ "${out}" == *"SPEC_KIT_JIRA_PROJECT_KEY"* ]]
  [[ "${out}" == *"zero writes"* ]]
}

@test "C3.2 the mismatch refusal names the committed configuration when that is the source" {
  local out
  out="$(_reconcile_project_mismatch_refusal "specs/031-test-feature/spec.md" "ALPHA" "BETA" "config")"
  [[ "${out}" == *"config.yml"* ]]
  [[ "${out}" != *"SPEC_KIT_JIRA_PROJECT_KEY"* ]]
}

@test "C3.2 the mismatch refusal says the bridge does not move a bound spec on its own" {
  local out
  out="$(_reconcile_project_mismatch_refusal "specs/031-test-feature/spec.md" "ALPHA" "BETA" "config")"
  [[ "${out}" == *"does not move"* ]]
}

@test "FR-007 an undeclared project coming from the markers says so" {
  # The existing unknown-project refusal blames a routing rule, a teams[] entry
  # or routing_default. None of those placed it when the record did, and
  # sending the operator to edit config.yml's routing would be advice for a
  # file that is already correct.
  local out
  out="$(_reconcile_unknown_project_refusal "GHOST" ".specify/jira" "marker" "specs/031-test-feature/spec.md")"
  [[ "${out}" == *"GHOST"* ]]
  [[ "${out}" == *"markers"* ]]
  [[ "${out}" == *"zero writes"* ]]
}

@test "FR-007 an undeclared project coming from routing keeps today's wording" {
  local out
  out="$(_reconcile_unknown_project_refusal "GHOST" ".specify/jira" "routing" "")"
  [[ "${out}" == *"GHOST"* ]]
  [[ "${out}" == *"routing rule"* ]]
  [[ "${out}" != *"markers"* ]]
}

@test "C6.1 both ports carry the same message literals exactly once" {
  local b p
  for lit in 'is bound to more than one Jira project' 'does not move a bound specification between projects'; do
    b="$(grep -c "${lit}" "${ROOT}/scripts/bash/commands/reconcile.sh")"
    p="$(grep -c "${lit}" "${ROOT}/scripts/powershell/commands/Reconcile.psm1")"
    [ "${b}" -eq 1 ]
    [ "${p}" -eq 1 ]
  done
}

# --- end-to-end: the properties a message builder cannot prove ---------------

@test "C3.3 the split refusal issues ZERO Jira requests — not merely zero writes" {
  # "No POST" is the weaker claim. Both refusals are evaluated before the gate
  # phase, so the call log must be EMPTY: a read that happened would mean the
  # refusal sits downstream of a network call, and C3.3 would be a coincidence
  # of ordering rather than a property of the design.
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _mirrored_repo \
    '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->' \
    '<!-- speckit-jira story=2222222222222222 ticket=LEGACY-9 -->'

  run cmd_reconcile reconcile "${SPEC_PATH}" --dry-run --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"bound to more than one Jira project"* ]]
  [[ "$output" == *"COMP"* ]]
  [[ "$output" == *"LEGACY"* ]]
  [ "$(wc -l < "${MOCK_CALLLOG}" | tr -d ' ')" -eq 0 ]
}

@test "C3.3 the mismatch refusal issues ZERO Jira requests" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_PROJECT_KEY="OTHER"
  _mirrored_repo '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->'

  run cmd_reconcile reconcile "${SPEC_PATH}" --dry-run --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"does not move a bound specification"* ]]
  [ "$(wc -l < "${MOCK_CALLLOG}" | tr -d ' ')" -eq 0 ]
}

@test "C3.5 both refusals downgrade to ONE warning under a hook, exit 0" {
  # Constitution III: an after_* hook must never fail the host command. This
  # feature adds two refusals, so the CHANGED branch needs its own case rather
  # than inheriting the unchanged one's.
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  export SPEC_KIT_JIRA_HOOK_EVENT=after_plan

  _mirrored_repo \
    '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->' \
    '<!-- speckit-jira story=2222222222222222 ticket=LEGACY-9 -->'
  run cmd_reconcile reconcile "${SPEC_PATH}" --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: "* ]]
  [[ "$output" == *"bound to more than one Jira project"* ]]
  [[ "$output" == *"This spec-kit command completed normally."* ]]

  export SPEC_KIT_JIRA_PROJECT_KEY="OTHER"
  _mirrored_repo '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->'
  run cmd_reconcile reconcile "${SPEC_PATH}" --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: "* ]]
  [[ "$output" == *"does not move a bound specification"* ]]
}

@test "C3.4 each refusal is byte-identical with and without --dry-run" {
  # The clause 035 exists to enforce: nothing may be reported in one mode and
  # withheld in the other. Compared as bytes, not as a substring match.
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _mirrored_repo \
    '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->' \
    '<!-- speckit-jira story=2222222222222222 ticket=LEGACY-9 -->'

  run cmd_reconcile reconcile "${SPEC_PATH}" --dry-run --json
  local dry_status="${status}" dry_out="${output}"
  run cmd_reconcile reconcile "${SPEC_PATH}" --json
  [ "${status}" -eq "${dry_status}" ]
  [ "${output}" = "${dry_out}" ]
}

@test "FR-009 no run produces an action set naming more than one project" {
  # The invariant the two refusals exist to protect, asserted directly over the
  # emitted actions rather than inferred from the refusals — so a future path
  # that splits a specification WITHOUT refusing is still caught here.
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _mirrored_repo '<!-- speckit-jira story=1111111111111111 ticket=COMP-1 -->'

  run cmd_reconcile reconcile "${SPEC_PATH}" --dry-run --json
  [ "$status" -eq 0 ]
  local projects
  projects="$(jq -r '[.actions[]?.body?.fields?.project?.key // empty] | unique | length' <<< "$output")"
  [ "${projects}" -le 1 ]
}
