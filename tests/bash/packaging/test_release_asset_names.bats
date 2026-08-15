#!/usr/bin/env bats
# T041 [026] [US2] — `publish-artifact.sh` derives `spec-kit-jira.zip` and
# `spec-kit-jira-<version>.zip` from ONE archive, the two carry identical
# bytes, and the version comes only from the manifest (contracts/publication.md
# C2.4, A4).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PUBLISH="${ROOT}/packaging/publish-artifact.sh"
  VERSION="$("${ROOT}/packaging/resolve-version.sh")"
  WORK="$(mktemp -d)"
  head -c 4096 /dev/urandom > "${WORK}/archive.zip"

  STUB_DIR="${WORK}/bin"
  mkdir -p "${STUB_DIR}"
  UPLOAD_DIR="${WORK}/uploaded"
  mkdir -p "${UPLOAD_DIR}"
  LOG="${WORK}/gh.log"
  : > "${LOG}"

  cat > "${STUB_DIR}/gh" << STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${LOG}"
case "\$1 \$2" in
  "release view")
    if [[ "\$*" == *"--json"* ]]; then
      printf ''
      exit 0
    fi
    exit 1
    ;;
  "release create")
    exit 0
    ;;
  "release upload")
    tag="\$3"; path="\$4"
    cp "\${path}" "${UPLOAD_DIR}/\$(basename "\${path}")"
    exit 0
    ;;
  *)
    echo "unexpected gh invocation: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${STUB_DIR}/gh"
}

teardown() {
  rm -rf "${WORK}"
}

@test "publish-artifact derives both asset names and uploads identical bytes" {
  PATH="${STUB_DIR}:${PATH}" run "${PUBLISH}" "v${VERSION}" "${WORK}/archive.zip"
  [ "$status" -eq 0 ]

  [ -f "${UPLOAD_DIR}/spec-kit-jira.zip" ]
  [ -f "${UPLOAD_DIR}/spec-kit-jira-${VERSION}.zip" ]

  local sum_stable sum_pinned sum_source
  sum_stable="$(shasum -a 256 "${UPLOAD_DIR}/spec-kit-jira.zip" | awk '{print $1}')"
  sum_pinned="$(shasum -a 256 "${UPLOAD_DIR}/spec-kit-jira-${VERSION}.zip" | awk '{print $1}')"
  sum_source="$(shasum -a 256 "${WORK}/archive.zip" | awk '{print $1}')"
  [ "${sum_stable}" = "${sum_source}" ]
  [ "${sum_pinned}" = "${sum_source}" ]
}

@test "the version in the pinned asset name comes only from the manifest, never a literal in publish-artifact.sh" {
  run grep -n "${VERSION}" "${ROOT}/packaging/publish-artifact.sh"
  [ "$status" -ne 0 ]
}

@test "the release is created when none exists yet (SC-008 zero manual steps)" {
  PATH="${STUB_DIR}:${PATH}" run "${PUBLISH}" "v${VERSION}" "${WORK}/archive.zip"
  [ "$status" -eq 0 ]
  grep -qF "release create v${VERSION}" "${LOG}"
}
