#!/usr/bin/env bats
# T009/T010/T011 [US1] — Style provenance conformance (FR-001/FR-002/FR-003).
#
# Drives the us1-style scenarios through the real dispatchers on both ports:
#   - us1-style-ambiguous-refusal: unattended run against a payload with no
#     style signal => exit 4, ZERO writes, stderr naming the project and the
#     missing signal — stderr and exit byte-identical across ports.
#   - us1-style-operator-answer: --style AMBI=team_managed => persisted
#     style_source "operator", summary audit, config.local.yml byte-identical
#     across ports.
#   - us2-team/company-managed-discovery (extended, T011): the persisted binding
#     also carries style + style_source "api" and the summary audits it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CONF="${ROOT}/tests/conformance"
  HARNESS="${CONF}/run-scenario.sh"
  TMP="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
}

teardown() {
  rm -rf "${TMP}"
}

both_ports() {
  bash "${HARNESS}" "${CONF}/scenarios/$1" bash "${TMP}/out-bash" > /dev/null
  bash "${HARNESS}" "${CONF}/scenarios/$1" powershell "${TMP}/out-ps" > /dev/null
}

@test "ambiguous refusal: exit 4, located stderr, zero writes (FR-002)" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-style-ambiguous-refusal.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "4" ]
  grep -q 'AMBI' "${TMP}/out-bash/stderr"
  grep -q 'no unambiguous style signal' "${TMP}/out-bash/stderr"
  grep -q -- '--style AMBI=company_managed' "${TMP}/out-bash/stderr"
  grep -q -- '--style AMBI=team_managed' "${TMP}/out-bash/stderr"
  # Zero writes: the workdir still holds only the fixture's config.yml.
  [ ! -f "${TMP}/out-bash/workdir/.specify/jira/config.local.yml" ]
  [ ! -f "${TMP}/out-bash/workdir/.specify/extensions.yml" ]
  [ ! -f "${TMP}/out-bash/workdir/README.md" ]
}

@test "ambiguous refusal is byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-style-ambiguous-refusal.json
  run diff "${TMP}/out-bash/exit" "${TMP}/out-ps/exit"
  [ "$status" -eq 0 ]
  run diff "${TMP}/out-bash/stderr" "${TMP}/out-ps/stderr"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

@test "operator answer: persisted style_source operator, summary audit (FR-003)" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-style-operator-answer.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local localj
  localj="$(config_yaml_to_json "${TMP}/out-bash/workdir/.specify/jira/config.local.yml")"
  [ "$(jq -r '.resolved_ids.AMBI.style' <<< "${localj}")" = "team_managed" ]
  [ "$(jq -r '.resolved_ids.AMBI.style_source' <<< "${localj}")" = "operator" ]
  [ "$(jq -r '.effects.discovery.projects.AMBI.style_source' "${TMP}/out-bash/stdout")" = "operator" ]
}

@test "operator answer: config.local.yml byte-identical across ports (FR-020)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-style-operator-answer.json
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

@test "team-managed discovery persists style + style_source api (T011)" {
  bash "${HARNESS}" "${CONF}/scenarios/us2-team-managed-discovery.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local localj
  localj="$(config_yaml_to_json "${TMP}/out-bash/workdir/.specify/jira/config.local.yml")"
  [ "$(jq -r '.resolved_ids.COMP.style' <<< "${localj}")" = "company_managed" ]
  [ "$(jq -r '.resolved_ids.COMP.style_source' <<< "${localj}")" = "api" ]
  [ "$(jq -r '.effects.discovery.projects.COMP.style' "${TMP}/out-bash/stdout")" = "company_managed" ]
  [ "$(jq -r '.effects.discovery.projects.COMP.style_source' "${TMP}/out-bash/stdout")" = "api" ]
}

@test "the DEFAULT (prose) summary carries the per-project style audit (T098)" {
  bash "${HARNESS}" "${CONF}/scenarios/us1-style-prose-audit.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  # Nested under the discovery effect line, before the next effect.
  grep -q '^    COMP: company_managed (api)$' "${TMP}/out-bash/stdout"
  # Not JSON: prose really is the default rendering.
  run jq -e . "${TMP}/out-bash/stdout"
  [ "$status" -ne 0 ]
}

@test "the prose style audit is byte-identical across ports (T098)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  both_ports us1-style-prose-audit.json
  run diff "${TMP}/out-bash/stdout" "${TMP}/out-ps/stdout"
  [ "$status" -eq 0 ]
  run diff -r "${TMP}/out-bash/workdir" "${TMP}/out-ps/workdir"
  [ "$status" -eq 0 ]
}

@test "company-managed discovery persists style + style_source api (T011)" {
  bash "${HARNESS}" "${CONF}/scenarios/us2-company-managed-discovery.json" bash "${TMP}/out-bash" > /dev/null
  [ "$(cat "${TMP}/out-bash/exit")" = "0" ]
  local localj
  localj="$(config_yaml_to_json "${TMP}/out-bash/workdir/.specify/jira/config.local.yml")"
  [ "$(jq -r '.resolved_ids.COMP.style' <<< "${localj}")" = "company_managed" ]
  [ "$(jq -r '.resolved_ids.COMP.style_source' <<< "${localj}")" = "api" ]
}
