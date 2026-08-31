#!/usr/bin/env bats
# T005/T007/T008/T011 [Phase 2, 036] — the artifact set
# (036 data-model.md §1; research R4/R5/R7; FR-001, FR-005, FR-007, FR-023).
#
# The engine's view of the feature directory: every file the repository does
# not ignore, at any depth, with its content hash, its size, and the flattened
# name it will carry as a Jira attachment. It contains no Jira knowledge — it
# would be identical if the sink were something else — which is why it lives in
# engine/ and is grep-guarded there (Principle VIII).
#
# Two properties are as load-bearing as the content:
#
#   * ORDER. Both ports must emit the same sequence, or the manifest, the
#     comment body and the multipart part list all diverge. `git ls-files`
#     output order is not contractual; the byte-wise sort on `path` is.
#   * PROCESS COUNT. The set is built with a bounded number of spawns whatever
#     its size (FR-023), and no command line grows with it. Both halves, or the
#     defect `docs/11-process-budget.md` records three times returns.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  ENGINE_DIR="${ROOT}/scripts/bash/engine"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/artifact_fixture.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  # shellcheck source=/dev/null
  source "${ENGINE_DIR}/artifact_set.sh"
  REPO="${BATS_TEST_TMPDIR}/repo"
  helper_make_artifact_repo "${REPO}"
}

# --- FR-001, FR-007: what is in the set, and what is not -------------------

@test "data-model §1 the set holds every non-ignored file, at any depth" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  local got
  got="$(jq -r '.[].path' <<< "${output}")"
  [ "${got}" = "$(helper_artifact_fixture_expected_paths)" ]
}

@test "FR-007 a file the repository ignores is absent from the set" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  # Both shapes the fixture plants: a suffix rule and a directory rule.
  ! grep -q 'editor.log' <<< "${output}"
  ! grep -q 'scratch/notes.md' <<< "${output}"
}

@test "FR-001 a nested artifact is found at depth two" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  mkdir -p "${dir}/contracts/v2"
  printf 'deep\n' > "${dir}/contracts/v2/deep.md"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.[] | select(.path == "contracts/v2/deep.md")] | length' <<< "${output}")" -eq 1 ]
}

# --- data-model §1 "Ordering" ----------------------------------------------

@test "data-model §1 the set is sorted byte-wise on path, not by discovery order" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  # Names chosen so an ASCII sort and a case-insensitive sort disagree: `Z`
  # (0x5A) precedes `a` (0x61) byte-wise but follows it case-insensitively.
  printf 'z\n' > "${dir}/Zebra.md"
  printf 'a\n' > "${dir}/apple.md"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  local paths
  paths="$(jq -r '.[].path' <<< "${output}")"
  [ "${paths}" = "$(LC_ALL=C sort <<< "${paths}")" ]
  # And specifically: the capital sorts first.
  local zi ai
  zi="$(jq -r 'map(.path) | index("Zebra.md")' <<< "${output}")"
  ai="$(jq -r 'map(.path) | index("apple.md")' <<< "${output}")"
  [ "${zi}" -lt "${ai}" ]
}

# --- FR-005, research R7: the flattened attachment name ---------------------

@test "FR-005 a top-level artifact keeps its exact filename" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.path == "spec.md") | .attachment_name' <<< "${output}")" = "spec.md" ]
  [ "$(jq -r '.[] | select(.path == "data-model.md") | .attachment_name' <<< "${output}")" = "data-model.md" ]
}

@test "FR-005 a nested artifact flattens its path with a double underscore" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  local got
  got="$(jq -r '.[].attachment_name' <<< "${output}")"
  [ "${got}" = "$(helper_artifact_fixture_expected_names)" ]
}

@test "FR-005 a two-level nesting flattens every separator" {
  run artifact_set_flatten 'checklists/ux/a.md'
  [ "$status" -eq 0 ]
  [ "$output" = 'checklists__ux__a.md' ]
}

# --- data-model §1 "Validation": the hash and the size ----------------------

@test "data-model §1 each entry carries the git hash of its own bytes" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  local got want
  got="$(jq -r '.[] | select(.path == "spec.md") | .hash' <<< "${output}")"
  want="$(git hash-object --no-filters "${dir}/spec.md")"
  [ "${got}" = "${want}" ]
}

@test "data-model §1 the binary artifact's hash and size are its real bytes" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  local got want
  got="$(jq -r '.[] | select(.path == "assets/diagram.png") | .hash' <<< "${output}")"
  want="$(git hash-object --no-filters "${dir}/assets/diagram.png")"
  [ "${got}" = "${want}" ]
  [ "$(jq -r '.[] | select(.path == "assets/diagram.png") | .size' <<< "${output}")" -eq 64 ]
}

@test "data-model §1 a path is relative to the feature directory and never absolute" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  # Not one entry may start with a separator or name the fixture root: an
  # absolute path would carry the operator's home directory into a Jira record
  # and break byte equivalence between machines.
  [ "$(jq -r '[.[] | select(.path | startswith("/"))] | length' <<< "${output}")" -eq 0 ]
  ! grep -q "${REPO}" <<< "${output}"
}

@test "data-model §1 an empty feature directory yields an empty set, not an error" {
  local dir="${REPO}/specs/empty"
  mkdir -p "${dir}"
  run artifact_set_build "${dir}"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# --- T011 / FR-005: the flattening collision --------------------------------

@test "FR-005 two artifacts flattening to one name are BOTH withheld" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  printf 'x\n' > "${dir}/contracts/collide.md"
  mkdir -p "${dir}/checklists"
  printf 'y\n' > "${dir}/checklists/collide.md"
  # Both flatten to `contracts__collide.md` / `checklists__collide.md` — which
  # do NOT collide. The real collision needs a literal `__` in a filename:
  printf 'z\n' > "${dir}/contracts__collide.md"
  run artifact_set_collisions "$(artifact_set_build "${dir}")"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -q 'contracts/collide.md' <<< "${output}"
  grep -q 'contracts__collide.md' <<< "${output}"
}

@test "FR-005 a set with no colliding name reports nothing" {
  local dir
  dir="$(helper_make_artifact_fixture "${REPO}")"
  run artifact_set_collisions "$(artifact_set_build "${dir}")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- T007 / FR-023: the process budget --------------------------------------

@test "FR-023 the spawn count does not grow with the artifact count" {
  # The instrument first. A shim that never fired reports 0 spawns, and a
  # budget assertion against a dead instrument passes for the wrong reason
  # (the repository has been bitten by exactly this).
  local shim="${BATS_TEST_TMPDIR}/shim" counts="${BATS_TEST_TMPDIR}/counts"
  helper_spawn_count_setup "${shim}" "${counts}" git
  PATH="${shim}:${PATH}" git --version > /dev/null
  [ "$(helper_spawn_count_for "${counts}" git)" -eq 1 ]

  local small wide
  small="$(helper_make_artifact_fixture_wide "${REPO}" "small" 4)"
  wide="$(helper_make_artifact_fixture_wide "${REPO}" "wide" 80)"

  : > "${counts}"
  PATH="${shim}:${PATH}" artifact_set_build "${small}" > /dev/null
  local n_small
  n_small="$(helper_spawn_count_total "${counts}")"

  : > "${counts}"
  PATH="${shim}:${PATH}" artifact_set_build "${wide}" > /dev/null
  local n_wide
  n_wide="$(helper_spawn_count_total "${counts}")"

  # 20x the artifacts must not mean more spawns. Equality, not a ratio: the
  # count is a constant of the algorithm, and anything else is a per-item
  # spawn wearing a disguise.
  [ "${n_wide}" -eq "${n_small}" ]
  # And the constant is small. A generous ceiling that still fails a
  # per-item implementation for either fixture.
  [ "${n_wide}" -le 12 ]
}

# --- T008 / FR-023: the argument-length cap ---------------------------------

@test "FR-023 no command line grows with the artifact set" {
  # The cap that binds is the tightest across supported hosts, NEVER this
  # machine's: Windows counts the whole command line against ~32767 bytes,
  # Linux caps a single argument at 128 KiB, macOS caps nothing at all. This
  # assertion is invisible on the maintainer's own machine unless it is
  # written against the Windows number.
  local shim="${BATS_TEST_TMPDIR}/argv" log="${BATS_TEST_TMPDIR}/argv.log"
  mkdir -p "${shim}"
  local real_git
  real_git="$(command -v git)"
  cat > "${shim}/git" << SHIM
#!/bin/sh
printf '%s\n' "\$*" | wc -c >> "${log}"
exec "${real_git}" "\$@"
SHIM
  chmod +x "${shim}/git"
  : > "${log}"

  local wide
  wide="$(helper_make_artifact_fixture_wide "${REPO}" "argvwide" 200)"
  PATH="${shim}:${PATH}" artifact_set_build "${wide}" > /dev/null

  local widest
  widest="$(sort -n "${log}" | tail -1)"
  [ -n "${widest}" ]
  # 200 artifacts whose paths alone exceed 4 KB: an argv-carrying
  # implementation lands well past this, a stdin-carrying one stays tiny.
  [ "${widest}" -lt 32767 ]
}
