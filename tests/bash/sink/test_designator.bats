#!/usr/bin/env bats
# T007/T011/T013/T015/T017 [027] — Designator grammar and reduction
# (contracts/designator-grammar.md). Key grammar (§2), URL reduction (§3),
# host comparison (§4), free text (§5), order and de-duplication (§6).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/designator.sh"
  BASE="https://acme.atlassian.net"
}

# --- D1: key grammar (§2) ----------------------------------------------------

@test "D1: PROJ-123 accepts" {
  run designator_reduce_key "PROJ-123"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-123" ]
}

@test "D1: proj-123 normalises to upper case" {
  run designator_reduce_key "proj-123"
  [ "$status" -eq 0 ]
  [ "$output" = "PROJ-123" ]
}

@test "D1: P-1 refuses (project key needs >= 2 chars)" {
  run designator_reduce_key "P-1"
  [ "$status" -ne 0 ]
}

@test "D1: PROJ- refuses" {
  run designator_reduce_key "PROJ-"
  [ "$status" -ne 0 ]
}

@test "D1: 1PROJ-1 refuses (must start with a letter)" {
  run designator_reduce_key "1PROJ-1"
  [ "$status" -ne 0 ]
}

# --- D2: the three URL shapes (§3) -------------------------------------------

@test "D2: browse path reduces to the key" {
  run designator_classify story "${BASE}/browse/PROJ-123" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.form' <<< "$output")" = "url" ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

@test "D2: board-context URL with selectedIssue reduces to the key" {
  run designator_classify story "${BASE}/jira/software/projects/PROJ/boards/7?selectedIssue=PROJ-123" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

@test "D2: trailing query or anchor on a browse URL still reduces" {
  run designator_classify story "${BASE}/browse/PROJ-123?filter=42#comment-9" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

# --- D3: selectedIssue wins over a key-shaped path segment -------------------

@test "D3: selectedIssue wins when the path segment disagrees" {
  run designator_classify story "${BASE}/browse/PROJ-999?selectedIssue=PROJ-123" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

# --- D4: percent-decoded selectedIssue ---------------------------------------

@test "D4: percent-encoded selectedIssue decodes before the grammar check" {
  run designator_classify story "${BASE}/jira/software/boards/7?selectedIssue=PROJ%2D123" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

# --- D5: host mismatch refuses with zero requests issued ---------------------

@test "D5: host mismatch refuses with REF-HOST" {
  run designator_classify story "https://evil.example.com/browse/PROJ-123" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.refuse' <<< "$output")" = "REF-HOST" ]
}

@test "D5: extraction failing on an unrecognised URL shape is REF-DESIGNATOR, not REF-HOST" {
  run designator_classify story "https://evil.example.com/not-an-issue-path" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.refuse' <<< "$output")" = "REF-DESIGNATOR" ]
}

# --- D6: base URL carrying a path prefix still matches -----------------------

@test "D6: a base URL with a path prefix matches, and reduces" {
  local dcbase="https://jira.example.com/jira/"
  run designator_classify story "https://jira.example.com/jira/browse/PROJ-1" "${dcbase}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-1" ]
}

# --- D7/D9: de-duplication and order preservation (§6) -----------------------

@test "D7: same issue as key and as URL is REF-DUPLICATE" {
  local a b
  a="$(designator_classify story "PROJ-11" "${BASE}")"
  b="$(designator_classify story "${BASE}/browse/PROJ-11" "${BASE}")"
  run designator_dedupe "[${a},${b}]"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<< "$output")" = "false" ]
  [ "$(jq -r '.duplicates | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.duplicates[0]' <<< "$output")" = "PROJ-11" ]
}

@test "D9: ten designators, positions preserved in argv order" {
  local arr="[" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ "${i}" != "1" ]] && arr+=","
    arr+="$(designator_classify story "PROJ-${i}" "${BASE}")"
  done
  arr+="]"
  run designator_dedupe "${arr}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<< "$output")" = "true" ]
  [ "$(jq -r '.designators | length' <<< "$output")" -eq 10 ]
  [ "$(jq -r '.designators[0].position' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.designators[9].position' <<< "$output")" -eq 9 ]
  [ "$(jq -r '.designators[4].key' <<< "$output")" = "PROJ-5" ]
}

@test "naming one issue as both roles is REF-DUPLICATE" {
  local parent stories
  parent="$(designator_classify specification "PROJ-1" "${BASE}")"
  stories="$(designator_classify story "PROJ-1" "${BASE}")"
  run designator_dedupe "[${parent},${stories}]"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<< "$output")" = "false" ]
  [ "$(jq -r '.duplicates[0]' <<< "$output")" = "PROJ-1" ]
}

# --- D8: blank --parent vs absent --parent (§5, FR-055) ---------------------

@test "D8: blank free-text parent refuses with REF-DESIGNATOR" {
  run designator_classify specification "   " "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.refuse' <<< "$output")" = "REF-DESIGNATOR" ]
}

@test "D8: non-blank free text is legal only for the specification role" {
  run designator_classify specification "Payment webhooks rollout" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.form' <<< "$output")" = "free_text" ]
  [ "$(jq -r '.text' <<< "$output")" = "Payment webhooks rollout" ]
}

@test "D8: free text on the story role refuses with REF-DESIGNATOR" {
  run designator_classify story "not a key or url" "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.refuse' <<< "$output")" = "REF-DESIGNATOR" ]
}

# --- D10: a trailing CR reduces identically -----------------------------------

@test "D10: a designator with a trailing CR reduces identically" {
  run designator_classify story $'PROJ-123\r' "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

@test "D10: a free-text parent with a trailing CR emits the trimmed title, raw untouched" {
  # §7: "a designator arriving with a trailing CR is trimmed". `text` becomes
  # the created parent's Jira summary (ticket_create's second argument), so
  # the CR must not survive into it. `raw` keeps the operator's exact bytes
  # for diagnostics — the two fields answer different questions.
  run designator_classify specification $'Payment webhooks rollout\r' "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.form' <<< "$output")" = "free_text" ]
  [ "$(jq -r '.text' <<< "$output")" = "Payment webhooks rollout" ]
  [ "$(jq -r '.raw' <<< "$output")" = $'Payment webhooks rollout\r' ]
}

@test "D10: a free-text parent padded with spaces emits the trimmed title" {
  # The same guard that decides non-blank also strips surrounding spaces, so
  # a padded title must reach Jira trimmed for the same reason a CR does.
  run designator_classify specification "   Payment webhooks rollout   " "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<< "$output")" = "Payment webhooks rollout" ]
}

@test "D10: a browse URL with a trailing CR reduces identically" {
  run designator_classify story $'https://acme.atlassian.net/browse/PROJ-123\r' "${BASE}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "PROJ-123" ]
}

# --- T064: FR-047, credentials never reach argv, logs, or traces ------------

@test "T064: designator.sh never references a credential variable or header" {
  run grep -c -E "JIRA_API_TOKEN|JIRA_EMAIL|Authorization" "${SINK_DIR}/designator.sh"
  [ "$output" = "0" ]
}

@test "T064: the token never leaks from designator_classify at max verbosity" {
  export JIRA_API_TOKEN="RAWSECRETXYZ0123456789"
  local out
  out="$(bash -x -c "source '${SINK_DIR}/designator.sh'; designator_classify story 'PROJ-1' 'https://acme.atlassian.net'" 2>&1)"
  run grep -c "RAWSECRETXYZ0123456789" <<< "${out}"
  [ "$output" = "0" ]
}
