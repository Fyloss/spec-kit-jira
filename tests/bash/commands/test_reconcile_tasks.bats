#!/usr/bin/env bats
# T042/T043 [US1] — Wiring the task tier into cmd_reconcile: tasks.md is read
# only when a `task` role resolved (FR-001, FR-011); attributed tasks become
# sub-tasks of their story; the run is byte-identical when no `task` role is
# declared.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-task-tier"
  LEGACY_FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-reconcile-legacy"
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
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  export SPEC_KIT_JIRA_REPO="acme/app"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_PROJECT_KEY
}

teardown() {
  mock_stop
}

_mock_configs() {
  mock_write_config '{"projects":{"TASKP":"t"}}'
}

@test "a fresh run creates the parent, the story, and the attributed sub-task, and skips the unattributed one" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 2 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.counts.tasks.unchanged' <<< "$output")" -eq 0 ]
  local calls; calls="$(mock_calls | grep -c '^POST /rest/api/3/issue$')"
  [ "${calls}" -eq 3 ]
  grep -q "task=.*ticket=TASKP-3" "${TASKS}"
  ! grep -q "T001" <(grep "speckit-jira task=" "${TASKS}")
}

@test "the sub-task is created under the story, not the parent" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(mock_issue_field "TASKP-3" '.fields.parent.key')" = "TASKP-2" ]
}

@test "a re-run issues zero writes for the task tier (zero churn)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  # --force: this re-run's local inputs are unchanged since the baseline run,
  # so without --force the state short-circuit (021) would skip Jira entirely
  # — this test's point is that a genuine reconcile issues zero writes, not
  # that the short-circuit fires.
  run cmd_reconcile reconcile "${SPEC}" --json --force
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.unchanged' <<< "$output")" -eq 1 ]
  [ "$(grep -vE 'issue/bulkfetch' "${MOCK_CALLLOG}" | grep -cE '^(POST|PUT) ')" -eq 0 ]
}

@test "T045/T046 [US2] — renumbering T0nn while preserving the durable marker updates the SAME ticket, never creates a second one (FR-016)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  # Regenerate the task list the way /speckit-tasks would: every T0nn shifts
  # up by one, but the durable marker line that recognition keys on is left
  # exactly where task_marker_assign put it — the SAME identifier, under a
  # DIFFERENT number. The rendered description's "Identifier: T0nn" bullet
  # is BY DESIGN human-readable cross-reference text (data-model.md §2,
  # adf_render_task_description), so this legitimately updates the existing
  # ticket rather than being zero-churn — what FR-016 actually guards
  # against is the renumbering being mistaken for a NEW task and creating a
  # duplicate, which is what this test asserts.
  sed -i.bak 's/^- \[ \] T001 /- [ ] T101 /; s/^- \[ \] T002 /- [ ] T102 /' "${TASKS}"
  rm -f "${TASKS}.bak"
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.tasks.updated' <<< "$output")" -eq 1 ]
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 0 ]
  [ "$(grep -c '^PUT /rest/api/3/issue/TASKP-3$' "${MOCK_CALLLOG}")" -eq 1 ]
  grep -q "T102" "${TASKS}"
  grep -q "ticket=TASKP-3" "${TASKS}"
}

@test "tasks.md is byte-preserved apart from the inserted marker lines" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local before; before="$(cat "${TASKS}")"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  local after; after="$(cat "${TASKS}")"
  [[ "${after}" == *"- [ ] T001 Do the setup work"* ]]
  [[ "${after}" == *"- [ ] T002 [US1] Implement the first story's feature"* ]]
  [ "${#after}" -gt "${#before}" ]
}

@test "--dry-run writes neither Jira nor tasks.md, and shows the planned sub-task" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  local before; before="$(cat "${TASKS}")"
  run cmd_reconcile reconcile "${SPEC}" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.tasks.created' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.actions[] | select(.role=="task")] | length' <<< "$output")" -eq 1 ]
  local after; after="$(cat "${TASKS}")"
  [ "${before}" = "${after}" ]
  # 017's duplicate probe is a read-only GET fired in the planning pass, so a
  # --dry-run over a specification with no parent marker legitimately reaches
  # the double. The dry-run invariant is zero WRITES, not zero requests.
  run mock_calls
  [ "$(grep -vE 'issue/bulkfetch' <<< "$output" | grep -cE '^(POST|PUT|DELETE) ')" -eq 0 ]
}

@test "no tasks.md is a silent no-op — no counts.tasks key at all" {
  rm -f "${TASKS}"
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts | has("tasks")' <<< "$output")" = "false" ]
}

@test "no task role declared: byte-identical output even with tasks.md present (FR-011)" {
  local work2="${BATS_TEST_TMPDIR}/repo-noroletask"
  cp -R "${LEGACY_FIXTURE}" "${work2}"
  mkdir -p "${work2}/specs/001-feature"
  cp "${SPEC}" "${work2}/specs/001-feature/spec.md"
  cp "${TASKS}" "${work2}/specs/001-feature/tasks.md"
  export JIRA_CONFIG_DIR="${work2}/.specify/jira"
  export SPEC_KIT_JIRA_PROJECT_KEY="TEST"
  local cfg; cfg="$(mock_write_config '{"projects":{"TEST":"t"}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  run cmd_reconcile reconcile "${work2}/specs/001-feature/spec.md" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts | has("tasks")' <<< "$output")" = "false" ]
  # No marker line was ever spliced into tasks.md — it was never read at all.
  ! grep -q "speckit-jira task=" "${work2}/specs/001-feature/tasks.md"
}

@test "T069 [US3] — a task removed from tasks.md reports its orphaned sub-task once, by key, and changes nothing in Jira (FR-021)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  # T002 (and its marker) is the only line attributing a task to the story;
  # removing it is the most direct "removed from tasks.md" (FR-021's own
  # wording), leaving TASKP-3 with no attributed task on the doc side.
  sed -i.bak '/^- \[ \] T002 /d' "${TASKS}"
  rm -f "${TASKS}.bak"
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.notes[] | select(contains("TASKP-3"))] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.notes[] | select(contains("TASKP-3"))' <<< "$output")" = "TASKP-3 is recorded in Jira as a sub-task of TASKP-2, but ${TASKS} no longer attributes any task to it; nothing was changed in Jira." ]
  # No write of any kind touched the sub-task — status, fields, and parent
  # were all left exactly as Jira already recorded them.
  [ "$(grep -cE "TASKP-3" "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "T070 [US3] — a task re-attributed to a different story reports the divergence once, by key, and re-parents nothing in Jira (FR-022)" {
  local cfg; cfg="$(_mock_configs)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  # Story 2 draws the NEXT id from the pool — the fixture's default four are
  # all consumed by the parent/story/two-task fresh run above.
  export SPEC_KIT_JIRA_ID_SOURCE="${SPEC_KIT_JIRA_ID_SOURCE} 5555555555555555"
  cat >> "${SPEC}" << 'EOF'

### User Story 2 - Second story (Priority: P2)

As a user, I want the second story.

- **Given** another thing
- **When** it happens
- **Then** it works too
EOF
  # A second run creates and recognises Story 2 (TASKP-4) BEFORE the
  # re-attribution happens — the divergence can only ever name a story
  # Jira already recorded, never one still pending creation this same run.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  # T002's durable marker (id=4444444444444444, ticket=TASKP-3) is untouched;
  # only its own attribution tag now points at User Story 2 instead of the
  # story Jira actually recorded it under. The tag, not the phase heading,
  # is what tasks_parse.sh resolves attribution from when both are present.
  sed -i.bak 's/\[US1\]/[US2]/' "${TASKS}"
  rm -f "${TASKS}.bak"
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local reattribution_note
  reattribution_note="$(jq -r '.notes[] | select(startswith("TASKP-3 is attributed to"))' <<< "$output")"
  [ -n "${reattribution_note}" ]
  [ "${reattribution_note}" = "TASKP-3 is attributed to TASKP-4 in ${TASKS}, but is recorded in Jira under TASKP-2; nothing was re-parented." ]
  # The description resync (the rendered "Attribution:" line) is a
  # legitimate, unrelated write — what matters is that no action ever
  # carries a "parent" field for this sub-task.
  [ "$(jq -r '[.actions[] | select(.url | endswith("TASKP-3")) | .body.fields | has("parent")] | any' <<< "$output")" = "false" ]
  [ "$(mock_issue_field "TASKP-3" '.fields.parent.key')" = "TASKP-2" ]
}
