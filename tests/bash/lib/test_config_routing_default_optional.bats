#!/usr/bin/env bats
# T035/T037/T039 [Phase 4, US2] — `routing_default` becomes OPTIONAL
# (contracts/routing-resolution.md C5.1–C5.3, spec FR-003).
#
# Optional means "may be absent", never "may be malformed" and never
# "is refused". The three cases below are the whole of C5:
#
#   C5.1  absent            -> accepted
#   C5.2  present, invalid  -> refused with the message it produces today
#   C5.3  present, valid    -> still a legal top-level key, never "unknown"
#
# Before this feature the key was REQUIRED: config.sh's schema emitted
# "routing_default must be a valid project key" for an absent key just as
# loudly as for a malformed one. C5.1 is the case that must flip; the other
# two exist so the flip cannot be implemented by deleting the whole rule.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

_write_team_config() {
  printf '%s\n' "$@" > "${WORK}/config.yml"
}

@test "C5.1 a team configuration omitting routing_default validates" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed'
  run config_load "${WORK}"
  [ "$status" -eq 0 ]
}

@test "C5.1 omitting routing_default emits no error mentioning the key" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed'
  run config_load "${WORK}"
  [[ "${output}" != *"routing_default"* ]]
}

@test "C5.1 a configuration omitting routing_default but declaring teams validates" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed' \
    '  - key: BETA' \
    '    style: company_managed' \
    'teams:' \
    '  - id: alpha' \
    '    project: ALPHA' \
    '    folder_prefix: "alpha-"' \
    '    branch_pattern: "alpha-<ID>/<FEATURE_NAME>"'
  run config_load "${WORK}"
  [ "$status" -eq 0 ]
}

@test "C5.2 a malformed routing_default is still refused with today's message" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed' \
    'routing_default: lower'
  run config_load "${WORK}"
  [ "$status" -eq 4 ]
  [[ "${output}" == *"routing_default must be a valid project key"* ]]
}

@test "C5.2 the refusal names the file it came from" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed' \
    'routing_default: 9NOPE'
  run config_load "${WORK}"
  [ "$status" -eq 4 ]
  [[ "${output}" == *"${WORK}/config.yml"* ]]
}

@test "C5.3 a valid routing_default remains a legal top-level key" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed' \
    'routing_default: ALPHA'
  run config_load "${WORK}"
  [ "$status" -eq 0 ]
  [[ "${output}" != *"unknown top-level key"* ]]
}

@test "C5.3 a valid routing_default survives into the merged document" {
  _write_team_config \
    'projects:' \
    '  - key: ALPHA' \
    '    style: company_managed' \
    'routing_default: ALPHA'
  run config_load "${WORK}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.routing_default' <<< "${output}")" = "ALPHA" ]
}
