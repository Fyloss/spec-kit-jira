#!/usr/bin/env bats
# T042 [026] [US2] — with a `gh` stub reporting an asset of that name already
# attached, `publish-artifact.sh` refuses and names the asset; and a `gh`
# failure of any kind fails the run rather than passing it (FR-012, FR-019,
# Principle II).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  PUBLISH="${ROOT}/packaging/publish-artifact.sh"
  VERSION="$("${ROOT}/packaging/resolve-version.sh")"
  WORK="$(mktemp -d)"
  head -c 4096 /dev/urandom > "${WORK}/archive.zip"
  STUB_DIR="${WORK}/bin"
  mkdir -p "${STUB_DIR}"
}

teardown() {
  rm -rf "${WORK}"
}

_write_stub() {
  # $1 = body of the case statement
  cat > "${STUB_DIR}/gh" << STUB
#!/usr/bin/env bash
set -euo pipefail
$1
STUB
  chmod +x "${STUB_DIR}/gh"
}

@test "an asset already attached under the stable name is refused, naming it" {
  _write_stub '
case "$1 $2" in
  "release view")
    if [[ "$*" == *"--json"* ]]; then
      printf "spec-kit-jira-mirror.zip\n"
      exit 0
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
'
  PATH="${STUB_DIR}:${PATH}" run "${PUBLISH}" "v${VERSION}" "${WORK}/archive.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'spec-kit-jira-mirror.zip'* ]]
  [[ "$output" == *'refusing to overwrite'* ]]
}

@test "an asset already attached under the pinned name is refused, naming it" {
  _write_stub '
case "$1 $2" in
  "release view")
    if [[ "$*" == *"--json"* ]]; then
      printf "spec-kit-jira-mirror-'"${VERSION}"'.zip\n"
      exit 0
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
'
  PATH="${STUB_DIR}:${PATH}" run "${PUBLISH}" "v${VERSION}" "${WORK}/archive.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spec-kit-jira-mirror-${VERSION}.zip"* ]]
  [[ "$output" == *'refusing to overwrite'* ]]
}

@test "a gh failure reading existing assets fails the run, not just a warning" {
  _write_stub '
case "$1 $2" in
  "release view")
    if [[ "$*" == *"--json"* ]]; then
      echo "network error" >&2
      exit 1
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
'
  PATH="${STUB_DIR}:${PATH}" run "${PUBLISH}" "v${VERSION}" "${WORK}/archive.zip"
  [ "$status" -ne 0 ]
}

@test "a gh failure during upload fails the run and removes any asset this run already attached" {
  DELETE_LOG="${WORK}/deletes.log"
  : > "${DELETE_LOG}"
  _write_stub '
case "$1 $2" in
  "release view")
    if [[ "$*" == *"--json"* ]]; then
      printf ""
      exit 0
    fi
    exit 0
    ;;
  "release upload")
    if [[ "$4" == *"spec-kit-jira-mirror.zip" ]]; then
      exit 0
    fi
    echo "upload failed" >&2
    exit 1
    ;;
  "release delete-asset")
    printf "%s\n" "$3 $4" >> "'"${DELETE_LOG}"'"
    exit 0
    ;;
  *) exit 1 ;;
esac
'
  PATH="${STUB_DIR}:${PATH}" run "${PUBLISH}" "v${VERSION}" "${WORK}/archive.zip"
  [ "$status" -ne 0 ]
  grep -qF "v${VERSION} spec-kit-jira-mirror.zip" "${DELETE_LOG}"
}
