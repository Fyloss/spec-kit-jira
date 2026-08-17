#!/usr/bin/env bats
# T108 [029, Phase 9] — SC-003: the number of re-invocations of the naming
# step equals the number of questions the operator was actually shown, and
# never exceeds three. Each test below is one of the three documented
# chains, built one `run` at a time so the shape of the test itself proves
# the invariant: every re-invocation answers exactly the question the
# previous run posed, and the chain stops the run after nothing is posed.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/feature.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

select_team() {
  printf 'team: %s\n' "$1" > "${JIRA_CONFIG_DIR}/personal.yml"
}

boot() {
  local cfg
  cfg="$(mktemp)"
  printf '%s' "$1" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

no_question_posed() {
  [ "$(jq -r 'has("reuse_required") or has("reuse_issues_required") or has("confirmation_required")' <<< "$1")" != "true" ]
}

@test "SC-003: a complete answer costs exactly one re-invocation, preceded by the question (FR-029)" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n    hierarchy:\n      specification: Epic\n      story: Story\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot "{\"projects\":{\"IJT\":\"team\"},\"issues\":{\"IJT-40\":{\"summary\":\"Rework the export pipeline\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"},\"project\":{\"key\":\"IJT\"}}}}"

  # Run 1: the ordinary question. Zero writes.
  run cmd_feature feature IJT-40 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'

  # Run 2 — the ONE re-invocation SC-003 promises for this case: "reuse"
  # with no designator accepts the question's own proposal and completes.
  run cmd_feature feature IJT-40 --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  no_question_posed "$output"
  [ "$(jq -r '.ticket.action' <<< "$output")" = "adopted" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-40" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'
}

@test "SC-003: the cross-team question first costs two re-invocations, each preceded by a question (FR-025)" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n    hierarchy:\n      specification: Epic\n      story: Story\n'
    printf '  - key: WEX\n    hierarchy:\n      specification: Epic\n      story: Story\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
    printf '  - id: wex\n    project: WEX\n    folder_prefix: "wex-"\n    branch_pattern: "wex-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot "{\"projects\":{\"IJT\":\"team\",\"WEX\":\"team\"},\"issues\":{\"WEX-7\":{\"summary\":\"Rework the export pipeline\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Epic\"},\"status\":{\"name\":\"In Progress\"},\"project\":{\"key\":\"WEX\"}}}}"

  # Run 1: the shipped cross-team question, unchanged (FR-025 requires the
  # team question first, never merged with the reuse question).
  run cmd_feature feature WEX-7 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("confirmation_required")' <<< "$output")" = "true" ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" != "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'

  # Run 2 — the FIRST re-invocation: answers the team question and, because
  # "reuse" was still unanswered, is shown the reuse question instead of
  # completing.
  run cmd_feature feature WEX-7 --use-team wex --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]
  [ "$(jq -r 'has("confirmation_required")' <<< "$output")" != "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'

  # Run 3 — the SECOND and last re-invocation SC-003 promises for this
  # case: both questions answered, the run completes.
  run cmd_feature feature WEX-7 --use-team wex --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  no_question_posed "$output"
  [ "$(jq -r '.ticket.action' <<< "$output")" = "adopted" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "WEX-7" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'
}

@test "SC-003: cross-team plus no declared hierarchy compounds to three re-invocations, each preceded by a question (FR-025, FR-029, FR-035)" {
  select_team ijt
  {
    printf 'projects:\n  - key: IJT\n    hierarchy:\n      specification: Epic\n      story: Story\n'
    printf '  - key: WEX\n'
    printf 'routing_default: IJT\nteams:\n  - id: ijt\n    project: IJT\n    folder_prefix: "ijt-"\n    branch_pattern: "ijt-<ID>/<FEATURE_NAME>"\n'
    printf '  - id: wex\n    project: WEX\n    folder_prefix: "wex-"\n    branch_pattern: "wex-<ID>/<FEATURE_NAME>"\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  boot "{\"projects\":{\"IJT\":\"team\",\"WEX\":\"team\"},\"issues\":{\"WEX-9\":{\"summary\":\"Legacy importer\",\"description\":\"Body text\",\"issuetype\":{\"name\":\"Task\"},\"status\":{\"name\":\"To Do\"},\"project\":{\"key\":\"WEX\"}}}}"

  # Run 1: the cross-team question.
  run cmd_feature feature WEX-9 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("confirmation_required")' <<< "$output")" = "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'

  # Run 2 — first re-invocation: team answered, reuse still unanswered ->
  # the reuse question.
  run cmd_feature feature WEX-9 --use-team wex --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'

  # Run 3 — second re-invocation: "reuse" answered, but WEX declares no
  # hierarchy, so no proposal exists to accept (FR-035) -> the which-issues
  # follow-up, not completion.
  run cmd_feature feature WEX-9 --use-team wex --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_issues_required")' <<< "$output")" = "true" ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" != "true" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'

  # Run 4 — the THIRD and last re-invocation SC-003 promises for the worst
  # case: explicit designators answer the which-issues follow-up and the
  # run completes.
  run cmd_feature feature --use-team wex --story WEX-9 --json "invoice export"
  [ "$status" -eq 0 ]
  no_question_posed "$output"
  [ "$(jq -r '.ticket.action' <<< "$output")" = "adopted" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "WEX-9" ]
  ! mock_calls | grep -qE 'POST /rest/api/3/issue$|PUT'
}
