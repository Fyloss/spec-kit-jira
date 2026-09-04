#!/usr/bin/env bash
# tests/bash/helpers/artifact_fixture.bash — the feature directory every 036
# suite reads: more than the three documents the mirror renders today, one
# nested artifact per subdirectory shape, one binary, and one file the
# repository's own ignore rules exclude.
#
# It builds its OWN git repository rather than writing into the caller's. Two
# reasons, and both are load-bearing:
#
#   1. `git ls-files --cached --others --exclude-standard` is the enumeration
#      under test (research R5). It answers relative to a repository, so the
#      fixture has to be in one, and it must be one whose ignore rules the
#      fixture controls.
#   2. The exclusion is written to `.git/info/exclude`, NOT to a `.gitignore`
#      inside the feature directory. A `.gitignore` there would itself be an
#      untracked, non-ignored file — i.e. an artifact — and every artifact-set
#      assertion would have to carry it. `info/exclude` keeps the fixture's
#      expected set exactly the files a real feature directory holds.
#
# Constitution XIII's isolation rule: every caller passes a path it generated
# (`$BATS_TEST_TMPDIR/...`), and nothing here scans for state by pattern.

# The artifact paths the fixture writes, relative to the feature directory, in
# the byte-wise sorted order the artifact set must produce (data-model §1
# "Ordering"). A test asserting the whole set compares against this.
HELPER_ARTIFACT_PATHS=(
  'assets/diagram.png'
  'checklists/requirements.md'
  'contracts/api.md'
  'data-model.md'
  'plan.md'
  'research.md'
  'spec.md'
  'tasks.md'
)

# The flattened attachment name for each path above, same order (research R7):
# a top-level artifact keeps its exact filename; a nested one joins its
# segments with `__`.
HELPER_ARTIFACT_NAMES=(
  'assets__diagram.png'
  'checklists__requirements.md'
  'contracts__api.md'
  'data-model.md'
  'plan.md'
  'research.md'
  'spec.md'
  'tasks.md'
)

# helper_make_artifact_repo <root> — a git repository at <root> with the
# ignore rule already in place. Prints nothing; the caller owns <root>.
helper_make_artifact_repo() {
  local root="$1"
  mkdir -p "${root}"
  git -C "${root}" init --quiet
  # Identity is required for `git hash-object` on some hosts and costs nothing
  # here; it is never read back.
  git -C "${root}" config user.email 'fixture@example.invalid'
  git -C "${root}" config user.name 'fixture'
  printf '%s\n' '*.log' 'scratch/' > "${root}/.git/info/exclude"
}

# helper_write_binary_artifact <path> — 64 deterministic bytes that are not
# text: a PNG signature (which carries a CRLF pair and a NUL-adjacent byte),
# then a run covering the whole 0x00-0xFF neighbourhood the guard and the
# transport must pass through untouched.
#
# The CRLF in the signature is deliberate. A port that normalises line endings
# anywhere on the upload path corrupts this file, and FR-002 requires the bytes
# to arrive unmodified.
helper_write_binary_artifact() {
  local path="$1" i oct
  mkdir -p "$(dirname "${path}")"
  {
    printf '\x89PNG\r\n\x1a\n'
    for ((i = 0; i < 56; i++)); do
      # `%b` with an OCTAL escape, not `\xHH`: the format string stays a
      # literal (no SC2059), and `\0NNN` is the escape `%b` is specified to
      # interpret, where `\xHH` is a bash extension.
      printf -v oct '%03o' $((i * 4 % 256))
      printf '%b' "\\0${oct}"
    done
  } > "${path}"
}

# helper_make_artifact_fixture <root> <feature-dir-name> — write the feature
# directory under an initialised repository and print its absolute path.
#
# The caller is expected to have run helper_make_artifact_repo on <root>
# first; this function does it when the repository is absent, so a test that
# only wants the directory need not know about the repository at all.
helper_make_artifact_fixture() {
  local root="$1" name="${2:-036-artifact-fixture}"
  [[ -d "${root}/.git" ]] || helper_make_artifact_repo "${root}"

  local dir="${root}/specs/${name}"
  mkdir -p "${dir}/contracts" "${dir}/checklists" "${dir}/assets" "${dir}/scratch"

  printf '%s\n' '# Feature Specification: Widget Management' '' \
    'We need to let users manage widgets end to end.' '' \
    '### User Story 1 - Manage widgets (Priority: P1)' '' \
    'As a user, I want to manage widgets.' '' \
    '- **Given** a precondition' '- **When** I act' '- **Then** it happens' > "${dir}/spec.md"

  printf '%s\n' '# Implementation Plan: Widget Management' '' \
    'Two ports, one contract.' > "${dir}/plan.md"

  printf '%s\n' '# Tasks: Widget Management' '' \
    '- [ ] T001 [US1] Do the thing in src/thing.sh' > "${dir}/tasks.md"

  printf '%s\n' '# Phase 0 — Research' '' \
    'The decision, the rationale, and what was rejected.' > "${dir}/research.md"

  printf '%s\n' '# Phase 1 — Data model' '' \
    'One entity, three fields.' > "${dir}/data-model.md"

  printf '%s\n' '# Contract: the widget interface' '' \
    'C1. A widget answers to its own name.' > "${dir}/contracts/api.md"

  printf '%s\n' '# Checklist: requirements' '' \
    '- [x] Scope is bounded' > "${dir}/checklists/requirements.md"

  helper_write_binary_artifact "${dir}/assets/diagram.png"

  # Excluded by `.git/info/exclude`: neither may appear in the artifact set
  # (FR-007). Two shapes, because a rule can match a suffix or a directory.
  printf '%s\n' 'editor noise, not an artifact' > "${dir}/editor.log"
  printf '%s\n' 'local scratch, not an artifact' > "${dir}/scratch/notes.md"

  printf '%s' "${dir}"
}

# helper_artifact_fixture_expected_paths — the sorted relative paths the
# artifact set must contain for a fixture built above, one per line.
helper_artifact_fixture_expected_paths() {
  printf '%s\n' "${HELPER_ARTIFACT_PATHS[@]}"
}

# helper_artifact_fixture_expected_names — the flattened attachment names, in
# the same order.
helper_artifact_fixture_expected_names() {
  printf '%s\n' "${HELPER_ARTIFACT_NAMES[@]}"
}

# helper_make_artifact_fixture_wide <root> <name> <count> — a feature
# directory holding <count> artifacts, for the process-budget and argv-size
# assertions. Paths are zero-padded so the byte-wise sort is also the numeric
# one, which keeps a failure message readable.
helper_make_artifact_fixture_wide() {
  local root="$1" name="$2" count="$3" i
  [[ -d "${root}/.git" ]] || helper_make_artifact_repo "${root}"
  local dir="${root}/specs/${name}"
  mkdir -p "${dir}/contracts"
  printf '%s\n' '# Feature Specification: Wide' > "${dir}/spec.md"
  for ((i = 0; i < count; i++)); do
    printf 'contract %03d\n' "${i}" > "$(printf '%s/contracts/c%03d.md' "${dir}" "${i}")"
  done
  printf '%s' "${dir}"
}
