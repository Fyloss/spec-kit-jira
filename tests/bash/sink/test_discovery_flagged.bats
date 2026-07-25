#!/usr/bin/env bats
# Flagged/impediment field discovery (FR-036 lifecycle safety input).
#
# The Flagged field feeds flagged-withholding: a ticket carrying the marker never
# receives a transition. Discovery must therefore be LOCALE-INDEPENDENT: the
# English name (`Impediment`/`Flagged`) is only a first-chance match — on a
# localized or renamed site the field is found by SHAPE (the Flagged field is an
# array-of-options checkbox custom field), and only an unambiguous single shape
# candidate is accepted (precision over recall). The PowerShell port resolves
# identically (NFR-1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/.specify/extensions/jira/scripts/bash/sink/jira"
  PS_SINK="${ROOT}/.specify/extensions/jira/scripts/powershell/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/discovery.sh"

  ENGLISH='[{"fieldId":"customfield_20044","name":"Impediment","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}},{"fieldId":"customfield_20011","name":"T-Shirt Estimate","schema":{"type":"number"}}]'
  LOCALIZED='[{"fieldId":"customfield_40077","name":"Kennzeichnung","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}},{"fieldId":"customfield_30044","name":"Aufwand","schema":{"type":"number"}}]'
  AMBIGUOUS='[{"fieldId":"customfield_1","name":"Kennzeichnung","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}},{"fieldId":"customfield_2","name":"Kategorien","schema":{"type":"array","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes"}}]'
}

@test "flagged field resolves by NAME on an English site" {
  run discovery_flagged_field "${ENGLISH}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<< "$output")" = "customfield_20044" ]
}

@test "flagged field resolves by SHAPE on a localized site — FR-036 safety stays active" {
  run discovery_flagged_field "${LOCALIZED}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<< "$output")" = "customfield_40077" ]
  [ "$(jq -r '.logical_name' <<< "$output")" = "Kennzeichnung" ]
}

@test "an ambiguous shape with no name match resolves to null (precision over recall)" {
  run discovery_flagged_field "${AMBIGUOUS}"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "no candidate at all resolves to null" {
  run discovery_flagged_field '[{"fieldId":"summary","name":"Summary","schema":{"type":"string"}}]'
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "the PowerShell port resolves the flagged field identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local b p
  b="$(discovery_flagged_field "${LOCALIZED}")"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_SINK}/Discovery.psm1' -Force
    Import-Module '${ROOT}/.specify/extensions/jira/scripts/powershell/lib/Output.psm1' -Force
    \$f = Get-JiraDiscoveryFlaggedField -FieldsJson '${LOCALIZED}'
    [Console]::Out.Write((ConvertTo-JiraJsonValue \$f))
  ")"
  [ "$b" = "$p" ]
}
