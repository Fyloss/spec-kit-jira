#!/usr/bin/env bats
# T004 [009] — Contract test for the curl shim backend
# (tests/conformance/mock-jira/curl-shim.sh), per contracts/curl-shim.md and
# contracts/mock-driver.md. Written and observed to FAIL before T005/T005b/T006
# existed (Constitution XIII TDD); now the shim's regression guard.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
}

teardown() {
  mock_stop
}

# --- Invariant 1: style routing -----------------------------------------------

@test "GET project/COMP serves the company-managed fixture" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP"
  [ "$status" -eq 0 ]
  [ "$(jq -r .style <<< "$output")" = "classic" ]
}

@test "GET project/TEAM serves the team-managed fixture" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/TEAM"
  [ "$status" -eq 0 ]
  [ "$(jq -r .style <<< "$output")" = "next-gen" ]
}

# --- Invariant 2: faults -------------------------------------------------------

@test "AUTH project injects a 401" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/AUTH"
  [ "$output" = "401" ]
}

@test "MISSING project injects a 404" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/MISSING"
  [ "$output" = "404" ]
}

@test "RATE project injects a 429 with Retry-After" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s -o /dev/null -w '%{http_code}' "${MOCK_BASE_URL}/rest/api/3/project/RATE"
  [ "$output" = "429" ]
  run curl -s -D - -o /dev/null "${MOCK_BASE_URL}/rest/api/3/project/RATE"
  [[ "$output" == *"Retry-After: 1"* ]]
}

@test "NET project drops the connection (network failure)" {
  mock_start "${MOCK}/configs/faults.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/project/NET"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- Invariant 3: writes --------------------------------------------------------

@test "POST /issue returns 201 with a created-issue body" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s -o /dev/null -w '%{http_code}' -X POST "${MOCK_BASE_URL}/rest/api/3/issue" \
    -d '{"fields":{"project":{"key":"COMP"},"summary":"x"}}'
  [ "$output" = "201" ]
  run curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" -d '{"fields":{"project":{"key":"COMP"},"summary":"y"}}'
  [ "$(jq -r '.key' <<< "$output")" != "null" ]
  [[ "$(jq -r '.key' <<< "$output")" == COMP-* ]]
}

# --- Invariant 4: call log order and exact-once -------------------------------

@test "every request appears once, in order, in mock_calls" {
  mock_start "${MOCK}/configs/default.json"
  curl -s "${MOCK_BASE_URL}/rest/api/3/project/COMP" > /dev/null
  curl -s "${MOCK_BASE_URL}/rest/api/3/priority" > /dev/null
  curl -s "${MOCK_BASE_URL}/rest/api/3/field" > /dev/null
  run mock_calls
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "GET /rest/api/3/project/COMP" ]
  [ "${lines[1]}" = "GET /rest/api/3/priority" ]
  [ "${lines[2]}" = "GET /rest/api/3/field" ]
}

# --- Invariant 5 / NFR-3: the Authorization header is never logged -----------

@test "the Authorization header never appears in MOCK_CALLLOG" {
  mock_start "${MOCK}/configs/default.json"
  printf 'header = "Authorization: Basic dXNlcjpTRUNSRVQ="\nurl = "%s/rest/api/3/project/COMP"\nrequest = "GET"\n' "${MOCK_BASE_URL}" \
    | curl --silent --config - --output /dev/null --dump-header /dev/null --write-out '%{http_code}' > /dev/null
  run grep -c 'SECRET\|Authorization' "${MOCK_CALLLOG}"
  [ "$status" -ne 0 ]
  [ "$output" -eq 0 ] 2> /dev/null || [ -z "$output" ] || [ "$output" = "0" ]
}

# --- Invariants 6-7 (008 surface): the issue store -----------------------------

@test "mock_issue_field resolves a field of an issue an earlier POST created" {
  mock_start "${MOCK}/configs/default.json"
  curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" \
    -d '{"fields":{"project":{"key":"COMP"},"summary":"child","parent":{"key":"COMP-9"}}}' > /dev/null
  local key
  key="$(mock_calls | tail -n1 > /dev/null; curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" -d '{"fields":{"project":{"key":"COMP"},"parent":{"key":"COMP-9"}}}' | jq -r .key)"
  [ "$(mock_issue_field "${key}" .fields.parent.key)" = "COMP-9" ]
}

@test "two concurrent mock_start instances never see each other's issues" {
  mock_start "${MOCK}/configs/default.json"
  curl -s -X POST "${MOCK_BASE_URL}/rest/api/3/issue" -d '{"fields":{"project":{"key":"COMP"},"summary":"a-only-in-first"}}' > /dev/null
  local first_tmp="${MOCK_TMPDIR}"

  # A second, independent instance in the SAME process (nested, without
  # stopping the first) must not share state or PATH-install collisions:
  # its store is freshly seeded, so COMP-1 is unknown to IT even though the
  # first instance just created it.
  mock_start "${MOCK}/configs/default.json"
  [ "${MOCK_TMPDIR}" != "${first_tmp}" ]
  [ "$(mock_issue_field COMP-1 .fields.summary)" != "a-only-in-first" ]
  mock_stop

  # The state file that no longer has an active mock_start session still
  # holds the first instance's data on disk (isolation, not clobbering).
  [ "$(jq -r '.issues["COMP-1"].fields.summary' "${first_tmp}/state.json")" = "a-only-in-first" ]
}

# --- T024 [036] — the four upload routes, served identically by BOTH mocks ----
#
# There are two mock backends and they are not interchangeable: the Bash suites
# reach `curl-shim.sh`, installed first on PATH so `jira_request` hits it
# instead of a socket, while the PowerShell suites and the conformance corpus
# drive the real loopback server `mock-server.ps1`. A route added to one and
# not the other yields a green suite on one port and a failure on the other —
# or worse, a green suite on both that proves nothing about the port whose
# backend never saw the request.
#
# These cases go through `mock_start`, which is the Bash side. The PowerShell
# side is asserted by Client.Multipart.Tests.ps1 and the conformance corpus
# against the same fixtures; what is guarded HERE is that the shim answers at
# all, with the shape the transport expects.

@test "T024 GET /attachment/meta answers with the site's upload limit" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s "${MOCK_BASE_URL}/rest/api/3/attachment/meta"
  [ "$status" -eq 0 ]
  [ "$(jq -r .enabled <<< "$output")" = "true" ]
  # A NUMBER, not a string: the bridge compares it against a file size.
  [ "$(jq -r '.uploadLimit | type' <<< "$output")" = "number" ]
  [ "$(jq -r .uploadLimit <<< "$output")" -gt 0 ]
}

@test "T024 POST .../attachments records one attachment per form part, in part order" {
  mock_start "${MOCK}/configs/default.json"
  # Driven through the real transport, not a hand-built curl: the point is that
  # the shim understands the config `jira_request_multipart` actually writes.
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/client.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="TOK" JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local d="${BATS_TEST_TMPDIR}/f"
  mkdir -p "${d}/contracts"
  printf 'spec\n' > "${d}/spec.md"
  printf 'api\n' > "${d}/contracts/api.md"
  local parts
  parts="$(jq -cn --arg d "${d}" '[
    {attachment_name:"spec.md",          file:($d + "/spec.md")},
    {attachment_name:"contracts__api.md", file:($d + "/contracts/api.md")}
  ]')"

  run jira_request_multipart POST "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${parts}"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 2 ]
  # The FLATTENED names, in part order — this is what proves the shim read the
  # `;filename=` parameter rather than deriving a basename.
  [ "$(jq -r '.[0].filename' <<< "$output")" = "spec.md" ]
  [ "$(jq -r '.[1].filename' <<< "$output")" = "contracts__api.md" ]
  [ "$(jq -r '.[0].size' <<< "$output")" -eq 5 ]
}

@test "T024 two uploads of the SAME filename both land — Jira allows it and 036 needs it" {
  # FR-014: a revised artifact is published again under the same name and the
  # earlier copy must survive. A mock that de-duplicated by filename would make
  # the revision tests pass for the wrong reason.
  mock_start "${MOCK}/configs/default.json"
  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/client.sh"
  export JIRA_EMAIL="user@example.com" JIRA_API_TOKEN="TOK" JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  local d="${BATS_TEST_TMPDIR}/g"
  mkdir -p "${d}"
  printf 'v1\n' > "${d}/spec.md"
  local parts
  parts="$(jq -cn --arg d "${d}" '[{attachment_name:"spec.md", file:($d + "/spec.md")}]')"

  run jira_request_multipart POST "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${parts}"
  [ "$status" -eq 0 ]
  local first_id
  first_id="$(jq -r '.[0].id' <<< "$output")"

  printf 'v2 revised\n' > "${d}/spec.md"
  run jira_request_multipart POST "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${parts}"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].filename' <<< "$output")" = "spec.md" ]
  # A DIFFERENT id: the second upload is a second attachment, not a replacement.
  [ "$(jq -r '.[0].id' <<< "$output")" != "${first_id}" ]
}

@test "T024 POST .../comment accepts an ADF body and answers with the created comment" {
  mock_start "${MOCK}/configs/default.json"
  run curl -s -X POST -d '{"body":{"type":"doc","version":1,"content":[]}}' \
    "${MOCK_BASE_URL}/rest/api/3/issue/COMP-1/comment"
  [ "$status" -eq 0 ]
  [ -n "$(jq -r '.id' <<< "$output")" ]
  [ "$(jq -r '.body.type' <<< "$output")" = "doc" ]
}

@test "T024 the manifest property round-trips under its own key" {
  # 036 stores the publication manifest at `spec-kit-jira-artifacts`. The
  # property route already existed; what is asserted is that OUR key is not
  # special-cased away by the identity-marker fallback beside it.
  mock_start "${MOCK}/configs/default.json"
  # The issue has to EXIST first. The shim records a property only for an issue
  # it knows about — pre-existing behaviour, and correct: a property on a
  # non-existent issue is not a thing Jira has either. A real run always has
  # the specification ticket by this point, seeded or created; this creates it
  # the same way the reconcile does.
  local created
  created="$(curl -s -X POST -d '{"fields":{"project":{"key":"COMP"},"summary":"s","issuetype":{"id":"1"}}}' \
    "${MOCK_BASE_URL}/rest/api/3/issue")"
  local ikey
  ikey="$(jq -r '.key' <<< "${created}")"
  [ -n "${ikey}" ] && [ "${ikey}" != "null" ]

  run curl -s -X PUT -d '{"schema":1,"artifacts":{"spec.md":{"hash":"aaaa","attachment_id":"1","run":"after_plan"}}}' \
    "${MOCK_BASE_URL}/rest/api/3/issue/${ikey}/properties/spec-kit-jira-artifacts"
  [ "$status" -eq 0 ]
  run curl -s "${MOCK_BASE_URL}/rest/api/3/issue/${ikey}/properties/spec-kit-jira-artifacts"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.key' <<< "$output")" = "spec-kit-jira-artifacts" ]
  [ "$(jq -r '.value.schema' <<< "$output")" = "1" ]
  [ "$(jq -r '.value.artifacts["spec.md"].hash' <<< "$output")" = "aaaa" ]
}

@test "T024 an unpublished manifest key answers 404, not a stale fixture" {
  # C1.2: a 404 means "no manifest", and every artifact is a first publication.
  # A mock that answered a fixture here would make the zero-churn tests pass
  # against a manifest nobody wrote.
  mock_start "${MOCK}/configs/default.json"
  run curl -s -o /dev/null -w '%{http_code}' \
    "${MOCK_BASE_URL}/rest/api/3/issue/COMP-9/properties/spec-kit-jira-artifacts"
  [ "$status" -eq 0 ]
  [ "$output" = "404" ]
}
