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
# kind, including the task tier's transition write kind (012, Constitution II —
# the assertion list is extended in the same change that adds a write kind).
# SC-008: a forced reinstall (a second config run) preserves the team config
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

  # Phase 8, US5 (012, Constitution II): a task checked before its sub-task
  # ever exists is created AND transitioned in the very first run (Edge
  # Cases, T084) — proving the transition write kind against a REAL Jira
  # workflow, not a mock's canned transition list, before the idempotency
  # of that same write kind is asserted below.
  local tasks_file="${WORK}/tasks.md"
  printf '%s\n' \
    '# Tasks: Live Zero-Churn' '' '## Phase 1: User Story 1' '' \
    '- [x] T001 [US1] Do the thing' \
    > "${tasks_file}"

  # Phase 3-4, US1/US2: the reported defect happened between two lifecycle
  # commands seconds apart, so it is the FIRST-to-SECOND transition that
  # must be proven live — a mocked Jira's search index has no lag to hide
  # (Constitution II, research R2). The first run creates the parent AND
  # its one story (008 US2: every specification now mirrors as a parent
  # plus its children), and stamps a marker for each into spec.md.
  local first
  first="$(cmd_reconcile reconcile --json "${SPEC}")"
  [ "$(jq -r '.counts.created' <<< "${first}")" -eq 2 ]
  [ "$(jq -r '.counts.tasks.created' <<< "${first}")" -eq 1 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "${first}")" -eq 1 ]
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
  # for the parent as well as the story AND the task tier's sub-task: the
  # already-done-category status read back from real Jira must never fire a
  # second transition (FR-031's idempotency, proven live rather than mocked).
  run cmd_reconcile reconcile --json "${SPEC}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.skipped' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 0 ]
  # 023 (contract §7 Z2/Z3, Constitution II): the specification/story-tier
  # write kind extends this SAME assertion list the change that made it
  # non-zero — this suite never sets a lifecycle event, so `counts.
  # transitioned` (FR-011, present only when an event AND a declared step
  # exist) must stay absent/null here, live, not merely in the mock corpus.
  [ "$(jq -r '.counts.transitioned // 0' <<< "$output")" -eq 0 ]
  # spec.md still names the SAME parent and the SAME ticket — neither
  # identifier was ever reassigned.
  grep -qF "${parent_key}" "${SPEC}"
  grep -qF "${ticket_key}" "${SPEC}"

  # A THIRD run, ten times over (SC-002), never drifts from that signature —
  # an unchanged corpus stays a permanent no-op, not a one-time recognition,
  # for the transition write kind as much as for created/updated.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run cmd_reconcile reconcile --json "${SPEC}"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
    [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
    [ "$(jq -r '.counts.tasks.transitioned' <<< "$output")" -eq 0 ]
    [ "$(jq -r '.counts.transitioned // 0' <<< "$output")" -eq 0 ]
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

@test "027: seeding from real issues, then a second reconcile, issues zero writes of every write kind this feature adds" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/seed_state.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  export SPEC_KIT_JIRA_REPO="live/scratch"
  export SPEC_KIT_JIRA_SPEC_SLUG="live-seed-source"

  # (1) Materialise a REAL parent + story to seed from, via the
  # already-proven reconcile path (SC-001 above) — a fresh specification,
  # never seeded itself.
  local source_spec="${WORK}/source-spec.md"
  printf '%s\n' \
    '# Feature Specification: Live Seed Source' '' 'The issue-content this test seeds from.' '' \
    '### User Story 1 - The seeded story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' \
    > "${source_spec}"
  local materialised
  materialised="$(cmd_reconcile reconcile --json "${source_spec}")"
  [ "$(jq -r '.counts.created' <<< "${materialised}")" -eq 2 ]
  local source_parent_key source_story_key
  source_parent_key="$(grep -oE 'speckit-jira spec=[0-9a-f]{16} ticket=[A-Z][A-Z0-9_]*-[1-9][0-9]*' "${source_spec}" | grep -oE '[A-Z][A-Z0-9_]*-[1-9][0-9]*')"
  source_story_key="$(grep -oE 'speckit-jira story=[0-9a-f]{16} ticket=[A-Z][A-Z0-9_]*-[1-9][0-9]*' "${source_spec}" | grep -oE '[A-Z][A-Z0-9_]*-[1-9][0-9]*')"
  [ -n "${source_parent_key}" ]
  [ -n "${source_story_key}" ]

  # (2) Seed a SECOND, unrelated specification by adopting that real parent
  # and story — proving the identity-stamp and parent-link write kinds
  # against a real instance, not the mock.
  local seed_spec="${WORK}/seed-spec.md"
  local designators
  designators="$(jq -cn --arg p "${source_parent_key}" --arg s "${source_story_key}" \
    '[{role:"specification",form:"key",key:$p,raw:$p,position:0},{role:"story",form:"key",key:$s,raw:$s,position:0}]')"
  local routing
  routing="$(jq -cn --arg proj "${SPEC_KIT_JIRA_PROJECT_KEY}" '{project:$proj, declared_type_specification:"", declared_type_story:"", terminal_statuses_csv:""}')"
  local doc
  doc="$(seed_state_compose "live-seed-spec" "${designators}" "" "${routing}" "[]")"
  seed_state_write "${seed_spec}" "${doc}"
  printf '%s\n\n### User Story 1 - The seeded story (Priority: P1)\n<!-- speckit-jira pin=%s -->\n\nSeeded body.\n' \
    "# Feature" "${source_story_key}" > "${seed_spec}"

  local bound
  bound="$(cmd_seed seed "${seed_spec}" --confirm --json)"
  [ "$(jq -r '.bindings | length' <<< "${bound}")" -eq 2 ]
  [ "$(jq -r '[.bindings[] | select(.role=="parent")][0].origin' <<< "${bound}")" = "human" ]

  # (3) A second reconcile of this now-bound, unchanged specification issues
  # ZERO writes of every kind — the identity stamp and the parent-link both
  # already exist and are recognised, not re-applied.
  run cmd_reconcile reconcile --json "${seed_spec}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.actions | length' <<< "$output")" -eq 0 ]
}

@test "027: creating a parent from free text, then a second reconcile, issues zero writes" {
  require_live
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/seed_state.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  mkdir -p "${JIRA_CONFIG_DIR}"
  export SPEC_KIT_JIRA_REPO="live/scratch"
  export SPEC_KIT_JIRA_SPEC_SLUG="live-create-parent"

  local create_spec="${WORK}/create-parent-spec.md"
  local designators
  designators="$(jq -cn '[{role:"specification",form:"free_text",raw:"Live seed parent-create",text:"Live seed parent-create",position:0}]')"
  # The type id must be resolved for real against the scratch project's own
  # config.local.yml in a live run — SPEC_KIT_JIRA_PROJECT_KEY alone is not
  # enough for a CREATE, only for reconcile's routing override. A real run
  # of this test needs /speckit.jira-mirror.config to have bound the scratch
  # project first, and its resolved specification-role type id read from
  # config.local.yml here rather than hand-supplied.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/lib/config.sh"
  local ptid
  ptid="$(jq -r --arg k "${SPEC_KIT_JIRA_PROJECT_KEY}" '.resolved_ids[$k].parent_type.id // empty' \
    <<< "$(_cfg_local_json "${JIRA_CONFIG_DIR}" 2> /dev/null)" 2> /dev/null)"
  [ -n "${ptid}" ] || skip "config.local.yml not bound for ${SPEC_KIT_JIRA_PROJECT_KEY} — run /speckit.jira-mirror.config against the scratch project first"
  local routing
  routing="$(jq -cn --arg proj "${SPEC_KIT_JIRA_PROJECT_KEY}" --arg ptid "${ptid}" \
    '{project:$proj, declared_type_specification:"", declared_type_story:"", terminal_statuses_csv:"", parent_type_id:$ptid}')"
  local doc
  doc="$(seed_state_compose "live-create-parent" "${designators}" "" "${routing}" "[]")"
  seed_state_write "${create_spec}" "${doc}"
  printf '# Feature\n\nA brand-new parent, created from free text.\n' > "${create_spec}"

  local bound
  bound="$(cmd_seed seed "${create_spec}" --confirm --json)"
  [ "$(jq -r '.bindings | length' <<< "${bound}")" -eq 1 ]
  [ "$(jq -r '.bindings[0].origin' <<< "${bound}")" = "bridge" ]
  local created_key
  created_key="$(jq -r '.bindings[0].key' <<< "${bound}")"
  [ -n "${created_key}" ]

  # A second reconcile of this now-bound specification issues zero writes —
  # the created parent's identity and content are recognised, not re-created.
  run cmd_reconcile reconcile --json "${create_spec}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
}
