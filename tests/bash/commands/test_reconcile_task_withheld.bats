#!/usr/bin/env bats
# T056 [US6] — a declared `task` role whose type carries an unsatisfiable
# or undefaultable required field must never make a run worse than not
# declaring the role at all (FR-036, FR-037): the specification and story
# tiers still mirror exactly as they would with no `task` role; the task
# tier alone is withheld — zero sub-task writes — with each unmet field
# named once, carrying a `--field-default` remedy only when the field is
# actually defaultable, and the run summary states the tier as withheld,
# distinctly from a tier with nothing to mirror.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-subtask-mandatory-field"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"
  TASKS="${WORK}/specs/001-feature/tasks.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111 2222222222222222"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
  local cfg; cfg="$(mock_write_config '{"projects":{"TASKM":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

@test "T056 — the specification and story tiers mirror exactly as they would with no task role declared" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  run mock_calls
  local posts; posts="$(grep -c '^POST /rest/api/3/issue$' <<< "$output")"
  [ "$posts" -eq 2 ]
}

@test "T056 — zero sub-task writes: no issue is created at the task role's own issue type" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  [ "$(mock_issue_field TASKM-1 '.fields.issuetype.id' 2> /dev/null)" != "40705" ]
  [ "$(mock_issue_field TASKM-2 '.fields.issuetype.id' 2> /dev/null)" != "40705" ]
  run mock_calls
  [ "$(grep -c '^POST /rest/api/3/issue$' <<< "$output")" -eq 2 ]
}

@test "T056 — each unmet field is named once, the defaultable one carrying its --field-default remedy, the other its reason and no remedy" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]

  local warnings; warnings="$(jq -c '.warnings' <<< "$output")"
  [ "$(jq -r '. | join("\n")' <<< "${warnings}" | grep -c 'Definition of Done')" -eq 1 ]
  [ "$(jq -r '. | join("\n")' <<< "${warnings}" | grep -c 'Affected Teams')" -eq 1 ]
  [ "$(jq -r '. | join("\n")' <<< "${warnings}" | grep -c -- '--field-default')" -eq 1 ]
  [[ "$(jq -r '. | join("\n")' <<< "${warnings}")" != *"customfield_"* ]]
  [[ "$(jq -r '. | join("\n")' <<< "${warnings}")" == *"a list of values cannot be expressed as a single recorded value"* ]]
}

@test "T056 — the summary states the tier as withheld, distinctly from a tier with nothing to mirror" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local withheld_output="$output"
  [[ "$(jq -r '.warnings | join("\n")' <<< "${withheld_output}")" == *"withheld"* ]]

  # A second run, against the same project, of a specification whose
  # tasks.md carries no task attributed to any story at all — the task
  # tier has nothing to mirror, which is not the same thing as a tier
  # whose mandatory fields could not be satisfied, and must not be
  # reported the same way.
  cat > "${TASKS}" << 'MD'
# Tasks: Task Tier Mandatory Field Demo

## Phase 1: Setup

- [ ] T001 Do the setup work
MD
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.warnings // [] | join("\n")' <<< "$output")" != *"withheld"* ]]
}

@test "T056 — through the real dispatcher entry point, a two-unmet-field withholding does not abort under set -e" {
  # Regression test: cmd_reconcile's per-field warning loop used to
  # post-increment its counter with `((i++))`, whose exit status reflects
  # the PRE-increment value — 0, hence falsy — on the first pass. Called
  # directly (as the tests above do via `run cmd_reconcile ...`), this
  # never surfaces, because bats' `run` does not put the function under
  # `set -e`. The real entry point (scripts/bash/spec-kit-jira.sh) does run
  # under `set -euo pipefail`, so the loop died silently — exit 1, zero
  # output — right after the first of the two unmet fields, never reaching
  # the second field's warning or the closing "withheld" summary line.
  run bash "${ROOT}/scripts/bash/spec-kit-jira.sh" reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local warnings; warnings="$(jq -c '.warnings' <<< "$output")"
  [ "$(jq -r '. | join("\n")' <<< "${warnings}" | grep -c 'Definition of Done')" -eq 1 ]
  [ "$(jq -r '. | join("\n")' <<< "${warnings}" | grep -c 'Affected Teams')" -eq 1 ]
  [[ "$(jq -r '.warnings | join("\n")' <<< "$output")" == *"withheld"* ]]
}

@test "T057 — tasks.md is unchanged after a withheld run — no durable identifier is recorded for a withheld task" {
  local before; before="$(cat "${TASKS}")"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local after; after="$(cat "${TASKS}")"
  [ "${before}" = "${after}" ]
  run grep -c 'speckit-jira task=' "${TASKS}"
  [ "$output" -eq 0 ]
}
