#!/usr/bin/env bats
# T043 [US1] — The privacy guard applies to adoption with NO exemption
# (003 FR-028, FR-030, Principle IX).
#
# Adoption claims no exemption because its action set goes through the SHARED
# write path: the BLOCK-tier guard scans every payload BEFORE the first write, so
# a match aborts with exit 9 and zero property PUTs. That inheritance is the
# whole point of research §7 — the guard is not something adoption remembers to
# call, it is something adoption cannot bypass.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SINK="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${SINK}/adoption.sh"
  # shellcheck source=/dev/null
  source "${SINK}/plan_apply.sh"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  BINDINGS='[{"spec_folder":"003-a","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
              "reason":"label-match","overrode_key":null,"status":"adopt"},
             {"spec_folder":"003-a","level":"story","story_ordinal":1,"issue_key":"ADO-2",
              "reason":"label-match","overrode_key":null,"status":"adopt"}]'
}

teardown() {
  mock_stop
}

start() {
  mock_start_json '{"projects":{"ADO":"company"}}'
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

puts() {
  mock_calls | grep -c '^PUT ' || true
}

@test "a clean stamp set passes the guard and writes (control)" {
  start
  run apply_writes "$(adopt_stamp_actions "${BINDINGS}" "acme/app")"
  [ "$status" -eq 0 ]
  [ "$(puts)" -eq 2 ]
}

@test "a BLOCK-tier Cloud host in the payload gives exit 9 with ZERO writes" {
  start
  local actions
  actions="$(adopt_stamp_actions "${BINDINGS}" "acme/mirror-of-acme.atlassian.net")"
  run apply_writes "${actions}"
  [ "$status" -eq 9 ]
  [ "$(puts)" -eq 0 ]
}

@test "a BLOCK-tier token shape in the payload gives exit 9 with ZERO writes" {
  start
  local actions
  actions="$(adopt_stamp_actions "${BINDINGS}" "acme/ATATT3xFfGF0leaked")"
  run apply_writes "${actions}"
  [ "$status" -eq 9 ]
  [ "$(puts)" -eq 0 ]
}

@test "a known coordinate in the payload gives exit 9 with ZERO writes" {
  start
  local actions
  actions="$(adopt_stamp_actions "${BINDINGS}" "acme/ops-known-coordinate")"
  run apply_writes "${actions}" '["ops-known-coordinate"]'
  [ "$status" -eq 9 ]
  [ "$(puts)" -eq 0 ]
}

@test "the guard runs BEFORE the first write, so one bad payload blocks them all" {
  start
  # Only the SECOND binding's payload carries the coordinate; the first must not
  # be written either — the gate is a pre-pass over the whole set, not a filter.
  local mixed
  mixed='[{"spec_folder":"003-clean","level":"feature","story_ordinal":null,"issue_key":"ADO-1",
           "reason":"label-match","overrode_key":null,"status":"adopt"},
          {"spec_folder":"acme.atlassian.net","level":"feature","story_ordinal":null,"issue_key":"ADO-2",
           "reason":"label-match","overrode_key":null,"status":"adopt"}]'
  run apply_writes "$(adopt_stamp_actions "${mixed}" "acme/app")"
  [ "$status" -eq 9 ]
  [ "$(puts)" -eq 0 ]
}

@test "the blocked value itself is never echoed (NFR-3)" {
  start
  local actions
  actions="$(adopt_stamp_actions "${BINDINGS}" "acme/mirror-of-secretsite.atlassian.net")"
  run apply_writes "${actions}"
  [ "$status" -eq 9 ]
  [[ "$output" != *"secretsite"* ]]
  [[ "$output" == *"BLOCK"* ]]
}

@test "adoption declares no allowlist of its own — the shared one still applies" {
  start
  local actions
  actions="$(adopt_stamp_actions "${BINDINGS}" "acme/docs.atlassian.net")"
  # An allowlisted host is neutralised for adoption exactly as for any other
  # write; adoption adds no second, weaker allowlist path (FR-053).
  run env SPEC_KIT_JIRA_ALLOWLIST='["docs.atlassian.net"]' bash -c "
    source '${SINK}/adoption.sh'; source '${SINK}/plan_apply.sh'
    apply_writes '${actions}'"
  [ "$status" -eq 0 ]
}

@test "an allowlist entry cannot neutralise a DIFFERENT host (fail-closed, FR-053)" {
  start
  local actions
  actions="$(adopt_stamp_actions "${BINDINGS}" "acme/mirror-of-docs.atlassian.net")"
  # The matched text is `mirror-of-docs.atlassian.net`, which the `docs...`
  # entry neither contains nor is a label-boundary domain of — so it still blocks.
  run env SPEC_KIT_JIRA_ALLOWLIST='["docs.atlassian.net"]' bash -c "
    source '${SINK}/adoption.sh'; source '${SINK}/plan_apply.sh'
    apply_writes '${actions}'"
  [ "$status" -eq 9 ]
}
