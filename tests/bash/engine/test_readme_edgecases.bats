#!/usr/bin/env bats
# T061 [US5] — Managed-section / README-block edge cases.
#
# Absent block appended once at the documented position; an absent README created
# with only the block; malformed markers (start-without-end / end-without-start /
# duplicated / nested) produce ZERO writes and a located error with exit 4
# (FR 026, FR 027).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE="${ROOT}/.specify/extensions/jira/scripts/bash/engine"
  HOOKS="${ROOT}/.specify/extensions/jira/scripts/bash/hooks"
  # shellcheck source=/dev/null
  source "${HOOKS}/readme_block.sh"   # brings the engine splice in too
  BEGIN='<!-- x:begin'
  END='<!-- x:end'
  BLOCK=$'<!-- x:begin v1 -->\nMANAGED LINE A\n<!-- x:end v1 -->'
  WORK="$(mktemp -d)"
  # A small synthetic template keeps writer assertions stable; the version comes
  # from the real single source (extension.yml → 0.1.0).
  printf '<!-- spec-kit-jira:begin v{{VERSION}} -->\nMANAGED v{{VERSION}}\n<!-- spec-kit-jira:end v{{VERSION}} -->\n' > "${WORK}/tmpl"
  export SPEC_KIT_JIRA_README_TEMPLATE="${WORK}/tmpl"
}

teardown() { rm -rf "${WORK}"; }

# --- engine: append + malformed refusal --------------------------------------

@test "an absent block is appended once, preserving the original bytes as a prefix" {
  printf '# Title\n\nSome content.\n' > "${WORK}/in"
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out"
  head -c "$(wc -c < "${WORK}/in")" "${WORK}/out" > "${WORK}/pref"
  run diff "${WORK}/in" "${WORK}/pref"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'x:begin' "${WORK}/out")" -eq 1 ]
  [ "$(grep -c 'x:end' "${WORK}/out")" -eq 1 ]
}

@test "a start marker without an end marker is refused with a located error (exit 4, zero output)" {
  printf 'top\n<!-- x:begin v0 -->\ndangling\n' > "${WORK}/in"
  rc=0
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out" 2> "${WORK}/err" || rc=$?
  [ "$rc" -eq 4 ]
  [ ! -s "${WORK}/out" ]
  run cat "${WORK}/err"
  [[ "$output" == *"line"* ]]
}

@test "an end marker without a start marker is refused (exit 4, zero output)" {
  printf 'top\n<!-- x:end v0 -->\nbottom\n' > "${WORK}/in"
  rc=0
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out" 2> "${WORK}/err" || rc=$?
  [ "$rc" -eq 4 ]
  [ ! -s "${WORK}/out" ]
}

@test "duplicated begin markers are refused as malformed (exit 4, zero output)" {
  printf '<!-- x:begin v0 -->\nA\n<!-- x:begin v0 -->\nB\n<!-- x:end v0 -->\n' > "${WORK}/in"
  rc=0
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out" 2> "${WORK}/err" || rc=$?
  [ "$rc" -eq 4 ]
  [ ! -s "${WORK}/out" ]
}

@test "an end marker preceding a begin marker is refused (exit 4)" {
  printf '<!-- x:end v0 -->\nmid\n<!-- x:begin v0 -->\n' > "${WORK}/in"
  rc=0
  managed_section_splice "${BEGIN}" "${END}" "${BLOCK}" < "${WORK}/in" > "${WORK}/out" 2> "${WORK}/err" || rc=$?
  [ "$rc" -eq 4 ]
  [ ! -s "${WORK}/out" ]
}

# --- writer: readme_block_write (hooks) --------------------------------------

@test "readme_block_write creates an absent README with only the block" {
  readme_block_write "${WORK}/README.md" false > "${WORK}/status"
  [ "$(cat "${WORK}/status")" = "created" ]
  [ -f "${WORK}/README.md" ]
  grep -q 'MANAGED v0.1.0' "${WORK}/README.md"
  [ "$(grep -c 'spec-kit-jira:begin' "${WORK}/README.md")" -eq 1 ]
}

@test "readme_block_write refuses a malformed README and writes nothing (exit 4)" {
  printf 'top\n<!-- spec-kit-jira:begin v0.0.9 -->\ndangling\n' > "${WORK}/README.md"
  cp "${WORK}/README.md" "${WORK}/before"
  rc=0
  readme_block_write "${WORK}/README.md" false > "${WORK}/status" || rc=$?
  [ "$rc" -eq 4 ]
  [ "$(cat "${WORK}/status")" = "refused" ]
  run diff "${WORK}/before" "${WORK}/README.md"
  [ "$status" -eq 0 ]
}
