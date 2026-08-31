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
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/commands/reconcile.sh"

  CFG='{
    "projects": [{"key": "ALPHA"}, {"key": "BETA"}],
    "routing_default": "BETA",
    "teams": [
      {"id": "alpha", "project": "ALPHA", "folder_prefix": "alpha-"},
      {"id": "beta", "project": "BETA", "folder_prefix": "beta-"}
    ]
  }'
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
