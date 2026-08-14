#!/usr/bin/env bats
# T034 [026] [US3] — every gate fails closed: an absent archive, an
# unreadable `.extensionignore`, a `git` failure, and an empty derived
# surface each fail the gate. An empty surface is never read as "nothing is
# missing" (contracts/surface-derivation.md C4.4, artifact-shape.md C5.3).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  VERIFY="${ROOT}/packaging/verify-artifact.sh"
  BUILDER="${ROOT}/packaging/build-artifact.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "bounds fails closed on an absent archive" {
  run "${VERIFY}" bounds "${WORK}/does-not-exist.zip" "${WORK}/does-not-exist.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'archive not found'* ]]
}

@test "bounds fails closed on an absent manifest" {
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/does-not-exist.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'manifest not found'* ]]
}

@test "bounds fails closed on an unparseable manifest" {
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  printf 'not a manifest\n' > "${WORK}/bad.manifest"
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/bad.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unparseable'* ]]
}

@test "bounds fails closed on a manifest with a duplicated field — never silently skips the check" {
  # A manifest with two `entries:` lines feeds the bound check a multi-line
  # value; without `head -n1` and numeric validation, `((entries > ceiling))`
  # throws a bash arithmetic syntax error that is swallowed (no `set -e`), the
  # entries check is skipped entirely, and the gate exits 0 — reporting a
  # tampered or malformed manifest as passing.
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  printf 'entries: 5\nentries: 999\nuncompressed_bytes: 100\nlargest_member_bytes: 50\nlargest_member_path: foo\n' > "${WORK}/dup.manifest"
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/dup.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unparseable'* ]]
}

@test "bounds fails closed on a manifest with a non-numeric field" {
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  printf 'entries: not-a-number\nuncompressed_bytes: 100\nlargest_member_bytes: 50\nlargest_member_path: foo\n' > "${WORK}/nan.manifest"
  run "${VERIFY}" bounds "${WORK}/good.zip" "${WORK}/nan.manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unparseable'* ]]
}

@test "completeness-purity fails closed on an absent archive" {
  run "${VERIFY}" completeness-purity "${WORK}/does-not-exist.zip"
  [ "$status" -ne 0 ]
  [[ "$output" == *'archive not found'* ]]
}

@test "completeness-purity fails closed on an unreadable .extensionignore (git error), never reads it as 'nothing missing'" {
  # A throwaway git repo whose own .extensionignore is unreadable: the
  # derivation must fail loudly, not silently widen to "everything included"
  # (which would make a genuinely wrong archive look complete).
  local fake="${WORK}/fake-repo"
  mkdir -p "${fake}"
  (
    cd "${fake}" || exit 1
    git init -q .
    printf 'x' > tracked.txt
    printf 'y\n' > .extensionignore
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m init
    chmod 000 .extensionignore
  )
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  run bash -c "cd '${fake}' && '${VERIFY}' completeness-purity '${WORK}/good.zip'"
  chmod 755 "${fake}/.extensionignore" 2> /dev/null || true
  [ "$status" -ne 0 ]
}

@test "completeness-purity fails closed on a git failure (not a repository)" {
  local notrepo="${WORK}/notrepo"
  mkdir -p "${notrepo}"
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  run bash -c "cd '${notrepo}' && '${VERIFY}' completeness-purity '${WORK}/good.zip'"
  [ "$status" -ne 0 ]
  [[ "$output" == *'could not derive'* ]]
}

@test "completeness-purity fails closed on an empty derived surface — never read as 'nothing missing'" {
  # A throwaway repo whose .extensionignore excludes every tracked file: the
  # derivation legitimately returns empty, and the gate MUST fail rather than
  # report the archive as complete.
  local empty_repo="${WORK}/empty-surface-repo"
  mkdir -p "${empty_repo}"
  (
    cd "${empty_repo}" || exit 1
    git init -q .
    printf 'x' > only.txt
    printf 'only.txt\n' > .extensionignore
    git add -A
    git -c user.email=t@t -c user.name=t commit -q -m init
  )
  "${BUILDER}" "${WORK}/good.zip" > /dev/null
  run bash -c "cd '${empty_repo}' && '${VERIFY}' completeness-purity '${WORK}/good.zip'"
  [ "$status" -ne 0 ]
  [[ "$output" == *'derived surface is empty'* ]]
}
