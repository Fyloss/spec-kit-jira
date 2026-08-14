#!/usr/bin/env bats
# T033 [026] [US3] — the purity gate: an archive with a development file
# injected (a `tests/` file, and separately a `.git/` entry) is rejected, and
# every extra path is listed (contracts/surface-derivation.md C4.2).

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

@test "an archive with a tests/ file injected is rejected, naming the extra path" {
  python3 - "${WORK}/good.zip" "${WORK}/inject-tests.zip" << 'PY'
import sys, shutil, zipfile
shutil.copy(sys.argv[1], sys.argv[2])
with zipfile.ZipFile(sys.argv[2], "a") as zf:
    zf.writestr("spec-kit-jira/tests/bash/leaked.bats", "#!/usr/bin/env bats\n")
PY
  run "${VERIFY}" completeness-purity "${WORK}/inject-tests.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'files the exclusion list excludes'* ]]
  [[ "$output" == *'tests/bash/leaked.bats'* ]]
}

@test "an archive with a .git/ entry injected is rejected, naming the extra path" {
  python3 - "${WORK}/good.zip" "${WORK}/inject-git.zip" << 'PY'
import sys, shutil, zipfile
shutil.copy(sys.argv[1], sys.argv[2])
with zipfile.ZipFile(sys.argv[2], "a") as zf:
    zf.writestr("spec-kit-jira/.git/HEAD", "ref: refs/heads/main\n")
PY
  run "${VERIFY}" completeness-purity "${WORK}/inject-git.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'files the exclusion list excludes'* ]]
  [[ "$output" == *'.git/HEAD'* ]]
}

@test "an archive with BOTH injections lists both extra paths" {
  python3 - "${WORK}/good.zip" "${WORK}/inject-both.zip" << 'PY'
import sys, shutil, zipfile
shutil.copy(sys.argv[1], sys.argv[2])
with zipfile.ZipFile(sys.argv[2], "a") as zf:
    zf.writestr("spec-kit-jira/tests/bash/leaked.bats", "x")
    zf.writestr("spec-kit-jira/.git/HEAD", "x")
PY
  run "${VERIFY}" completeness-purity "${WORK}/inject-both.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'tests/bash/leaked.bats'* ]]
  [[ "$output" == *'.git/HEAD'* ]]
}
