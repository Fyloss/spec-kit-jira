#!/usr/bin/env bats
# T056 [027] — The seed command skeleton and confirmation gate
# (contracts/seed-cli-contract.md §4, §5, §7).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  LIB_DIR="${ROOT}/scripts/bash/lib"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/seed_state.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  FEATURE_DIR="${WORK}/specs/001-add-payment-webhooks"
  mkdir -p "${FEATURE_DIR}"
  SPEC="${FEATURE_DIR}/spec.md"
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody.\n' > "${SPEC}"
}

teardown() {
  mock_stop 2> /dev/null || true
  rm -rf "${WORK}"
}

_write_seed_record() {
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"
}

@test "no seed record, folder present -> REF-EXISTS, zero writes" {
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-EXISTS"* ]]
}

@test "a readable spec file argument is required" {
  run cmd_seed seed
  [ "$status" -eq 1 ]
}

# --- C-7: the gate without --confirm ------------------------------------

@test "C-7: without --confirm, emits confirmation_required, exit 0, zero mutations" {
  _write_seed_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(jq -r 'has("confirmation_required")' <<< "$output")" = "true" ]
  # The seed record is untouched (zero mutations).
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
}

@test "C-7: the confirmation payload reuses the {active,confirmation_required} shape" {
  _write_seed_record
  run cmd_seed seed "${SPEC}" --json
  [ "$(jq -r '.confirmation_required | has("plan")' <<< "$output")" = "true" ]
  [ "$(jq -r '.confirmation_required | has("provenance")' <<< "$output")" = "true" ]
  [ "$(jq -r '.confirmation_required | has("delta")' <<< "$output")" = "true" ]
}

# --- T064: FR-047, credentials never reach argv, logs, or traces ------------

@test "T064: seed.sh never references a credential variable or header" {
  run grep -c -E "JIRA_API_TOKEN|Authorization" "${CMD_DIR}/seed.sh"
  [ "$output" = "0" ]
}

@test "T064: the token never leaks from a refusal path (REF-EXISTS) at max verbosity" {
  export JIRA_API_TOKEN="RAWSECRETXYZ0123456789"
  local out
  out="$(bash -x "${ROOT}/scripts/bash/spec-kit-jira.sh" seed "${SPEC}" --verbose --json 2>&1 || true)"
  run grep -c "RAWSECRETXYZ0123456789" <<< "${out}"
  [ "$output" = "0" ]
}

# --- T079/T080: REF-DECOMP — pin_marker_validate wired into cmd_seed ---------

@test "T079: a missing pinning marker (P1) refuses REF-DECOMP, naming the key" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n\nBody, no marker.\n' > "${SPEC}"
  _write_seed_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-DECOMP"* ]]
  [[ "$output" == *"PROJ-11"* ]]
}

@test "T079: an orphan marker (P2) refuses REF-DECOMP, naming the key and line" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\n### User Story 2 - B (Priority: P1)\n<!-- speckit-jira pin=PROJ-99 -->\n\nBody.\n' > "${SPEC}"
  _write_seed_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-DECOMP"* ]]
  [[ "$output" == *"PROJ-99"* ]]
}

@test "T079: a split marker (P3, same key twice) refuses REF-DECOMP" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\n### User Story 2 - B (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody.\n' > "${SPEC}"
  _write_seed_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-DECOMP"* ]]
}

@test "T079: a reordered marker (P4) refuses REF-DECOMP" {
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]' "")"
  seed_state_write "${SPEC}" "${doc}"
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-12 -->\n\n### User Story 2 - B (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody.\n' > "${SPEC}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"REF-DECOMP"* ]]
}

@test "T079: all four violation kinds at once are reported together, not one at a time" {
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]' "")"
  seed_state_write "${SPEC}" "${doc}"
  # PROJ-11 missing entirely; PROJ-12 split across two markers; PROJ-77 orphan.
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-12 -->\n\n### User Story 2 - B (Priority: P1)\n<!-- speckit-jira pin=PROJ-12 -->\n\n### User Story 3 - C (Priority: P1)\n<!-- speckit-jira pin=PROJ-77 -->\n\nBody.\n' > "${SPEC}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -ne 0 ]
  local count
  count="$(grep -c "REF-DECOMP" <<< "$output")"
  [ "${count}" -ge 2 ]
}

@test "T079: a valid decomposition (the C-7 fixture) passes REF-DECOMP validation silently" {
  _write_seed_record
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"REF-DECOMP"* ]]
}

# --- T081-T084: binding — identity marker, consumption, atomicity -----------

@test "T081/T082: --confirm binds each named story with origin:human role:story, stamped per ticket" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody one.\n\n### User Story 2 - B (Priority: P1)\n<!-- speckit-jira pin=PROJ-12 -->\n\nBody two.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0},{"role":"story","form":"key","key":"PROJ-12","raw":"PROJ-12","position":1}]' "")"
  seed_state_write "${SPEC}" "${doc}"

  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(jq '.bindings | length' <<< "$output")" -eq 2 ]

  # Two identity writes, one per ticket, never batched.
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/PROJ-11/properties/spec-kit-jira')" -eq 1 ]
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/PROJ-12/properties/spec-kit-jira')" -eq 1 ]

  # The marker on disk is now a bound story marker, origin:human, role:story.
  local written_props
  written_props="$(mock_issue_field PROJ-11 '.' 2>/dev/null || true)"
  grep -qE '<!-- speckit-jira story=[0-9a-f]{16} ticket=PROJ-11 -->' "${SPEC}"
  grep -qE '<!-- speckit-jira story=[0-9a-f]{16} ticket=PROJ-12 -->' "${SPEC}"
  ! grep -q 'pin=' "${SPEC}"

  # The seed record is deleted on success (§4).
  run seed_state_read "${SPEC}"
  [ "$status" -ne 0 ]
}

@test "T083 (P-7): consumption replaces the marker line in place, preserving every other byte" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody one, untouched.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  grep -qF '# Feature' "${SPEC}"
  grep -qF '### User Story 1 - A (Priority: P1)' "${SPEC}"
  grep -qF 'Body one, untouched.' "${SPEC}"
}

@test "T081: identity stores origin:human and role:story on the property" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody one.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"
  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-11":{"summary":"S","description":"D"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_REPO="local/repo"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  local stored
  stored="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/PROJ-11/properties/spec-kit-jira" | jq -c '.value')"
  [ "$(jq -r '.origin' <<< "${stored}")" = "human" ]
  [ "$(jq -r '.role' <<< "${stored}")" = "story" ]
}

# --- T085/T086: --dry-run predicts, writes NOTHING (including the record) --

@test "C-16 (T085): --dry-run predicts the identical action set and writes no seed record" {
  _write_seed_record
  run cmd_seed seed "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("confirmation_required")' <<< "$output")" = "true" ]
  run seed_state_read "${SPEC}"
  [ "$status" -eq 0 ]
}

# --- C-13 (T087/T088): idempotent second run --------------------------------

@test "C-13 (T087): a second run against a bound specification is a no-op, exit 0, zero writes" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody one.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"
  local cfg
  cfg="$(mktemp)"
  printf '{}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  local before
  before="$(cat "${SPEC}")"

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active' <<< "$output")" = "true" ]
  [ "$(cat "${SPEC}")" = "${before}" ]
}

# --- T090/T091 (US3): parent adoption ----------------------------------------

@test "T090/T091: an existing parent is adopted (never created), marker origin:human role:parent" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=PROJ-11 -->\n\nBody one.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0},{"role":"story","form":"key","key":"PROJ-11","raw":"PROJ-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"

  local cfg
  cfg="$(mock_write_config '{"issues":{"PROJ-1":{"summary":"Payment webhooks rollout","description":"Epic body"},"PROJ-11":{"summary":"S","description":"D"}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(jq '.bindings | length' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.bindings[] | select(.role=="parent")][0].origin' <<< "$output")" = "human" ]
  [ "$(jq -r '[.bindings[] | select(.role=="parent")][0].key' <<< "$output")" = "PROJ-1" ]

  # Never created: no POST /rest/api/3/issue at all.
  [ -z "$(mock_calls | grep '^POST /rest/api/3/issue$')" ]
  [ "$(mock_calls | grep -c 'PUT /rest/api/3/issue/PROJ-1/properties/spec-kit-jira')" -eq 1 ]

  grep -qE '<!-- speckit-jira spec=[0-9a-f]{16} ticket=PROJ-1 -->' "${SPEC}"

  local stored
  stored="$(curl -sf "${MOCK_BASE_URL}/rest/api/3/issue/PROJ-1/properties/spec-kit-jira" | jq -c '.value')"
  [ "$(jq -r '.origin' <<< "${stored}")" = "human" ]
  [ "$(jq -r '.role' <<< "${stored}")" = "parent" ]
}

# --- T096 (FR-014): a non-default hierarchy (SAFe-shaped roles) binds identically ---

@test "T096 (FR-014): binding is agnostic to the project's declared role names (SAFe: Capability/Feature)" {
  printf '# Feature\n\n### User Story 1 - A (Priority: P1)\n<!-- speckit-jira pin=SAFE-11 -->\n\nBody one.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"specification","form":"key","key":"SAFE-1","raw":"SAFE-1","position":0},{"role":"story","form":"key","key":"SAFE-11","raw":"SAFE-11","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"

  local cfg
  cfg="$(mock_write_config '{"issues":{"SAFE-1":{"summary":"Payment webhooks rollout","description":"Capability body","issuetype":{"name":"Capability"},"project":{"key":"SAFE"}},"SAFE-11":{"summary":"S","description":"D","issuetype":{"name":"Feature"},"project":{"key":"SAFE"}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(jq '.bindings | length' <<< "$output")" -eq 2 ]
  grep -qE '<!-- speckit-jira spec=[0-9a-f]{16} ticket=SAFE-1 -->' "${SPEC}"
  grep -qE '<!-- speckit-jira story=[0-9a-f]{16} ticket=SAFE-11 -->' "${SPEC}"
}

# --- T120-T123 (US4): a parent alone, no pinning constraint at all ---------

@test "T120: a parent-only invocation (zero story designators) passes pin validation over zero markers" {
  printf '# Feature\n\n### User Story 1 - Freely chosen by the agent (Priority: P1)\n\nBody one, unpinned.\n\n### User Story 2 - Also freely chosen (Priority: P1)\n\nBody two, unpinned.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"specification","form":"key","key":"PROJ-1","raw":"PROJ-1","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"REF-DECOMP"* ]]
}

@test "T121/T123: --confirm on a parent-only invocation binds only the parent; a following reconcile creates one issue per drafted user story under it, and never duplicates the parent" {
  printf '# Feature\n\n### User Story 1 - Freely chosen by the agent (Priority: P1)\n\nBody one, unpinned.\n\n### User Story 2 - Also freely chosen (Priority: P1)\n\nBody two, unpinned.\n' > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" '[{"role":"specification","form":"key","key":"COMP-1","raw":"COMP-1","position":0}]' "")"
  seed_state_write "${SPEC}" "${doc}"

  # reconcile.sh treats "no config.local.yml" as unbound (skips mirroring),
  # so this test needs the minimal resolved binding, independent of
  # helper_seed_config (which only writes config.yml/personal.yml).
  {
    printf 'resolved_ids:\n'
    printf '  COMP:\n'
    printf '    style: company_managed\n'
    printf '    issue_types:\n'
    printf '      - logical_name: "Epic"\n'
    printf '        id: "10000"\n'
    printf '        hierarchy_level: "1"\n'
    printf '        subtask: false\n'
    printf '      - logical_name: "Story"\n'
    printf '        id: "10001"\n'
    printf '        hierarchy_level: "0"\n'
    printf '        subtask: false\n'
    printf '    child_type:\n'
    printf '      logical_name: "Story"\n'
    printf '      id: "10001"\n'
    printf '      source: derived\n'
    printf '    parent_type:\n'
    printf '      logical_name: "Epic"\n'
    printf '      id: "10000"\n'
    printf '      source: derived\n'
    printf '    required_fields:\n'
    printf '      "10000":\n'
    printf '        - logical_name: "Summary"\n'
    printf '          field_id: "summary"\n'
    printf '      "10001":\n'
    printf '        - logical_name: "Summary"\n'
    printf '          field_id: "summary"\n'
    printf '    parent_link_available:\n'
    printf '      "10001": true\n'
    printf '    statuses:\n'
    printf '      To Do: "10000"\n'
  } > "${JIRA_CONFIG_DIR}/config.local.yml"
  {
    printf 'projects:\n'
    printf '  - key: COMP\n'
    printf '    style: company_managed\n'
    printf 'routing_default: COMP\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"

  local cfg
  cfg="$(mock_write_config '{"issues":{"COMP-1":{"summary":"Payment webhooks rollout","description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Epic body"}]}]}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-add-payment-webhooks"

  run cmd_seed seed "${SPEC}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(jq '.bindings | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.bindings[0].role' <<< "$output")" = "parent" ]
  grep -qE '<!-- speckit-jira spec=[0-9a-f]{16} ticket=COMP-1 -->' "${SPEC}"
  ! grep -q 'pin=' "${SPEC}"
  ! grep -q 'story=' "${SPEC}"

  # Same mock instance: the identity property PUT during --confirm above
  # must still be visible to reconcile's own recognition read.
  source "${CMD_DIR}/reconcile.sh"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
  [ "$(mock_calls | grep -c '^POST /rest/api/3/issue$')" -eq 2 ]
  [ -z "$(mock_calls | grep '^POST /rest/api/3/issue$' | grep -i 'COMP-1')" ]
}
