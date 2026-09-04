#!/usr/bin/env bats
# T115 [Phase 6, 036] — every test or script file the CURRENT feature's own
# documents name is a real, tracked path, spelled with the exact case it has on
# disk.
#
# `quickstart.md` is a runbook: an operator reads it and pastes the commands.
# A line naming a file that was renamed during implementation does not fail
# loudly — `bats` on a missing file, or `Invoke-Pester` on a mis-cased
# directory, reports success on a macOS checkout and nothing at all runs. The
# reviewer who follows the runbook concludes the suite is green when it never
# executed. `tasks.md` fails the same way from the other side: a task marked
# [X] that cites a file which does not exist reads as covered work, and this
# repository has already shipped one of those (029, three findings of four).
#
# Two scoping decisions, both deliberate.
#
# ONLY THE CURRENT FEATURE. A repo-wide sweep is red on 40 references today,
# nearly all of them correct: a spec written in August names `register_hooks.sh`
# because that file existed in August, and 034 retired it. Those documents are
# historical records, not instructions, and rewriting them would falsify the
# record. The feature named by `.specify/feature.json` is the one whose
# documents are still instructions.
#
# EXACT CASE, VIA `git ls-files`. `[ -e ]` is case-insensitive on this
# repository's usual host — macOS — and case-sensitive on both CI runners that
# matter. `tests/powershell/Engine/…` therefore passes every local check and
# resolves to nothing on ubuntu-latest. The tracked-path list is the only
# spelling git will actually serve, so a verbatim match against it is the test.
#
# The guard is proven RED in this same file, against a planted document,
# because this repository has shipped guards that were inert — two of three,
# once.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
}

# _scan <docdir> — print one line per stale reference. Silence means clean.
#
# One `git ls-files` and one `find … -exec grep … +` for the whole document
# set, rather than a process per file: the pattern the process budget asks for
# even where, as here, the budget does not bind.
_scan() {
  local docdir="$1"
  local tracked="${BATS_TEST_TMPDIR}/tracked.txt"

  git -C "${ROOT}" ls-files >"${tracked}"

  find "${docdir}" -name '*.md' -type f \
    -exec grep -oHnE '(tests|scripts)/[A-Za-z0-9._/-]*\.(bats|ps1|psm1|sh|bash)' {} + \
    | awk -F: '
        NR == FNR { tracked[$0] = 1; next }
        !($3 in tracked) {
          printf "%s:%s: names %s, which is no tracked path — renamed, deleted, or mis-cased\n", $1, $2, $3
        }
      ' "${tracked}" -
}

@test "T115 the current feature's documents name only real, tracked paths" {
  local feature_dir
  feature_dir="$(awk -F'"' '/feature_directory/ { print $4 }' "${ROOT}/.specify/feature.json")"
  [ -n "${feature_dir}" ]
  [ -d "${ROOT}/${feature_dir}" ]

  run _scan "${ROOT}/${feature_dir}"
  [ "${status}" -eq 0 ]

  if [ -n "${output}" ]; then
    printf 'stale path references in %s:\n%s\n' "${feature_dir}" "${output}" >&2
    return 1
  fi
}

@test "T115 the guard is not inert — it catches a renamed file and a mis-cased directory" {
  local planted="${BATS_TEST_TMPDIR}/planted"
  mkdir -p "${planted}"

  # Both real shapes this feature shipped: a file that never existed under the
  # name the document gives it, and a directory whose case only macOS forgives.
  cat >"${planted}/quickstart.md" <<'DOC'
bats -r tests/bash/sink/test_artifact_publication.bats
pwsh -c "Invoke-Pester tests/powershell/Engine/ArtifactSet.Tests.ps1"
bats -r tests/bash/sink/test_attachments.bats
DOC

  run _scan "${planted}"
  [ "${status}" -eq 0 ]

  # The two planted references are reported…
  [[ "${output}" == *"test_artifact_publication.bats"* ]]
  [[ "${output}" == *"powershell/Engine/ArtifactSet.Tests.ps1"* ]]
  # …and the correctly spelled third one is not.
  [[ "${output}" != *"test_attachments.bats"* ]]
}
