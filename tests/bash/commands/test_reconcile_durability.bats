#!/usr/bin/env bats
# T041-T042 [Phase 5, US3] — recognition depends on nothing machine-local: no
# state file, no cache directory, and a renamed specification folder still
# recognises its tickets and creates none.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  FIXTURE="${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE
}

teardown() {
  mock_stop
}

@test "recognition succeeds with no local run history at all — no state file, empty HOME" {
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  # A run from a completely empty $HOME and no XDG cache/state dirs: nothing
  # this feature reads or writes lives outside spec.md and the Jira API.
  local emptyhome="${BATS_TEST_TMPDIR}/empty-home"
  mkdir -p "${emptyhome}"
  : > "${MOCK_CALLLOG}"
  HOME="${emptyhome}" XDG_CACHE_HOME="${emptyhome}/.cache" XDG_STATE_HOME="${emptyhome}/.state" \
    run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 3 ]
  [ ! -d "${emptyhome}/.cache" ]
  [ ! -d "${emptyhome}/.state" ]
}

@test "a renamed specification folder still recognises its STORY tickets and creates none" {
  # This proves story recognition's rename tolerance (its durable `story`
  # identifier, decoupled from spec_slug) — not the parent's, which the
  # contract deliberately keeps slug-sensitive (contracts/
  # hierarchy-resolution.md §7, "different repo or spec_slug -> blocked");
  # that is covered on its own in test_recognition_parent.bats. A caller
  # that renames a spec folder mid-lifecycle keeps SPEC_KIT_JIRA_SPEC_SLUG
  # stable across the rename in practice, which this test mirrors.
  export SPEC_KIT_JIRA_SPEC_SLUG="001-billing-invoices"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  cmd_reconcile reconcile "${spec}" --json > /dev/null

  mv "${work}/specs/001-billing-invoices" "${work}/specs/001-billing-invoices-renamed"
  local renamed_spec="${work}/specs/001-billing-invoices-renamed/spec.md"

  : > "${MOCK_CALLLOG}"
  run cmd_reconcile reconcile "${renamed_spec}" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.counts.created' <<< "$output")" -eq 0 ]
  [ "$(jq -r '.counts.recognised' <<< "$output")" -eq 3 ]
  [ "$(grep -c '^POST /rest/api/3/issue$' "${MOCK_CALLLOG}")" -eq 0 ]
}

@test "recognition is scoped to the routed project: two specs mirrored into different projects never recognise each other's tickets" {
  mock_start "${ROOT}/tests/conformance/mock-jira/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  # Reuse the SAME durable identifier (via SPEC_KIT_JIRA_ID_SOURCE) across
  # two DIFFERENT specifications, mirrored into two DIFFERENT projects.
  # Recognition must never let one spec's marker satisfy the other's.
  mkdir -p "${BATS_TEST_TMPDIR}/a" "${BATS_TEST_TMPDIR}/b"
  local specA="${BATS_TEST_TMPDIR}/a/spec.md" specB="${BATS_TEST_TMPDIR}/b/spec.md"
  printf '%s\n' '### User Story 1 - Alpha (Priority: P1)' '<!-- speckit-jira story=1111111111111111 ticket=OTHER-1 -->' '' 'Alpha body.' > "${specA}"
  printf '%s\n' '### User Story 1 - Beta (Priority: P1)' '<!-- speckit-jira story=1111111111111111 ticket=COMP-9 -->' '' 'Beta body.' > "${specB}"

  local stories='[{"local_id":"1111111111111111","marker":{"state":"bound","id":"1111111111111111","ticket":"OTHER-1"}}]'
  local specRefB='{"repo":"acme/app","spec_slug":"002-beta","folder":"x"}'
  run recognition_run "${stories}" "${specRefB}" "COMP" "${specB}"
  [ "$status" -eq 0 ]
  # 035 C5.1: the branch that short-circuited on the project prefix — mirroring
  # such a story as NEW into the routed project — is gone. The scoping
  # guarantee this test exists for is unchanged and now rests entirely on the
  # identity marker: OTHER-1 is READ, and its identity names specification
  # 001-alpha, not this one, so it never satisfies 002-beta's marker. What must
  # never happen is that it is silently adopted.
  [ "$(jq -r '[.bound[].key] | index("OTHER-1") // "no"' <<< "$output")" = "no" ]
}

@test "035 C3.2: a recorded key in another project REFUSES, zero writes, both modes" {
  # Was: "re-routed: the catalogued notice names the story, the former key and
  # project, and the new key (T071)". That behaviour is retired. Re-creating a
  # bound story in the routed project stranded the recorded one and, under
  # --dry-run, said nothing at all about having done so.
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local work="${BATS_TEST_TMPDIR}/repo"
  cp -R "${FIXTURE}" "${work}"
  local spec="${work}/specs/001-billing-invoices/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"

  printf '%s\n' \
    '# Feature Specification: Billing Invoices' '' \
    '### User Story 1 - Export single invoice (Priority: P1)' \
    '<!-- speckit-jira story=1111111111111111 ticket=LEGACY-42 -->' '' \
    'As a customer, I want to export one invoice as a PDF.' '' \
    '- **Given** a signed-in customer viewing an invoice' \
    '- **When** they choose Export' \
    '- **Then** a PDF download starts' > "${spec}"

  run cmd_reconcile reconcile "${spec}" --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"LEGACY"* ]]
  [[ "$output" == *"COMP"* ]]
  [[ "$output" == *"does not move a bound specification"* ]]

  # C3.3 — refused before any Jira read, so zero writes is structural.
  [ "$(grep -c 'LEGACY-42' "${MOCK_CALLLOG}")" -eq 0 ]
  [ "$(grep -c 'POST' "${MOCK_CALLLOG}")" -eq 0 ]

  # The recorded marker is untouched: nothing was re-created anywhere.
  grep -q 'ticket=LEGACY-42' "${spec}"
  ! grep -q 'ticket=COMP-' "${spec}"

  # C3.4 — identical under --dry-run, which is where the old note went silent.
  run cmd_reconcile reconcile "${spec}" --dry-run --json
  [ "$status" -eq 4 ]
  [[ "$output" == *"does not move a bound specification"* ]]
}

@test "T061 [016] — FR-000/FR-000a: a real run leaves every byte of the spec file unchanged except the speckit-jira marker lines" {
  local pristine="${ROOT}/tests/conformance/fixtures/repo-with-markdown-prose/specs/001-markdown-prose/spec.md"
  local work="${BATS_TEST_TMPDIR}/repo-markdown-prose-durability"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-markdown-prose" "${work}"
  local spec="${work}/specs/001-markdown-prose/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-markdown-prose"
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  cmd_reconcile reconcile "${spec}" --json > /dev/null

  run diff <(grep -v 'speckit-jira ' "${pristine}") <(grep -v 'speckit-jira ' "${spec}")
  [ "$status" -eq 0 ]
  grep -q 'speckit-jira ' "${spec}"
}

@test "T061 [016] — FR-000/FR-000a: a --dry-run leaves the spec file byte-identical, including its marker lines (there are none to add)" {
  local pristine="${ROOT}/tests/conformance/fixtures/repo-with-markdown-prose/specs/001-markdown-prose/spec.md"
  local work="${BATS_TEST_TMPDIR}/repo-markdown-prose-durability-dry"
  cp -R "${ROOT}/tests/conformance/fixtures/repo-with-markdown-prose" "${work}"
  local spec="${work}/specs/001-markdown-prose/spec.md"
  export JIRA_CONFIG_DIR="${work}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  export SPEC_KIT_JIRA_SPEC_SLUG="001-markdown-prose"
  export SPEC_KIT_JIRA_ID_SOURCE="aaaaaaaaaaaaaaaa 1111111111111111"
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  cmd_reconcile reconcile "${spec}" --dry-run --json > /dev/null

  run cmp "${spec}" "${pristine}"
  [ "$status" -eq 0 ]
}

@test "035 C5.1: recognition holds no opinion about which project a key names" {
  # Was: "a story whose recorded ticket lives outside the routed project is
  # mirrored into the routed project, not blocked". That short-circuit is gone.
  # Recognition compared the recorded key's project against the routed one and
  # re-created the item elsewhere; the parent tier never did, so one run could
  # update a parent in one project while creating its children in another.
  #
  # The comparison now lives in ONE place, in the command layer, and refuses
  # (C3.2) before any read. Reaching recognition at all therefore means the
  # projects already agree — so recognition reads a foreign-looking key exactly
  # as it reads any other, and classifies it on what the read returns.
  ! grep -q '_key_proj' "${ROOT}/scripts/bash/sink/jira/recognition.sh"
  ! grep -q 'rerouted' "${ROOT}/scripts/bash/sink/jira/recognition.sh"
  ! grep -q 'rerouted' "${ROOT}/scripts/powershell/sink/jira/Recognition.psm1"

  # C5.3: the project-prefix helper is KEPT — the task-tier check reuses it.
  grep -q '_recognition_project_of' "${ROOT}/scripts/bash/sink/jira/recognition.sh"
  grep -q 'Get-JiraRecognitionProjectOf' "${ROOT}/scripts/powershell/sink/jira/Recognition.psm1"
}
