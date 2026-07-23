#!/usr/bin/env bats
# T035/T039 [US2] — Status classification into the four categories and the
# many-to-one phase->status mapping (research §4, FR-011/FR-034).
#
# Classification is SEEDED objectively from Jira's statusCategory (new /
# indeterminate / done) and refined by the operator: a status a phase maps to is
# `mapped`; an operator stop-state is `halted`; a `done` status the operator did
# not map is `post-scope`; anything else is `unknown`. Crucially there is NO
# built-in "ideal" status/phase default table — the operator's configured
# workflow is authoritative (FR-012). Lives in lib/config.sh; the PowerShell port
# mirrors it byte-for-byte.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/lib"
  PS_LIB="${ROOT}/.specify/extensions/jira/scripts/powershell/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/output.sh"
  STATUSES='[{"name":"To Do","status_category":"new"},{"name":"In Progress","status_category":"indeterminate"},{"name":"In Review","status_category":"indeterminate"},{"name":"Done","status_category":"done"},{"name":"Won'\''t Do","status_category":"done"}]'
}

@test "seeds category-only classification when the operator maps nothing (no default table)" {
  run config_classify_statuses "${STATUSES}"
  [ "$status" -eq 0 ]
  # done -> post-scope; new/indeterminate -> unknown; purely from statusCategory.
  [ "$(jq -r '."Done"' <<< "$output")" = "post-scope" ]
  [ "$(jq -r '."To Do"' <<< "$output")" = "unknown" ]
  [ "$(jq -r '."In Progress"' <<< "$output")" = "unknown" ]
}

@test "an operator-mapped status becomes mapped, overriding the done seed" {
  # Two consecutive phases resolve to one status (many-to-one) — both keep it mapped.
  local pm='{"build":"In Progress","verify":"In Progress","ship":"Done"}'
  run config_classify_statuses "${STATUSES}" "${pm}"
  [ "$(jq -r '."In Progress"' <<< "$output")" = "mapped" ]
  [ "$(jq -r '."Done"' <<< "$output")" = "mapped" ]
}

@test "an operator-designated stop state becomes halted" {
  run config_classify_statuses "${STATUSES}" '{}' '["Won'\''t Do"]'
  [ "$(jq -r '."Won'\''t Do"' <<< "$output")" = "halted" ]
  # A done status NOT designated halted stays post-scope.
  [ "$(jq -r '."Done"' <<< "$output")" = "post-scope" ]
}

@test "many-to-one phase->status is representable (two phases, one status)" {
  local pm='{"design":"In Review","develop":"In Review"}'
  run config_phase_status_targets "${pm}"
  [ "$status" -eq 0 ]
  # Both phases collapse to a single distinct target status.
  [ "$(jq -r 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0]' <<< "$output")" = "In Review" ]
}

@test "the PowerShell port classifies byte-identically (NFR-1)" {
  # A quote-free dataset keeps the cross-port pwsh invocation free of shell
  # escaping noise; apostrophe handling is proven by the serializer parity tests.
  local statuses='[{"name":"To Do","status_category":"new"},{"name":"Done","status_category":"done"},{"name":"Canceled","status_category":"done"}]'
  local pm='{"build":"To Do","ship":"Done"}'
  local halted='["Canceled"]'
  run config_classify_statuses "${statuses}" "${pm}" "${halted}"
  local bash_out="$output"
  local ps_out
  ps_out="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Config.psm1' -Force
    [Console]::Out.Write((Get-JiraStatusClassification -StatusesJson '${statuses}' -PhaseStatusMapJson '${pm}' -HaltedJson '${halted}'))
  ")"
  [ "$bash_out" = "$ps_out" ]
}
