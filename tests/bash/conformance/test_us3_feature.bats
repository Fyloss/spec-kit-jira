#!/usr/bin/env bats
# T050/T051/T052 [US3] — Feature-naming conformance (FR-013…FR-019).
#
# Drives the six US3 scenarios through the real dispatchers on both ports and
# asserts content + cross-port byte-parity: attach, create (POST + identity
# stamp recorded), no-team pass-through (empty call log), cross-team
# confirmation, unreachable-Jira fallback, and the gitignore effect
# (created then unchanged, `git check-ignore` honours it).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP}"
}

both_ports() {
  bash "${HARNESS}" "${CONF}/scenarios/$1" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${CONF}/scenarios/$1" powershell "${TMP}/out-ps" > /dev/null
}

parity() {
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stderr" "${TMP}/out-ps/stderr"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/calls.log" "${TMP}/out-ps/calls.log"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

@test "attach: mentioned IJT-42 with no --reuse answer now returns the reuse question, not a silent attach (029 FR-001, T050)" {
  # us3-feature-attach.json (mention IJT-42, no designator, no --reuse) is the
  # reported-incident scenario itself: this feature's whole point is that it
  # no longer names the feature silently. The scenario file stays unmodified
  # (mention-grammar.md §4); this assertion moves with the behaviour it now
  # legitimately proves.
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-attach.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r 'has("reuse_required")' "${TMP}/out-bash/stdout")" = "true" ]
  [ "$(jq -r 'has("branch_name")' "${TMP}/out-bash/stdout")" = "false" ]
  [ "$(jq -r 'has("short_name")' "${TMP}/out-bash/stdout")" = "false" ]
}

@test "attach is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-feature-attach.json
  parity
}

@test "create: POST /issue recorded, created number feeds <ID> (T050)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-create.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.ticket.key' "${TMP}/out-bash/stdout")" = "IJT-123" ]
  [ "$(jq -r '.ticket.action' "${TMP}/out-bash/stdout")" = "created" ]
  [ "$(jq -r '.branch_name' "${TMP}/out-bash/stdout")" = "ijt-123/invoice-export" ]
  grep -q 'POST /rest/api/3/issue' "${TMP}/out-bash/calls.log"
  grep -q 'PUT /rest/api/3/issue/IJT-123/properties/spec-kit-jira' "${TMP}/out-bash/calls.log"
}

@test "create is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-feature-create.json
  parity
}

@test "no team selected: {active:false} and an empty mock call log (T051)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-no-team.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.active' "${TMP}/out-bash/stdout")" = "false" ]
  [ ! -s "${TMP}/out-bash/calls.log" ]
}

@test "cross-team: WEX-7 => confirmation_required naming wex (T051)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-cross-team.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.confirmation_required.ticket_team' "${TMP}/out-bash/stdout")" = "wex" ]
  [ "$(jq -r '.confirmation_required.selected_team' "${TMP}/out-bash/stdout")" = "ijt" ]
  # The personal file is untouched by the confirmation round-trip.
  run diff "${ROOT}/tests/conformance/fixtures/repo-with-teams/.specify/jira/personal.yml" \
    "${TMP}/out-bash/workdir/.specify/jira/personal.yml"
  [ "$status" -eq 0 ]
}

@test "fallback: unreachable Jira => {active:false} + one warning, exit 0 (T051)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-fallback.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.active' "${TMP}/out-bash/stdout")" = "false" ]
  [ "$(jq -r '.warnings | length' "${TMP}/out-bash/stdout")" -eq 1 ]
  [ "$(grep -c '^WARNING:' "${TMP}/out-bash/stderr")" -eq 1 ]
}

@test "no-team, cross-team, and fallback are byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-feature-no-team.json
  parity
  both_ports us3-feature-cross-team.json
  parity
  both_ports us3-feature-fallback.json
  parity
}

@test "gitignore effect: first run created, second run unchanged, check-ignore honours it (T052)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-gitignore-effect.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.effects.gitignore.status' "${TMP}/out-bash/stdout")" = "created" ]

  # Second run in a persistent workdir: every effect unchanged; the personal
  # file is ignored by git.
  WD="${TMP}/wd"
  mkdir -p "${WD}"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-teams/." "${WD}/"
  source "${ROOT}/tests/conformance/mock-jira/lib.sh"
  MOCK_CFG="$(mktemp)"
  jq '.mock' "${CONF}/scenarios/us3-gitignore-effect.json" > "${MOCK_CFG}"
  mock_start "${MOCK_CFG}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="RAWSECRETXYZ" JIRA_NO_SLEEP=1
  ( cd "${WD}" && bash "${ROOT}/scripts/bash/spec-kit-jira.sh" config --json ) > "${TMP}/run1" 2>/dev/null
  ( cd "${WD}" && bash "${ROOT}/scripts/bash/spec-kit-jira.sh" config --json ) > "${TMP}/run2" 2>/dev/null
  mock_stop
  [ "$(jq -r '.effects.gitignore.status' "${TMP}/run2")" = "unchanged" ]
  [ "$(jq -r '.effects.discovery.status' "${TMP}/run2")" = "unchanged" ]
  ( cd "${WD}" && git init -q -b main && git check-ignore -q .specify/jira/personal.yml )
}

@test "gitignore effect is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-gitignore-effect.json
  parity
}

@test "no plan context: FR-016 fallback, exit 0, zero Jira calls (T085)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-no-plan-context.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  [ "$(jq -r '.active' "${TMP}/out-bash/stdout")" = "false" ]
  [ "$(jq -r '.warnings | length' "${TMP}/out-bash/stdout")" -eq 1 ]
  [ "$(grep -c '^WARNING:' "${TMP}/out-bash/stderr")" -eq 1 ]
  [ ! -s "${TMP}/out-bash/calls.log" ]
}

@test "no plan context is byte-identical across ports (T085, FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-feature-no-plan-context.json
  parity
}

@test "prose dry-run: feature-shaped prose, no run-summary nulls (T087)" {
  bash "${HARNESS}" "${CONF}/scenarios/us3-feature-prose-dry-run.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  run cat "${TMP}/out-bash/stdout"
  [[ "$output" == *"Feature: active (team: ijt)"* ]]
  [[ "$output" == *"Folder: ijt-invoice-export"* ]]
  [[ "$output" != *"Command: null"* ]]
  [[ "$output" != *"Exit: null"* ]]
}

@test "prose dry-run is byte-identical across ports (T087, FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us3-feature-prose-dry-run.json
  parity
}
