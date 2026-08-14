#!/usr/bin/env bats
# T042a [026] [US2] — `.github/workflows/release.yml` invokes
# `packaging/verify-artifact.sh` before any upload step, and carries no
# version literal and no inline publication logic of its own
# (contracts/publication.md C2.3, C2.7, V1).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  RELEASE_YML="${ROOT}/.github/workflows/release.yml"
  VERSION="$("${ROOT}/packaging/resolve-version.sh")"
}

@test "release.yml exists and is triggered by a version tag" {
  [ -f "${RELEASE_YML}" ]
  run grep -nE "^\s*-\s*['\"]?v\*['\"]?" "${RELEASE_YML}"
  [ "$status" -eq 0 ]
}

@test "release.yml runs packaging/verify-artifact.sh before any upload step" {
  local verify_line upload_line
  verify_line="$(grep -vE '^\s*#' "${RELEASE_YML}" | grep -n 'packaging/verify-artifact.sh' | head -n1 | cut -d: -f1)"
  upload_line="$(grep -vE '^\s*#' "${RELEASE_YML}" | grep -n 'packaging/publish-artifact.sh' | head -n1 | cut -d: -f1)"
  [ -n "${verify_line}" ]
  [ -n "${upload_line}" ]
  [ "${verify_line}" -lt "${upload_line}" ]
}

@test "release.yml carries no version literal (V1)" {
  run grep -nF "${VERSION}" "${RELEASE_YML}"
  [ "$status" -ne 0 ]
}

@test "release.yml holds no inline publication logic — no direct gh release calls of its own" {
  run grep -nE '^\s*run:\s*gh release|gh release (create|upload|view|delete-asset)' "${RELEASE_YML}"
  [ "$status" -ne 0 ]
}

@test "release.yml calls packaging/build-artifact.sh to produce the archive it gates" {
  run grep -nF 'packaging/build-artifact.sh' "${RELEASE_YML}"
  [ "$status" -eq 0 ]
}
