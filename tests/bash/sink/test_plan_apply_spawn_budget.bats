#!/usr/bin/env bats
# T024/T024a — spawn-budget guards for the write path (contracts/spawn-budget.md
# C1.2/C1.4). Scoped like T022/T023 (tests/bash/engine/test_parse_spawn_budget.bats):
# each test exercises one already-batched extraction directly rather than the
# whole gate/plan/apply integration surface.
#
# `gate` (hierarchy_mandatory_gate, reconcile.sh's mandatory-field path) is
# NOT per-item at all — it validates the routed binding's child/parent issue
# TYPES once, never loops over stories — so T029 needed no change there; the
# guard below asserts that stays true rather than re-proving a fix that was
# never required.
#
# `plan_writes`'s own per-story field-building (adf rendering, checklist
# digest, summary drift, label union, parent-link correction — roughly 60-80
# `jq` calls per UPDATE-branch story) is UNCHANGED by this pass: only the
# `stories` accumulator (an O(n²) `. + [$a]` re-parse) was converted to
# native accumulation. T030's full per-field consolidation is not attempted
# here — see tasks.md's Phase 5 notes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/spawn_count.bash"
  SHIM_DIR="${BATS_TMPDIR}/aw_spawn_shims_$$"
  COUNT_FILE="${BATS_TMPDIR}/aw_spawn_count_$$.log"
  helper_spawn_count_setup "${SHIM_DIR}" "${COUNT_FILE}"
}

teardown() {
  rm -rf "${SHIM_DIR}" "${COUNT_FILE}"
}

_gen_actions() {
  local n="$1" i out="["
  for ((i = 0; i < n; i++)); do
    ((i > 0)) && out+=","
    out+="{\"method\":\"PUT\",\"url\":\"https://x/rest/api/3/issue/PROJ-${i}\",\"body\":{\"fields\":{\"summary\":\"s${i}\"}}}"
  done
  out+="]"
  printf '%s' "${out}"
}

@test "T024: _apply_writes_decode_rows spawns exactly one jq call regardless of action count" {
  local actions10 actions20 c10 c20
  actions10="$(_gen_actions 10)"
  actions20="$(_gen_actions 20)"
  c10="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${SINK_DIR}"'/plan_apply.sh"
    : > "'"${COUNT_FILE}"'"
    _apply_writes_decode_rows "$1" $'"'"'\x1f'"'"' > /dev/null
  ' _ "${actions10}"; helper_spawn_count_total "${COUNT_FILE}")"
  c20="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${SINK_DIR}"'/plan_apply.sh"
    : > "'"${COUNT_FILE}"'"
    _apply_writes_decode_rows "$1" $'"'"'\x1f'"'"' > /dev/null
  ' _ "${actions20}"; helper_spawn_count_total "${COUNT_FILE}")"
  [ "${c10}" = "1" ]
  [ "${c20}" = "1" ]
}

@test "T024: _apply_writes_decode_rows reaches the same floor on an empty action list (C1.4)" {
  local c0
  c0="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${SINK_DIR}"'/plan_apply.sh"
    : > "'"${COUNT_FILE}"'"
    _apply_writes_decode_rows "[]" $'"'"'\x1f'"'"' > /dev/null
  '; helper_spawn_count_total "${COUNT_FILE}")"
  [ "${c0}" = "1" ]
}

@test "T024: _apply_writes_decode_rows round-trips method/url/body for every action, in order" {
  local out
  out="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${SINK_DIR}"'/plan_apply.sh"
    _apply_writes_decode_rows "$1" $'"'"'\x1f'"'"'
  ' _ "$(_gen_actions 3)")"
  [ "$(printf '%s\n' "${out}" | wc -l | tr -d " ")" = "3" ]
  [[ "$(printf '%s\n' "${out}" | sed -n '2p')" == *"PROJ-1"* ]]
}

@test "T029: hierarchy_mandatory_gate spawns the same count whether the binding names 1 or many required fields (never per-story)" {
  source "${SINK_DIR}/hierarchy.sh"
  local binding1 binding2 c1 c2
  binding1='{"child_type":{"id":"10","logical_name":"Story"},"parent_type":{"id":"11","logical_name":"Epic"},"parent_link_available":{"10":true},"required_fields":{"10":["summary"],"11":["summary"]}}'
  binding2='{"child_type":{"id":"10","logical_name":"Story"},"parent_type":{"id":"11","logical_name":"Epic"},"parent_link_available":{"10":true},"required_fields":{"10":["summary","priority","reporter","labels"],"11":["summary","priority"]}}'
  c1="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${SINK_DIR}"'/hierarchy.sh"
    : > "'"${COUNT_FILE}"'"
    hierarchy_mandatory_gate "$1" "PROJ" "{}" > /dev/null
  ' _ "${binding1}"; helper_spawn_count_total "${COUNT_FILE}")"
  c2="$(PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${SINK_DIR}"'/hierarchy.sh"
    : > "'"${COUNT_FILE}"'"
    hierarchy_mandatory_gate "$1" "PROJ" "{}" > /dev/null
  ' _ "${binding2}"; helper_spawn_count_total "${COUNT_FILE}")"
  [ "${c1}" -gt 0 ]
  [ "${c1}" = "${c2}" ]
}

# --- T024a: recognition — confirmed spawn-bound by T019a, fixed by T031a ---

_t024a_recognition_count() {
  local n_stories="$1" ROOT_DIR="${BATS_TEST_DIRNAME}/../../.."
  PATH="${SHIM_DIR}:${PATH}" bash -c '
    ROOT="'"${ROOT_DIR}"'"
    source "${ROOT}/scripts/bash/lib/output.sh"
    source "${ROOT}/scripts/bash/lib/cli.sh"
    source "${ROOT}/scripts/bash/sink/jira/client.sh"
    source "${ROOT}/scripts/bash/sink/jira/prefetch.sh"
    source "${ROOT}/scripts/bash/sink/jira/recognition.sh"
    _recognition_read() {
      printf "{\"gone\":false,\"marker\":{\"origin\":\"bridge\",\"story\":\"%s\",\"repo\":\"acme/app\",\"spec_slug\":\"001-billing\"},\"fields\":{\"summary\":\"S\",\"status\":{\"name\":\"Open\",\"statusCategory\":{\"key\":\"new\"}},\"labels\":[\"a\",\"b\",\"c\",\"d\",\"e\"],\"issuelinks\":[],\"subtasks\":[]}}" "$1"
    }
    : > "'"${COUNT_FILE}"'"
    n="$1"
    stories="["
    for ((i = 0; i < n; i++)); do
      id=$(printf "%016x" "$i")
      ((i > 0)) && stories+=","
      stories+="{\"local_id\":\"${id}\",\"marker\":{\"state\":\"bound\",\"id\":\"${id}\",\"ticket\":\"COMP-${i}\"}}"
    done
    stories+="]"
    spec_ref="{\"repo\":\"acme/app\",\"spec_slug\":\"001-billing\",\"folder\":\"specs/001-billing\"}"
    recognition_run "${stories}" "${spec_ref}" "COMP" "spec.md" > /dev/null
  ' _ "${n_stories}"
  helper_spawn_count_total "${COUNT_FILE}"
}

@test "T024a: recognition_run's per-story marginal jq cost is small and does not include a per-field loop (024, C1.3)" {
  local c1 c4 marginal
  c1="$(_t024a_recognition_count 1)"
  c4="$(_t024a_recognition_count 4)"
  marginal=$(( (c4 - c1) / 3 ))
  # Pre-024 this same "bound, fully-verified" path cost ~12 jq calls per
  # story (fields, origin, last_summary, current, status, status_category,
  # flagged, blockers, subtasks, last_checklist, entry assembly, keyed
  # merge) — T031a's consolidation collapses that to one call per story
  # (the read-and-verify sequence is still per-story by necessity: each
  # bound story names its OWN ticket to fetch).
  [ "${marginal}" -le 5 ]
}
