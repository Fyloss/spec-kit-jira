#!/usr/bin/env bats
# T060 — the configuration parser's per-line helpers do not fork (FR-018, FR-041;
# research R8).
#
# `$( … )` around a shell function forks a subshell and never calls `exec`, so a
# PATH-interposed counting stand-in cannot see it. On the motivating machine the
# parser performed 26 000-35 000 such forks for an 8 658-line config.local.yml —
# ~25 s of the phase's 31 s — while the spawn counter reported a few hundred
# external invocations and was read as evidence that forking was not the problem.
#
# FR-041 therefore requires this property to be asserted **statically**, at the
# call sites, rather than by a runtime counter: an in-process counter is lost to
# the very subshell it would count (the FR-036 defect), and a file-backed one
# would cost a write per call — 34 600 of them — distorting what it measures, as
# research R4 records the PATH shim already doing to wall-clock.
#
# The second test pins the parser's output through the refactor. The conversion
# is a change of calling convention with a null observable diff; if a byte moves,
# it is a bug, not a trade-off.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONFIG_SH="${ROOT}/scripts/bash/lib/config.sh"
}

@test "T060: the per-line helpers are never invoked through command substitution (FR-018, FR-041)" {
  # Each of these is called once per configuration line, per scalar, or per key.
  # A `$( … )` around any of them is one fork per occurrence of that unit.
  local pattern='\$\((_cfg_strip_inline_comment|_cfg_scalar_json|_cfg_json_encode|_cfg_decode_escapes)\b'
  run grep -nE "${pattern}" "${CONFIG_SH}"
  # grep exits 1 when it finds nothing, which is the state this asserts.
  if [ "${status}" -eq 0 ]; then
    printf 'command-substitution call sites still present:\n%s\n' "${output}" >&2
    return 1
  fi
}

@test "T060: the parser's output is unchanged by the conversion (null observable diff)" {
  local f="${BATS_TEST_TMPDIR}/cfg.yml"
  cat > "${f}" << 'YAML'
version_compat: ">=1.0"   # trailing comment
routing_default: PROJ
"quoted: key": "value with \"escape\" and \\ backslash"
flags:
  enabled: true
  disabled: false
  absent: null
  empty_map: {}
  empty_list: []
projects:
  - key: "PROJ1"
    style: "company_managed"
  - key: "PROJ2"
plain_seq:
  - alpha
  - "beta with # hash"
YAML

  run bash -c '
    source "'"${ROOT}"'/scripts/bash/lib/output.sh"
    source "'"${ROOT}"'/scripts/bash/lib/config.sh"
    config_yaml_to_json "$1"
  ' _ "${f}"

  [ "${status}" -eq 0 ]
  # Pinned from the pre-conversion implementation. Exercises every path the
  # conversion touches: an inline comment stripped from a value, a quoted key
  # carrying both escape forms, quoted and bare scalars, the three literals,
  # both empty flow collections, a mapping sequence, and a plain sequence whose
  # item contains a `#` that is NOT a comment.
  [ "${output}" = '{"flags":{"absent":null,"disabled":false,"empty_list":[],"empty_map":{},"enabled":true},"plain_seq":["alpha","beta with # hash"],"projects":[{"key":"PROJ1","style":"company_managed"},{"key":"PROJ2"}],"quoted: key":"value with \"escape\" and \\ backslash","routing_default":"PROJ","version_compat":">=1.0"}' ]
}
