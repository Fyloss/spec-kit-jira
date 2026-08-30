#!/usr/bin/env bats
# T023 [US2] — Degraded mode: loud, provisional, write-free (FR-008/FR-009).
#
# The trigger is tested BEFORE any Jira call and fires ONLY when
# SPEC_KIT_JIRA_BASE_URL is unset/empty or the token resolves through neither of
# the two rungs (030). A degraded run exits 0 with exactly one warning naming the
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
  unset JIRA_API_TOKEN JIRA_PAT_COMMAND
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

@test "degraded effects report gitignore and personal with their TRUE status (030, T062, research R5)" {
  # Reordered ahead of the degraded early return: the fresh-setup case IS
  # degraded mode, and it is exactly when personal.yml must be created and
  # covered by the ignore rule (research R5) — reporting either "skipped"
  # would be a lie about work that was in fact performed.
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  [ "$(jq -r '.effects.gitignore.status' <<< "${summary}")" = "created" ]
  [ "$(jq -r '.effects.personal.status' <<< "${summary}")" = "created" ]
  [ -f "${WORK}/.gitignore" ]
  [ -f "${JIRA_CONFIG_DIR}/personal.yml" ]
}

@test "degraded prose surfaces the proposals and the rerun guidance (T093)" {
  # The agent command doc instructs the model to relay the re-run guidance
  # verbatim — it must exist in the default (non---json) output, not only in
  # the JSON summary.
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  run run_in_work config
  [ "$status" -eq 0 ]
  [[ "$output" == *"  gitignore: created"* ]]
  [[ "$output" == *"  personal: created"* ]]
  [[ "$output" == *"Provisional teams: ijt, wex"* ]]
  # The re-run guidance names the bridge in the repository-relative per-port form
  # (003 FR-014, FR-018) — a bare `spec-kit-jira` names nothing after install.
  [[ "$output" == *"Rerun: define SPEC_KIT_JIRA_BASE_URL, then re-run: .specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh config (on Windows: .specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 config)"* ]]
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
  [[ "${guidance}" == *".specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh config"* ]]
  [[ "${guidance}" == *".specify/extensions/jira-mirror/scripts/powershell/spec-kit-jira.ps1 config"* ]]
  run grep -qE '(^|[^/])spec-kit-jira[[:space:]]+config' <<< "${guidance}"
  [ "$status" -ne 0 ]
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

@test "015 T034 — a degraded-mode ceremony with no Jira read performs no allowed-value check at all, and stays silent about it" {
  # No Jira read means no defaultable_fields is ever discovered, so rule A3
  # (contract §6.2) excludes every entry from examination — a recorded value
  # that WOULD be outside_allowed against a real project's metadata is not
  # checked here, and the run neither refuses nor mentions the field.
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  printf 'field_defaults:\n  TEAM:\n    ask: true\n    Epic:\n      Region: NotAnAllowedValue\n' >> "${JIRA_CONFIG_DIR}/config.yml"
  local before; before="$(cat "${JIRA_CONFIG_DIR}/config.yml")"
  run run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"must be one of"* ]]
  [[ "$output" != *"NotAnAllowedValue"* ]]
  [ "$(cat "${JIRA_CONFIG_DIR}/config.yml")" = "${before}" ]
}

# =============================================================================
# T044a [030, US1] — the ceremony's degraded trigger splits the credential
# reason (contracts/credential-resolution.md C6.4–C6.6, FR-038)
# =============================================================================

@test "T044a — with no JIRA_PAT_COMMAND declared, degraded mode is silent about the rung (C6.4)" {
  unset SPEC_KIT_JIRA_BASE_URL JIRA_API_TOKEN JIRA_PAT_COMMAND
  run --separate-stderr run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"JIRA_API_TOKEN"* ]]
  [[ "$stderr" != *"JIRA_PAT_COMMAND"* ]]
}

@test "T044a — a declared and failing JIRA_PAT_COMMAND reports its reason on stderr and in detail, exit 0 (C6.5)" {
  unset SPEC_KIT_JIRA_BASE_URL JIRA_API_TOKEN
  export JIRA_PAT_COMMAND="${WORK}/nonexistent-pat-helper"
  run --separate-stderr run_in_work config --json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"JIRA_PAT_COMMAND"* ]]
  [[ "$stderr" == *"could not be executed"* ]]
  local summary
  summary="$(printf '%s\n' "$output" | grep -v '^WARNING:')"
  [[ "$(jq -r '.effects.personal.status' <<< "${summary}")" != "" ]]
}

# =============================================================================
# 034 T010 [US1] — The ceremony says nothing about the hook registry, whatever
# state that registry is in (FR-002, SC-001, US1 AC1–AC3).
# =============================================================================
#
# The three states are asserted together, in one file, because the claim is
# about their EQUALITY rather than about any one of them: a correct registry, an
# absent one and a malformed one must produce summaries that are identical in
# hook-related content, and that content must be none.
#
# The malformed case is the load-bearing one. Before 034 the extension parsed
# this file, so unparseable bytes produced an `unreadable` verdict and a warning.
# A file the extension never opens cannot do that — so there must be no parse
# warning, no hook claim, and no difference in exit code. If this case ever
# diverges from the other two, something is still reading the registry.

# seed_registry <state> — write `.specify/extensions.yml` into the work tree in
# one of three states, or remove it.
seed_registry() {
  local state="$1" f="${WORK}/.specify/extensions.yml"
  case "${state}" in
    absent) rm -f "${f}" ;;
    malformed) printf 'hooks:\n  - [unclosed\n\t\tbroken: "%s\n' 'x' > "${f}" ;;
    correct)
      { printf 'hooks:\n'
        local e
        for e in before_specify after_specify after_clarify after_plan after_tasks after_implement after_analyze; do
          printf '  %s:\n  - extension: jira-mirror\n    command: speckit.jira-mirror.reconcile\n' "${e}"
          printf '    enabled: true\n    optional: false\n'
        done
      } > "${f}" ;;
  esac
}

# hook_content <summary-json> — everything the summary says about the registry.
# Empty is the only acceptable value after 034.
hook_content() {
  jq -S '{hook_health: (.hook_health // null), hooks_effect: (.effects.hooks // null)}' <<< "$1"
}

@test "034 — correct, absent and malformed registries give identical hook content: none (SC-001)" {
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  local state out rc summaries=() codes=()
  for state in correct absent malformed; do
    seed_registry "${state}"
    rc=0
    out="$(run_in_work config --json 2> /dev/null)" || rc=$?
    summaries+=("$(hook_content "${out}")")
    codes+=("${rc}")
    # Each summary individually carries no registry claim (US1 AC1–AC3).
    [ "$(jq -r 'has("hook_health")' <<< "${out}")" = "false" ]
    [ "$(jq -r '.effects | has("hooks")' <<< "${out}")" = "false" ]
  done
  # …and the three agree with each other, which is the actual SC-001 claim.
  [ "${summaries[0]}" = "${summaries[1]}" ]
  [ "${summaries[1]}" = "${summaries[2]}" ]
  [ "${codes[0]}" = "${codes[1]}" ]
  [ "${codes[1]}" = "${codes[2]}" ]
}

@test "034 — a malformed registry produces no parse warning of any kind (US1 AC3)" {
  # NOTE: unlike the test above, this one passes BEFORE 034 as well. Pre-034 the
  # extension did parse the registry, but it reported an unreadable one through
  # the summary's `unreadable` flag rather than through stderr, so this channel
  # was already quiet. It is kept as a regression guard on that channel — the
  # obvious way to reintroduce a registry claim is a warning — and not as
  # evidence of the change. Test 17 above is what goes red for 034.
  unset SPEC_KIT_JIRA_BASE_URL
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  seed_registry malformed
  run --separate-stderr run_in_work config --json
  [ "$status" -eq 0 ]
  # The degraded run warns about the missing base URL and nothing else; a
  # registry the extension never opens cannot contribute a word here.
  [[ "$stderr" != *"extensions.yml"* ]]
  [[ "$stderr" != *"hook"* ]]
}
