#!/usr/bin/env bats
# T009 [026] — the version resolver returns `extension.version`, never
# `schema_version` and never `requires.speckit_version`; fails loudly on an
# absent or empty field; and `packaging/` contains no version literal
# anywhere (contracts/publication.md C1.1-C1.4).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  RESOLVER="${ROOT}/packaging/resolve-version.sh"
}

@test "the resolver exists and is executable" {
  [ -x "${RESOLVER}" ]
}

@test "the resolver returns extension.version, computed the same way the existing gate does" {
  run "${RESOLVER}"
  [ "$status" -eq 0 ]
  expected="$(sed -n 's/^[[:space:]]\{1,\}version:[[:space:]]*//p' "${ROOT}/extension.yml" | head -n1)"
  [ -n "${expected}" ]
  [ "$output" = "${expected}" ]
}

@test "the resolved value looks like extension.version, not schema_version or a requires range" {
  run "${RESOLVER}"
  [ "$status" -eq 0 ]
  # requires.speckit_version is a range like ">=0.13.0" — never this shape.
  [[ "$output" != *'>='* ]]
  # extension.version is plain SemVer.
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]
}

@test "the resolver fails loudly on an absent version field" {
  work="$(mktemp -d)"
  printf 'schema_version: 1\nextension:\n  name: test\n' > "${work}/extension.yml"
  cp -r "${ROOT}/packaging" "${work}/packaging"
  run bash -c "cd '${work}' && packaging/resolve-version.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'absent or empty'* ]]
  rm -rf "${work}"
}

@test "the resolver fails loudly on an empty version field" {
  work="$(mktemp -d)"
  printf 'extension:\n  version:\n' > "${work}/extension.yml"
  cp -r "${ROOT}/packaging" "${work}/packaging"
  run bash -c "cd '${work}' && packaging/resolve-version.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'absent or empty'* ]]
  rm -rf "${work}"
}

@test "packaging/ contains no version literal anywhere (C1.4)" {
  version="$("${RESOLVER}")"
  esc="$(printf '%s' "${version}" | sed 's/\./\\./g')"
  run grep -rnE "${esc}" "${ROOT}/packaging"
  [ "$status" -ne 0 ]
}
