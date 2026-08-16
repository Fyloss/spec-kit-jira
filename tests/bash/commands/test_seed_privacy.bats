#!/usr/bin/env bats
# T077 [027] — FR-065: the two-tier pre-write privacy guard over content
# seeded from a named Jira issue. This is NEW scanned surface (spec.md
# Assumptions): until this feature no content originating in the tracker
# ever reached a tracked file. One fixture per tier — moment 1
# (commands/feature.sh), the scan over the seed material before it is
# handed to the drafting agent (FR-065, first bullet).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  LIB_DIR="${ROOT}/scripts/bash/lib"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/seed_fixture.bash"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/seed_state.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/feature.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  helper_seed_config "${JIRA_CONFIG_DIR}" PROJ proj
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

_priv_seed_issue() {
  printf '"%s":{"summary":"%s","description":"%s","status":{"name":"%s","statusCategory":{"key":"%s"}},"issuetype":{"id":"10001","name":"%s"},"project":{"key":"%s"}}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

@test "T077: a known coordinate (an ATATT token) in a seeded description BLOCKs, exit 9, zero bytes written" {
  local issues="{$(_priv_seed_issue "PROJ-11" "Accept a partial payment" "See token ATATTxxxxSECRETxxxx for access" "To Do" "new" "Story" "PROJ")}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_feature feature --json --story PROJ-11 "invoice export"
  [ "$status" -eq 9 ]
  [ ! -d "specs/proj-11" ]
}

@test "T077: a generic email in a seeded description WARNs without blocking" {
  local issues="{$(_priv_seed_issue "PROJ-11" "Accept a partial payment" "Contact jane.doe@example.com for follow-up" "To Do" "new" "Story" "PROJ")}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_feature feature --json --story PROJ-11 "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
}

@test "T077: an allowlisted Confluence link in a seeded description passes silently" {
  export SPEC_KIT_JIRA_ALLOWLIST='["https://acme.atlassian.net/wiki/"]'
  local issues="{$(_priv_seed_issue "PROJ-11" "Accept a partial payment" "See https://acme.atlassian.net/wiki/spaces/X/page for detail" "To Do" "new" "Story" "PROJ")}"
  local cfg
  cfg="$(mock_write_config "{\"issues\":${issues}}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_feature feature --json --story PROJ-11 "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
}

# --- T158: FR-065 tier 2 — the scan over spec.md before the first Jira
# mutation, on the seed.sh (moment 2) binding path. -------------------------

@test "T158: a known coordinate in spec.md as it now stands BLOCKs seed --confirm, exit 9, zero writes" {
  FEATURE_DIR="${WORK}/specs/001-add-payment-webhooks"
  mkdir -p "${FEATURE_DIR}"
  SPEC="${FEATURE_DIR}/spec.md"
  # A poisoned body — as if the operator pasted a credential into spec.md
  # after the drafting agent wrote it, before confirming the gate.
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nSee token ATATTxxxxSECRETxxxx for access.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"

  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 9 ]
  [ -z "$(mock_calls)" ]
  # Zero writes: the pinning marker is still `pin=`, never consumed, and the
  # seed record survives (a BLOCK is not a binding).
  grep -q 'pin=PROJ-11' "${SPEC}"
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
}
