#!/usr/bin/env bats
# Guard for _normalize_state_base_url (tests/conformance/ci-conformance.sh).
#
# The normalizer masks the ONE field a recorded run-state document can never
# agree on across ports — `base_url`, the mock's OS-assigned port on the
# PowerShell side against the curl shim's fixed sentinel on the Bash side. It
# runs on both captures immediately before the written-files diff, so anything
# it does wrong it does symmetrically, and a symmetric corruption compares
# EQUAL: the divergence it was meant to expose disappears instead.
#
# That is the failure mode pinned here. Rewriting a document jq could not
# parse truncates it to zero bytes on both sides, so a corrupt state document
# — exactly what us021-state-corrupt.json produces on purpose — would diff
# clean against another corrupt one. The normalizer must leave a document it
# cannot parse exactly as it found it, and let the diff speak.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CI_CONFORMANCE="${ROOT}/tests/conformance/ci-conformance.sh"
  STATE_DIR="${BATS_TEST_TMPDIR}/workdir/.specify/jira/state"
  mkdir -p "${STATE_DIR}"

  # ci-conformance.sh runs the whole corpus on source, so the function is
  # lifted out of its text rather than sourced — the same extract-and-assert
  # shape test_coverage_runner_bounds.bats uses on that script.
  eval "$(awk '/^_normalize_state_base_url\(\) \{/ { on = 1 } on { print } on && /^\}$/ { exit }' "${CI_CONFORMANCE}")"
}

@test "the guard lifts a non-empty _normalize_state_base_url out of ci-conformance.sh" {
  declare -F _normalize_state_base_url > /dev/null
}

@test "a parseable state document has base_url masked and every other field kept" {
  printf '%s' '{"base_url":"http://127.0.0.1:51234","email":"a@b.c","on_drift":"abort","schema":1}' \
    > "${STATE_DIR}/001-feature.json"

  _normalize_state_base_url "${BATS_TEST_TMPDIR}/workdir"

  run jq -r '.base_url' "${STATE_DIR}/001-feature.json"
  [ "$output" = "MOCK_BASE_URL" ]
  run jq -r '.email' "${STATE_DIR}/001-feature.json"
  [ "$output" = "a@b.c" ]
  run jq -r '.on_drift' "${STATE_DIR}/001-feature.json"
  [ "$output" = "abort" ]
  run jq -r '.schema' "${STATE_DIR}/001-feature.json"
  [ "$output" = "1" ]
}

@test "a state document jq cannot parse is left byte-identical, never truncated" {
  local corrupt='{ not valid json'
  printf '%s' "${corrupt}" > "${STATE_DIR}/001-feature.json"

  _normalize_state_base_url "${BATS_TEST_TMPDIR}/workdir"

  # Zero bytes here is the masking bug: both ports' corrupt documents would
  # be emptied identically and the diff would call them equal.
  [ -s "${STATE_DIR}/001-feature.json" ]
  run cat "${STATE_DIR}/001-feature.json"
  [ "$output" = "${corrupt}" ]
}

@test "an empty state document is left empty rather than being rewritten" {
  : > "${STATE_DIR}/001-feature.json"

  _normalize_state_base_url "${BATS_TEST_TMPDIR}/workdir"

  [ -f "${STATE_DIR}/001-feature.json" ]
  [ ! -s "${STATE_DIR}/001-feature.json" ]
}
