#!/usr/bin/env bats
# T086 — guard: the prefetch field union (contracts/recognition-prefetch.md
# §5) must stay a superset of every field either reader ever requests. A
# field added to a reader and forgotten here silently drops from the result
# on a prefetch HIT only — the fall-through GET still supplies it, and the
# mock's GET-vs-bulkfetch field-filtering asymmetry hides the divergence.
# This is how Flagged was lost until T057 (US4 checkpoint). Parses the
# readers' own literal field lists out of recognition.sh rather than
# hardcoding a second copy, so a future field addition there fails this
# test instead of silently narrowing prefetch's coverage.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/prefetch.sh"
}

@test "the prefetch field union is a superset of every field either reader requests (T086)" {
  local recognition_file="${SINK_DIR}/recognition.sh"

  local base_fields story_extra parent_fields
  base_fields="$(grep -oE 'fields_param="[^"]+"' "${recognition_file}" | head -1 | sed -E 's/fields_param="([^"]+)"/\1/')"
  story_extra="$(grep -oE 'read_extra="[^"]+"' "${recognition_file}" | head -1 | sed -E 's/read_extra="([^"]+)"/\1/')"
  parent_fields="$(grep -oE 'prefetch_get "\$\{key\}" "[^"]+"' "${recognition_file}" | tail -1 | sed -E 's/.*"([^"]+)"$/\1/')"

  [ -n "${base_fields}" ]
  [ -n "${story_extra}" ]
  [ -n "${parent_fields}" ]

  local -A union_set=()
  local -a u_arr
  IFS=',' read -r -a u_arr <<< "${_PREFETCH_FIELDS}"
  local u
  for u in "${u_arr[@]}"; do union_set["${u}"]=1; done

  local -a required=()
  local -a b_arr
  IFS=',' read -r -a b_arr <<< "${base_fields},${story_extra}"
  required+=("${b_arr[@]}")
  local -a p_arr
  IFS=',' read -r -a p_arr <<< "${parent_fields}"
  required+=("${p_arr[@]}")

  local -a missing=()
  local f
  for f in "${required[@]}"; do
    [[ -n "${union_set[${f}]:-}" ]] || missing+=("${f}")
  done

  if ((${#missing[@]} > 0)); then
    printf 'field(s) missing from _PREFETCH_FIELDS: %s\n' "${missing[*]}" >&2
    return 1
  fi
}
