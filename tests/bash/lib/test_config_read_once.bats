#!/usr/bin/env bats
# T036 — config-line spawn assertion (contracts/spawn-budget.md C1.2/C1.4).
# `config_yaml_to_json`'s two per-line jq calls (one to JSON-encode each key,
# one to JSON-encode each string scalar — up to 2N spawns for an N-line file,
# ~6 ms/line unmanaged hardware per research) are now `_cfg_json_encode`, a
# native encoder (the same algorithm as engine/markdown.sh's
# `_md_json_escape`, duplicated rather than sourced across the lib->engine
# layer boundary).
#
# T033-T035/T036a/T036b (read-once orchestration, error parity, the
# hooks-disabled self-write, precedence/defaulting parity, containment) are
# NOT added here — `config_load` already reads each file exactly once per
# call (one `config_yaml_to_json` per path in `commands/reconcile.sh`), and
# changing that orchestration was out of scope for this pass: only the
# per-line PARSING cost was fixed. See tasks.md Phase 6 notes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  HELPERS="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${HELPERS}/spawn_count.bash"
  SHIM_DIR="${BATS_TMPDIR}/cfg_spawn_shims_$$"
  COUNT_FILE="${BATS_TMPDIR}/cfg_spawn_count_$$.log"
  helper_spawn_count_setup "${SHIM_DIR}" "${COUNT_FILE}"
}

teardown() {
  rm -rf "${SHIM_DIR}" "${COUNT_FILE}"
}

_gen_config() {
  local n="$1" i out="version_compat: \">=1.0\""$'\n'"routing_default: PROJ"$'\n'"projects:"$'\n'
  for ((i = 0; i < n; i++)); do
    out+="  - key: \"PROJ${i}\""$'\n'
    out+="    style: \"company_managed\""$'\n'
  done
  printf '%s' "${out}"
}

_spawn_count_for_config() {
  local content="$1" f n
  f="${BATS_TMPDIR}/cfg_spawn_input_$$.yml"
  printf '%s' "${content}" > "${f}"
  PATH="${SHIM_DIR}:${PATH}" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    : > "'"${COUNT_FILE}"'"
    config_yaml_to_json "$1" > /dev/null
  ' _ "${f}"
  rm -f "${f}"
  helper_spawn_count_total "${COUNT_FILE}"
}

@test "T036: config_yaml_to_json spawns a bounded, non-growing count as project (line) count doubles (C1.2)" {
  local c20 c40
  c20="$(_spawn_count_for_config "$(_gen_config 20)")"
  c40="$(_spawn_count_for_config "$(_gen_config 40)")"
  [ "${c20}" -gt 0 ]
  [ "${c40}" = "${c20}" ]
}

@test "T036: config_yaml_to_json reaches the same floor on a near-empty file (C1.4)" {
  local c0 c20
  c0="$(_spawn_count_for_config "version_compat: \">=1.0\"")"
  c20="$(_spawn_count_for_config "$(_gen_config 20)")"
  [ "${c0}" = "${c20}" ]
}

@test "_cfg_json_encode matches jq's --arg encoding for control characters, quotes, and backslashes" {
  ROOT_DIR="${BATS_TEST_DIRNAME}/../../.."
  local got want
  # 024, T060: _cfg_json_encode returns through _CFG_JSON rather than stdout —
  # it is called once per key and once per scalar, so capturing it with
  # `$( … )` forked a subshell per value (research R8). The encoding it
  # produces is unchanged, which is what this test asserts; only how the caller
  # receives it moved.
  got="$(bash -c '
    source "'"${ROOT_DIR}"'/scripts/bash/lib/config.sh"
    _cfg_json_encode "$1"
    printf "%s" "${_CFG_JSON}"
  ' _ $'a "quoted" \\ value\twith\ttabs and \x01 control')"
  want="$(jq -Rn --arg v $'a "quoted" \\ value\twith\ttabs and \x01 control' '$v')"
  [ "${got}" = "${want}" ]
}
