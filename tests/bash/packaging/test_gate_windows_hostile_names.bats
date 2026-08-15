#!/usr/bin/env bats
# T035 [026] [US3] — a member path containing a Windows-invalid character
# (`<>:"|?*`) or a reserved device name is rejected. Without this, such a
# name is discovered only by a Windows consumer, after publication
# (contracts/artifact-shape.md C3.3).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  VERIFY="${ROOT}/packaging/verify-artifact.sh"
  BUILDER="${ROOT}/packaging/build-artifact.sh"
  WORK="$(mktemp -d)"
  "${BUILDER}" "${WORK}/good.zip" > "${WORK}/good.manifest"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a member path containing a Windows-invalid character is rejected" {
  cp "${WORK}/good.zip" "${WORK}/bad-char.zip"
  python3 - "${WORK}/bad-char.zip" << 'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a") as zf:
    zf.writestr('spec-kit-jira/scripts/bash/bad<name>.sh', "x")
PY
  run "${VERIFY}" bounds "${WORK}/bad-char.zip" "${WORK}/good.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Windows-invalid character'* ]]
}

@test "a reserved device name in any path component is rejected" {
  cp "${WORK}/good.zip" "${WORK}/reserved-name.zip"
  python3 - "${WORK}/reserved-name.zip" << 'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a") as zf:
    zf.writestr('spec-kit-jira/scripts/bash/CON/note.txt', "x")
PY
  run "${VERIFY}" bounds "${WORK}/reserved-name.zip" "${WORK}/good.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Windows-reserved device name'* ]]
}

@test "a reserved device name with an extension (NUL.txt) is still rejected" {
  cp "${WORK}/good.zip" "${WORK}/reserved-ext.zip"
  python3 - "${WORK}/reserved-ext.zip" << 'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a") as zf:
    zf.writestr('spec-kit-jira/scripts/bash/NUL.txt', "x")
PY
  run "${VERIFY}" bounds "${WORK}/reserved-ext.zip" "${WORK}/good.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Windows-reserved device name'* ]]
}

@test "an ordinary path containing neither is accepted" {
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/good.manifest"
  [ "$status" -eq 0 ]
}
