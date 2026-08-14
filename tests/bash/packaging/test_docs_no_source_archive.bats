#!/usr/bin/env bats
# T046 [026] [US4] — README.md and INSTALL.md contain no repository
# source-archive address, in any branch or tag form. The pattern that must
# never reappear is `archive/refs/` (contracts/publication.md C3.1, C3.6).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
}

@test "README.md never contains a source-archive address" {
  run grep -n 'archive/refs/' "${ROOT}/README.md"
  [ "$status" -ne 0 ]
}

@test "INSTALL.md never contains a source-archive address" {
  run grep -n 'archive/refs/' "${ROOT}/INSTALL.md"
  [ "$status" -ne 0 ]
}

@test "templates/readme-block.template never contains a source-archive address" {
  # Not named by C3.1, but the same class of risk: this template is SHIPPED —
  # it writes its install command into every consuming repository's own
  # README, so a stale address here propagates rather than staying local.
  run grep -n 'archive/refs/' "${ROOT}/templates/readme-block.template"
  [ "$status" -ne 0 ]
}
