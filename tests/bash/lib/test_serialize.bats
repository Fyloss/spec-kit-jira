#!/usr/bin/env bats
# T012 — Canonical-serializer parity (research §11): stable key ordering, UTF-8,
# no trailing newline, jq <-> ConvertTo-Json byte-parity, @uri %20->+ rule.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  PS_LIB="${ROOT}/scripts/powershell/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/output.sh"
}

# Emit canonical JSON from the PowerShell port for the same input (parity oracle).
ps_canonical() {
  pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Output.psm1' -Force
    \$in = [Console]::In.ReadToEnd()
    [Console]::Out.Write((ConvertTo-JiraCanonicalJson \$in))
  "
}

@test "json_canonical sorts object keys and compacts" {
  run bash -c "printf '%s' '{\"b\":2,\"a\":1}' | { source '${LIB_DIR}/output.sh'; json_canonical; }"
  [ "$output" = '{"a":1,"b":2}' ]
}

@test "json_canonical preserves raw UTF-8 (no \\u escaping of non-ASCII)" {
  result="$(printf '%s' '{"k":"café"}' | json_canonical)"
  [ "$result" = '{"k":"café"}' ]
}

@test "json_canonical escapes quote, backslash, and newline" {
  result="$(printf '%s' '{"k":"a\"b\\c\nd"}' | json_canonical)"
  [ "$result" = '{"k":"a\"b\\c\nd"}' ]
}

@test "json_canonical emits no trailing newline" {
  result="$(printf '%s' '{"a":1}' | json_canonical | wc -c | tr -d ' ')"
  [ "$result" = "7" ]   # {"a":1} == 7 bytes, no newline
}

@test "uri_encode applies @uri then %20->+" {
  run uri_encode "a b/c"
  [ "$output" = "a+b%2Fc" ]
}

@test "canonical output is byte-identical across ports (nested)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  input='{"z":[3,2,1],"a":{"n":2.5,"m":"café \" \n"}}'
  bash_out="$(printf '%s' "$input" | json_canonical)"
  ps_out="$(printf '%s' "$input" | ps_canonical)"
  [ "$bash_out" = "$ps_out" ]
}

@test "uri_encode is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  s="hello world/x?y=1&z=café"
  bash_out="$(uri_encode "$s")"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraUriComponent '$s'))")"
  [ "$bash_out" = "$ps_out" ]
}
