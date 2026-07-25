#!/usr/bin/env bats
# T062 [US5] — README-block idempotency (FR 028, FR 029).
#
# Re-running with an unchanged version and content rewrites nothing and reports a
# zero-change result; a hand-edited block is regenerated (bridge-owned) and the
# summary states it was replaced.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HOOKS="${ROOT}/scripts/bash/hooks"
  # shellcheck source=/dev/null
  source "${HOOKS}/readme_block.sh"
  # The version is read from the single source (extension.yml), never hardcoded in
  # a test — the version literal must live only in extension.yml (SC-006/FR-022).
  VERSION="$(sed -n 's/^[[:space:]]\{1,\}version:[[:space:]]*//p' "${ROOT}/extension.yml" | head -n1)"
  WORK="$(mktemp -d)"
  printf '<!-- spec-kit-jira:begin v{{VERSION}} -->\nMANAGED v{{VERSION}}\n<!-- spec-kit-jira:end v{{VERSION}} -->\n' > "${WORK}/tmpl"
  export SPEC_KIT_JIRA_README_TEMPLATE="${WORK}/tmpl"
}

teardown() { rm -rf "${WORK}"; }

@test "re-running against an up-to-date README reports unchanged and rewrites nothing" {
  readme_block_write "${WORK}/README.md" false > /dev/null
  cp "${WORK}/README.md" "${WORK}/snap"
  readme_block_write "${WORK}/README.md" false > "${WORK}/status"
  [ "$(cat "${WORK}/status")" = "unchanged" ]
  run diff "${WORK}/snap" "${WORK}/README.md"
  [ "$status" -eq 0 ]
}

@test "readme_block_render emits the version-marked block from the single source" {
  run readme_block_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"spec-kit-jira:begin v${VERSION}"* ]]
  [[ "$output" == *"spec-kit-jira:end v${VERSION}"* ]]
}

@test "a hand-edited block is regenerated and reported written" {
  readme_block_write "${WORK}/README.md" false > /dev/null
  sed "s/MANAGED v${VERSION}/HUMAN EDIT/" "${WORK}/README.md" > "${WORK}/tampered"
  cp "${WORK}/tampered" "${WORK}/README.md"
  readme_block_write "${WORK}/README.md" false > "${WORK}/status"
  [ "$(cat "${WORK}/status")" = "written" ]
  grep -q "MANAGED v${VERSION}" "${WORK}/README.md"
  ! grep -q 'HUMAN EDIT' "${WORK}/README.md"
}

@test "dry-run reports the status without writing the file" {
  readme_block_write "${WORK}/README.md" true > "${WORK}/status"
  [ "$(cat "${WORK}/status")" = "created" ]
  [ ! -f "${WORK}/README.md" ]
}

@test "content outside a present block is byte-preserved across an update" {
  printf 'INTRO LINE\n\n<!-- spec-kit-jira:begin v0.0.1 -->\nold\n<!-- spec-kit-jira:end v0.0.1 -->\n\nOUTRO LINE\n' > "${WORK}/README.md"
  readme_block_write "${WORK}/README.md" false > "${WORK}/status"
  [ "$(cat "${WORK}/status")" = "written" ]
  [ "$(head -n1 "${WORK}/README.md")" = "INTRO LINE" ]
  [ "$(tail -n1 "${WORK}/README.md")" = "OUTRO LINE" ]
  grep -q "MANAGED v${VERSION}" "${WORK}/README.md"
}
