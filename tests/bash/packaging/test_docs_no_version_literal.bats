#!/usr/bin/env bats
# T047 [026] [US4] — the resolved version literal appears in neither
# README.md nor INSTALL.md, nor anywhere under `packaging/`. This is what
# makes the version-free documented address a CHECKED property, not an
# intention (contracts/publication.md C1.4, C3.2).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  VERSION="$("${ROOT}/packaging/resolve-version.sh")"
}

@test "README.md contains no resolved version literal" {
  run grep -nF "${VERSION}" "${ROOT}/README.md"
  [ "$status" -ne 0 ]
}

@test "INSTALL.md contains no resolved version literal, except inside the <X.Y.Z> placeholder form" {
  # The pinned form is documented with a PLACEHOLDER, never a literal
  # (C3.3) — so any occurrence of the real resolved version would mean the
  # placeholder was accidentally filled in.
  run grep -nF "${VERSION}" "${ROOT}/INSTALL.md"
  [ "$status" -ne 0 ]
}

@test "packaging/ contains no resolved version literal" {
  run grep -rnF "${VERSION}" "${ROOT}/packaging"
  [ "$status" -ne 0 ]
}
