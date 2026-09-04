#!/usr/bin/env bats
# T007 [026] — the derivation of contracts/surface-derivation.md §2 yields
# exactly the installable surface: 102 files, containing the manifest, both
# ports' entry points and all four command documents, and nothing under any
# development-only directory.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=packaging/lib/surface.sh
  source "${ROOT}/packaging/lib/surface.sh"
}

@test "the derived surface has exactly 102 members (quickstart.md step 1)" {
  run packaging_derive_surface
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c .)"
  [ "${count}" -eq 102 ]
}

@test "the derived surface contains the manifest, both entry points and the four command documents" {
  run packaging_derive_surface
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nextension.yml'* || "$output" == 'extension.yml'* ]]
  grep -qxF 'extension.yml' <<< "$output"
  grep -qxF 'scripts/bash/spec-kit-jira.sh' <<< "$output"
  grep -qxF 'scripts/powershell/spec-kit-jira.ps1' <<< "$output"
  grep -qxF 'commands/speckit.jira-mirror.config.md' <<< "$output"
  grep -qxF 'commands/speckit.jira-mirror.feature.md' <<< "$output"
  grep -qxF 'commands/speckit.jira-mirror.reconcile.md' <<< "$output"
  grep -qxF 'commands/speckit.jira-mirror.seed.md' <<< "$output"
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

@test "the derivation is locale-independent — a non-C collation must not silently include everything" {
  # `comm` requires BOTH its inputs sorted under ITS OWN ambient collation,
  # not merely under whatever collation `sort` used to produce them. Pinning
  # `LC_ALL=C` on the `sort` calls alone (surface.sh) leaves `comm` itself
  # reading them under the caller's locale; under en_US.UTF-8 that mismatch
  # makes `comm` treat both inputs as unsorted and it silently stops
  # excluding anything, so the derived surface becomes every tracked file
  # instead of the 102-file surface (SC-004, C2.1).
# 034 removed two shipped modules — hooks/register_hooks.sh and its PowerShell
# twin, the hook-registry reader — taking the surface from 100 to 98; 036 then
# added engine/artifact_set.sh and its PowerShell twin, taking it back to 100,
# and sink/jira/attachments.sh with ITS twin, taking it to 102.
# The count is a hand-maintained literal: adding a port module means editing it
# here, in two places, or this guard fails on a correct change.
  if ! locale -a 2> /dev/null | grep -qxF 'en_US.UTF-8'; then
    skip "en_US.UTF-8 locale is not installed on this host"
  fi
  count="$(LC_ALL=en_US.UTF-8 bash -c "source '${ROOT}/packaging/lib/surface.sh'; packaging_derive_surface | grep -c .")"
  [ "${count}" -eq 102 ]
}
