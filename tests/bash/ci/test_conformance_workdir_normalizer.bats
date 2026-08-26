#!/usr/bin/env bats
# Guard for _bre_escape / _normalize_workdir_path (tests/conformance/ci-conformance.sh).
#
# The normalizer masks the other value two ports can never agree on: each gets
# its OWN `mktemp -d`, so any capture that legitimately names an absolute path
# under the workdir diverges even when the run itself is byte-identical.
#
# On Windows that path arrives in the PowerShell port's capture spelt the
# NATIVE way — `C:\Users\runneradmin\AppData\Local\Temp\tmp.X` — and the
# masking is a `sed s#…#WORKDIR#g`. GNU sed honours ITS OWN escapes inside a
# pattern, so an unescaped native path is read as `\r` = CR, `\t` = TAB,
# `\U`/`\L`/`\A` as GNU extensions: the pattern that reaches the matcher is
# not the path, and it matches nothing. The candidate spelling can be exactly
# right and the mask still fires on nothing.
#
# That is what these tests pin, and why they are worth their weight: the
# defect was "fixed" four times (e310bf6, d560d10, 745bd27, 71822ff) by
# correcting the recorded SPELLING, each round costing a ~90-minute remote
# round-trip on windows-latest, because both halves produce the identical
# symptom — an unmasked path in the diff — and nothing tested the masking
# itself. Everything below runs on every host: the Windows-shaped paths are
# literals, not something the host has to produce.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CI_CONFORMANCE="${ROOT}/tests/conformance/ci-conformance.sh"
  OUTDIR="${BATS_TEST_TMPDIR}/out"
  mkdir -p "${OUTDIR}"

  # ci-conformance.sh runs the whole corpus on source, so the functions are
  # lifted out of its text rather than sourced — the same extract-and-assert
  # shape test_conformance_state_normalizer.bats uses on that script.
  eval "$(awk '/^_bre_escape\(\) \{/ { on = 1 } on { print } on && /^\}$/ { exit }' "${CI_CONFORMANCE}")"
  eval "$(awk '/^_normalize_workdir_path\(\) \{/ { on = 1 } on { print } on && /^\}$/ { exit }' "${CI_CONFORMANCE}")"
}

# record <spelling>... — the workdir.path run-scenario.sh writes, one
# candidate spelling per line.
record() {
  printf '%s\n' "$@" > "${OUTDIR}/workdir.path"
}

@test "the guard lifts non-empty _bre_escape and _normalize_workdir_path out of ci-conformance.sh" {
  declare -F _bre_escape > /dev/null
  declare -F _normalize_workdir_path > /dev/null
}

@test "a native Windows workdir is masked out of stderr" {
  local wd='C:\Users\runneradmin\AppData\Local\Temp\tmp.wF2KFDjMGj'
  record "${wd}"
  # us031-no-project (FR-008): the no-repository report names the directory it
  # walked from, and there is no .specify/jira suffix to anchor a structural
  # mask on — the workdir IS the whole path.
  printf 'feature: no project found — no ancestor of %s contains .specify/\n' "${wd}" \
    > "${OUTDIR}/stderr"

  _normalize_workdir_path "${OUTDIR}"

  run cat "${OUTDIR}/stderr"
  [ "$output" = 'feature: no project found — no ancestor of WORKDIR contains .specify/' ]
}

@test "a native Windows workdir is masked out of stdout and calls.log too" {
  local wd='C:\Users\runneradmin\AppData\Local\Temp\tmp.tRUe'
  record "${wd}"
  printf '{"config_dir":"%s\\\\.specify\\\\jira"}\n' "${wd}" > "${OUTDIR}/stdout"
  printf 'GET %s/seed_material\n' "${wd}" > "${OUTDIR}/calls.log"

  _normalize_workdir_path "${OUTDIR}"

  run grep -c 'tmp\.tRUe' "${OUTDIR}/stdout" "${OUTDIR}/calls.log"
  [ "$status" -ne 0 ]
}

@test "the MSYS and mixed spellings of the same directory are all masked" {
  # run-scenario.sh records every spelling this host can produce; whichever
  # one a port's own output used has to be the one that fires.
  record '/tmp/tmp.aBc123' \
    'C:/Users/RUNNER~1/AppData/Local/Temp/tmp.aBc123' \
    'C:/Users/runneradmin/AppData/Local/Temp/tmp.aBc123' \
    'C:\Users\RUNNER~1\AppData\Local\Temp\tmp.aBc123' \
    'C:\Users\runneradmin\AppData\Local\Temp\tmp.aBc123'
  {
    printf 'msys /tmp/tmp.aBc123\n'
    printf 'mixed-short C:/Users/RUNNER~1/AppData/Local/Temp/tmp.aBc123\n'
    printf 'mixed-long C:/Users/runneradmin/AppData/Local/Temp/tmp.aBc123\n'
    printf 'native-short C:\\Users\\RUNNER~1\\AppData\\Local\\Temp\\tmp.aBc123\n'
    printf 'native-long C:\\Users\\runneradmin\\AppData\\Local\\Temp\\tmp.aBc123\n'
  } > "${OUTDIR}/stderr"

  _normalize_workdir_path "${OUTDIR}"

  run cat "${OUTDIR}/stderr"
  [ "${lines[0]}" = 'msys WORKDIR' ]
  [ "${lines[1]}" = 'mixed-short WORKDIR' ]
  [ "${lines[2]}" = 'mixed-long WORKDIR' ]
  [ "${lines[3]}" = 'native-short WORKDIR' ]
  [ "${lines[4]}" = 'native-long WORKDIR' ]
}

@test "a native Windows workdir is masked inside JSON, where its separators are doubled" {
  # stdout is JSON. `C:\Users\…` reaches the capture as `C:\\Users\\…`, so the
  # raw candidate matches nothing — and on a host whose temp directory sits
  # under a spaced home directory the structural fallback then masks only the
  # tail, producing `C:\\Users\\Ada WORKDIR/.specify/jira/…`: a divergence
  # that reads exactly like one more unrecorded spelling.
  # (us29-feature-reuse-yes-auto-accept's `seed_material`.)
  # Captured verbatim from the PowerShell port on windows: the workdir half
  # is native and JSON-doubled, the part it joins on keeps its forward
  # slashes.
  local wd='C:\Users\Ada Lovelace\AppData\Local\Temp\tmp.Q7'
  record "${wd}"
  printf '%s\n' \
    '{"seed_material":"C:\\Users\\Ada Lovelace\\AppData\\Local\\Temp\\tmp.Q7/.specify/jira/state/x.json"}' \
    > "${OUTDIR}/stdout"

  _normalize_workdir_path "${OUTDIR}"

  run cat "${OUTDIR}/stdout"
  [ "$output" = '{"seed_material":"WORKDIR/.specify/jira/state/x.json"}' ]
}

@test "a workdir under a home directory with a space in it is masked whole" {
  # The structural `.specify/jira` fallback stops at the first space, so on a
  # host like this one it masks only the tail. The enumerated candidate is
  # what has to carry it — this is the case that proves the two are not
  # interchangeable.
  local wd='C:\Users\Ada Lovelace\AppData\Local\Temp\tmp.Zz9'
  record "${wd}"
  printf 'no ancestor of %s contains .specify/\n' "${wd}" > "${OUTDIR}/stderr"

  _normalize_workdir_path "${OUTDIR}"

  run cat "${OUTDIR}/stderr"
  [ "$output" = 'no ancestor of WORKDIR contains .specify/' ]
}

@test "regex metacharacters in a workdir are matched literally, not as a pattern" {
  local wd='/tmp/a.b*c[d]e^f$g#h'
  record "${wd}"
  printf 'x %s y\n' "${wd}" > "${OUTDIR}/stderr"

  _normalize_workdir_path "${OUTDIR}"

  run cat "${OUTDIR}/stderr"
  [ "$output" = 'x WORKDIR y' ]
}

@test "a path that merely resembles the workdir pattern is left alone" {
  # `.` unescaped would match any character, so a sibling directory one
  # character apart would be masked too and a real divergence would vanish.
  record '/tmp/tmp.aBc123'
  printf '/tmp/tmpXaBc123\n' > "${OUTDIR}/stderr"

  _normalize_workdir_path "${OUTDIR}"

  run cat "${OUTDIR}/stderr"
  [ "$output" = '/tmp/tmpXaBc123' ]
}

@test "_bre_escape leaves a string with nothing special in it untouched" {
  run _bre_escape '/tmp/tmp-plain/path'
  [ "$output" = '/tmp/tmp-plain/path' ]
}
