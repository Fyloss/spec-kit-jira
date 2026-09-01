#!/usr/bin/env bats
# The RECONCILE run summary declares every key and status it emits.
#
# The companion of test_run_summary_schema.bats, which covers the config
# ceremony. Both judge against one reading of the contract, shared through
# tests/bash/helpers/summary_schema.bash — two copies of that jq program would
# drift exactly the way the schema itself did.
#
# A separate file because the harnesses are not compatible: this suite needs a
# different fixture, a different mock config, and a ceremony run before every
# reconcile so the mandatory fields resolve. Merging it with the config suite
# would mean a setup() that serves neither.
#
# Three shapes, because reconcile's summary is not one object with optional
# fields — different outcomes populate genuinely different key sets:
#
#   * PLANNING (`--dry-run`)  — `actions` full, `counts.created` zero.
#   * CONFIRMED              — real creations, so the counters and any warning
#                              the sink produced are populated instead.
#   * FAIL-CLOSED            — the sink refuses, exit 2, and the summary carries
#                              the warning set that only this path produces.
#
# `effects` is config-only, so the drift class that motivated these suites cannot
# occur here. What CAN occur, and what this file is for, is a new top-level key
# added to reconcile's summary alone — which the config suite would never see.
#
# A FOURTH shape arrived with 036 (T052): PUBLISHING, where the summary carries
# `artifacts[]`. It needs its own setup because the three above cannot reach it:
# the artifact set is `git ls-files` over the feature directory, and a fixture
# copied out of `tests/conformance/fixtures` is not a repository, so those runs
# emit no artifacts at all and would judge the new key vacuously.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/summary_schema.bash"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/config.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-mandatory-field" "${WORK}"
  SPEC="${WORK}/specs/001-reporting/spec.md"

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-reporting"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
}

# _record_defaults — the ceremony run the confirming paths need first, so the
# mandatory fields resolve rather than blocking the create.
_record_defaults() {
  cmd_config config PM --issue-type "PM=story=Story" \
    --field-default 'PM=Deliverable=Business Owner=Platform Team' \
    --field-default 'PM=Deliverable=Program Increment=PI-2026-Q3' \
    --json > /dev/null
}

@test "the planning (--dry-run) reconcile summary declares every key it emits" {
  # The ceremony runs first even for a plan: this fixture records its issue
  # types and field defaults through the ceremony, and without them the
  # planning run is refused at config resolution (exit 4) before it ever
  # assembles a summary.
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults

  local summary
  summary="$(cmd_reconcile reconcile --dry-run --json "${SPEC}" 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile --dry-run"
}

@test "the confirmed-creation reconcile summary declares every key it emits" {
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --accept-defaults --json 2> /dev/null)"
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile (confirmed)"
}

@test "the fail-closed reconcile summary declares every key it emits" {
  # A refused create populates the warning set no other path produces, and
  # returns 2 rather than 0 — the summary is still a published artifact and is
  # still bound by the contract.
  mock_start "${MOCK}/configs/mandatory-field.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults
  mock_stop

  local cfg
  cfg="${BATS_TEST_TMPDIR}/fault.json"
  printf '%s' '{"projects":{"PM":"company"},"createmetaFields":{"10101":"parent-mandatory"},"faults":{"PM":{"status":400}}}' > "${cfg}"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # This path returns 2, so the capture must tolerate a non-zero exit — and the
  # exit code is then asserted, because a run that silently succeeded would
  # produce a DIFFERENT summary shape and this test would pass while proving
  # nothing about the fail-closed one.
  local summary rc=0
  summary="$(cmd_reconcile reconcile "${SPEC}" --accept-defaults --json 2> /dev/null)" || rc=$?
  [ "${rc}" -eq 2 ]
  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile (fail-closed)"
}

# ---- 036 T052: the publishing shape ------------------------------------------

# _make_publishing_feature — turn the copied fixture into a real repository and
# give the feature directory one artifact of every decision class the summary
# can report. Prints the mock config path to start with.
#
# The three classes are deliberate and each one exercises a different part of
# the contract: a plain file publishes, a pair sharing a flattened name is
# withheld as a collision, and a file over the site's DISCOVERED limit is
# withheld as oversized. A run producing only publications would leave the
# `reason`, `size`, `limit` and `collides_with` keys — the four the schema is
# most likely to fall behind on — completely unjudged.
_make_publishing_feature() {
  git -C "${WORK}" init --quiet
  git -C "${WORK}" config user.email 'fixture@example.invalid'
  git -C "${WORK}" config user.name 'fixture'

  local dir="${WORK}/specs/001-reporting"
  mkdir -p "${dir}/contracts"
  printf '%s\n' '# Contract: reporting' 'C1. It reports.' > "${dir}/contracts/api.md"
  # Collides with the above: a literal `__` in a top-level name flattens to the
  # same attachment name as `contracts/api.md` does.
  printf '%s\n' 'the collision' > "${dir}/contracts__api.md"
  # Over the limit pinned below, and nothing else in the tree is.
  head -c 4096 /dev/zero | tr '\0' 'x' > "${dir}/research.md"

  local cfg="${BATS_TEST_TMPDIR}/publishing.json"
  jq -c '. + {attachment_meta: {enabled: true, uploadLimit: 2048}}' \
    "${MOCK}/configs/mandatory-field.json" > "${cfg}"
  printf '%s' "${cfg}"
}

@test "the publishing reconcile summary declares every artifact key it emits" {
  local cfg
  cfg="$(_make_publishing_feature)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults

  local summary
  summary="$(cmd_reconcile reconcile "${SPEC}" --accept-defaults --json 2> /dev/null)"

  # First that the key is there at all. Without this the conformance assertion
  # below passes on an absent array and proves nothing — the exact way a guard
  # goes inert.
  [ "$(jq -r '(.artifacts // []) | length' <<< "${summary}")" -gt 0 ]
  # …and that all three decision classes are present, so every key the schema
  # declares for a withholding is actually being judged.
  [ "$(jq -r '[.artifacts[] | select(.action == "published")] | length' <<< "${summary}")" -gt 0 ]
  [ "$(jq -r '[.artifacts[] | select(.reason == "name-collision")] | length' <<< "${summary}")" -eq 2 ]
  [ "$(jq -r '[.artifacts[] | select(.reason == "oversized")] | length' <<< "${summary}")" -eq 1 ]

  helper_summary_assert_conformant "${summary}" "${SCHEMA}" "reconcile (publishing)"
}

@test "the publishing summary is judged against the PRE-036 schema and fails" {
  # The red-proof, run in the suite rather than described in a commit message.
  # A guard nobody has watched fail is not known to work, and this repository
  # has shipped two inert ones out of three.
  local cfg
  cfg="$(_make_publishing_feature)"
  mock_start "${cfg}"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  _record_defaults

  local summary old violations
  summary="$(cmd_reconcile reconcile "${SPEC}" --accept-defaults --json 2> /dev/null)"
  old="${BATS_TEST_TMPDIR}/pre-036-schema.json"
  jq 'del(.properties.artifacts)' "${SCHEMA}" > "${old}"

  violations="$(helper_summary_violations "${summary}" "${old}")"
  [[ "${violations}" == *"top-level key not declared by the schema: artifacts"* ]]
  # Not merely the top-level key: every entry's keys are reported too, which is
  # what proves the per-entry reading is live rather than defaulted into silence.
  [[ "${violations}" == *"artifacts[0] key not declared by the schema: action"* ]]
}
