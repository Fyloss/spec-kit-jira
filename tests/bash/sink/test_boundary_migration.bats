#!/usr/bin/env bats
# T052 [Phase 6, US4] — the one-time upgrade of a pre-release estate onto the
# boundary (FR-020/FR-020a/FR-020b/FR-021): an untouched ticket migrates
# cleanly, a human-prefixed one keeps its prefix exactly, an ambiguous one
# loses nothing and warns by ticket key, and the run after each settles to
# zero writes.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-pre-release-migration"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  SPEC="${WORK}/specs/001-feature/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-feature"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_ID_SOURCE

  mock_start "${MOCK}/configs/preserve-pre-release.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
}

@test "an untouched pre-release story migrates with nothing above the boundary and no duplication (FR-020a)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local pre1; pre1="$(jq -c '.actions[] | select(.url | endswith("PRE-1"))' <<< "$output")"
  [ -n "${pre1}" ]
  # The marker paragraph is the FIRST node: nothing sits above the boundary.
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre1}")" = "Synced from spec-kit — do not edit below this line" ]
  # The story's own line appears exactly once in the payload.
  [ "$(jq -r '[.body.fields.description.content[].content[].text? // empty] | map(select(. == "As a user, I want my note kept.")) | length' <<< "${pre1}")" -eq 1 ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-1"))) | length' <<< "$output")" -eq 0 ]
}

@test "a human-prefixed pre-release story keeps its prefix exactly (FR-020a)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local pre2; pre2="$(jq -c '.actions[] | select(.url | endswith("PRE-2"))' <<< "$output")"
  [ -n "${pre2}" ]
  # The human paragraph is preserved verbatim, above the boundary.
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre2}")" = "A human paragraph added after the mirror last wrote." ]
  [ "$(jq -r '.body.fields.description.content[1].content[0].text' <<< "${pre2}")" = "Synced from spec-kit — do not edit below this line" ]
  # The story's own line appears exactly once — no duplication.
  [ "$(jq -r '[.body.fields.description.content[].content[].text? // empty] | map(select(. == "As a user, I want my note kept.")) | length' <<< "${pre2}")" -eq 1 ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-2"))) | length' <<< "$output")" -eq 0 ]
}

@test "an ambiguous pre-release story loses nothing and produces one warning naming the ticket key (FR-020b)" {
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  local pre3; pre3="$(jq -c '.actions[] | select(.url | endswith("PRE-3"))' <<< "$output")"
  [ -n "${pre3}" ]
  # The whole prior description is preserved above the boundary — nothing lost.
  [ "$(jq -r '.body.fields.description.content[0].content[0].text' <<< "${pre3}")" = "Some unrelated content nobody expected." ]
  [ "$(jq -r '.body.fields.description.content[1].content[0].text' <<< "${pre3}")" = "Synced from spec-kit — do not edit below this line" ]
  [ "$(jq -r '[.warnings[]? // empty] | map(select(test("PRE-3"))) | length' <<< "$output")" -eq 1 ]
}

@test "the run after each migration reports zero writes (FR-021)" {
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null
  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.updated' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.warnings | length' <<< "$output")" -eq 0 ]
  # 021 US4's prefetch fires its own bulkfetch POST as a read, not a write.
  [ "$(grep -vE 'issue/bulkfetch' "${MOCK_CALLLOG}" | grep -cE '^(POST|PUT) ')" -eq 0 ]
}

# --- 019, T009: the reported defect — origin bridge, no boundary, an edited
# specification — driven directly through plan_writes rather than the mock
# pipeline above (spec.md's Independent Test for User Story 1).

DOC_AC='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]}},
      "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2",
                  "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},
                  "acceptance_criteria":[{"given":[[{"text":"the page is open"}]],"when":[[{"text":"the button is clicked"}]],"then":[[{"text":"Hello Universe is shown"}]]}]}]}'

@test "019, T009 — origin bridge, no boundary, edited acceptance criteria: exactly one AC section, status ok, no warning (FR-002)" {
  local old_ac existing ctx
  old_ac='{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},"acceptance_criteria":[{"given":[[{"text":"the page is open"}]],"when":[[{"text":"the button is clicked"}]],"then":[[{"text":"Hello World is shown"}]]}]}'
  existing="$(adf_render_description "${old_ac}" | jq -c '{type:"doc", version:1, content:.content}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, ticket_origins:{s1:"bridge"}, priority_ids:{P2:"2"}}')"
  run plan_writes "${DOC_AC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  local n; n="$(jq '[.. | objects | select(.type?=="heading") | .content[0].text] | map(select(.=="Acceptance Criteria")) | length' <<< "${desc}")"
  [ "${n}" -eq 1 ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"Hello Universe is shown"* ]]
  [[ "$(jq -c '.' <<< "${desc}")" != *"Hello World is shown"* ]]
  [ "$(jq -r '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

@test "019, T009 — origin bridge, no boundary, unchanged specification: exactly one AC section, status ok, no warning" {
  local existing ctx
  existing="$(adf_render_description "$(jq -c '.stories[0]' <<< "${DOC_AC}")" | jq -c '{type:"doc", version:1, content:.content}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, ticket_origins:{s1:"bridge"}, priority_ids:{P2:"2"}}')"
  run plan_writes "${DOC_AC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  local n; n="$(jq '[.. | objects | select(.type?=="heading") | .content[0].text] | map(select(.=="Acceptance Criteria")) | length' <<< "${desc}")"
  [ "${n}" -eq 1 ]
  [ "$(jq -r '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

# --- 019, T021: an origin that is neither "bridge" nor "human" ------------

@test "019, T021 — an undeterminable origin preserves the whole existing content and names the ticket in a warning (FR-004)" {
  local existing ctx
  existing="$(jq -cn '{type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:"unrelated content nobody expected"}]}]}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, ticket_origins:{s1:"corrupted-value"}, priority_ids:{P2:"2"}}')"
  run plan_writes '{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18","marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},"description":{"blocks":[]}},
      "stories":[{"local_id":"s1","title":"Story One","priority_logical":"P2","description":{"blocks":[{"type":"paragraph","spans":[{"text":"Story body.","marks":[]}]}]}}]}' "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  [[ "$(jq -c '.' <<< "${desc}")" == *"unrelated content nobody expected"* ]]
  [[ "$(jq -r '.warnings[]' <<< "$output")" == *"PROJ-1"* ]]
}

# --- 019, T046: the parent tier in the same condition (US1 AC3, FR-008) ----
# All three 019 cases above assert `.stories[0]` only, and PRE-9 in the
# pre-release fixture already carries the marker (it exercises rule 2, not
# the marker-absent branch this feature adds). This is the row-3 guard on
# the parent tier: probed by hand and correct, only the test was missing.

DOC_AC_PARENT='{"routing":{"project_key":"COMP"},
      "epic":{"title":"The Epic","local_id":"3f2a91c04b7e6d18",
              "marker":{"state":"assigned","id":"3f2a91c04b7e6d18","lines":[2]},
              "description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},
              "acceptance_criteria":[{"given":[[{"text":"the page is open"}]],"when":[[{"text":"the button is clicked"}]],"then":[[{"text":"Hello Universe is shown"}]]}]},
      "stories":[]}'

@test "019, T046 — origin bridge, no boundary, parent tier: the whole existing parent description is replaced, exactly one AC section, no warning (US1 AC3, FR-008)" {
  local old_ac existing ctx
  old_ac='{"description":{"blocks":[{"type":"paragraph","spans":[{"text":"Greeting button","marks":[]}]}]},"acceptance_criteria":[{"given":[[{"text":"the page is open"}]],"when":[[{"text":"the button is clicked"}]],"then":[[{"text":"Hello World is shown"}]]}]}'
  existing="$(adf_render_description "${old_ac}" | jq -c '{type:"doc", version:1, content:.content}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_origin:"bridge", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "${DOC_AC_PARENT}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.parent.body.fields.description' <<< "$output")"
  local n; n="$(jq '[.. | objects | select(.type?=="heading") | .content[0].text] | map(select(.=="Acceptance Criteria")) | length' <<< "${desc}")"
  [ "${n}" -eq 1 ]
  [[ "$(jq -c '.' <<< "${desc}")" == *"Hello Universe is shown"* ]]
  [[ "$(jq -c '.' <<< "${desc}")" != *"Hello World is shown"* ]]
  [ "$(jq -r '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

# --- 019, T052: the accepted-loss case, stated explicitly (spec Edge Cases,
# Assumptions) — a human deleted the boundary from a ticket the mirror
# created. The recorded origin still names the mirror, so rule 3 replaces the
# whole existing description; a paragraph a human typed while the boundary
# was missing is lost, silently (no warning: status is "ok", not
# "migrated-warned"). This is accepted deliberately, not a bug: the
# alternative is the duplication this feature fixes, and the record says the
# ticket is the mirror's.

@test "019, T052 — origin bridge, no boundary, a human paragraph typed into the gap: lost silently, not a warning (accepted trade-off)" {
  local managed existing ctx
  managed="$(adf_render_description "$(jq -c '.stories[0]' <<< "${DOC_AC}")" | jq -c '.content')"
  existing="$(jq -cn --argjson h '[{"type":"paragraph","content":[{"type":"text","text":"A human paragraph typed after the boundary went missing."}]}]' --argjson m "${managed}" '{type:"doc", version:1, content: ($h + $m)}')"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_local_id:"3f2a91c04b7e6d18", tickets:{s1:"PROJ-1"}, ticket_descriptions:{s1:$ex}, ticket_origins:{s1:"bridge"}, priority_ids:{P2:"2"}}')"
  run plan_writes "${DOC_AC}" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.stories[0].body.fields.description' <<< "$output")"
  # The human paragraph is gone — the accepted loss, not preserved anywhere.
  [[ "$(jq -c '.' <<< "${desc}")" != *"A human paragraph typed after the boundary went missing."* ]]
  # And silently: no warning names this ticket, because the recorded origin
  # says the ticket is the mirror's own (status "ok", not "migrated-warned").
  [ "$(jq -r '.warnings // [] | length' <<< "$output")" -eq 0 ]
}
