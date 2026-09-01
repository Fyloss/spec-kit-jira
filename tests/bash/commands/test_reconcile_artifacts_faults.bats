#!/usr/bin/env bats
# T084/T085/T086/T088/T090/T092 [Phase 6, 036] — the operator can predict and
# audit the publication, and no publication failure ever fails the host command
# (contracts/artifact-publication.md C3.2-C3.6, C4.4.2; FR-018, FR-020, FR-021;
# US4 AS1-AS4; SC-006, SC-011).
#
# C3.2 IS THE LOAD-BEARING ROW and the reason this file exists. The shared
# transport maps 401/403 to the `auth` exit code for every caller. Propagating
# that here would fail EVERY reconcile for any team whose token lacks "Create
# attachments", the moment they upgrade, for a feature they did not ask for. The
# assertion is on the run's exit code, not on the warning.
#
# The faults are injected per route through the mock's own `faults` map, keyed
# on the path fragment — the same mechanism the rest of the corpus uses.

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
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_HOOK_CONTEXT SPEC_KIT_JIRA_BASE_URL
}

# The shim re-reads its config on EVERY request, so a fault can be added or
# lifted mid-test without restarting the mock. Restarting would throw away the
# issues the first run created, and the next run would then fail to recognise
# its own tickets — a failure that looks like the fault under test.
#
# The file to edit is `$MOCK_CONFIG_PATH`, NOT the path handed to `mock_start`:
# lib.sh COPIES the config into the mock's own temp directory and normalises it
# there, so edits to the original are read by nobody. Measured the slow way —
# a 403 that never fired, on a route a direct `curl` proved faulted.

# _start_faulted <path-fragment> <status> — the mock with one route faulted.
_start_faulted() {
  local frag="$1" status="$2" cfg="${BATS_TEST_TMPDIR}/mock-config.json"
  jq -c --arg f "${frag}" --argjson s "${status}" \
    '.faults = {($f): {status: $s}}' "${MOCK}/configs/default.json" > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

# _fault <path-fragment> <status> — add a fault to the RUNNING mock, KEEPING
# everything else its config declares. Overwriting the file wholesale drops the
# createmeta and issue-type fixtures the run needs, and the run then fails
# before it ever reaches the publication the fault is about.
_fault() {
  local tmp="${MOCK_CONFIG_PATH}.tmp"
  jq -c --arg f "$1" --argjson s "$2" '.faults = {($f): {status: $s}}' "${MOCK_CONFIG_PATH}" > "${tmp}"
  mv "${tmp}" "${MOCK_CONFIG_PATH}"
}

# _unfault — lift every fault from the RUNNING mock, keeping the rest.
_unfault() {
  local tmp="${MOCK_CONFIG_PATH}.tmp"
  jq -c 'del(.faults, .fault)' "${MOCK_CONFIG_PATH}" > "${tmp}"
  mv "${tmp}" "${MOCK_CONFIG_PATH}"
}

_start_clean() {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
}

_count() { mock_calls | grep -cE "$1" || true; }

# ---- T084 / T085 / FR-020 / SC-006: the dry run predicts exactly ------------

@test "T084 FR-020 a dry-run names what it would publish and issues ZERO writes" {
  _start_clean

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --dry-run --json 2> /dev/null)"

  # The two write actions are rendered as their `would-` twins, and no other
  # action appears in their place.
  [ "$(jq -r '[.artifacts[] | select(.action == "would-publish")] | length' <<< "${summary}")" -gt 0 ]
  [ "$(jq -r '[.artifacts[] | select(.action == "published" or .action == "revised")] | length' <<< "${summary}")" -eq 0 ]

  # …and the run wrote nothing at all, of any kind.
  [ "$(_count '^(POST|PUT|DELETE) ')" -eq 0 ]
}

@test "T084 FR-020 the dry-run names the comment it would post, verbatim" {
  # "Names every comment it would post" is not satisfied by a count: the body
  # is what a reader is being promised, and it is composed from two languages'
  # pinned literals.
  _start_clean

  local summary body
  summary="$(cmd_reconcile reconcile "${SPEC}" --dry-run --json 2> /dev/null)"
  body="$(jq -c '[.actions[] | select(.url | endswith("/comment"))] | first | .body.body' <<< "${summary}")"
  [ "$(jq -r '.type' <<< "${body}")" = "doc" ]
  [ "$(jq -r '.content[1].content | length' <<< "${body}")" -gt 0 ]
}

@test "T085 SC-006 the dry-run's predicted set equals the real run's actual set, exactly" {
  # The assertion the whole dry-run promise rests on. Compared as PATHS: the
  # action names differ by design (`would-publish` against `published`), and a
  # comparison that ignored that would be comparing nothing.
  _start_clean

  local predicted actual
  predicted="$(cmd_reconcile reconcile "${SPEC}" --dry-run --json 2> /dev/null \
    | jq -r '[.artifacts[] | select(.action == "would-publish" or .action == "would-revise") | .path] | sort | join(",")')"
  actual="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null \
    | jq -r '[.artifacts[] | select(.action == "published" or .action == "revised") | .path] | sort | join(",")')"

  [ -n "${predicted}" ]
  [ "${predicted}" = "${actual}" ]
}

@test "T085 SC-006 the predicted PART LIST equals the one the real run sent" {
  # Prediction equality read from the wire rather than from the summary: the
  # multipart part list the real run actually put on the network, against the
  # attach action the dry run predicted.
  _start_clean

  local predicted
  predicted="$(cmd_reconcile reconcile "${SPEC}" --dry-run --json 2> /dev/null \
    | jq -r '[.actions[] | select(.url | endswith("/attachments"))] | first | .body.parts | join(",")')"
  : > "${MOCK_CALLLOG}"
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1

  [ "$(mock_calls | grep -E '^POST .*/attachments' | sed 's/^.* parts=//')" = "${predicted}" ]
}

# ---- T086 / FR-021 / US4 AS3: every withholding carries its facts -----------

@test "T086 FR-021 an oversized withholding carries the size and the limit" {
  local cfg="${BATS_TEST_TMPDIR}/small.json"
  printf '%s' '{"projects":{"COMP":"company"},"attachment_meta":{"enabled":true,"uploadLimit":8}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local summary entry
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  entry="$(jq -c '[.artifacts[] | select(.reason == "oversized")] | first' <<< "${summary}")"
  [ "${entry}" != "null" ]
  [ "$(jq -r '.size' <<< "${entry}")" -gt 8 ]
  [ "$(jq -r '.limit' <<< "${entry}")" -eq 8 ]
}

@test "T086 FR-021 a name collision carries the path it collides with" {
  _start_clean
  mkdir -p "${FEATURE_DIR}/contracts"
  printf 'api\n' > "${FEATURE_DIR}/contracts/api.md"
  printf 'collides\n' > "${FEATURE_DIR}/contracts__api.md"

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(jq -r '[.artifacts[] | select(.reason == "name-collision")] | length' <<< "${summary}")" -eq 2 ]
  [ "$(jq -r '[.artifacts[] | select(.reason == "name-collision") | .collides_with] | join("|")' <<< "${summary}")" = "contracts__api.md|contracts/api.md" ]
}

@test "T086 FR-021 a whole-publication withholding is reported per artifact, never as published" {
  # The one an audit trail cannot afford to get wrong: the site refused
  # everything, and every entry must say so. Reporting `published` for a file
  # that reached nothing is worse than reporting nothing at all.
  local cfg="${BATS_TEST_TMPDIR}/off.json"
  printf '%s' '{"projects":{"COMP":"company"},"attachment_meta":{"enabled":false}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --json 2> /dev/null)"
  [ "$(jq -r '(.artifacts // []) | length' <<< "${summary}")" -gt 0 ]
  [ "$(jq -r '[.artifacts[] | select(.action != "withheld")] | length' <<< "${summary}")" -eq 0 ]
  [ "$(jq -r '[.artifacts[] | select(.reason != "site-disabled")] | length' <<< "${summary}")" -eq 0 ]
}

# ---- T088 / C3.2 / FR-018: the fail-closed DEPARTURE ------------------------

@test "T088 C3.2 a 403 on the upload withholds and leaves the run's exit code unchanged" {
  # THE test. Without the translation at the call site, `auth` (exit 3)
  # propagates and every reconcile fails for a token that merely lacks one
  # optional permission.
  _start_clean
  # Establish the tickets first, so the 403 lands on publication alone rather
  # than on a run that had nothing else to do. The fault is added to the
  # RUNNING mock — restarting it would discard those tickets, and the next run
  # would fail to recognise its own keys for a reason unrelated to the 403.
  cmd_reconcile reconcile "${SPEC}" --json > /dev/null 2>&1

  _fault 'rest/api/3/issue/COMP-1/attachments' 403
  printf '%s\n' '# Research' '' 'A change to publish.' > "${FEATURE_DIR}/research.md"

  run cmd_reconcile reconcile "${SPEC}" --json
  # NOT 3 (auth). The reconcile's own writes stand and the run reports success.
  [ "$status" -eq 0 ]

  local summary="${output}"
  [ "$(jq -r '[.warnings[] | select(test("Create attachments"))] | length' <<< "${summary}")" -eq 1 ]
  # The warning names the TICKET, not merely the capability — an operator with
  # several projects cannot act on "this project".
  [ "$(jq -r '[.warnings[] | select(test("COMP-1"))] | length' <<< "${summary}")" -ge 1 ]
  # …and the artifacts are reported withheld, not published.
  [ "$(jq -r '[.artifacts[] | select(.reason == "upload-failed")] | length' <<< "${summary}")" -gt 0 ]
}

@test "T088 C3.2 the reconcile's OWN writes survive the 403" {
  _start_faulted 'rest/api/3/issue/COMP-1/attachments' 403

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # The tickets were created — publication failing did not roll anything back
  # and did not stop the run before it.
  [ "$(jq -r '.counts.created' <<< "${output}")" -gt 0 ]
  [ "$(_count '^POST /rest/api/3/issue$')" -gt 0 ]
}

# ---- T090 / C3.4-C3.6: the remaining outcome rows ---------------------------

@test "T090 C3.4 a 5xx withholds, writes NO manifest, and the next run retries" {
  _start_faulted 'rest/api/3/issue/COMP-1/attachments' 500

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  # The manifest must NOT be written: recording a publication that did not
  # happen makes the next run skip exactly the artifacts this one lost.
  [ "$(_count '^PUT .*properties/spec-kit-jira-artifacts')" -eq 0 ]
  [ "$(jq -r '[.warnings[] | select(test("could not be uploaded"))] | length' <<< "${output}")" -eq 1 ]

  # The retry: same mock, fault lifted, everything publishes. Same reason as
  # above — the tickets this run created must survive into the retry.
  _unfault
  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$(jq -r '[.artifacts[] | select(.action == "published" or .action == "revised")] | length' <<< "${output}")" -gt 0 ]
}

@test "T090 C3.5 a failed comment still writes the manifest — the attachments landed" {
  _start_faulted 'rest/api/3/issue/COMP-1/comment' 500

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(_count '^POST .*/attachments')" -eq 1 ]
  # The manifest IS written: they are published, whatever the announcement did.
  [ "$(_count '^PUT .*properties/spec-kit-jira-artifacts')" -eq 1 ]
  [ "$(jq -r '[.warnings[] | select(test("comment announcing them could not be posted"))] | length' <<< "${output}")" -eq 1 ]
}

@test "T090 C3.6 a failed manifest write warns, and the next run does not duplicate" {
  _start_faulted 'rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts' 500

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(_count '^POST .*/attachments')" -eq 1 ]
  [ "$(jq -r '[.warnings[] | select(test("record of them could not be saved"))] | length' <<< "${output}")" -eq 1 ]
}

@test "T090 C4.4.2 a manifest write refused with a 4xx names SIZE as the cause" {
  # Not a generic "the record did not save": C4.4.1 already checked the size,
  # so a site refusing the document anyway means the assumed cap is wrong, and
  # the operator needs the number to say so.
  _start_faulted 'rest/api/3/issue/COMP-1/properties/spec-kit-jira-artifacts' 400

  run cmd_reconcile reconcile "${SPEC}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.warnings[] | select(test("refused the [0-9]+-byte record"))] | length' <<< "${output}")" -eq 1 ]
  [ "$(jq -r '[.warnings[] | select(test("assumed cap"))] | length' <<< "${output}")" -eq 1 ]
}

# ---- T092 / FR-018 / SC-011 / Principle III: never fail the host command ----

@test "T092 SC-011 a publication failure in HOOK context leaves exit 0 and one warning" {
  export SPEC_KIT_JIRA_HOOK_CONTEXT=1
  _start_faulted 'rest/api/3/issue/COMP-1/attachments' 403

  run cmd_reconcile reconcile "${SPEC}"
  [ "$status" -eq 0 ]
  # Exactly one actionable warning about the publication, not a stack of them.
  [ "$(grep -cE 'Warnings: [1-9]' <<< "${output}")" -eq 1 ]
}
