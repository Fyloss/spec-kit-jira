#!/usr/bin/env bats
# T005 [US1] — Three-valued style mapping regression (FR-001/FR-002).
#
# `_disc_style` maps the GET /project/{key} payload to a style ONLY on an
# explicit, non-contradictory signal: next-gen / simplified:true -> team_managed,
# classic / simplified:false -> company_managed. Both signals absent, or the two
# signals contradicting each other, MUST yield the EMPTY result (surfaced as
# `style: null` in the binding) — never the silent company_managed default that
# caused the reported defect. Written FIRST and observed failing against the
# defaulting implementation (Constitution XIII).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"
}

@test "a payload with neither style nor simplified yields empty — never company_managed (FR-001)" {
  run _disc_style '{"id":"10002","key":"AMBI","name":"Ambiguous Signals Demo"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "contradictory signals (classic + simplified:true) yield empty (FR-002)" {
  run _disc_style '{"key":"CONTRA","style":"classic","simplified":true}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "contradictory signals (next-gen + simplified:false) yield empty (FR-002)" {
  run _disc_style '{"key":"CONTRA","style":"next-gen","simplified":false}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unambiguous next-gen / simplified:true signal still maps to team_managed" {
  run _disc_style '{"key":"TEAM","style":"next-gen","simplified":true}'
  [ "$output" = "team_managed" ]
  run _disc_style '{"key":"TEAM","simplified":true}'
  [ "$output" = "team_managed" ]
  run _disc_style '{"key":"TEAM","style":"next-gen"}'
  [ "$output" = "team_managed" ]
}

@test "an unambiguous classic / simplified:false signal still maps to company_managed" {
  run _disc_style '{"key":"COMP","style":"classic","simplified":false}'
  [ "$output" = "company_managed" ]
  run _disc_style '{"key":"COMP","simplified":false}'
  [ "$output" = "company_managed" ]
  run _disc_style '{"key":"COMP","style":"classic"}'
  [ "$output" = "company_managed" ]
}

@test "an unknown style string with no simplified signal yields empty, not a default" {
  run _disc_style '{"key":"ODD","style":"something-new"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
