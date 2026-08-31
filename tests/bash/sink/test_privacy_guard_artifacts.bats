#!/usr/bin/env bats
# T013 [Phase 2, 036] — the privacy guard over feature-artifact content
# (036 contracts/artifact-publication.md C5.1–C5.5; FR-016, SC-007;
# Constitution IX).
#
# 036 widens the guard's surface materially: `research.md`, `data-model.md`,
# `contracts/` and `checklists/` become write payloads for the first time. They
# were written for a repository, not for a Jira site.
#
# C5.1 — WHERE the scan runs is the whole point. `/speckit-analyze` found that
# FR-016's "zero writes for the ENTIRE run" is unachievable from the publication
# phase, because publication runs after the description and story writes have
# already landed. The scan belongs at the pre-write sweep, and the assertion is
# therefore not "the upload was refused" but "the ticket was never touched".
#
# C5.2 — binary artifacts are scanned with no special case. That case is not
# theoretical padding: raw binary through a shell variable made `grep` stop
# reporting matches at all, so an `ATATT…` token appended to a PNG sat in the
# file, vanished from the payload, and the guard returned clear. Every
# assertion below that names the PNG exists because of that.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/artifact_fixture.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/artifact_set.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/privacy_guard.sh"
  REPO="${BATS_TEST_TMPDIR}/repo"
  helper_make_artifact_repo "${REPO}"
  DIR="$(helper_make_artifact_fixture "${REPO}")"
}

# The set for the fixture as it currently stands on disk.
_set() { artifact_set_build "${DIR}"; }

# --- C5.3 / FR-016: a BLOCKED shape refuses, and names the artifact ---------

@test "C5.3 a live Cloud host in research.md blocks, naming that artifact" {
  printf 'see https://acme-real.atlassian.net/browse/X-1\n' >> "${DIR}/research.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 9 ]
  [[ "$output" == *"research.md"* ]]
  [[ "$output" == *"Atlassian Cloud host"* ]]
}

@test "C5.3 an API token in research.md blocks, naming that artifact" {
  printf 'token ATATTabc123XYZ456\n' >> "${DIR}/research.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 9 ]
  [[ "$output" == *"research.md"* ]]
  [[ "$output" == *"ATATT prefix"* ]]
}

@test "C5.2 a token inside the BINARY artifact blocks, naming the binary" {
  # The regression that shipped once: the bytes were in the file and absent
  # from the scanned payload, and the guard said clear.
  printf 'ATATTdeadbeef99\n' >> "${DIR}/assets/diagram.png"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 9 ]
  [[ "$output" == *"assets/diagram.png"* ]]
}

@test "C5.3 a token in a NESTED artifact blocks, naming its relative path" {
  printf 'ATATTzzz99988\n' >> "${DIR}/contracts/api.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 9 ]
  [[ "$output" == *"contracts/api.md"* ]]
}

@test "C5.3 a known coordinate in an artifact blocks" {
  printf 'the project lives at acme-internal-coordinate\n' >> "${DIR}/data-model.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)" '["acme-internal-coordinate"]'
  [ "$status" -eq 9 ]
  [[ "$output" == *"data-model.md"* ]]
  [[ "$output" == *"known coordinate"* ]]
}

# --- NFR-3: the value is named by shape, never echoed ----------------------

@test "C5.3 the message names the shape and NEVER the offending value" {
  printf 'token ATATTsecretvalue00099\n' >> "${DIR}/research.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 9 ]
  # The shape is named; the secret itself must not appear anywhere in output.
  [[ "$output" == *"ATATT prefix"* ]]
  ! grep -q 'ATATTsecretvalue00099' <<< "${output}"
}

# --- FR-053: the allowlist neutralises, at both tiers ----------------------

@test "SC-007 an allowlisted host inside artifact content neither blocks nor warns" {
  printf 'see https://acme-real.atlassian.net/wiki/spaces/X\n' >> "${DIR}/research.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)" '[]' '["acme-real.atlassian.net"]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "SC-007 an allowlisted corporate domain inside artifact content passes silently" {
  printf 'contact platform@corp.example.internal for access\n' >> "${DIR}/contracts/api.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)" '[]' '["corp.example.internal"]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "FR-053 an allowlist entry never neutralises an UNRELATED token" {
  # Fail-closed: a broad entry covers only the text it matches.
  printf 'https://acme-real.atlassian.net/x and ATATTunrelated999\n' >> "${DIR}/research.md"
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)" '[]' '["acme-real.atlassian.net"]'
  [ "$status" -eq 9 ]
  [[ "$output" == *"ATATT prefix"* ]]
}

# --- the clear path -------------------------------------------------------

@test "C5.3 a clean artifact set returns 0 and says nothing" {
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C5.3 an empty artifact set is clear, not an error" {
  run privacy_guard_scan_artifacts "${DIR}" '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "C5.3 the scan emits no stray warning on binary content" {
  # Bash drops a NUL from a command substitution WITH a warning on stderr.
  # `run` merges stderr into $output, so a leaked warning shows up here — and
  # an operator reading a clean run must not see one.
  run privacy_guard_scan_artifacts "${DIR}" "$(_set)"
  [ "$status" -eq 0 ]
  ! grep -qi 'null byte' <<< "${output}"
  ! grep -qi 'illegal byte sequence' <<< "${output}"
}

# --- C5.4: one pass, no process per artifact ------------------------------

@test "C5.4 the clear-path scan spawns no process per artifact" {
  local shim="${BATS_TEST_TMPDIR}/shim" counts="${BATS_TEST_TMPDIR}/counts"
  helper_spawn_count_setup "${shim}" "${counts}" cat tr xargs
  # Probe the instrument before trusting a zero from it.
  PATH="${shim}:${PATH}" cat /dev/null
  [ "$(helper_spawn_count_for "${counts}" cat)" -eq 1 ]

  local small wide s_small s_wide n_small n_wide
  small="$(helper_make_artifact_fixture_wide "${REPO}" "pgsmall" 4)"
  wide="$(helper_make_artifact_fixture_wide "${REPO}" "pgwide" 80)"
  s_small="$(artifact_set_build "${small}")"
  s_wide="$(artifact_set_build "${wide}")"

  : > "${counts}"
  PATH="${shim}:${PATH}" privacy_guard_artifact_reason "${small}" "${s_small}" > /dev/null
  n_small="$(helper_spawn_count_total "${counts}")"

  : > "${counts}"
  PATH="${shim}:${PATH}" privacy_guard_artifact_reason "${wide}" "${s_wide}" > /dev/null
  n_wide="$(helper_spawn_count_total "${counts}")"

  # 20x the artifacts, the same spawn count. Equality, not a ratio: the count
  # is a constant of the algorithm, and anything else is a per-item spawn in
  # disguise.
  [ "${n_wide}" -eq "${n_small}" ]
}

@test "C5.4 the scan passes no artifact path through a growing command line" {
  # The cap that binds is the tightest across supported hosts, NEVER this
  # machine's: Windows counts the whole command line against ~32767 bytes.
  local shim="${BATS_TEST_TMPDIR}/argv" log="${BATS_TEST_TMPDIR}/argv.log" real
  mkdir -p "${shim}"
  real="$(command -v cat)"
  cat > "${shim}/cat" << SHIM
#!/bin/sh
printf '%s\n' "\$*" | wc -c >> "${log}"
exec "${real}" "\$@"
SHIM
  chmod +x "${shim}/cat"
  : > "${log}"

  local wide s
  wide="$(helper_make_artifact_fixture_wide "${REPO}" "pgargv" 200)"
  s="$(artifact_set_build "${wide}")"
  PATH="${shim}:${PATH}" privacy_guard_artifact_reason "${wide}" "${s}" > /dev/null

  local widest
  widest="$(sort -n "${log}" | tail -1)"
  [ -n "${widest}" ]
  [ "${widest}" -lt 32767 ]
}
