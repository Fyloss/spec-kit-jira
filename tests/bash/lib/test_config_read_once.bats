#!/usr/bin/env bats
# T036 — config-line spawn assertion (contracts/spawn-budget.md C1.2/C1.4).
# `config_yaml_to_json`'s two per-line jq calls (one to JSON-encode each key,
# one to JSON-encode each string scalar — up to 2N spawns for an N-line file,
# ~6 ms/line unmanaged hardware per research) are now `_cfg_json_encode`, a
# native encoder (the same algorithm as engine/markdown.sh's
# `_md_json_escape`, duplicated rather than sourced across the lib->engine
# layer boundary).
#
# T033 (2026-08-11) — `config.local.yml` is read and parsed TWICE per run:
# `config_load` (this file) for `.overrides`, `_reconcile_local_binding_for`
# (commands/reconcile.sh) for `.resolved_ids`, for the identical
# (project-key, config-dir) pair. "Source" means a distinct file path
# (FR-009 as amended), so this is the decisive case T037 did not satisfy.
# Uses `config_yaml_parse_count` (T059), the counting stand-in for file
# reads — a cache HIT never increments it, so it counts what actually costs
# (the parse), not how many callers asked.
#
# T034/T035/T036a/T036b (2026-08-11) — error parity, the hooks-disabled
# self-write, precedence/defaulting parity, and containment, all against the
# cache T057 added.

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

@test "T033: config.local.yml is opened and parsed at most once per run (FR-009, FR-038)" {
  ROOT2="${ROOT}"
  run bash -c '
    source "'"${ROOT2}"'/scripts/bash/commands/reconcile.sh"
    config_yaml_cache_prime
    FIXTURE="'"${ROOT2}"'/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
    config_load "${FIXTURE}" > /dev/null
    _reconcile_local_binding_for "COMP" "${FIXTURE}" > /dev/null
    printf "count=%s" "$(config_yaml_parse_count "${FIXTURE}/config.local.yml")"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == "count=1" ]]
}

@test "T033: an unprimed cache changes nothing — every call still parses (today's behaviour, unaffected)" {
  ROOT2="${ROOT}"
  run bash -c '
    source "'"${ROOT2}"'/scripts/bash/commands/reconcile.sh"
    FIXTURE="'"${ROOT2}"'/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
    a="$(config_load "${FIXTURE}")"
    b="$(_reconcile_local_binding_for "COMP" "${FIXTURE}")"
    [ -n "${a}" ] && [ -n "${b}" ] && printf "ok"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" = "ok" ]
}

@test "T034: a malformed source is never cached — every call reports the identical error (FR-012)" {
  ROOT2="${ROOT}"
  run bash -c '
    source "'"${ROOT2}"'/scripts/bash/commands/reconcile.sh"
    config_yaml_cache_prime
    DIR="'"${BATS_TEST_TMPDIR}"'/malformed"
    mkdir -p "${DIR}"
    printf "resolved_ids:\n  JET:\n    this line has no delimiter\n" > "${DIR}/bad.yml"
    rc1=0; err1="$(config_yaml_to_json "${DIR}/bad.yml" 2>&1 1>/dev/null)" || rc1=$?
    rc2=0; err2="$(config_yaml_to_json "${DIR}/bad.yml" 2>&1 1>/dev/null)" || rc2=$?
    same="no"; [ "${err1}" = "${err2}" ] && same="yes"
    printf "rc1=%s rc2=%s same=%s" "${rc1}" "${rc2}" "${same}"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == "rc1=4 rc2=4 same=yes" ]]
}

@test "T034: an absent config.local.yml bypasses the cache entirely, cache primed or not (FR-012)" {
  ROOT2="${ROOT}"
  run bash -c '
    source "'"${ROOT2}"'/scripts/bash/commands/reconcile.sh"
    config_yaml_cache_prime
    DIR="'"${BATS_TEST_TMPDIR}"'/neverbound"
    mkdir -p "${DIR}"
    rc=0
    _reconcile_local_binding_for "COMP" "${DIR}" > /dev/null || rc=$?
    printf "rc=%s" "${rc}"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" = "rc=2" ]
}

# T035 RETIRED by 034 — "a self-write in this process is reflected by a later
# read, not the pre-write cache entry (FR-013)".
#
# The behaviour is not merely untested now; it has no producer. That test drove
# the cache through `config_hooks_disabled_add`, which was the ONLY code path in
# either port that wrote a config source from inside a running process. 034
# retired the operator disable record along with the rest of the hook-registry
# reader, so the last in-process writer is gone — and with it
# `config_yaml_cache_invalidate`, whose sole caller it was.
#
# Both the helper and this test were removed together. Re-introducing an
# in-process config write means re-introducing the invalidation AND this test:
# the cache is primed once per run, so a writer that does not invalidate would
# serve a later read its own pre-write answer.

@test "T036a: the team/local merge answer is identical whether the cache is warm or cold (FR-011)" {
  ROOT2="${ROOT}"
  run bash -c '
    source "'"${ROOT2}"'/scripts/bash/commands/reconcile.sh"
    config_yaml_cache_prime
    FIXTURE="'"${ROOT2}"'/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
    cfg="$(config_load "${FIXTURE}")"
    printf "routing_default=%s " "$(jq -r ".routing_default" <<< "${cfg}")"
    binding="$(_reconcile_local_binding_for "COMP" "${FIXTURE}")"
    printf "child_type=%s " "$(jq -r ".child_type.id" <<< "${binding}")"
    cfg2="$(config_load "${FIXTURE}")"
    same="no"; [ "${cfg}" = "${cfg2}" ] && same="yes"
    printf "same=%s" "${same}"
  '
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"routing_default=COMP "* ]]
  [[ "${output}" == *"child_type=10004 "* ]]
  [[ "${output}" == *"same=yes"* ]]
}

@test "T036b: a credential-shaped value is never written to the cache file, even on an otherwise-successful parse (FR-014, Constitution IV)" {
  ROOT2="${ROOT}"
  run bash -c '
    source "'"${ROOT2}"'/scripts/bash/lib/config.sh"
    config_yaml_cache_prime
    DIR="'"${BATS_TEST_TMPDIR}"'/leaky"
    mkdir -p "${DIR}"
    printf "resolved_ids:\n  JET:\n    token: \"ATATT3xFfGF0superSecretValue\"\n" > "${DIR}/config.local.yml"
    config_yaml_to_json "${DIR}/config.local.yml" > /dev/null
    hits="$(grep -rl "ATATT3xFfGF0superSecretValue" "${_CFG_YAML_CACHE_DIR}" 2>/dev/null | wc -l | tr -d " ")"
    printf "hits=%s" "${hits}"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" = "hits=0" ]
}

@test "T036b: the resolved config never touches disk anywhere else, and holds no credential material when it does cache (FR-014)" {
  ROOT2="${ROOT}"
  run env JIRA_API_TOKEN="ATATT3xFfGF0notInAnyConfigFile" bash -c '
    source "'"${ROOT2}"'/scripts/bash/commands/reconcile.sh"
    config_yaml_cache_prime
    FIXTURE="'"${ROOT2}"'/tests/conformance/fixtures/repo-with-reconcile-binding/.specify/jira"
    config_load "${FIXTURE}" > /dev/null
    _reconcile_local_binding_for "COMP" "${FIXTURE}" > /dev/null
    hits="$(grep -rl "ATATT3xFfGF0notInAnyConfigFile" "${_CFG_YAML_CACHE_DIR}" 2>/dev/null | wc -l | tr -d " ")"
    printf "hits=%s" "${hits}"
  '
  [ "${status}" -eq 0 ]
  [ "${output}" = "hits=0" ]
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
