#!/usr/bin/env bats
# T060 [US5] — Managed-section byte-splice (engine, neutral).
#
# Replace only the content between the markers; preserve every byte outside
# (CRLF-safe); adopt the host's dominant line ending for the block; a new file
# uses LF; the spliced bytes are identical across ports (FR 025, SC-005).
#
# The engine module is marker-agnostic (the marker tokens are parameters), so
# these tests use neutral placeholder tokens — no Jira/README vocabulary leaks
# into the engine layer.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/scripts/bash/engine"
  PS_ENGINE="${ROOT}/scripts/powershell/engine"
  # shellcheck source=/dev/null
  source "${ENGINE}/managed_section.sh"
  BEGIN='<!-- x:begin'
  END='<!-- x:end'
  BLOCK=$'<!-- x:begin v1 -->\nMANAGED LINE A\nMANAGED LINE B\n<!-- x:end v1 -->'
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "${WORK}"; }

@test "replaces only the content between markers, preserving bytes outside (LF)" {
  printf 'header line\n<!-- x:begin v0 -->\nOLD\n<!-- x:end v0 -->\nfooter line\n' > "${WORK}/in"
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out"
  printf 'header line\n<!-- x:begin v1 -->\nMANAGED LINE A\nMANAGED LINE B\n<!-- x:end v1 -->\nfooter line\n' > "${WORK}/exp"
  run diff "${WORK}/exp" "${WORK}/out"
  [ "$status" -eq 0 ]
}

@test "adopts the host's CRLF line ending and preserves the outer CRLF bytes" {
  printf 'header\r\n<!-- x:begin v0 -->\r\nOLD\r\n<!-- x:end v0 -->\r\nfooter\r\n' > "${WORK}/in"
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out"
  printf 'header\r\n<!-- x:begin v1 -->\r\nMANAGED LINE A\r\nMANAGED LINE B\r\n<!-- x:end v1 -->\r\nfooter\r\n' > "${WORK}/exp"
  run diff "${WORK}/exp" "${WORK}/out"
  [ "$status" -eq 0 ]
}

@test "line-ending detection reports CRLF for a predominantly CRLF host" {
  run bash -c "printf 'a\r\nb\r\nc\n' | { source '${ENGINE}/managed_section.sh'; managed_section_line_ending; }"
  [ "$output" = "CRLF" ]
}

@test "line-ending detection reports LF for an LF host" {
  run bash -c "printf 'a\nb\nc\n' | { source '${ENGINE}/managed_section.sh'; managed_section_line_ending; }"
  [ "$output" = "LF" ]
}

@test "an empty host yields a new block terminated with LF (never CRLF)" {
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < /dev/null > "${WORK}/out"
  printf '<!-- x:begin v1 -->\nMANAGED LINE A\nMANAGED LINE B\n<!-- x:end v1 -->\n' > "${WORK}/exp"
  run diff "${WORK}/exp" "${WORK}/out"
  [ "$status" -eq 0 ]
  run grep -c $'\r' "${WORK}/out"
  [ "$output" = "0" ]
}

@test "the spliced output is byte-identical across ports (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  printf 'header\r\n<!-- x:begin v0 -->\r\nOLD\r\n<!-- x:end v0 -->\r\nfooter\r\n' > "${WORK}/in"
  printf '%s' "${BLOCK}" > "${WORK}/block"
  managed_section_splice "${BEGIN}" "${END}" "$(cat "${WORK}/block")" < "${WORK}/in" > "${WORK}/out-bash"
  pwsh -NoProfile -Command "
    Import-Module '${PS_ENGINE}/ManagedSection.psm1' -Force
    \$t = [System.IO.File]::ReadAllText('${WORK}/in')
    \$b = [System.IO.File]::ReadAllText('${WORK}/block')
    \$r = Invoke-JiraManagedSectionSplice -Text \$t -BeginToken '${BEGIN}' -EndToken '${END}' -NewBlock \$b
    [System.IO.File]::WriteAllText('${WORK}/out-ps', \$r.Content, (New-Object System.Text.UTF8Encoding(\$false)))
  "
  run diff "${WORK}/out-bash" "${WORK}/out-ps"
  [ "$status" -eq 0 ]
}
