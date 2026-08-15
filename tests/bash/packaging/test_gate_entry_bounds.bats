#!/usr/bin/env bats
# T031 [026] [US3] — the bounds gate: an archive padded past the entry
# ceiling is rejected, the message reports the measured count AND the
# ceiling; each of the uncompressed-total, largest-member, path-length and
# component-length bounds is rejected the same way with its measured value
# (contracts/artifact-shape.md §3).

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

@test "a real archive passes the bounds gate" {
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/good.manifest"
  [ "$status" -eq 0 ]
}

@test "an archive padded past 256 entries is rejected, naming the count and the ceiling" {
  cp "${WORK}/good.zip" "${WORK}/padded.zip"
  local i
  for ((i = 0; i < 200; i++)); do
    printf 'padding' > "${WORK}/pad_${i}.txt"
    (cd "${WORK}" && zip -q padded.zip "pad_${i}.txt")
  done
  cat > "${WORK}/padded.manifest" << EOF
entries: 305
uncompressed_bytes: 1722754
largest_member_bytes: 148243
largest_member_path: scripts/powershell/commands/Reconcile.psm1
EOF
  run "${VERIFY}" bounds "${WORK}/padded.zip" "${WORK}/padded.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'too many entries'* ]]
  [[ "$output" == *'305'* ]]
  [[ "$output" == *'256'* ]]
}

@test "an archive breaching the uncompressed-total bound is rejected with the measured value" {
  cat > "${WORK}/big-total.manifest" << 'EOF'
entries: 10
uncompressed_bytes: 99999999999
largest_member_bytes: 100
largest_member_path: foo.txt
EOF
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/big-total.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'uncompressed total too large'* ]]
  [[ "$output" == *'99999999999'* ]]
}

@test "an archive breaching the largest-member bound is rejected, naming the member and the value" {
  cat > "${WORK}/big-member.manifest" << 'EOF'
entries: 10
uncompressed_bytes: 1000
largest_member_bytes: 99999999999
largest_member_path: scripts/bash/huge.sh
EOF
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/big-member.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'largest member too large'* ]]
  [[ "$output" == *'scripts/bash/huge.sh'* ]]
  [[ "$output" == *'99999999999'* ]]
}

@test "a member with a path longer than the ceiling is rejected" {
  # A real filesystem path this long would exceed the OS's own PATH_MAX
  # before the test could even create it — a zip archive has no such limit,
  # so the member is fabricated directly inside the archive instead. Every
  # path component stays under the (separate) component ceiling (128),
  # isolating what this test checks.
  cp "${WORK}/good.zip" "${WORK}/longpath.zip"
  python3 - "${WORK}/longpath.zip" << 'PY'
import sys, zipfile
segment = "s" * 110
path = "/".join(f"{segment}{i}" for i in range(10)) + "/f.txt"
with zipfile.ZipFile(sys.argv[1], "a") as zf:
    zf.writestr(path, "x")
PY
  run "${VERIFY}" bounds "${WORK}/longpath.zip" "${WORK}/good.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'path too long'* ]]
}

@test "a member with a path component longer than the ceiling is rejected" {
  local longcomp
  longcomp="$(printf 'y%.0s' $(seq 1 200))"
  mkdir -p "${WORK}/${longcomp}"
  cp "${WORK}/good.zip" "${WORK}/longcomp.zip"
  printf 'x' > "${WORK}/${longcomp}/f.txt"
  (cd "${WORK}" && zip -q longcomp.zip "${longcomp}/f.txt")
  run "${VERIFY}" bounds "${WORK}/longcomp.zip" "${WORK}/good.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'path component too long'* ]]
}
