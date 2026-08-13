#!/usr/bin/env bats
# T074/T076 [Phase 6, US4] — the `phase_status_map` schema (023, contracts/
# role-lifecycle-config.md §2/§3): two accepted shapes — every key a
# lifecycle event (role-blind, routes wholesale to the `story` role,
# FR-020), or every key a hierarchy role (specification/story/task). The
# discrimination is on the CLOSED, DISJOINT key sets alone; mixing the two
# vocabularies, or naming a key from neither, refuses at config load
# (EXIT_CONFIG, zero requests) before recognition, planning or any Jira
# call.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/config.sh"
  DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${DIR}"
}

# --- Discrimination: empty, all-events, all-roles (contract §2) ------------

@test "an empty phase_status_map is valid under either shape" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map: {}
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "a role-blind (all lifecycle events) phase_status_map is valid" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      after_specify: "To Do"
      after_plan: "In Progress"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

@test "a per-role (all hierarchy roles) phase_status_map is valid" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      specification:
        after_plan: "Building"
      story:
        after_plan: "In Progress"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 0 ]
}

# --- The seven validation messages (contract §3) ---------------------------

@test "M1: a non-mapping phase_status_map refuses, naming both accepted shapes" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map: "To Do"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *"projects[0].phase_status_map must be a mapping of lifecycle-event name to status name, or of hierarchy role to that role's own mapping"* ]]
}

@test "M2: a legacy-shape value that is empty refuses, naming the key" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      after_specify: ""
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map.after_specify must be a non-empty status name'* ]]
}

@test "M3: a per-role value that is not itself a mapping refuses, naming the role" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      story: "In Progress"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map.story must be a mapping of lifecycle-event name to status name'* ]]
}

@test "M4: an unknown lifecycle event inside a per-role mapping refuses, naming role and event" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      story:
        after_typo: "In Progress"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map.story declares unknown lifecycle event `after_typo`'* ]]
}

@test "M5: an empty status value inside a per-role mapping refuses, naming role and event" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      story:
        after_plan: ""
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map.story.after_plan must be a non-empty status name'* ]]
}

@test "M6: mixing a lifecycle-event key and a hierarchy-role key refuses" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      after_plan: "In Progress"
      story:
        after_plan: "In Progress"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map mixes lifecycle events and hierarchy roles; declare either one mapping for the story role, or one mapping per role (specification, story, task)'* ]]
}

@test "M7: a key that is neither a lifecycle event nor a hierarchy role refuses, naming both closed sets" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      epic:
        after_plan: "In Progress"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map declares unknown key `epic`; the lifecycle events are after_specify, after_clarify, after_plan, after_tasks, after_implement, after_analyze and the roles are specification, story, task'* ]]
}

@test "before_specify is never an accepted phase_status_map key (M7 wording)" {
  cat > "${DIR}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      before_specify: "Backlog"
routing_default: PROJ
YAML
  JIRA_CONFIG_DIR="${DIR}" run config_load
  [ "$status" -eq 4 ]
  [[ "$output" == *'projects[0].phase_status_map declares unknown key `before_specify`'* ]]
}

# --- B5 (023, T153, spawn-budget.md §4): declaring more roles costs no more
# process spawns — the whole phase_status_map, however many roles it names,
# is validated inside the ONE jq program config_load already runs over the
# whole document (_cfg_schema_errors), never a per-role bash-level spawn. ---

@test "B5 -- config_load's own process-spawn count is unchanged by declaring three roles instead of one" {
  local helpers="${ROOT}/tests/bash/helpers"
  # shellcheck source=/dev/null
  source "${helpers}/spawn_count.bash"
  local shim_dir="${BATS_TMPDIR}/aw_config_psm_shims_$$"
  local count_file_1="${BATS_TMPDIR}/aw_config_psm_count1_$$.log"
  local count_file_3="${BATS_TMPDIR}/aw_config_psm_count3_$$.log"

  local dir1="${DIR}/one-role"
  local dir3="${DIR}/three-roles"
  mkdir -p "${dir1}" "${dir3}"

  cat > "${dir1}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      story:
        after_specify: "To Do"
        after_plan: "In Progress"
routing_default: PROJ
YAML

  cat > "${dir3}/config.yml" << 'YAML'
projects:
  - key: PROJ
    style: company_managed
    phase_status_map:
      specification:
        after_specify: "To Do"
        after_plan: "Building"
      story:
        after_specify: "To Do"
        after_plan: "In Progress"
      task:
        after_plan: "In Progress"
routing_default: PROJ
YAML

  local stub='
    source "'"${LIB_DIR}"'/config.sh"
    JIRA_CONFIG_DIR="$1" config_load > /dev/null
  '
  helper_spawn_count_setup "${shim_dir}" "${count_file_1}"
  PATH="${shim_dir}:${PATH}" bash -c "${stub}" _ "${dir1}"
  helper_spawn_count_setup "${shim_dir}" "${count_file_3}"
  PATH="${shim_dir}:${PATH}" bash -c "${stub}" _ "${dir3}"

  local jq1 jq3
  jq1="$(helper_spawn_count_for "${count_file_1}" jq)"
  jq3="$(helper_spawn_count_for "${count_file_3}" jq)"
  [ "${jq1}" -gt 0 ]
  [ "${jq3}" = "${jq1}" ]

  rm -rf "${shim_dir}" "${count_file_1}" "${count_file_3}"
}
