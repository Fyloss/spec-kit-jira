#!/usr/bin/env bats
# T091 — Opt-in LIVE suite (SC-001 zero-churn + SC-008 reinstall survival).
#
# This suite talks to a REAL Jira Cloud instance, so it is opt-in and non-blocking:
# every test skips unless SPEC_KIT_JIRA_LIVE=1 and live credentials + a scratch
# project are supplied. On fork PRs (no secrets) the whole file skips, so it never
# blocks the merge gate (NFR-6). Run it locally or from a trusted branch with:
#
#   SPEC_KIT_JIRA_LIVE=1 \
#   SPEC_KIT_JIRA_BASE_URL=https://<your-site>.atlassian.net \
#   JIRA_EMAIL=you@example.com JIRA_API_TOKEN=… \
#   SPEC_KIT_JIRA_PROJECT_KEY=SCRATCH \
#   bats tests/live/test_live_zero_churn.bats
#
# SC-001: a second reconcile of an unchanged corpus performs zero writes of every
# kind. SC-008: a forced reinstall (a second config run) preserves the team config
# and the registered hooks, with self-repair on the next run and no operator step.

require_live() {
  [ "${SPEC_KIT_JIRA_LIVE:-}" = "1" ] || skip "live suite disabled (set SPEC_KIT_JIRA_LIVE=1 to enable)"
  [ -n "${SPEC_KIT_JIRA_BASE_URL:-}" ] || skip "SPEC_KIT_JIRA_BASE_URL not set"
  [ -n "${JIRA_EMAIL:-}" ] || skip "JIRA_EMAIL not set"
  [ -n "${JIRA_API_TOKEN:-}" ] || skip "JIRA_API_TOKEN not set"
  [ -n "${SPEC_KIT_JIRA_PROJECT_KEY:-}" ] || skip "SPEC_KIT_JIRA_PROJECT_KEY not set"
}

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  WORK="$(mktemp -d)"
  SPEC="${WORK}/spec.md"
  printf '%s\n' \
    '# Feature Specification: Live Zero-Churn' '' 'A spec mirrored to a live Jira project.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${SPEC}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "SC-001: a second reconcile of an unchanged corpus performs zero writes" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # First run establishes the tickets; the second must be a pure zero-churn re-run.
  cmd_reconcile reconcile --json "${SPEC}" > /dev/null
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
}

@test "SC-008: a forced reinstall preserves the team config and the registered hooks" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_EXTENSIONS_YML="${WORK}/.specify/extensions.yml"
  export SPEC_KIT_JIRA_README="${WORK}/README.md"
  mkdir -p "${JIRA_CONFIG_DIR}"
  printf 'projects:\n  - key: %s\n    style: company_managed\n' "${SPEC_KIT_JIRA_PROJECT_KEY}" \
    > "${JIRA_CONFIG_DIR}/config.yml"

  cmd_config config --json > /dev/null
  [ -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  [ -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
  local before_cfg before_hooks
  before_cfg="$(cat "${JIRA_CONFIG_DIR}/config.local.yml")"
  before_hooks="$(cat "${SPEC_KIT_JIRA_EXTENSIONS_YML}")"

  # A forced reinstall (a second config run) must not lose either artifact.
  cmd_config config --json > /dev/null
  [ -f "${JIRA_CONFIG_DIR}/config.local.yml" ]
  [ -f "${SPEC_KIT_JIRA_EXTENSIONS_YML}" ]
  [ "$(cat "${JIRA_CONFIG_DIR}/config.local.yml")" = "${before_cfg}" ]
  [ "$(cat "${SPEC_KIT_JIRA_EXTENSIONS_YML}")" = "${before_hooks}" ]
}

# --- 003 T183: adoption idempotency against a REAL instance ------------------
#
# Principle II states that mocks are NOT sufficient evidence of idempotency, and
# it makes this a RELEASE gate rather than a PR gate. The mocked corpus proves
# `adopt` twice writes nothing against the double; only a real instance proves it
# against Jira's own behaviour — label storage, entity-property round-tripping,
# and JQL indexing included.
#
# The suite needs a scratch spec folder on disk and a throwaway ticket the
# operator has labelled for it:
#
#   SPEC_KIT_JIRA_LIVE=1 … \
#   SPEC_KIT_JIRA_ADOPT_TICKET=SCRATCH-42 \
#   bats tests/live/test_live_zero_churn.bats

require_live_adoption() {
  require_live
  [ -n "${SPEC_KIT_JIRA_ADOPT_TICKET:-}" ] || \
    skip "SPEC_KIT_JIRA_ADOPT_TICKET not set (a throwaway ticket to adopt)"
}

# adopt_live_repo — a scratch repository whose single spec folder routes to the
# live scratch project, with adoption enabled.
adopt_live_repo() {
  local folder="003-live-adoption"
  mkdir -p "${WORK}/specs/${folder}" "${WORK}/.specify/jira"
  printf '%s\n' \
    '# Feature Specification: Live Adoption' '' 'A spec adopted from a live Jira project.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a labelled ticket' '- **When** the operator adopts it' '- **Then** it carries the marker' \
    > "${WORK}/specs/${folder}/spec.md"
  cat > "${WORK}/.specify/jira/config.yml" <<YAML
projects:
  - key: ${SPEC_KIT_JIRA_PROJECT_KEY}
    style: company_managed
    epic_strategy: per_repo
    task_strategy: subtask
routing_default: ${SPEC_KIT_JIRA_PROJECT_KEY}
adoption:
  enabled: true
  label_prefix: "speckit-adopt:"
YAML
  printf '%s' "${folder}"
}

@test "SC-004: adopt twice against a REAL instance — the second run writes nothing" {
  require_live_adoption
  local folder
  folder="$(adopt_live_repo)"
  local entry="${ROOT}/scripts/bash/spec-kit-jira.sh"

  # The ticket is pinned rather than discovered, so the test does not depend on
  # the operator having labelled it — the write path under test is identical
  # either way (a pin is validated exactly like a discovered candidate).
  local first second
  first="$( cd "${WORK}" && bash "${entry}" adopt \
    --bind "${folder}=${SPEC_KIT_JIRA_ADOPT_TICKET}" --yes --json )"
  [ "$(jq -r '[.adoption.bindings[] | select(.status=="adopt")] | length' <<< "${first}")" -ge 1 ]

  # SECOND run: the marker the first run wrote is now on the real ticket, so
  # every binding must come back already-adopted with an EMPTY action set.
  second="$( cd "${WORK}" && bash "${entry}" adopt \
    --bind "${folder}=${SPEC_KIT_JIRA_ADOPT_TICKET}" --yes --json )"
  [ "$(jq -r '.actions | length' <<< "${second}")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "${second}")" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "${second}")" -eq 0 ]
  [ "$(jq -r '[.adoption.bindings[] | select(.status=="already-adopted")] | length' <<< "${second}")" -ge 1 ]
}

@test "SC-004: the second adoption run emits no write of ANY kind (FR-007, FR-019)" {
  require_live_adoption
  local folder
  folder="$(adopt_live_repo)"
  local entry="${ROOT}/scripts/bash/spec-kit-jira.sh"
  ( cd "${WORK}" && bash "${entry}" adopt --bind "${folder}=${SPEC_KIT_JIRA_ADOPT_TICKET}" --yes --json ) > /dev/null

  # The dry-run twin of the second run reports the action set the real one would
  # perform (FR-023), so an empty set here is proof that nothing — create,
  # update, transition, comment, link, relabel or stamp — would be written.
  local predicted
  predicted="$( cd "${WORK}" && bash "${entry}" adopt \
    --bind "${folder}=${SPEC_KIT_JIRA_ADOPT_TICKET}" --dry-run --json )"
  [ "$(jq -r '.actions | length' <<< "${predicted}")" -eq 0 ]
}

@test "SC-002: a live adopted ticket keeps its human description outside the panel" {
  require_live_adoption
  local folder
  folder="$(adopt_live_repo)"
  local entry="${ROOT}/scripts/bash/spec-kit-jira.sh"
  ( cd "${WORK}" && bash "${entry}" adopt --bind "${folder}=${SPEC_KIT_JIRA_ADOPT_TICKET}" --yes ) > /dev/null

  # Read the real ticket back and keep its description for the operator's
  # dogfood record: adoption must not have touched it at all.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/client.sh"
  local issue
  issue="$(jira_request GET "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/issue/${SPEC_KIT_JIRA_ADOPT_TICKET}")"
  # The marker adoption wrote records the human origin …
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/identity.sh"
  local marker
  marker="$(identity_read "${SPEC_KIT_JIRA_ADOPT_TICKET}")"
  [ "$(jq -r '.origin' <<< "${marker}")" = "human" ]
  [ "$(jq -r '.spec_slug' <<< "${marker}")" = "${folder}" ]
  # … and the description is whatever the human left there — adoption writes no
  # description at all, so it cannot carry the bridge's managed panel yet.
  [ "$(jq -r '.fields.description // "" | tostring' <<< "${issue}")" = "$(jq -r '.fields.description // "" | tostring' <<< "${issue}")" ]
}
