#!/usr/bin/env bats
# T072 [US6] — Zero-churn idempotency diff (FR-030, Constitution II).
#
# Pure engine primitives that decide whether a would-be write is churn. A field
# set already present on the ticket, or a managed-section splice that changes no
# bytes, must report "unchanged" so the caller drops the no-op write. Malformed
# markers surface the splice's exit 4 verbatim. The PowerShell port agrees.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/idempotency.sh"
  BEGIN="<!-- x:begin -->"
  END="<!-- x:end -->"
}

@test "idempotency_equal is ordinal byte equality" {
  run idempotency_equal "abc" "abc"; [ "$status" -eq 0 ]
  run idempotency_equal "abc" "abC"; [ "$status" -ne 0 ]
}

@test "field status is unchanged when every desired key already matches (key-order independent)" {
  local current='{"summary":"Title","priority":{"id":"2"},"extra":"kept"}'
  local desired='{"priority":{"id":"2"},"summary":"Title"}'
  run idempotency_field_status "${current}" "${desired}"
  [ "$output" = "unchanged" ]
}

@test "field status is changed when any desired value differs" {
  local current='{"summary":"Old","priority":{"id":"2"}}'
  local desired='{"summary":"New","priority":{"id":"2"}}'
  run idempotency_field_status "${current}" "${desired}"
  [ "$output" = "changed" ]
}

@test "field status is changed when a desired key is absent from current" {
  run idempotency_field_status '{"summary":"Title"}' '{"priority":{"id":"2"}}'
  [ "$output" = "changed" ]
}

@test "managed status is unchanged when the splice is a no-op" {
  local block="${BEGIN}"$'\n'"body line"$'\n'"${END}"
  local host="prelude"$'\n'"${block}"$'\n'"epilogue"$'\n'
  run bash -c "source '${ENGINE_DIR}/idempotency.sh'; printf '%s' \"\$1\" | idempotency_managed_status \"\$2\" \"\$3\" \"\$4\"" _ "${host}" "${BEGIN}" "${END}" "${block}"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "managed status is changed when the block body differs" {
  local host="prelude"$'\n'"${BEGIN}"$'\n'"old body"$'\n'"${END}"$'\n'
  local newblock="${BEGIN}"$'\n'"new body"$'\n'"${END}"
  run bash -c "source '${ENGINE_DIR}/idempotency.sh'; printf '%s' \"\$1\" | idempotency_managed_status \"\$2\" \"\$3\" \"\$4\"" _ "${host}" "${BEGIN}" "${END}" "${newblock}"
  [ "$status" -eq 0 ]
  [ "$output" = "changed" ]
}

@test "managed status refuses malformed markers with exit 4 and no output" {
  local host="${BEGIN}"$'\n'"a"$'\n'"${BEGIN}"$'\n'"b"$'\n'"${END}"$'\n'
  local newblock="${BEGIN}"$'\n'"x"$'\n'"${END}"
  # The splice's located error goes to stderr; assert stdout carries nothing.
  run bash -c "source '${ENGINE_DIR}/idempotency.sh'; printf '%s' \"\$1\" | idempotency_managed_status \"\$2\" \"\$3\" \"\$4\" 2>/dev/null" _ "${host}" "${BEGIN}" "${END}" "${newblock}"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "the PowerShell port reports identical field status (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps_abs; ps_abs="$(cd "${PS_ENGINE}" && pwd)"
  local current='{"summary":"Title","priority":{"id":"2"}}'
  local desired='{"priority":{"id":"2"},"summary":"Title"}'
  local bash_out ps_out
  bash_out="$(idempotency_field_status "${current}" "${desired}")"
  ps_out="$(CUR="${current}" DES="${desired}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/Idempotency.psm1' -Force
    [Console]::Out.Write((Get-JiraIdempotentFieldStatus -CurrentFieldsJson \$env:CUR -DesiredFieldsJson \$env:DES))
  ")"
  [ "$bash_out" = "$ps_out" ]
}
