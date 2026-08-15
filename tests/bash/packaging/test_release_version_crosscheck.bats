#!/usr/bin/env bats
# T040 [026] [US2] — `packaging/publish-artifact.sh` refuses to publish when
# the tag names a version that disagrees with `extension.yml`, and names
# BOTH values (contracts/publication.md C2.2). Accepts both `v1.2.3` and
# `1.2.3` spellings of the tag.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PUBLISH="${ROOT}/packaging/publish-artifact.sh"
  ACTUAL_VERSION="$("${ROOT}/packaging/resolve-version.sh")"
  WORK="$(mktemp -d)"
  printf 'archive-bytes' > "${WORK}/archive.zip"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a mismatched v-prefixed tag is refused, naming both the tag's and the manifest's version" {
  run "${PUBLISH}" "v9.9.9" "${WORK}/archive.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'9.9.9'* ]]
  [[ "$output" == *"${ACTUAL_VERSION}"* ]]
}

@test "a mismatched bare tag (no v prefix) is refused the same way" {
  run "${PUBLISH}" "9.9.9" "${WORK}/archive.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'9.9.9'* ]]
  [[ "$output" == *"${ACTUAL_VERSION}"* ]]
}

@test "a matching v-prefixed tag does not fail on the cross-check" {
  # A minimal PATH with no `gh` on it (but still resolving bash/env/coreutils)
  # — expect this to fail LATER, at the gh call, never at the cross-check.
  PATH="/usr/bin:/bin" run "${PUBLISH}" "v${ACTUAL_VERSION}" "${WORK}/archive.zip"
  [[ "$output" != *"refusing to publish"* ]]
}

@test "an absent archive is refused before any version check" {
  run "${PUBLISH}" "v${ACTUAL_VERSION}" "${WORK}/does-not-exist.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'archive not found'* ]]
}
