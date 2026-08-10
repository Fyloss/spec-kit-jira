#!/usr/bin/env bats
# T070/T072/T074/T076 [Phase 5, US3, 022] — the task_mirror config ceremony
# (contracts/task-mirror-config.md). T070 covers the managed-region write's
# five outcomes as a pure unit (mirrors test_config_field_defaults.bats);
# T072/T074/T076 cover the ceremony's question, no-re-ask, hand-edit
# preservation, and FR-012 remedy end to end through cmd_config.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-config"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  DIR="$(mktemp -d)"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
}

teardown() {
  mock_stop
  rm -rf "${DIR}"
}

# --- T070 — the managed-region write: five outcomes (contract §3) ----------

@test "T070 [022] — a non-empty map creates the region in an absent file" {
  local path="${DIR}/config.yml"
  run _config_task_mirror_write "${path}" '{"COMP":"checklist"}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "created" ]
  grep -qF 'spec-kit-jira:task_mirror:begin' "${path}"
  grep -qF '"COMP": "checklist"' "${path}"
}

@test "T070 [022] — an empty map with no pre-existing region is left completely untouched (inert, FR-002/FR-011)" {
  local path="${DIR}/config.yml"
  printf 'projects:\n  - key: COMP\nrouting_default: COMP\n' > "${path}"
  local before; before="$(cat "${path}")"
  run _config_task_mirror_write "${path}" '{}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "inert" ]
  [ "$(cat "${path}")" = "${before}" ]
}

@test "T070 [022] — a second run with the same map reports unchanged and leaves the file byte-identical (FR-009)" {
  local path="${DIR}/config.yml"
  _config_task_mirror_write "${path}" '{"COMP":"checklist"}' "false" > /dev/null
  cp "${path}" "${DIR}/before"
  run _config_task_mirror_write "${path}" '{"COMP":"checklist"}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
  run cmp "${DIR}/before" "${path}"
  [ "$status" -eq 0 ]
}

@test "T070 [022] — a changed map rewrites only the region, preserving bytes outside it" {
  local path="${DIR}/config.yml"
  printf '# a comment the operator wrote\nprojects:\n  - key: COMP\nrouting_default: COMP\n' > "${path}"
  _config_task_mirror_write "${path}" '{"COMP":"subtask"}' "false" > /dev/null
  run _config_task_mirror_write "${path}" '{"COMP":"checklist"}' "false"
  [ "$status" -eq 0 ]
  [ "$output" = "written" ]
  grep -qF '# a comment the operator wrote' "${path}"
  grep -qF '"checklist"' "${path}"
  ! grep -qF '"subtask"' "${path}"
}

@test "T070 [022] — malformed markers refuse with exit 4 and zero writes" {
  local path="${DIR}/config.yml"
  printf '# --- spec-kit-jira:task_mirror:begin ---\nstray\n' > "${path}"
  local before; before="$(cat "${path}")"
  run _config_task_mirror_write "${path}" '{"COMP":"checklist"}' "false"
  [ "$status" -eq 4 ]
  [[ "$output" == *"refused" ]]
  [ "$(cat "${path}")" = "${before}" ]
}

# --- T072 — the closed question, no re-ask, byte-identical rewrite ---------

@test "T072 [022] — the closed question is reported when nothing is recorded (FR-008), and the per-project effect line says so (FR-011/FR-013)" {
  local work="${DIR}/repo"; mkdir -p "${work}"; cp -R "${FIXTURE}/.specify" "${work}/.specify"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"config: project COMP: how should tasks be mirrored — choose one of: subtask, checklist (answer with --task-mirror 'COMP=checklist')."* ]]
  [[ "$stderr" == *"Task mirror: COMP — not recorded; today's behaviour applies"* ]]
  [ "$(jq -r '.effects.task_mirror.status' <<< "$output")" = "inert" ]
}

@test "T072 [022] — answering the question records it, and a re-run neither re-asks nor rewrites the file (FR-009)" {
  local work="${DIR}/repo"; mkdir -p "${work}"; cp -R "${FIXTURE}/.specify" "${work}/.specify"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  run --separate-stderr cmd_config config --child-type COMP=Story --task-mirror COMP=checklist --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Task mirror: COMP — checklist (recorded)"* ]]
  cp "${JIRA_CONFIG_DIR}/config.yml" "${DIR}/after-first.yml"

  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"how should tasks be mirrored"* ]]
  [[ "$stderr" == *"Task mirror: COMP — checklist (unchanged)"* ]]
  run cmp "${DIR}/after-first.yml" "${JIRA_CONFIG_DIR}/config.yml"
  [ "$status" -eq 0 ]
}

# --- T074 — a hand-written entry the ceremony did not ask about this run ---

@test "T074 [022] — a hand-written entry inside the region for a project this run did not touch is re-emitted unchanged (FR-010)" {
  local work="${DIR}/repo"; mkdir -p "${work}"; cp -R "${FIXTURE}/.specify" "${work}/.specify"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  # Insert a second declared project (TEAM) right after the projects: key,
  # so it stays inside the projects[] sequence — a YAML mapping document
  # cannot carry a stray list item appended after routing_default/privacy.
  awk '{print} /^projects:/ && !done {print "  - key: TEAM"; done=1}' \
    "${JIRA_CONFIG_DIR}/config.yml" > "${JIRA_CONFIG_DIR}/config.yml.new"
  mv "${JIRA_CONFIG_DIR}/config.yml.new" "${JIRA_CONFIG_DIR}/config.yml"
  printf 'task_mirror:\n  TEAM: checklist\n' >> "${JIRA_CONFIG_DIR}/config.yml"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  # Only COMP is named this run — TEAM is a declared project the ceremony did
  # not process, so its hand-recorded entry must survive untouched (FR-010).
  run --separate-stderr cmd_config config COMP --child-type COMP=Story --task-mirror COMP=subtask --json
  [ "$status" -eq 0 ]
  grep -qF '"TEAM": "checklist"' "${JIRA_CONFIG_DIR}/config.yml"
  grep -qF '"COMP": "subtask"' "${JIRA_CONFIG_DIR}/config.yml"
}

# --- T076 — the FR-012 remedy at config time --------------------------------

@test "T076 [022] — 'subtask' recorded with no resolvable sub-task type is reported at config time with its remedy" {
  local work="${DIR}/repo"; mkdir -p "${work}"; cp -R "${FIXTURE}/.specify" "${work}/.specify"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  printf 'task_mirror:\n  COMP: subtask\n' >> "${JIRA_CONFIG_DIR}/config.yml"
  local cfg; cfg="$(mock_write_config '{"projects":{"COMP":"company"},"issueTypeStyle":{"COMP":"notask"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run --separate-stderr cmd_config config --child-type COMP=Story --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"config: project COMP: task_mirror is 'subtask' but no sub-task issue type is resolved for this project — declare hierarchy.task, or switch with --task-mirror 'COMP=checklist'"* ]]
  [[ "$stderr" == *"Task mirror: COMP — subtask (unchanged)"* ]]
}
