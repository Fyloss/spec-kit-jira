#!/usr/bin/env bats
# T077/T078/T079/T080 [Phase 5, 036] — a revised artifact is republished and the
# earlier one survives (FR-013, FR-014, FR-015; US3 AS1-AS4; C6, comment-body B3).
#
# The record follows the folder across the feature's life. That is only true if
# nothing is ever removed: a superseded attachment is a previous version of the
# specification, and Principle I says the bridge does not destroy what it did not
# create — nor, here, what it did.
#
# The assertions read the TICKET, through the mock's own attachment list, rather
# than the run summary. "The earlier copy survives" is a statement about the
# ticket, and a summary cannot make it true.

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

  # research.md exists BEFORE the first run, so the first publication carries it
  # and every later change to it is a REVISION. Creating it after settling would
  # make every case below assert `published`, which is the other feature.
  printf '%s\n' '# Phase 0 — Research' '' 'The first version of this file.' \
    > "${FEATURE_DIR}/research.md"

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
_settle() {
  _run_mirror > /dev/null
}

# _ticket_attachments — the attachment list the TICKET actually carries, as the
# mock reports it. This is the ground truth the whole phase is about.
_ticket_attachments() {
  curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1?fields=attachment" \
    | jq -c '[.fields.attachment[] | {id: (.id|tostring), filename: .filename}]'
}

_count() { mock_calls | grep -cE "$1" || true; }

# ---- T077 / FR-013 / US3 AS1: the revision is published and announced -------

@test "T077 FR-013 a changed artifact is published again and announced as a revision" {
  _settle
  : > "${MOCK_CALLLOG}"

  printf '%s\n' '# Phase 0 — Research' '' 'The second version of this file.' \
    > "${FEATURE_DIR}/research.md"

  local summary
  summary="$(_run_mirror)"
  [ "$(jq -r '[.artifacts[] | select(.path == "research.md") | .action] | join("")' <<< "${summary}")" = "revised" ]

  # B3: the comment's own line for it reads ' — revised', not ' — new'. Read
  # from the call log, which carries the body verbatim since T053, so this is
  # the bytes the ticket received rather than what the port says it composed.
  local body
  body="$(mock_calls | grep -E '^POST .*/comment' | sed 's/^.* body=//')"
  [ "$(jq -r '.body.content[1].content[0].content[0].content[1].text' <<< "${body}")" = " — revised" ]
  [ "$(jq -r '.body.content[1].content[0].content[0].content[0].text' <<< "${body}")" = "research.md" ]
}

@test "T077 B2 the paragraph switches to the revision literal when anything is a revision" {
  _settle
  : > "${MOCK_CALLLOG}"
  printf '%s\n' '# Phase 0 — Research' '' 'Changed.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null

  local body tail
  body="$(mock_calls | grep -E '^POST .*/comment' | sed 's/^.* body=//')"
  tail="$(jq -r '.body.content[0].content[2].text' <<< "${body}")"
  # Compared against the contract's own line rather than a transcription of it:
  # the display layer through which a human reads a file can drop words.
  local contract_line
  contract_line="$(sed -n '42p' "${ROOT}/specs/036-attach-feature-artifacts/contracts/comment-body.md" | sed 's/^  //')"
  [ "$(jq -r '.body.content[0].content[0].text' <<< "${body}")\`<event>\`${tail}" = "${contract_line}" ]
}

# ---- T078 / FR-014 / US3 AS2 / C6: the earlier copy survives ----------------

@test "T078 FR-014 after a revision the ticket carries BOTH copies, under one name" {
  _settle
  local before
  before="$(_ticket_attachments)"
  [ "$(jq -r '[.[] | select(.filename == "research.md")] | length' <<< "${before}")" -eq 1 ]

  printf '%s\n' '# Phase 0 — Research' '' 'Revised.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null

  local after
  after="$(_ticket_attachments)"
  # TWO attachments now share the name, with different ids: the revision is a
  # second attachment, never a replacement (research R7).
  [ "$(jq -r '[.[] | select(.filename == "research.md")] | length' <<< "${after}")" -eq 2 ]
  [ "$(jq -r '[.[] | select(.filename == "research.md") | .id] | unique | length' <<< "${after}")" -eq 2 ]
  # The original id is still there — this is the assertion, not the count.
  local first_id
  first_id="$(jq -r '[.[] | select(.filename == "research.md") | .id] | first' <<< "${before}")"
  [ "$(jq -r --arg i "${first_id}" '[.[] | select(.id == $i)] | length' <<< "${after}")" -eq 1 ]
}

@test "T078 C6 no DELETE is issued against any attachment, on any run" {
  _settle
  printf '%s\n' '# Research' '' 'Revised once.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null
  printf '%s\n' '# Research' '' 'Revised twice.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null

  [ "$(_count '^DELETE ')" -eq 0 ]
}

# ---- T079 / US3 AS3: the order is unambiguous from the comments -------------

@test "T079 US3 AS3 several versions leave a comment stream that orders them" {
  _settle
  : > "${MOCK_CALLLOG}"

  printf '%s\n' '# Research' '' 'Version two.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null
  printf '%s\n' '# Research' '' 'Version three.' > "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null

  # Two comments, in run order, each naming research.md as revised. A reader
  # identifies the most recent version as the one the last comment announces,
  # without opening a single file.
  local comments
  comments="$(mock_calls | grep -cE '^POST .*/comment')"
  [ "${comments}" -eq 2 ]

  local line
  while IFS= read -r line; do
    local body
    body="$(sed 's/^.* body=//' <<< "${line}")"
    [ "$(jq -r '.body.content[1].content[0].content[0].content[0].text' <<< "${body}")" = "research.md" ]
    [ "$(jq -r '.body.content[1].content[0].content[0].content[1].text' <<< "${body}")" = " — revised" ]
  done < <(mock_calls | grep -E '^POST .*/comment')

  # …and the ticket carries three copies: the original and the two revisions.
  [ "$(jq -r '[.[] | select(.filename == "research.md")] | length' <<< "$(_ticket_attachments)")" -eq 3 ]
}

# ---- T080 / FR-015 / US3 AS4: a deleted artifact is left alone -------------

@test "T080 FR-015 deleting an artifact leaves its copies on the ticket and writes nothing" {
  _settle
  local before
  before="$(_ticket_attachments)"
  [ "$(jq -r '[.[] | select(.filename == "research.md")] | length' <<< "${before}")" -eq 1 ]

  rm -f "${FEATURE_DIR}/research.md"
  : > "${MOCK_CALLLOG}"

  local summary
  summary="$(_run_mirror)"

  # Zero Jira writes of every publication kind: a deletion is not a publication
  # event, and there is nothing on the ticket to correct.
  [ "$(_count '^POST .*/attachments')" -eq 0 ]
  [ "$(_count '^POST .*/comment')" -eq 0 ]
  [ "$(_count '^PUT .*properties/spec-kit-jira-artifacts')" -eq 0 ]

  # The published copy is still downloadable.
  [ "$(jq -r '[.[] | select(.filename == "research.md")] | length' <<< "$(_ticket_attachments)")" -eq 1 ]
  # …and it has left the run summary, because it has left the directory.
  [ "$(jq -r '[.artifacts[] | select(.path == "research.md")] | length' <<< "${summary}")" -eq 0 ]
}

@test "T080 FR-015 the manifest entry for a deleted artifact is LEFT IN PLACE" {
  # Its attachment still exists on the ticket, so the manifest still describes
  # reality. Dropping it would make a later re-add look like a first
  # publication — a duplicate for no reason.
  _settle
  rm -f "${FEATURE_DIR}/research.md"
  _run_mirror > /dev/null

  local manifest
  manifest="$(curl -s "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts" \
    | jq -c '.value.artifacts')"
  [ "$(jq -r 'has("research.md")' <<< "${manifest}")" = "true" ]
}
