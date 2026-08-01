#!/usr/bin/env bats
# T035 [US3] — Conformance: a shared defect neither port can hide behind the
# other (SC-005, research R6, R7 case 12).
#
# Drives the us1-unicode-binding scenario through the real dispatcher on both
# ports. The fixture's config.local.yml carries the bug report's own
# reproduction under project JET — a project config.yml never declares, so the
# config command preserves it verbatim while it (re)discovers COMP. Asserted
# against the fixture's EXPECTED CONTENT, not only port-against-port: a defect
# both ports share would otherwise produce two identical WRONG captures and
# pass the parity diff alone.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  SCENARIO="${CONF}/scenarios/us1-unicode-binding.json"
  TMP="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
}

teardown() {
  rm -rf "${TMP}"
}

_assert_jet_entry() {
  local localj="$1"
  # New list shape (008 T014a): issue_types is a list of
  # {logical_name, id, hierarchy_level, subtask}, not a name-to-id map.
  [ "$(jq -r '.resolved_ids.JET.issue_types[] | select(.logical_name=="Récit") | .id' <<< "${localj}")" = "10004" ]
  [ "$(jq -r '.resolved_ids.JET.issue_types[] | select(.logical_name=="Story") | .id' <<< "${localj}")" = "10005" ]
  [ "$(jq -r '.resolved_ids.JET.child_type.logical_name' <<< "${localj}")" = "Récit" ]
  [ "$(jq -r '.resolved_ids.JET.parent_type.logical_name' <<< "${localj}")" = "Chantier" ]
  [ "$(jq -r '.resolved_ids.JET.priorities["Faible"]' <<< "${localj}")" = "4" ]
  [ "$(jq -r '.resolved_ids.JET.priorities["Élevée"]' <<< "${localj}")" = "1" ]
  [ "$(jq -r '.resolved_ids.JET.priorities["Приоритет"]' <<< "${localj}")" = "2" ]
  [ "$(jq -r '.resolved_ids.JET.priorities["Größe"]' <<< "${localj}")" = "3" ]
  [ "$(jq -r '.resolved_ids.JET.statuses["Terminé"]' <<< "${localj}")" = "10002" ]
  [ "$(jq -r ".resolved_ids.JET.statuses[\"Won't Do\"]" <<< "${localj}")" = "10004" ]
  [ "$(jq -r '.resolved_ids.JET.statuses["À faire"]' <<< "${localj}")" = "10001" ]
  [ "$(jq -r '.resolved_ids.JET.statuses["完了"]' <<< "${localj}")" = "10003" ]
  [ "$(jq -r '.resolved_ids.JET.statuses["Done (QA)"]' <<< "${localj}")" = "10005" ]
  [ "$(jq -r '.resolved_ids.JET.statuses["high/low"]' <<< "${localj}")" = "6" ]
  [ "$(jq -r '.resolved_ids.JET.style' <<< "${localj}")" = "company_managed" ]
}

@test "the unicode binding's every key with every expected id survives (bash)" {
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local localj
  localj="$(config_yaml_to_json "${TMP}/out-bash/workdir/.specify/jira/config.local.yml")"
  _assert_jet_entry "${localj}"
}

@test "the unicode binding is byte-identical across ports (FR-014, SC-005)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash "${HARNESS}" "${SCENARIO}" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${SCENARIO}" powershell "${TMP}/out-ps" > /dev/null
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}
