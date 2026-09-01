#!/usr/bin/env bats
# T070/T071/T075 [Phase 4, 036] — run state schema 3: the short-circuit
# considers EVERY artifact, not three fixed documents
# (contracts/run-state-v3.md C1-C5, FR-011, US2 AS4).
#
# WHY THE CONSEQUENCE EXISTS (contract C4). Under schema 2 the recorded inputs
# were `spec.md`, `plan.md` and `tasks.md`. A run fired after only `research.md`
# changed found all three hashes matching, short-circuited, made zero Jira
# calls — and the artifact was never published. The publication feature would
# have been unreachable for exactly the files it exists to add.
#
# T071 is the red-proof and it is IN THIS FILE rather than in a commit message:
# the regression case is re-run against the pre-change module retrieved from
# git, and asserted to fail there. A guard nobody has watched fail is not known
# to work, and this repository has shipped two inert ones out of three.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/artifact_fixture.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/engine/artifact_set.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/run_state.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  FEATURE_DIR="$(helper_make_artifact_fixture "${WORK}" "001-artifacts")"
  SPEC="${FEATURE_DIR}/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  printf 'projects:\n  - key: COMP\n' > "${JIRA_CONFIG_DIR}/config.yml"
}

# _compose — a state document for the fixture as it currently stands.
_compose() {
  run_state_compose "${SPEC}" "https://x.invalid" "u@example.com" "abort" "" "" \
    "$(artifact_set_build "${FEATURE_DIR}")"
}

_record() {
  run_state_record "${SPEC}" "https://x.invalid" "u@example.com" "abort" "" "" \
    "$(artifact_set_build "${FEATURE_DIR}")"
}

_matches() {
  run_state_matches "${SPEC}" "https://x.invalid" "u@example.com" "abort" "" "" \
    "$(artifact_set_build "${FEATURE_DIR}")"
}

# ---- C1: the schema bump ----------------------------------------------------

@test "C1 the recorded schema is 3" {
  # The set of recorded inputs changed, which is the module's own stated rule
  # for a bump. Every schema-2 file is thereby invalidated, and the first run
  # after an upgrade does real work — which is correct: those artifacts are
  # published and no record says so.
  [ "$(jq -r '.schema' <<< "$(_compose)")" -eq 3 ]
}

@test "C1 a recorded schema-2 document does not match, so the next run proceeds" {
  _record
  local recorded
  recorded="$(run_state_path "${SPEC}")"
  jq -c '.schema = 2' "${recorded}" > "${recorded}.tmp" && mv "${recorded}.tmp" "${recorded}"

  run _matches
  [ "$status" -ne 0 ]
}

# ---- C2/C3: the inputs are the artifact set ---------------------------------

@test "C3.1 every artifact of the directory is an input key" {
  local inputs
  inputs="$(jq -c '.inputs' <<< "$(_compose)")"
  local p
  for p in "${HELPER_ARTIFACT_PATHS[@]}"; do
    [ "$(jq -r --arg k "${p}" 'has($k)' <<< "${inputs}")" = "true" ]
  done
}

@test "C3.1 a git-ignored file is NOT an input key" {
  # The set is `git ls-files --exclude-standard`, so an ignored file is not an
  # artifact — and a state document that hashed it would invalidate on every
  # editor save.
  local inputs
  inputs="$(jq -c '.inputs' <<< "$(_compose)")"
  [ "$(jq -r 'has("editor.log")' <<< "${inputs}")" = "false" ]
  [ "$(jq -r 'has("scratch/notes.md")' <<< "${inputs}")" = "false" ]
}

@test "C3.3 artifact input paths are relative and /-separated, never absolute" {
  # The document is byte-compared across ports and machines, so an absolute
  # path would make it match only on the machine that wrote it.
  #
  # Scoped to the ARTIFACT keys. The three configuration keys beside them are
  # spelled `${JIRA_CONFIG_DIR}/…` verbatim and have been since schema 1, so
  # they are relative exactly when the caller's JIRA_CONFIG_DIR is — a
  # pre-existing property of those three keys, not of this schema, and widening
  # this assertion to cover them would be asserting something 036 neither
  # changed nor is free to change here.
  local doc
  doc="$(_compose)"
  [ "$(jq -r '.inputs | keys[] | select(contains("contracts"))' <<< "${doc}")" = "contracts/api.md" ]
  local p
  for p in "${HELPER_ARTIFACT_PATHS[@]}"; do
    [[ "${p}" != /* ]]
    [ "$(jq -r --arg k "${p}" 'has($k)' <<< "$(jq -c '.inputs' <<< "${doc}")")" = "true" ]
  done
}

@test "C3.5 the keys are canonically sorted" {
  local keys
  keys="$(jq -r '.inputs | keys_unsorted | join(",")' <<< "$(_compose)")"
  [ "${keys}" = "$(jq -rn --argjson k "$(jq -c '.inputs | keys_unsorted' <<< "$(_compose)")" '$k | sort | join(",")')" ]
}

@test "C3.6 a set the module cannot read returns 1 and prints nothing" {
  run run_state_compose "${SPEC}" "https://x.invalid" "u@e.com" "abort" "" "" 'not json at all'
  [ "$status" -ne 0 ]
  [ -z "${output}" ]
}

# ---- C4: THE regression this whole schema bump exists for --------------------

@test "C4 FR-011 changing ONLY research.md invalidates the state — the run proceeds" {
  # The assertion the feature rests on. Under schema 2 all three recorded
  # hashes still matched and the run short-circuited with zero Jira calls,
  # leaving research.md unpublished forever.
  _record
  run _matches
  [ "$status" -eq 0 ]

  printf '%s\n' '# Phase 0 — Research' '' 'A decision recorded after the last run.' \
    > "${FEATURE_DIR}/research.md"

  run _matches
  [ "$status" -ne 0 ]
}

@test "C4 a NEW artifact — a checklist that did not exist — invalidates the state" {
  # The `after_checklist` scenario, at the state layer: a file appearing is a
  # change to the key SET, which schema 2 could not represent at all.
  _record
  printf '%s\n' '# Checklist: UX' '- [x] Understandable' > "${FEATURE_DIR}/checklists/ux.md"
  run _matches
  [ "$status" -ne 0 ]
}

@test "C4 a genuinely unchanged directory still matches — the short-circuit survives" {
  # The other half. A schema that invalidated on every run would make the
  # short-circuit useless and every reconcile expensive.
  _record
  run _matches
  [ "$status" -eq 0 ]
}

@test "T071 the regression is RED against schema 2 — proven, not asserted" {
  # The pre-change module, retrieved from git rather than re-implemented, so
  # what is demonstrated is the real previous behaviour. `git show` against the
  # merge-base of this branch would drift as the branch moves; the file is
  # taken from the commit that last carried schema 2.
  local old_module
  old_module="${BATS_TEST_TMPDIR}/run_state_v2.sh"
  local rev
  rev="$(git -C "${ROOT}" log --format=%H -S'_RUN_STATE_SCHEMA=2' -1 -- scripts/bash/lib/run_state.sh 2> /dev/null)"
  [ -n "${rev}" ] || skip "cannot locate the schema-2 revision in this checkout"
  git -C "${ROOT}" show "${rev}:scripts/bash/lib/run_state.sh" > "${old_module}" 2> /dev/null || \
    skip "cannot retrieve the schema-2 module from git"
  grep -q '_RUN_STATE_SCHEMA=2' "${old_module}"

  # Run the OLD module in its own shell: it defines the same function names,
  # and sourcing it here would replace the ones under test for every later case
  # in this file.
  #
  # Its own `source` lines resolve relative to `${BASH_SOURCE[0]}`, which is now
  # a temp path with no siblings — they fail silently and the module reaches
  # `output_warn: command not found` at the first warning, composing nothing and
  # reporting INVALIDATED for a reason that has nothing to do with schema 2.
  # That looked exactly like the guard passing. The real `lib/output.sh` and
  # `lib/config.sh` are therefore loaded FIRST, so the old module finds every
  # function it needs already defined.
  local out
  out="$(bash -c '
    cd "$1"
    source scripts/bash/lib/output.sh
    source scripts/bash/lib/config.sh
    source "$2"
    export JIRA_CONFIG_DIR="$4"
    # Record, then change ONLY research.md, then ask whether it still matches.
    run_state_record "$3" "https://x.invalid" "u@example.com" "abort" "" ""
    [ -f "$(run_state_path "$3")" ] || { printf "NO-RECORD"; exit 0; }
    printf "# Phase 0\n\nchanged\n" > "$(dirname "$3")/research.md"
    if run_state_matches "$3" "https://x.invalid" "u@example.com" "abort" "" ""; then
      printf "MATCHED"
    else
      printf "INVALIDATED"
    fi
  ' _ "${ROOT}" "${old_module}" "${SPEC}" "${JIRA_CONFIG_DIR}" 2> /dev/null)"

  # A module that could not record at all would report INVALIDATED for a reason
  # unrelated to the schema, and the assertion below would read as a pass of the
  # wrong thing. Name that state instead of letting it hide.
  [ "${out}" != "NO-RECORD" ]

  # THE red-proof: schema 2 says "nothing changed" after research.md changed.
  # That is the defect, reproduced, in the suite.
  [ "${out}" = "MATCHED" ]
}

# ---- C5: the state phase's own process budget -------------------------------

@test "C5 the state phase spawns a bounded number of processes, whatever the count" {
  # v3 replaces N `git hash-object` calls with one `--stdin-paths` call over
  # the whole set, so the state phase's cost must not grow with the artifact
  # count. Measured, not reasoned: the shim is prepended to PATH and probed
  # first, because a shim that never fires reports 0 spawns forever and a
  # budget assertion against a dead instrument passes for the wrong reason.
  local shim counts n_small n_wide wide_dir
  shim="${BATS_TEST_TMPDIR}/shim"
  counts="${BATS_TEST_TMPDIR}/counts"

  helper_spawn_count_setup "${shim}" "${counts}" git
  PATH="${shim}:${PATH}" _compose > /dev/null
  n_small="$(helper_spawn_count_total "${counts}")"
  [ "${n_small}" -gt 0 ]

  wide_dir="$(helper_make_artifact_fixture_wide "${WORK}" "002-wide" 60)"
  helper_spawn_count_setup "${shim}" "${counts}" git
  PATH="${shim}:${PATH}" run_state_compose "${wide_dir}/spec.md" \
    "https://x.invalid" "u@example.com" "abort" "" "" \
    "$(PATH="${shim}:${PATH}" artifact_set_build "${wide_dir}")" > /dev/null
  n_wide="$(helper_spawn_count_total "${counts}")"

  # 52 more artifacts. A per-input implementation costs at least one process
  # each; anything within a small constant of the narrow case is bounded.
  if ((n_wide > n_small + 6)); then
    printf 'the state phase spawns per artifact: %d for 8 artifacts, %d for 61\n' \
      "${n_small}" "${n_wide}" >&2
    return 1
  fi
}
