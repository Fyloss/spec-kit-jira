#!/usr/bin/env bats
# T007 [026] — the derivation of contracts/surface-derivation.md §2 yields
# exactly the installable surface: 87 files, containing the manifest, both
# ports' entry points and all three command documents, and nothing under any
# development-only directory.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=packaging/lib/surface.sh
  source "${ROOT}/packaging/lib/surface.sh"
}

@test "the derived surface has exactly 87 members (quickstart.md step 1)" {
  run packaging_derive_surface
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c .)"
  [ "${count}" -eq 87 ]
}

@test "the derived surface contains the manifest, both entry points and the three command documents" {
  run packaging_derive_surface
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nextension.yml'* || "$output" == 'extension.yml'* ]]
  grep -qxF 'extension.yml' <<< "$output"
  grep -qxF 'scripts/bash/spec-kit-jira.sh' <<< "$output"
  grep -qxF 'scripts/powershell/spec-kit-jira.ps1' <<< "$output"
  grep -qxF 'commands/speckit.jira.config.md' <<< "$output"
  grep -qxF 'commands/speckit.jira.feature.md' <<< "$output"
  grep -qxF 'commands/speckit.jira.reconcile.md' <<< "$output"
}

@test "the derived surface contains nothing under a development-only directory" {
  run packaging_derive_surface
  [ "$status" -eq 0 ]
  for prefix in 'tests/' 'specs/' 'docs/' '.specify/' '.github/' 'packaging/'; do
    run grep -c "^${prefix}" <<< "$output"
    [ "$status" -ne 0 ] || [ "$output" -eq 0 ]
  done
}

@test "the derived surface never contains .extensionignore itself (S3)" {
  run packaging_derive_surface
  [ "$status" -eq 0 ]
  run grep -qxF '.extensionignore' <<< "$output"
  [ "$status" -ne 0 ]
}
