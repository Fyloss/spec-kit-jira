#!/usr/bin/env bats
# T105/T106/T107 [029, Phase 9] — SC-002 (the headline outcome, "the chain
# nobody was testing") and US2 AC3 (the other half, equally untested). Every
# other test in this feature exercises one command in isolation; this file
# chains `feature` -> `seed --confirm` -> `reconcile --dry-run` in-process,
# because the reported incident was a COMPOSITION defect — each command was
# individually correct, and the ticket was still never bound.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/seed_fixture.bash"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/feature.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/seed.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  WORK="$(mktemp -d)"
  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  helper_seed_config "${JIRA_CONFIG_DIR}" IJT ijt
  # reconcile needs the resolved numeric ids a real /speckit.jira-mirror.config run
  # would have discovered — copied from the proven repo-with-seed-teams
  # fixture rather than re-derived, since this file's own job is the
  # feature->seed->reconcile composition, not type-id discovery.
  cp "${ROOT}/tests/conformance/fixtures/repo-with-seed-teams/.specify/jira/config.local.yml" \
    "${JIRA_CONFIG_DIR}/config.local.yml"
}

teardown() {
  mock_stop
  rm -rf "${WORK}"
}

@test "T105/T107: SC-002 — question, --reuse yes, seed --confirm, reconcile --dry-run: zero duplicate parents, IJT-42 reused" {
  local cfg
  cfg="$(mock_write_config '{"projects":{"IJT":"team"},"issues":{"IJT-42":{"summary":"Rework the export pipeline","issuetype":{"name":"Epic"},"status":{"name":"To Do"},"project":{"key":"IJT"},"description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Rework the export pipeline body."}]}]}}}}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Run 1: a mentioned ticket, no designator -> the reuse question. Zero
  # writes, nothing named (this is the reported defect's fix) — the only
  # request is the wide GET the question is composed from.
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]
  ! mock_calls | grep -qE 'POST|PUT'

  # Run 2: --reuse yes with no explicit designator auto-accepts the derived
  # proposal (US3 AC1) and routes into 027's designator path. Still zero
  # Jira writes — only the local seeded-not-bound record.
  run cmd_feature feature IJT-42 --reuse yes --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "adopted" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-42" ]
  ! mock_calls | grep -qE 'POST|PUT'
  local short_name spec
  short_name="$(jq -r '.short_name' <<< "$output")"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-${short_name}"
  spec="${WORK}/specs/${short_name}/spec.md"
  mkdir -p "$(dirname "${spec}")"
  printf '%s\n' \
    '# Feature' \
    '' \
    '### User Story 1 - Freely chosen by the agent (Priority: P1)' \
    '' \
    'Body one, unpinned.' \
    > "${spec}"

  # Run 3: seed --confirm actually binds IJT-42 as the parent — the write
  # the original bug report's incident never reached. The drafted,
  # unpinned user story is NOT created here; that is reconcile's job, and
  # proving so (zero duplicate parent, one story) is run 4's whole point.
  run cmd_seed seed "${spec}" --confirm --json
  [ "$status" -eq 0 ]
  [ "$(mock_calls | grep -c '^PUT /rest/api/3/issue/IJT-42/properties/spec-kit-jira$')" -eq 1 ]
  grep -qE 'speckit-jira spec=[0-9a-f]{16} ticket=IJT-42' "${spec}"

  # Run 4: the ordinary reconcile that follows — SC-002's headline claim.
  # Zero parent creates: IJT-42 is already bound, and is the parent reused
  # (a PUT update, never a POST create) while the drafted story IS created.
  run cmd_reconcile reconcile "${spec}" --json --dry-run
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.actions[]? // empty | select(.role=="parent" and (.url | endswith("/issue")) and .method=="POST")] | length' <<< "$output")" -eq 0 ]
  [ "$(jq -r '[.actions[]? // empty | select(.role=="parent" and .url=="/rest/api/3/issue/IJT-42" and .method=="PUT")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.actions[]? // empty | select(.role=="story" and (.url | endswith("/issue")) and .method=="POST")] | length' <<< "$output")" -eq 1 ]
}

@test "T106: US2 AC3 — --reuse no leaves IJT-42 untouched and the following reconcile creates a fresh parent, exactly as before this feature" {
  local cfg
  cfg="$(mock_write_config '{"projects":{"IJT":"team"},"issues":{"IJT-42":{"summary":"Rework the export pipeline","issuetype":{"name":"Epic"},"status":{"name":"To Do"},"project":{"key":"IJT"},"description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Rework the export pipeline body."}]}]}}},"createdKey":"IJT-500"}')"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Run 1: the same reuse question as the other half of this proof.
  run cmd_feature feature IJT-42 --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("reuse_required")' <<< "$output")" = "true" ]

  # Run 2: --reuse no proceeds exactly as the pre-029 release did — naming
  # only, from the mentioned ticket's number. No binding, no adoption stamp.
  run cmd_feature feature IJT-42 --reuse no --json "invoice export"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ticket.action' <<< "$output")" = "attached" ]
  [ "$(jq -r '.ticket.key' <<< "$output")" = "IJT-42" ]
  local short_name spec
  short_name="$(jq -r '.short_name' <<< "$output")"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-${short_name}"
  spec="${WORK}/specs/${short_name}/spec.md"
  mkdir -p "$(dirname "${spec}")"

  # The drafted spec.md carries no marker of any kind — IJT-42 was named for
  # naming purposes only, never bound, exactly as it was before this feature.
  printf '%s\n' \
    '# Feature' \
    '' \
    '### User Story 1 - Freely chosen by the agent (Priority: P1)' \
    '' \
    'Body one, unpinned.' \
    > "${spec}"

  # Run 3: reconcile creates a fresh parent plus the one drafted story — the
  # acceptance criterion that says "reconcile behaves exactly as it does
  # today" (US2 AC3), which had no task of any kind before T106.
  run cmd_reconcile reconcile "${spec}" --json --dry-run
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.actions[]? // empty | select(.role=="parent" and (.url | endswith("/issue")) and .method=="POST")] | length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '[.actions[]? // empty | select(.role=="story" and (.url | endswith("/issue")) and .method=="POST")] | length' <<< "$output")" -eq 1 ]
  # IJT-42 itself is never referenced by this reconcile's plan at all.
  [[ "$output" != *"IJT-42"* ]]
}
