#!/usr/bin/env bats
# T010 [026] — the builder writes an archive whose members all sit under a
# single `spec-kit-jira/` root, whose stripped contents equal the derived
# surface, and building twice produces byte-identical archives
# (contracts/artifact-shape.md C1.1, C2.1, §4).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  BUILDER="${ROOT}/packaging/build-artifact.sh"
  # shellcheck source=packaging/lib/surface.sh
  source "${ROOT}/packaging/lib/surface.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "the builder exists and is executable" {
  [ -x "${BUILDER}" ]
}

@test "every member sits under a single spec-kit-jira/ root (C1.1)" {
  run "${BUILDER}" "${WORK}/out.zip"
  [ "$status" -eq 0 ]
  run unzip -Z1 "${WORK}/out.zip"
  [ "$status" -eq 0 ]
  while IFS= read -r member; do
    [[ -z "${member}" ]] && continue
    [[ "${member}" == 'spec-kit-jira/'* ]]
  done <<< "$output"
}

@test "stripped of its root, the archive's contents equal the derived surface, both directions (C2.1)" {
  run "${BUILDER}" "${WORK}/out.zip"
  [ "$status" -eq 0 ]

  archived="$(unzip -Z1 "${WORK}/out.zip" \
    | sed -e 's#^spec-kit-jira/##' -e '/\/$/d' -e '/^$/d' | LC_ALL=C sort)"
  expected="$(packaging_derive_surface | LC_ALL=C sort)"

  diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${archived}")
}

@test "building twice from the same commit produces byte-identical archives (C4.1)" {
  run "${BUILDER}" "${WORK}/a.zip"
  [ "$status" -eq 0 ]
  run "${BUILDER}" "${WORK}/b.zip"
  [ "$status" -eq 0 ]

  sum_a="$(shasum -a 256 "${WORK}/a.zip" | awk '{print $1}')"
  sum_b="$(shasum -a 256 "${WORK}/b.zip" | awk '{print $1}')"
  [ "${sum_a}" = "${sum_b}" ]
}

@test "the builder prints a manifest with entry count, uncompressed total and largest member" {
  run "${BUILDER}" "${WORK}/out.zip"
  [ "$status" -eq 0 ]
  [[ "$output" == *'entries: '* ]]
  [[ "$output" == *'uncompressed_bytes: '* ]]
  [[ "$output" == *'largest_member_bytes: '* ]]
  [[ "$output" == *'largest_member_path: '* ]]
}

@test "the builder refuses to leave a partial archive on failure" {
  run "${BUILDER}" "/nonexistent-dir-${RANDOM}/out.zip"
  [ "$status" -ne 0 ]
}
