#!/usr/bin/env bats
# T032 [026] [US3] — the completeness gate: an archive with a surface file
# removed is rejected, and EVERY missing path is listed, not just the first
# (contracts/surface-derivation.md C4.1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  VERIFY="${ROOT}/packaging/verify-artifact.sh"
  BUILDER="${ROOT}/packaging/build-artifact.sh"
  WORK="$(mktemp -d)"
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
}

teardown() {
  rm -rf "${WORK}"
}

@test "a real archive passes the completeness gate" {
  run "${VERIFY}" completeness-purity "${WORK}/good.zip"
  [ "$status" -eq 0 ]
}

@test "an archive with a surface file removed is rejected, naming the missing path" {
  python3 - "${WORK}/good.zip" "${WORK}/missing-one.zip" << 'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
    for item in zin.infolist():
        if item.filename == "spec-kit-jira/extension.yml":
            continue
        zout.writestr(item, zin.read(item.filename))
PY
  run "${VERIFY}" completeness-purity "${WORK}/missing-one.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'missing files the reference install produced'* ]]
  [[ "$output" == *'extension.yml'* ]]
}

@test "an archive with TWO surface files removed lists both, not just the first" {
  python3 - "${WORK}/good.zip" "${WORK}/missing-two.zip" << 'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
drop = {"spec-kit-jira/extension.yml", "spec-kit-jira/README.md"}
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
    for item in zin.infolist():
        if item.filename in drop:
            continue
        zout.writestr(item, zin.read(item.filename))
PY
  run "${VERIFY}" completeness-purity "${WORK}/missing-two.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'extension.yml'* ]]
  [[ "$output" == *'README.md'* ]]
}
