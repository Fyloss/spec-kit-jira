#!/usr/bin/env bats
# T057 [US2] — The reconcile-time consolidated question (011, contract §3.3/
# §3.4/§3.10, data-model.md §4). T059/T063 extend this file with summary
# provenance and non-blocking coverage; T075/T079 [US3] extend it with the
# surviving refusal and a rejected value.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${WORK}"
  SPEC="${WORK}/specs/001-reporting/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

_record_both_fields() {
  cmd_config config PM --issue-type "PM=story=Story" \
    --field-default 'PM=Deliverable=Business Owner=Platform Team' \
    --field-default 'PM=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
}

@test "FR-013 — no question when the plan creates nothing" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  cmd_reconcile reconcile "${SPEC}" --accept-defaults --json > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
}

@test "FR-014 — no question when ask is false; the summary still attributes each value to its source" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  # Hand-set ask:false in the recorded region (contract §2, FR-014).
  local map='{"PM":{"ask":false,"Deliverable":{"Business Owner":"Platform Team","Program Increment":"PI-2026-Q3"}}}'
  _config_field_defaults_write "${JIRA_CONFIG_DIR}/config.yml" "${map}" "false" > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
  [[ "$output" == *"sent from team-config"* ]]
  [[ "$output" == *"ask: false"* ]]
}

@test "FR-015 — no question with --accept-defaults" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
}

@test "FR-028 — no question when creations are pending, ask is on, but neither trigger fires: an optional defaultable field is never recorded and every required field is already satisfiable" {
  mock_start "${MOCK}/configs/optional-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # No --field-default at all: the type's only custom field is optional and
  # unrecorded; every required field (summary/description/priority) is
  # bridge-supplied.
  cmd_config config PM --issue-type "PM=story=Story" --json > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
}

@test "FR-011 — one question naming each field once, however many creations are pending" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "confirmation-pending" ]
  # One parent (Deliverable) creation and one story creation are pending
  # (creations_pending == 2), yet the field is named exactly once — the
  # question is per FIELD, not per creation.
  [ "$(jq -r '.creations_pending' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.fields[] | select(.label=="Business Owner")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.fields[] | select(.label=="Program Increment")] | length' <<< "$output")" -eq 1 ]
}

@test "FR-012 — an answer applies to every creation in the run" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --field-value 'PM=Deliverable=Business Owner=Override Team' --accept-defaults --json
  [ "$status" -eq 0 ]
  # The parent is the only creation carrying the Deliverable type's fields
  # this run; the override reaches it.
  [ "$(jq -r '[.actions[] | select(.role=="parent")][0].body.fields.customfield_40011' <<< "$output")" = "Override Team" ]
  [[ "$output" == *"Override Team"* ]]
}

@test "FR-015 — a decline resumed with --accept-defaults is indistinguishable from an acceptance; the summary gives that one reason" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  # First pass: the question fires (a "decline" is simply not answering it).
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "confirmation-pending" ]

  # Resumed exactly as an acceptance would be — there is no decline flag.
  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status // "ok"' <<< "$output")" != "confirmation-pending" ]
  [ "$(jq -r '[.notes[] | select(. | contains("--accept-defaults was given"))] | length' <<< "$output")" -eq 1 ]
}

# --- T059 [US2] — summary provenance (contract §4.1, FR-022) ----------------

@test "FR-022 — every filled field is attributed to its source; the raw resolution map is never printed" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --field-value 'PM=Deliverable=Business Owner=Override Team' --accept-defaults --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -c '.notes' <<< "$output")"
  # One field came from an operator answer this run, the other from the
  # recorded team config — each attributed to its own source, by label.
  [ "$(jq -r '[.[] | select(contains("Business Owner") and contains("sent from operator-answer"))] | length' <<< "${notes}")" -eq 1 ]
  [ "$(jq -r '[.[] | select(contains("Program Increment") and contains("sent from team-config"))] | length' <<< "${notes}")" -eq 1 ]
  # An operator-answer override carries the promotion line so it can be made
  # permanent through the config ceremony (FR-021). It is copy-pasteable, so
  # the KEY=Type=Label=Value token is quoted — both the label and the answered
  # value here carry a space and would otherwise word-split.
  [ "$(jq -r '[.[] | select(contains("speckit.jira-mirror.config") and contains("--field-default"))] | length' <<< "${notes}")" -ge 1 ]
  [ "$(jq -r "[.[] | select(contains(\"--field-default 'PM=Deliverable=Business Owner=Override Team'\"))] | length" <<< "${notes}")" -eq 1 ]
  # Never a raw field id, and never the internal map keys, in a note.
  [[ "${notes}" != *"customfield_"* ]]
  [[ "${notes}" != *"field_default_sources"* ]]
}

@test "FR-022 — a bridge-supplied field (never recorded, never answered) earns no provenance line at all" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  local notes; notes="$(jq -c '.notes' <<< "$output")"
  [[ "${notes}" != *"Summary"* ]]
  [[ "${notes}" != *"sent from bridge"* ]]
}

# --- T063 [US2] — non-blocking (FR-020, contract §3.9) ----------------------

@test "FR-020 — a hook-fired run that stops for the question leaves the host command's outcome unchanged, at most one WARNING line" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "confirmation-pending" ]
  [ "$(grep -c '^WARNING: ' <<< "$output")" -eq 0 ]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}

@test "FR-020 — a hook-fired run that fails while applying a default leaves the host command's outcome unchanged, at most one WARNING line" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  # Stop the mock (restores the real curl on PATH) before pointing reconcile
  # at a dead port — a transport failure while APPLYING the (already-
  # recorded) defaults, distinct from the question path above.
  mock_stop
  export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WARNING: ' <<< "$output")" -eq 1 ]
  [[ "$output" == *"This spec-kit command completed normally"* ]]
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}

# --- T075 [US3] — the surviving refusal (contract §3.6, FR-016) -------------

@test "FR-016 — with no default and no answer, the run refuses with zero writes, the pre-existing exit code, and a remedy naming each field" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # Nothing recorded at all — the pristine fixture, no config ceremony run.
  # --accept-defaults declares the operator unreachable (§3.10), so the run
  # must refuse rather than ask.

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"Business Owner"* ]]
  [[ "$output" == *"Program Increment"* ]]
  # The remedy is advertised as copy-pasteable, so the KEY=Type=Label=Value
  # token must survive a shell round-trip: both labels here carry a space, and
  # the placeholder is spelled `<value>` — unquoted, the shell would word-split
  # the token and read `<value>` as an input redirection.
  [[ "$output" == *"speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Business Owner=<value>'"* ]]
  [[ "$output" == *"speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Program Increment=<value>'"* ]]
  [[ "$output" != *"customfield_"* ]]

  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

# --- T079 [US3] — a rejected value (contract §3.7, FR-019) ------------------

@test "FR-019 — Jira rejecting a defaulted value names the field by label and the value sent, explains in human terms, substitutes nothing, does not retry" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  mock_stop

  # A field-validation fault for project PM's creations, naming the exact
  # field id "Program Increment" resolves to (contract §3.7).
  local faulty_cfg; faulty_cfg="${BATS_TEST_TMPDIR}/faulty-mandatory-field.json"
  jq '. + {faults: {PM: {status: 400, errors: {customfield_40012: "Option id 123 is not valid"}}}}' \
    "${MOCK}/configs/mandatory-field.json" > "${faulty_cfg}"
  mock_start "${faulty_cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  # The transport fails closed (fail_closed=2); no substitution, no retry —
  # exactly one attempt reaches the mock for the failing creation.
  [ "$status" -ge 2 ]
  local rejection_line
  # "the value", not "the recorded value": this path also reports a value that
  # came from a --field-value answer this run, which was never recorded.
  rejection_line="$(grep -F 'Jira rejected the value' <<< "$output")"
  [ -n "${rejection_line}" ]
  [[ "${rejection_line}" == *'Jira rejected the value for "Program Increment"'* ]]
  [[ "${rejection_line}" == *'sent PI-2026-Q3'* ]]
  [[ "${rejection_line}" == *"Option id 123 is not valid"* ]]
  [[ "${rejection_line}" == *"Nothing was substituted and the creation was not retried"* ]]
  # The human message never names the raw field id — only its Jira label
  # (FR-019); the JSON summary's own action payload, elsewhere in $output,
  # legitimately carries the id and is not this clause's concern.
  [[ "${rejection_line}" != *"customfield_40012"* ]]

  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 1 ]
}

# --- T101 — a reconcile run never modifies config.yml (contract §3.8, FR-021) -

@test "T101 — a plain run that stops at the consolidated question leaves config.yml byte-for-byte unchanged" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  local cfg="${JIRA_CONFIG_DIR}/config.yml"
  local before; before="${BATS_TEST_TMPDIR}/config.yml.before"
  cp "${cfg}" "${before}"

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "confirmation-pending" ]
  cmp "${before}" "${cfg}"
}

@test "T101 — an --accept-defaults run that writes tickets leaves config.yml byte-for-byte unchanged" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  local cfg="${JIRA_CONFIG_DIR}/config.yml"
  local before; before="${BATS_TEST_TMPDIR}/config.yml.before"
  cp "${cfg}" "${before}"

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -gt 0 ]
  cmp "${before}" "${cfg}"
}

@test "T101 — a --field-value override run leaves config.yml byte-for-byte unchanged" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  local cfg="${JIRA_CONFIG_DIR}/config.yml"
  local before; before="${BATS_TEST_TMPDIR}/config.yml.before"
  cp "${cfg}" "${before}"

  run cmd_reconcile reconcile "${SPEC}" \
    --field-value 'PM=Deliverable=Business Owner=Override Team' --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.actions[] | select(.role=="parent")][0].body.fields.customfield_40011' <<< "$output")" = "Override Team" ]
  cmp "${before}" "${cfg}"
}

@test "T101 — a hook-fired run leaves config.yml byte-for-byte unchanged" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields
  local cfg="${JIRA_CONFIG_DIR}/config.yml"
  local before; before="${BATS_TEST_TMPDIR}/config.yml.before"
  cp "${cfg}" "${before}"
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<< "$output")" = "confirmation-pending" ]
  cmp "${before}" "${cfg}"
  unset SPEC_KIT_JIRA_HOOK_CONTEXT
}

# --- T103 — the write-path half of the removal off switch (FR-029, contract §5.2) -

@test "T103 — removing a recorded default for an optional field excludes it from the next creation payload" {
  mock_start "${MOCK}/configs/optional-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # Type id 10101 (the derived specification role, "Deliverable") carries the
  # fd-optional shape's sole custom field, "Slack Channel" — optional, never
  # asked about (FR-004), recorded here by flag.
  cmd_config config PM --issue-type "PM=story=Story" \
    --field-default 'PM=Deliverable=Slack Channel=general' --json > /dev/null

  # The operator removes the entry by hand — the map the region carries no
  # longer names "Slack Channel" at all (§2.6's carry-forward has nothing left
  # to carry for it).
  local map='{"PM":{}}'
  _config_field_defaults_write "${JIRA_CONFIG_DIR}/config.yml" "${map}" "false" > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
  [ "$(jq -r '[.actions[] | select(.role=="parent")][0].body.fields | has("customfield_40099")' <<< "$output")" = "false" ]
  [[ "$output" != *"general"* ]]
}

@test "T103 — removing a recorded default for a required field returns the §3.6 refusal with zero writes and the remedy line" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_both_fields

  # The operator removes only "Program Increment"; "Business Owner" stays
  # recorded and satisfiable.
  local map='{"PM":{"Deliverable":{"Business Owner":"Platform Team"}}}'
  _config_field_defaults_write "${JIRA_CONFIG_DIR}/config.yml" "${map}" "false" > /dev/null

  run cmd_reconcile reconcile "${SPEC}" --accept-defaults --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"Program Increment"* ]]
  [[ "$output" == *"speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Program Increment=<value>'"* ]]
  # Business Owner is still satisfiable — it is not named as an unsatisfiable field.
  [[ "$output" != *"speckit.jira-mirror.config PM --field-default 'PM=Deliverable=Business Owner="* ]]

  run mock_calls
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    [[ "${line}" == GET\ * ]]
  done <<< "$output"
}

# --- 015 T019/T020 [US2] — every operator-facing surface keeps speaking the --
# operator's own words. Decision R2 makes this hold BY CONSTRUCTION: the
# three display sites (plan_confirmation_fields, the provenance line, and the
# --field-default promotion command) keep reading the recorded map, never the
# encoded one — these are guard tests, direct unit calls against an
# option-typed field, proving no wire shape leaks through.

@test "015 T019 — plan_confirmation_fields' recorded_value for an option-typed field is the plain recorded string" {
  local itypes='[{"logical_name":"Deliverable","id":"10101"}]'
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA","APAC"]}]}'
  local defaults='{"10101":{"customfield_1":"EMEA"}}'
  run plan_confirmation_fields "${itypes}" "${df}" "${defaults}" '["10101"]'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].recorded_value' <<< "$output")" = "EMEA" ]
  [[ "$output" != *'"value"'* ]]
}

@test "015 T019 (FR-010) — a required option-typed field with nothing to send is still listed, with a null value" {
  local itypes='[{"logical_name":"Deliverable","id":"10101"}]'
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA","APAC"]}]}'
  run plan_confirmation_fields "${itypes}" "${df}" "{}" '["10101"]'
  [ "$(jq -r 'length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.[0].recorded_value' <<< "$output")" = "null" ]
}

@test "015 T020 — the provenance line reads the plain recorded value for an option-typed field, never its wire shape" {
  local itypes='[{"logical_name":"Deliverable","id":"10101"}]'
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA","APAC"]}]}'
  local resolved='{"field_defaults":{"10101":{"customfield_1":"EMEA"}},"field_default_sources":{"10101":{"customfield_1":"team-config"}},"unresolved":[]}'
  local actions='[{"method":"POST","url":"https://example.atlassian.net/rest/api/3/issue","body":{"fields":{"issuetype":{"id":"10101"},"customfield_1":"EMEA"}}}]'
  run _reconcile_field_default_notes "PM" "${itypes}" "${df}" "${resolved}" "${actions}" "null" "true" "false" "false"
  [[ "$output" == *'Region (Deliverable) = "EMEA" — sent from team-config'* ]]
  [[ "$output" != *'"value"'* ]]
}

@test "015 T020 — the --field-default promotion command embeds the recorded value verbatim, re-recordable as printed" {
  local itypes='[{"logical_name":"Deliverable","id":"10101"}]'
  local df='{"10101":[{"logical_name":"Region","field_id":"customfield_1","schema_type":"option","required":true,"defaultable":true,"allowed_values":["EMEA","APAC"]}]}'
  local resolved='{"field_defaults":{"10101":{"customfield_1":"EMEA"}},"field_default_sources":{"10101":{"customfield_1":"operator-answer"}},"unresolved":[]}'
  local actions='[{"method":"POST","url":"https://example.atlassian.net/rest/api/3/issue","body":{"fields":{"issuetype":{"id":"10101"},"customfield_1":"EMEA"}}}]'
  run _reconcile_field_default_notes "PM" "${itypes}" "${df}" "${resolved}" "${actions}" "null" "true" "false" "false"
  [[ "$output" == *"--field-default 'PM=Deliverable=Region=EMEA'"* ]]
  # Running the printed command re-records exactly the recorded value —
  # the promotion line must never carry {"value": ...} or any other wrap.
  [[ "$output" != *'{"value"'* ]]
}
