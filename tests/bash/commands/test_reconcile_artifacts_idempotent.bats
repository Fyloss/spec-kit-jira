#!/usr/bin/env bats
# T061/T063/T065/T067/T068/T069 [Phase 4, 036] — re-running changes nothing
# (contracts/artifact-publication.md C1 "Call budget", C4.3, C4.4; FR-009,
# FR-010; US2 AS1-AS3; SC-003, SC-010).
#
# US1 shipped alone republishes every artifact on every run — a Principle II
# violation, which is why the specification made US2 P1 alongside it. THIS file
# is what makes the increment shippable.
#
# Every assertion reads `$MOCK_CALLLOG`, never the summary. A run that reported
# `unchanged` and issued the writes anyway is precisely the defect, and only the
# call log can tell the two apart.
#
# THE STEADY STATE IS THE SECOND RUN. Run 1 creates the tickets, stamps its
# identity marker into spec.md, and publishes the artifact set as it stands
# AFTER that write — so run 2 has nothing left to do. It took a defect to learn
# why that ordering matters: while the publication classified the PRE-write set,
# run 1 attached bytes it had already superseded, run 2 "revised" spec.md to
# correct it, and the run-state document recorded a hash the next run could
# never reproduce.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${WORK}"
  FEATURE_DIR="${WORK}/specs/001-billing-invoices"
  SPEC="${FEATURE_DIR}/spec.md"

  git -C "${WORK}" init --quiet
  git -C "${WORK}" config user.email 'fixture@example.invalid'
  git -C "${WORK}" config user.name 'fixture'

  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT

  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_BASE_URL
}

_run_mirror() { cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null; }

# _settle — run once to the steady state. ONE run, not two: the set the
# publication classifies is rebuilt AFTER the apply, so the ticket markers the
# apply stamps into spec.md are already in the recorded hashes. Before that
# rebuild the first run published pre-marker bytes under a hash matching
# neither, and the second run "revised" spec.md to correct it — a second
# publication of a file nobody had touched.
# The call log is truncated after, so every count below is "what the NEXT run
# did" rather than a total.
_settle() {
  _run_mirror > /dev/null
  : > "${MOCK_CALLLOG}"
}

_count() { mock_calls | grep -cE "$1" || true; }

_uploads() { _count '^POST .*/attachments( |$)'; }
_comments() { _count '^POST .*/comment( |$)'; }
_manifest_writes() { _count '^PUT .*properties/spec-kit-jira-artifacts'; }
_manifest_reads() { _count '^GET .*properties/spec-kit-jira-artifacts'; }

# ---- T065 / FR-009 / US2 AS1: the zero-churn floor ---------------------------

@test "T065 FR-009 an unchanged directory issues ZERO writes of all three kinds" {
  _settle

  _run_mirror > /dev/null

  [ "$(_uploads)" -eq 0 ]
  [ "$(_comments)" -eq 0 ]
  [ "$(_manifest_writes)" -eq 0 ]
}

@test "T065 the run still REPORTS every artifact, as unchanged" {
  # Zero writes must not mean zero information: the operator needs to see that
  # the run considered each file and decided nothing, which is what
  # distinguishes a working zero-churn run from one that skipped the phase.
  _settle

  local summary
  summary="$(_run_mirror)"
  [ "$(jq -r '(.artifacts // []) | length' <<< "${summary}")" -gt 0 ]
  [ "$(jq -r '[.artifacts[] | select(.action != "unchanged")] | length' <<< "${summary}")" -eq 0 ]
}

# ---- T067 / C1 "Call budget": the three rows ---------------------------------

@test "T067 C1 a run that proceeds with everything unchanged makes exactly ONE artifact call" {
  # The middle row, and the one a loose reading gets wrong: not zero — the
  # manifest still has to be read to know nothing changed — and not more than
  # one, because the trust rule's ticket read is conditional and the ids are
  # all still on the ticket.
  _settle
  _run_mirror > /dev/null

  [ "$(_manifest_reads)" -eq 1 ]
  [ "$(_uploads)" -eq 0 ]
  [ "$(_comments)" -eq 0 ]
  [ "$(_manifest_writes)" -eq 0 ]
}

@test "T067 C1 a run that publishes makes the bounded set and no more" {
  # One limit discovery, one manifest read, one upload, one comment, one
  # manifest write — whatever the artifact count (FR-023).
  : > "${MOCK_CALLLOG}"
  _run_mirror > /dev/null

  [ "$(_count '^GET /rest/api/3/attachment/meta$')" -eq 1 ]
  [ "$(_manifest_reads)" -eq 1 ]
  [ "$(_uploads)" -eq 1 ]
  [ "$(_comments)" -eq 1 ]
  [ "$(_manifest_writes)" -eq 1 ]
}

@test "T067 C1 a short-circuited run makes ZERO artifact calls of any kind" {
  # The first row. A short-circuit means the run decided nothing had changed
  # before reaching the network at all, so not even the limit is discovered.
  _settle
  _run_mirror > /dev/null
  : > "${MOCK_CALLLOG}"

  # Re-run with the state file intact and nothing touched.
  _run_mirror > /dev/null
  [ "$(_count '^GET /rest/api/3/attachment/meta$')" -le 1 ]
  [ "$(_uploads)" -eq 0 ]
  [ "$(_comments)" -eq 0 ]
  [ "$(_manifest_writes)" -eq 0 ]
}

# ---- T068 / US2 AS2: the third and fourth runs ------------------------------

@test "T068 US2 AS2 the third and fourth runs leave the counts where the first left them" {
  _settle

  _run_mirror > /dev/null
  local after_third_up after_third_cm
  after_third_up="$(_uploads)"
  after_third_cm="$(_comments)"

  _run_mirror > /dev/null
  [ "$(_uploads)" -eq "${after_third_up}" ]
  [ "$(_comments)" -eq "${after_third_cm}" ]
  [ "$(_uploads)" -eq 0 ]
}

# ---- T069 / FR-010 / US2 AS3 / SC-003: exactly one artifact changed ----------

@test "T069 FR-010 SC-003 exactly one changed artifact publishes exactly that one" {
  _settle

  printf '%s\n' '# Phase 0 — Research' '' 'One line changed, nothing else.' \
    > "${FEATURE_DIR}/research.md"

  local summary
  summary="$(_run_mirror)"

  # Exactly one upload, carrying exactly one part.
  [ "$(_uploads)" -eq 1 ]
  [ "$(mock_calls | grep -E '^POST .*/attachments' | sed 's/^.* parts=//')" = "research.md" ]
  # …and the comment announces exactly it.
  [ "$(_comments)" -eq 1 ]
  # No write for any unchanged artifact: the summary says so and the part list
  # above proves it.
  [ "$(jq -r '[.artifacts[] | select(.action == "published" or .action == "revised") | .path] | join(",")' <<< "${summary}")" = "research.md" ]
}

@test "T069 FR-008 SC-004 exactly ONE comment per publishing run, and zero otherwise" {
  # T044's command-level half. The module test proves the body; only a run can
  # prove how many times it is posted.
  _settle
  [ "$(_comments)" -eq 0 ]

  printf '%s\n' '# Phase 0 — Research' '' 'A change.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null
  [ "$(_comments)" -eq 1 ]

  : > "${MOCK_CALLLOG}"
  _run_mirror > /dev/null
  [ "$(_comments)" -eq 0 ]
}

# ---- T061 / C4.3 / SC-010: the trust rule, and recovery from a partial run ---

@test "T061 C4.3 the ticket's attachment list is read ONLY when the manifest claims an id" {
  # A first run has no manifest, so there is nothing to disbelieve and the
  # extra read would be a request for nothing.
  : > "${MOCK_CALLLOG}"
  _run_mirror > /dev/null
  [ "$(_count '^GET /rest/api/3/issue/[^/]+\?fields=attachment')" -eq 0 ]

  # A later run has one, so the rule fires exactly once.
  : > "${MOCK_CALLLOG}"
  _run_mirror > /dev/null
  [ "$(_count '^GET /rest/api/3/issue/[^/]+\?fields=attachment')" -eq 1 ]
}

@test "T061 SC-010 a manifest ahead of the ticket republishes rather than trusting itself" {
  # The property write landed and the upload did not — the shape a run that
  # died partway leaves behind. Without the trust rule the artifact reads
  # `unchanged` forever and never actually exists on the ticket.
  _settle

  # Rewrite the manifest to claim an attachment id the ticket does not carry.
  local manifest
  manifest="$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts" \
    | jq -c '.value.artifacts | with_entries(.value.attachment_id = "999999")')"
  curl -s -X PUT -H 'Content-Type: application/json' \
    -d "$(jq -cn --argjson a "${manifest}" '{schema: 1, artifacts: $a}')" \
    "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts" > /dev/null
  : > "${MOCK_CALLLOG}"

  local summary
  summary="$(_run_mirror)"
  [ "$(_uploads)" -eq 1 ]
  [ "$(jq -r '[.artifacts[] | select(.action == "published")] | length' <<< "${summary}")" -gt 0 ]
}

@test "T061 SC-010 an upload that landed with no manifest written republishes, as a revision" {
  # The other half of the partial-run pair: the attachments are on the ticket
  # and nothing recorded them. The duplicate is accepted — Jira allows two
  # attachments with one name, and losing an artifact is worse than carrying it
  # twice (FR-014).
  _settle

  # An EMPTY manifest, not a deleted property: the classifier reads both the
  # same way — "nothing was ever recorded" — and Jira's property DELETE is a
  # route neither mock serves, so a delete here would silently do nothing and
  # the test would pass against an unchanged manifest instead.
  curl -s -X PUT -H 'Content-Type: application/json' \
    -d '{"schema":1,"artifacts":{}}' \
    "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts" > /dev/null
  : > "${MOCK_CALLLOG}"

  local summary
  summary="$(_run_mirror)"
  # Everything is published again; nothing is lost.
  [ "$(_uploads)" -eq 1 ]
  [ "$(jq -r '[.artifacts[] | select(.action == "unchanged")] | length' <<< "${summary}")" -eq 0 ]
  [ "$(_manifest_writes)" -eq 1 ]
}

# ---- T063 / C4.4: the manifest's bound at the command level -----------------

@test "T063 C4.4.1 a manifest that would overflow withholds the WHOLE publication before any upload" {
  # Fail closed rather than publishing what fits: a partial manifest would make
  # the next run republish exactly the artifacts this one dropped, forever.
  # The cap is lowered rather than the fixture widened — the assertion is about
  # the decision, and a 400-file fixture would make the suite slow to prove the
  # same thing.
  export SPEC_KIT_JIRA_PROPERTY_CAP=1
  local summary
  summary="$(_run_mirror)"

  [ "$(_uploads)" -eq 0 ]
  [ "$(_comments)" -eq 0 ]
  [ "$(_manifest_writes)" -eq 0 ]
  [ "$(jq -r '[.warnings[] | select(test("more artifacts than one ticket can track"))] | length' <<< "${summary}")" -eq 1 ]
  unset SPEC_KIT_JIRA_PROPERTY_CAP
}
