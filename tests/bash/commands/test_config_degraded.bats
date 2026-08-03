#!/usr/bin/env bats
# T023 [US2] — Degraded mode: loud, provisional, write-free (FR-008/FR-009).
#
# The trigger is tested BEFORE any Jira call and fires ONLY when
# SPEC_KIT_JIRA_BASE_URL is unset/empty or the token resolves through none of
# the three rungs. A degraded run exits 0 with exactly one warning naming the
# missing variables, proposes the distinct `<prefix>-<number>/…` branch prefixes
# as provisional team candidates, prints re-run guidance, and writes NOTHING —
# config.local.yml is byte-identical to before. Defined-but-wrong credentials
# keep the fail-closed auth/network exits and never degrade (research §4).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_NO_SLEEP=1
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/.specify/jira"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  {
    printf 'projects:\n'
    printf '  - key: TEAM\n'
    printf 'routing_default: TEAM\n'
  } > "${JIRA_CONFIG_DIR}/config.yml"
  # A git repo with team-shaped and unrelated branches for the proposal scan.
  (
    cd "${WORK}"
    git init -q -b main
    git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
    git branch ijt-12/invoice-export
    git branch ijt-9/fix-rounding
    git branch wex-3/onboarding
    git branch feature/unrelated
  )
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

run_in_work() {
  ( cd "${WORK}" && cmd_config "$@" )
}

@test "no base URL: exit 0, one warning naming the variable, provisional proposals, zero writes (FR-008)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  # Exactly one warning, naming the missing variable.
  [ "$(printf '%s\n' "$output" | grep -c '^WARNING:')" -eq 1 ]
  [[ "$output" == *"SPEC_KIT_JIRA_BASE_URL"* ]]
  # The JSON summary carries the provisional proposals and re-run guidance.
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  [ "$(jq -r '.provisional | length' <<< "${summary}")" -eq 2 ]
  [ "$(jq -r '.provisional[0].team_prefix' <<< "${summary}")" = "ijt" ]
  [ "$(jq -r '.provisional[0].provisional' <<< "${summary}")" = "true" ]
  [ "$(jq -r '.provisional[1].team_prefix' <<< "${summary}")" = "wex" ]
  [ "$(jq -r '.rerun_guidance | length > 0' <<< "${summary}")" = "true" ]
  [ "$(jq -r '.counts.warnings' <<< "${summary}")" -ge 1 ]
  # Every effect is skipped; nothing was written.
  [ "$(jq -r '.effects.discovery.status' <<< "${summary}")" = "skipped" ]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  [ ! -f "${WORK}/.specify/extensions.yml" ]
  [ ! -f "${WORK}/README.md" ]
}

@test "an existing config.local.yml is byte-identical after a degraded run (FR-009)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  printf 'site_alias: prod\n' > "${JIRA_CONFIG_DIR}/config.local.yml"
  cp "${JIRA_CONFIG_DIR}/config.local.yml" "${WORK}/before.yml"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  run cmp "${WORK}/before.yml" "${JIRA_CONFIG_DIR}/config.local.yml"
  [ "$status" -eq 0 ]
}

@test "an unresolvable token triggers degraded mode before any Jira call" {
  # Base URL defined but pointing nowhere reachable: if the trigger check ran
  # any Jira call first this would fail with a network exit, not degrade.
  export SPEC_KIT_JIRA_BASE_URL="http://127.0.0.1:1"
  unset JIRA_API_TOKEN
  # Neutralise the secret-manager and .env rungs deterministically.
  export PATH="${WORK}/nobin:${PATH}"
  mkdir -p "${WORK}/nobin"
  printf '#!/bin/sh\nexit 1\n' > "${WORK}/nobin/security"
  printf '#!/bin/sh\nexit 1\n' > "${WORK}/nobin/secret-tool"
  chmod +x "${WORK}/nobin/security" "${WORK}/nobin/secret-tool"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"JIRA_API_TOKEN"* ]]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "defined-but-wrong credentials fail closed with the auth exit — never degraded (research §4)" {
  local cfg
  cfg="$(mktemp)"
  printf '%s' '{"fault":{"status":401}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export JIRA_API_TOKEN="WRONGTOKEN"
  run run_in_work config --json
  [ "$status" -eq 3 ]
  [ ! -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
}

@test "a degraded run performs zero Jira calls" {
  local cfg
  cfg="$(mktemp)"
  printf '%s' '{"projects":{"TEAM":"team"}}' > "${cfg}"
  mock_start "${cfg}"
  # The mock is up, but the port never learns its URL.
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  [ -z "$(mock_calls)" ]
}

@test "degraded effects include gitignore: skipped — same effect set as nominal (T093)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  [ "$(jq -r '.effects.gitignore.status' <<< "${summary}")" = "skipped" ]
  [ ! -f "${WORK}/.gitignore" ]
}

@test "degraded prose surfaces the proposals and the rerun guidance (T093)" {
  # The agent command doc instructs the model to relay the re-run guidance
  # verbatim — it must exist in the default (non---json) output, not only in
  # the JSON summary.
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config
  [ "$status" -eq 0 ]
  [[ "$output" == *"  gitignore: skipped"* ]]
  # The hooks effect is NOT skipped: it reads two local files and needs no Jira,
  # so reporting it skipped would be a lie about work that was performed (003 US6).
  [[ "$output" != *"  hooks: skipped"* ]]
  [[ "$output" == *"Provisional teams: ijt, wex"* ]]
  # The re-run guidance names the bridge in the repository-relative per-port form
  # (003 FR-014, FR-018) — a bare `spec-kit-jira` names nothing after install.
  [[ "$output" == *"Rerun: define SPEC_KIT_JIRA_BASE_URL, then re-run: bash .specify/extensions/jira/scripts/bash/spec-kit-jira.sh config (on Windows: .specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 config)"* ]]
}

# =============================================================================
# T046 [003 US5] — The degraded causes are told APART (FR-017, SC-006)
# =============================================================================
#
# The reported message named one cause ("CLI not installed") that was not the
# real one and could not have been — this extension is not delivered as a
# machine-wide CLI. FR-017 requires the message to name the TRUE cause, and lists
# six that must be distinguishable. The ceremony can reach five of them; the
# sixth, the entry point being absent, is asserted in test_reconcile.bats because
# it is a property of the bridge's own availability rather than of the run.
#
# In every one of them the host command succeeds (SC-006): a ceremony that cannot
# reach Jira is a report, not a failure.

@test "not yet configured names the missing variables, not a missing CLI (FR-017)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPEC_KIT_JIRA_BASE_URL"* ]]
  # Never the wording of the reported defect.
  [[ "$output" != *"CLI not installed"* ]]
  [[ "$output" != *"not installed"* ]]
}

@test "credentials absent is distinguished from base URL absent (FR-017)" {
  export SPEC_KIT_JIRA_BASE_URL="https://mock"
  unset JIRA_API_TOKEN
  run run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"JIRA_API_TOKEN"* ]]
  [[ "$output" != *"SPEC_KIT_JIRA_BASE_URL"* ]]
}

@test "both absent are named together in ONE message (FR-016, FR-017)" {
  unset SPEC_KIT_JIRA_BASE_URL
  unset JIRA_API_TOKEN
  run run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPEC_KIT_JIRA_BASE_URL, JIRA_API_TOKEN"* ]]
  # One warning, not two.
  [ "$(grep -c 'WARNING:' <<< "$output")" -eq 1 ]
}

@test "the re-run guidance names a bridge invocation that is runnable (FR-018)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config --json
  local guidance
  guidance="$(jq -r '.rerun_guidance' <<< "$(grep '^{' <<< "$output")")"
  # The repository-relative per-port form, never a bare executable name.
  [[ "${guidance}" == *".specify/extensions/jira/scripts/bash/spec-kit-jira.sh config"* ]]
  [[ "${guidance}" == *".specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1 config"* ]]
  run grep -qE '(^|[^/])spec-kit-jira[[:space:]]+config' <<< "${guidance}"
  [ "$status" -ne 0 ]
}

@test "an unreadable registry is a distinct cause from an unconfigured repository (FR-017, FR-024)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  mkdir -p "${WORK}/.specify"
  printf '%s\n' 'hooks:' '  after_plan:' '   - broken' '     : : :' > "${WORK}/.specify/extensions.yml"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  local summary
  summary="$(grep '^{' <<< "$output")"
  # The discovery effect is skipped for the connection; the hooks effect is
  # unreadable for the file. Two causes, two reports, one run.
  [ "$(jq -r '.effects.discovery.status' <<< "${summary}")" = "skipped" ]
  [ "$(jq -r '.effects.hooks.status' <<< "${summary}")" = "unreadable" ]
}

@test "T052 [011] — degraded mode asks no field-default question and writes nothing to config.yml (FR-009)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local before; before="$(cat "${JIRA_CONFIG_DIR}/config.yml")"
  run run_in_work config --field-default 'TEAM=Epic=Business Owner=Platform Team' --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"field_defaults"* ]]
  [ "$(cat "${JIRA_CONFIG_DIR}/config.yml")" = "${before}" ]
}
