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

@test "SC-001: a second reconcile of an unchanged corpus performs zero writes — parent included" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  # Phase 3-4, US1/US2: the reported defect happened between two lifecycle
  # commands seconds apart, so it is the FIRST-to-SECOND transition that
  # must be proven live — a mocked Jira's search index has no lag to hide
  # (Constitution II, research R2). The first run creates the parent AND
  # its one story (008 US2: every specification now mirrors as a parent
  # plus its children), and stamps a marker for each into spec.md.
  local first
  first="$(cmd_reconcile reconcile --json "${SPEC}")"
  [ "$(jq -r '.counts.created' <<< "${first}")" -eq 2 ]
  local parent_marker_line; parent_marker_line="$(grep -o 'speckit-jira spec=[0-9a-f]\{16\} ticket=[A-Z][A-Z0-9_]*-[1-9][0-9]*' "${SPEC}")"
  [ -n "${parent_marker_line}" ]
  local parent_key; parent_key="$(printf '%s' "${parent_marker_line}" | grep -o '[A-Z][A-Z0-9_]*-[1-9][0-9]*')"
  local marker_line; marker_line="$(grep -o 'speckit-jira story=[0-9a-f]\{16\} ticket=[A-Z][A-Z0-9_]*-[1-9][0-9]*' "${SPEC}")"
  [ -n "${marker_line}" ]
  local ticket_key; ticket_key="$(printf '%s' "${marker_line}" | grep -o '[A-Z][A-Z0-9_]*-[1-9][0-9]*')"
  # The story's own creation POST carried the parent's real key (008 US2:
  # every child names the parent), reported by the run summary itself.
  [ "$(jq -r '[.actions[] | select(.role=="story")][0].body.fields.parent.key' <<< "${first}")" = "${parent_key}" ]

  # The second run must recognise that SAME parent and that SAME ticket by
  # their recorded keys — never search — and issue zero writes of any kind,
  # for the parent as well as the story.
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 0 ]
  # spec.md still names the SAME parent and the SAME ticket — neither
  # identifier was ever reassigned.
  grep -qF "${parent_key}" "${SPEC}"
  grep -qF "${ticket_key}" "${SPEC}"

  # A THIRD run, ten times over (SC-002), never drifts from that signature —
  # an unchanged corpus stays a permanent no-op, not a one-time recognition.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run cmd_reconcile reconcile --json "${SPEC}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
    [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  done
}

@test "T099 [Phase 8, US2/quickstart Step 12]: adding one story to an already-mirrored hierarchy creates only that story — the parent is untouched" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  # First run: the parent plus its two stories.
  printf '%s\n' \
    '# Feature Specification: Live Hierarchy Growth' '' 'A spec mirrored to a live Jira project as a hierarchy.' '' \
    '### User Story 1 - The first story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' '' \
    '### User Story 2 - The second story (Priority: P2)' '' \
    '- **Given** another user' '- **When** they act' '- **Then** it also works' \
    > "${SPEC}"
  local first
  first="$(cmd_reconcile reconcile --json "${SPEC}")"
  [ "$(jq -r '.counts.created' <<< "${first}")" -eq 3 ]
  local parent_marker_line; parent_marker_line="$(grep -o 'speckit-jira spec=[0-9a-f]\{16\} ticket=[A-Z][A-Z0-9_]*-[1-9][0-9]*' "${SPEC}")"
  local parent_key; parent_key="$(printf '%s' "${parent_marker_line}" | grep -o '[A-Z][A-Z0-9_]*-[1-9][0-9]*')"

  # An unchanged re-run: zero writes, the parent included.
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]

  # Add a third story. Exactly one creation follows — the new story, under
  # the SAME parent — and the parent itself is never re-sent (parent: null,
  # zero writes for it, per plan_writes' zero-churn rule).
  printf '%s\n' \
    '### User Story 3 - The third story (Priority: P3)' '' \
    '- **Given** a third user' '- **When** they act' '- **Then** it also works' \
    >> "${SPEC}"
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.actions[] | select(.role=="parent")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.actions[] | select(.role=="story")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.actions[] | select(.role=="story")][0].body.fields.parent.key' <<< "$output")" = "${parent_key}" ]
  # spec.md still names the SAME parent — it was never re-created.
  grep -qF "${parent_key}" "${SPEC}"
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
