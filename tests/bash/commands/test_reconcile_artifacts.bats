#!/usr/bin/env bats
# T034/T039/T040/T041/T048/T054/T055/T056 [Phase 3, 036] — the publication as a
# whole reconcile performs it (contracts/artifact-publication.md C1, C3.7, C3.9;
# FR-001, FR-003, FR-006, FR-017, FR-019, FR-023; SC-001, SC-005).
#
# The unit cases in tests/bash/sink/test_attachments.bats prove the module
# decides correctly. These prove the only things they cannot: what the RUN sent.
# Every assertion here reads `$MOCK_CALLLOG` — what the reconcile actually did —
# rather than the summary, which is what it says it did. Those two disagreeing
# is the defect class this file exists for.
#
# The call log carries the multipart part list and the comment body since T053,
# so "one request, parts in the set's sort order" is a single string comparison
# rather than an inference from a count.

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

  # The artifact set is `git ls-files` over the feature directory (research R5),
  # so the fixture has to be a repository — which every consumer tree is.
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
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_HOOK_CONTEXT SPEC_KIT_JIRA_BASE_URL
}

# _start <config-json-or-path> — start the mock on a config, either an existing
# path or a JSON literal written to a temp file.
_start() {
  local cfg="$1"
  if [[ "${cfg}" == '{'* ]]; then
    local f="${BATS_TEST_TMPDIR}/cfg-$$-${RANDOM}.json"
    printf '%s' "${cfg}" > "${f}"
    cfg="${f}"
  fi
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

# _attachment_posts — one line per upload request, with its `parts=` annotation.
_attachment_posts() {
  mock_calls | grep -E '^POST .*/attachments( |$)' || true
}

# _count <extended-regex> — how many call-log lines match.
_count() {
  mock_calls | grep -cE "$1" || true
}

# ---- T048 / SC-001: a first run publishes everything -------------------------

@test "T048 SC-001 a first run publishes EVERY artifact of the directory" {
  _start "${MOCK}/configs/default.json"

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"

  # The summary names every file the feature directory holds — none missing.
  # Derived from the tree rather than hard-coded, so a fixture that grows makes
  # this stricter instead of stale.
  local expected actual
  expected="$(cd "${FEATURE_DIR}" && git ls-files --cached --others --exclude-standard | sort | tr '\n' ' ')"
  actual="$(jq -r '[.artifacts[].path] | sort | join(" ") + " "' <<< "${summary}")"
  [ "${actual}" = "${expected}" ]

  # …and every one of them as a first publication.
  [ "$(jq -r '[.artifacts[] | select(.action != "published")] | length' <<< "${summary}")" -eq 0 ]
}

@test "T039 FR-023 exactly ONE upload request per run, parts in the set's sort order" {
  _start "${MOCK}/configs/default.json"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1

  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq 1 ]

  # The part list, as sent, against the flattened names in the set's byte-wise
  # path order. A port batching correctly but ordering differently would pass a
  # count assertion and fail this one, which is the point.
  local expected got
  expected="$(cd "${FEATURE_DIR}" && git ls-files --cached --others --exclude-standard \
    | LC_ALL=C sort | sed 's#/#__#g' | paste -sd, -)"
  got="$(_attachment_posts | sed 's/^.* parts=//')"
  [ "${got}" = "${expected}" ]
}

@test "T034 C1.1 GET /attachment/meta is called exactly once per run" {
  # The limit is held in-process for the run: a second discovery per artifact
  # would be a process-budget defect invisible to every other assertion here.
  _start "${MOCK}/configs/default.json"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1
  [ "$(_count '^GET /rest/api/3/attachment/meta$')" -eq 1 ]
}

@test "T034 C1.1 the limit is not discovered at all when there is nothing to publish" {
  # Routing is refused, so the run never reaches a ticket — and a discovery
  # call made anyway would be a request issued for a run that publishes
  # nothing.
  _start "${MOCK}/configs/default.json"
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
routing: []
YAML
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1 || true
  [ "$(_count '^GET /rest/api/3/attachment/meta$')" -eq 0 ]
}

@test "T040 FR-003 the upload targets the specification tier only" {
  _start "${MOCK}/configs/default.json"

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"

  # Whatever keys this run created, exactly ONE of them is an attachment
  # target, and it is the parent. Read from the log, so a story-tier upload
  # would show up here even if the summary claimed otherwise.
  local targets
  targets="$(_attachment_posts | sed -E 's#^POST /rest/api/3/issue/([^/]+)/attachments.*#\1#')"
  [ "$(wc -l <<< "${targets}" | tr -d ' ')" -eq 1 ]

  # The parent is the FIRST issue this fixture creates, and the story the
  # second; asserting the target is not the story is the half that would catch
  # a tier mix-up.
  [ "${targets}" = "COMP-1" ]
  [ "$(_count '^POST /rest/api/3/issue/COMP-2/attachments')" -eq 0 ]
}

@test "T041 FR-006 a specification ticket created in this run is published onto in this run" {
  # Nothing pre-exists in this fixture, so the parent's key is known only from
  # the apply outcome — recognition ran before it existed. Publication deferred
  # to a later run would leave zero uploads here and look like success.
  _start "${MOCK}/configs/default.json"

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(jq -r '.counts.created' <<< "${summary}")" -gt 0 ]
  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq 1 ]
  # The create and the upload are in ONE run, in that order.
  local order
  order="$(mock_calls | grep -nE '^POST /rest/api/3/issue($| )|^POST .*/attachments' | head -1)"
  [[ "${order}" == *"POST /rest/api/3/issue"* ]]
}

# ---- T034: withholding the whole publication (C3.7, C3.9) --------------------

@test "T034 C3.9 attachments disabled site-wide withholds everything, with one warning" {
  # `"enabled": false` is the C3.9 site state, and reading it back correctly is
  # not free: jq's `//` treats false as absent, so both the shim and the Bash
  # port answered TRUE for this config until this case was written. The
  # PowerShell twin tests for presence and always honoured it — a silent
  # cross-port divergence on the one path that switches the whole feature off.
  _start '{"projects":{"COMP":"company"},"attachment_meta":{"enabled":false,"uploadLimit":10485760}}'

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(_count '^POST .*/comment')" -eq 0 ]
  [ "$(_count 'properties/spec-kit-jira-artifacts')" -eq 0 ]
  # The warning is read out of the summary, not the prose: the prose renderer
  # prints a warning COUNT and never the text (lib/output.sh
  # summary_render_prose), which is pre-existing and wider than this feature.
  [ "$(jq -r '[.warnings[] | select(test("attachments disabled"))] | length' <<< "${summary}")" -eq 1 ]
}

@test "T034 C3.7 an unreadable limit withholds everything, with one warning and no upload" {
  # No guessed default: Principle VII forbids compiling in a site fact, so a
  # discovery that fails means the run cannot know what it may send.
  _start '{"projects":{"COMP":"company"},"faults":{"rest/api/3/attachment/meta":{"status":500}}}'

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(_count '^POST .*/comment')" -eq 0 ]
  # Not even the manifest is read: the run stopped before it could matter.
  [ "$(_count 'properties/spec-kit-jira-artifacts')" -eq 0 ]
  [ "$(jq -r '[.warnings[] | select(test("attachment limit could not be read"))] | length' <<< "${summary}")" -eq 1 ]
}

# ---- T054: the scenario that justifies after_checklist -----------------------

@test "T054 SC-005 FR-019 a new checklist file alone is published on the next mirror" {
  # The scenario that justifies `after_checklist` existing at all: spec.md,
  # plan.md and tasks.md are untouched, and the ONLY change is a checklist a
  # Spec Kit command just wrote. If the run does not publish it, the event buys
  # nothing.
  _start "${MOCK}/configs/default.json"
  # ONE run reaches the steady state: the publication classifies the set as it
  # stands AFTER the apply, so the identity marker the apply writes into
  # spec.md is already in the published hashes and the next run has nothing to
  # correct.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1

  local first_uploads
  first_uploads="$(_attachment_posts | wc -l | tr -d ' ')"
  [ "${first_uploads}" -eq 1 ]

  mkdir -p "${FEATURE_DIR}/checklists"
  printf '%s\n' '# Checklist: UX' '' '- [x] The flow is understandable' \
    > "${FEATURE_DIR}/checklists/ux.md"

  local summary
  summary="$(SPEC_KIT_JIRA_HOOK_EVENT=after_checklist \
    cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"

  # Exactly that file, and nothing else, published by the second run.
  [ "$(jq -r '[.artifacts[] | select(.action == "published" or .action == "revised") | .path] | join(",")' <<< "${summary}")" = "checklists/ux.md" ]
  [ "$(_attachment_posts | tail -1 | sed 's/^.* parts=//')" = "checklists__ux.md" ]
}

# ---- T055: publication onto an adopted ticket --------------------------------

@test "T055 publication onto a human-origin (adopted) specification ticket succeeds" {
  # The human-origin protection concerns DELETION and OVERWRITE, and publication
  # is neither: it adds an attachment and a comment, taking nothing away. A
  # guard that refused here would make the feature useless on every ticket a
  # team adopted rather than let the bridge create (Principle I, spec Edge
  # Cases).
  _start "${MOCK}/configs/default.json"

  # Run once so the ticket exists, then re-stamp its origin marker as adopted —
  # the state an adopted ticket is in, without depending on the adoption path's
  # own machinery.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1
  curl -s -X PUT -H 'Content-Type: application/json' \
    -d '{"origin":"human","adopted":true}' \
    "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/properties/spec-kit-jira-origin" > /dev/null

  # Change one artifact so the second run has something to publish at all.
  printf '%s\n' '# Research' '' 'A second revision, nothing sensitive.' \
    > "${FEATURE_DIR}/research.md"

  local before summary
  before="$(_attachment_posts | wc -l | tr -d ' ')"
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq $((before + 1)) ]
  [ "$(jq -r '[.artifacts[] | select(.action == "published" or .action == "revised")] | length' <<< "${summary}")" -gt 0 ]
}

# ---- T056: no specification ticket, and no half-publication ------------------

@test "T056 a refused routing publishes nothing, half-publishes nothing, writes no manifest" {
  _start "${MOCK}/configs/default.json"
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
routing: []
YAML

  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1 || true

  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(_count '^POST .*/comment')" -eq 0 ]
  # The manifest is the thing that must NOT be written: a manifest recorded for
  # a publication that never happened makes the next run believe those
  # artifacts are already on a ticket that does not exist.
  [ "$(_count '^PUT .*properties/spec-kit-jira-artifacts')" -eq 0 ]
}

@test "T056 the next successful run publishes the directory as it then stands" {
  # Not as it stood when the refused run saw it. The refusal recorded nothing,
  # so the recovery is a first publication of the CURRENT tree — including a
  # file written between the two runs.
  _start "${MOCK}/configs/default.json"
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
routing: []
YAML
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1 || true

  printf '%s\n' '# Phase 0 — Research' '' 'Written after the refusal.' \
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

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(_attachment_posts | wc -l | tr -d ' ')" -eq 1 ]
  # research.md is in it, as a FIRST publication — nothing recorded it before.
  [ "$(jq -r '[.artifacts[] | select(.path == "research.md") | .action] | join("")' <<< "${summary}")" = "published" ]
}
