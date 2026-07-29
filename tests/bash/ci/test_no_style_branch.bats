#!/usr/bin/env bats
# T047 [US4] — Payload assembly must never branch on a project's style
# (FR-028, Principle VII). This is the mechanical enforcement, following the
# test_no_registry_write.bats convention: `plan_apply.sh` decides which
# attributes a creation may declare from what the resolved project reports it
# accepts, never from a rule keyed on `company_managed` / `team_managed`.

@test "plan_apply.sh contains no style-keyed branch (FR-028)" {
  local root plan_apply bad
  root="${BATS_TEST_DIRNAME}/../../.."
  plan_apply="${root}/scripts/bash/sink/jira/plan_apply.sh"
  bad="$(grep -nE 'company_managed|team_managed' "${plan_apply}" || true)"
  [ -z "${bad}" ] || { printf 'style-keyed text in plan_apply.sh:\n%s\n' "${bad}" >&2; return 1; }
}

@test "PlanApply.psm1 contains no style-keyed branch (FR-028)" {
  local root plan_apply bad
  root="${BATS_TEST_DIRNAME}/../../.."
  plan_apply="${root}/scripts/powershell/sink/jira/PlanApply.psm1"
  bad="$(grep -nE 'company_managed|team_managed' "${plan_apply}" || true)"
  [ -z "${bad}" ] || { printf 'style-keyed text in PlanApply.psm1:\n%s\n' "${bad}" >&2; return 1; }
}
