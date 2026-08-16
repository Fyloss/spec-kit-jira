#!/usr/bin/env bats
# T140 [027] — Budget assertions at scale, through seed.sh's own resume path
# (contract seed-cli-contract.md §6, C-14, C-15, C-19), using 024's
# PATH-interposed counting stand-ins. COUNTING RUNS AND TIMING RUNS MUST BE
# SEPARATE (research R4, spawn_count.bash's own header) — nothing here reads
# a duration.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  LIB_DIR="${ROOT}/scripts/bash/lib"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/seed_state.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/argv_size.bash"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  FEATURE_DIR="${WORK}/specs/001-add-payment-webhooks"
  mkdir -p "${FEATURE_DIR}"
  SPEC="${FEATURE_DIR}/spec.md"
  export SPEC_KIT_JIRA_REPO="local/repo"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-add-payment-webhooks"
}

teardown() {
  mock_stop 2> /dev/null || true
  rm -rf "${WORK}"
}

_routing() {
  jq -cn '{project:"PROJ", declared_type_specification:"Epic", declared_type_story:"Story", terminal_statuses_csv:""}'
}

# _seed_n_stories <n> — designators, spec.md, and record for N pinned story
# designators — no per-item process spawn (bash string concatenation only).
_seed_n_stories() {
  local n="$1" i
  local designators="[" spec="# Feature"$'\n'
  for ((i = 1; i <= n; i++)); do
    ((i > 1)) && designators+=","
    designators+="{\"role\":\"story\",\"form\":\"key\",\"key\":\"PROJ-${i}\",\"raw\":\"PROJ-${i}\",\"position\":$((i - 1))}"
    spec+=$'\n'"### User Story ${i} - S${i} (Priority: P1)"$'\n'"<!-- speckit-jira pin=PROJ-${i} -->"$'\n\n'"Body ${i}."$'\n'
  done
  designators+="]"
  printf '%s' "${spec}" > "${SPEC}"
  local doc
  doc="$(seed_state_compose "add-payment-webhooks" "${designators}" "" "$(_routing)" "[]")"
  seed_state_write "${SPEC}" "${doc}"
}

_seed_n_issues_json() {
  local n="$1" i issues="{"
  for ((i = 1; i <= n; i++)); do
    ((i > 1)) && issues+=","
    issues+="\"PROJ-${i}\":{\"summary\":\"S${i}\",\"description\":\"body ${i}\",\"status\":{\"name\":\"To Do\"},\"issuetype\":{\"name\":\"Story\"},\"project\":{\"key\":\"PROJ\"}}"
  done
  issues+="}"
  printf '%s' "${issues}"
}

@test "C-14/C-19 at scale: 100 designators, first gate-reach then resume, exactly 1 bulkfetch on resume, never a comment field" {
  _seed_n_stories 100
  local cfg
  cfg="$(mock_write_config "{\"issues\":$(_seed_n_issues_json 100)}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # First gate-reach: T100's one-way-read guarantee — zero requests.
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls)" ]

  # Resume: exactly ceil(100/100) = 1 bulkfetch, never a comment field.
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c '^POST /rest/api/3/issue/bulkfetch$')" -eq 1 ]
  local calls
  calls="$(mock_calls)"
  [[ "${calls}" != *"comment"* ]]
}

@test "C-14 at scale: 101 designators, resume issues exactly 2 bulkfetch requests, never one per issue" {
  _seed_n_stories 101
  local cfg
  cfg="$(mock_write_config "{\"issues\":$(_seed_n_issues_json 101)}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c '^POST /rest/api/3/issue/bulkfetch$')" -eq 2 ]
  # Never one GET per issue — no per-key fallback at this scale.
  [ "$(mock_calls | grep -cE '^GET .*/issue/[^/?]+\?')" -eq 0 ]
}

@test "no per-designator REQUEST spawn: 100 designators cost exactly ONE curl invocation on resume, measured independently of mock_calls" {
  # docs/11-process-budget.md's rule is about the REQUEST layer — the
  # bulkfetch body is built once and sent once — not about in-process jq
  # post-processing of the (already in-memory) response, which is the
  # existing, accepted per-key cost adoption_evaluate and pin_marker_validate
  # already carry from earlier phases. spawn_count.bash measures the curl
  # layer directly, independent of (and so a genuine second proof beside)
  # the mock's own calls.log count in the C-14/C-19 test above.
  _seed_n_stories 100
  local cfg
  cfg="$(mock_write_config "{\"issues\":$(_seed_n_issues_json 100)}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  local shim_dir="${BATS_TEST_TMPDIR}/spawn_shim" count_file="${BATS_TEST_TMPDIR}/spawn_count.log"
  helper_spawn_count_setup "${shim_dir}" "${count_file}"
  PATH="${shim_dir}:${PATH}" run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(helper_spawn_count_for "${count_file}" curl)" -eq 1 ]
}

@test "C-15 at scale: the 100-designator bulkfetch body reaches jira_request via a temp file, never argv" {
  _seed_n_stories 100
  local cfg
  cfg="$(mock_write_config "{\"issues\":$(_seed_n_issues_json 100)}")"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]

  local shim_dir="${BATS_TEST_TMPDIR}/argv_shim" report="${BATS_TEST_TMPDIR}/argv_report.log"
  helper_argv_size_setup "${shim_dir}" "${report}"
  PATH="${shim_dir}:${PATH}" run cmd_seed seed "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ ! -s "${report}" ]
}
