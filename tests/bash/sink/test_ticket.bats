#!/usr/bin/env bats
# T042 [US3] — Ticket sink: validate (read) and create (guarded write)
# (FR-013, contracts/jira-endpoints-delta.md).
#
# `ticket_validate` reads GET /issue/{key}?fields=project through the existing
# transport (fail-closed codes for a mentioned key). `ticket_create` POSTs with
# fields.project.key = the team project and fields.issuetype.id = the caller's
# resolved story-type id (never a literal type name); the PASS-1 privacy guard
# runs BEFORE the POST (BLOCK => exit 9, zero writes); the created ticket is
# identity-stamped like any bridge-created artifact.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/ticket.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

@test "ticket_validate reads the mentioned key's project (fields=project)" {
  boot '{"projects":{"IJT":"team"}}'
  run ticket_validate "IJT-42"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "IJT-42" ]
  [ "$(jq -r '.project' <<< "$output")" = "IJT" ]
  mock_calls | grep -q 'GET /rest/api/3/issue/IJT-42?fields=project'
}

@test "ticket_validate fails closed on an unknown mentioned key (exit 2)" {
  boot '{"projects":{"IJT":"team"}}'
  run ticket_validate "NOPE-1"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "jira_create_fields_base returns exactly {project,issuetype,summary} (FR-025)" {
  run jira_create_fields_base "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -cS 'keys' <<< "$output")" = '["issuetype","project","summary"]' ]
  [ "$(jq -r '.project.key' <<< "$output")" = "IJT" ]
  [ "$(jq -r '.issuetype.id' <<< "$output")" = "10201" ]
  [ "$(jq -r '.summary' <<< "$output")" = "invoice export" ]
}

@test "_ticket_create_body is built from jira_create_fields_base, unchanged (FR-025)" {
  local base
  base="$(jira_create_fields_base "IJT" "invoice export" "10201")"
  run _ticket_create_body "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.fields' <<< "$output")" = "$(jq -c . <<< "${base}")" ]
}

@test "the create body carries the team project and the resolved story-type id" {
  run _ticket_create_body "IJT" "invoice export" "10201"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fields.project.key' <<< "$output")" = "IJT" ]
  [ "$(jq -r '.fields.issuetype.id' <<< "$output")" = "10201" ]
  [ "$(jq -r '.fields.summary' <<< "$output")" = "invoice export" ]
  # The id arrives from the caller (the binding) — never a literal type name.
  [ "$(jq -r '.fields.issuetype | has("name")' <<< "$output")" = "false" ]
}

@test "ticket_create POSTs, prints the created key, and identity-stamps it" {
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run ticket_create "IJT" "invoice export" "10201" '[]' '[]' '{"repo":"acme/app","spec_slug":"003-x"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "IJT-123" ]
  mock_calls | grep -q 'POST /rest/api/3/issue'
  # Identity stamp (entity property PUT) follows the create.
  mock_calls | grep -q 'PUT /rest/api/3/issue/IJT-123/properties/spec-kit-jira'
}

@test "the PASS-1 privacy guard blocks BEFORE the POST (exit 9, zero writes)" {
  boot '{"projects":{"IJT":"team"},"createdKey":"IJT-123"}'
  run ticket_create "IJT" "summary with token ATATT3xFfGF0abcdef" "10201"
  [ "$status" -eq 9 ]
  # Zero writes: nothing reached the mock.
  [ -z "$(mock_calls)" ]
}
