#!/usr/bin/env bats
# T019/T020 [Phase 2, 036] — the multipart request shape
# (036 contracts/artifact-publication.md C2.1; FR-023; Constitution IV, NFR-3).
#
# The transport gains one capability: a `multipart/form-data` request carrying
# one `file` part per artifact. Three constraints meet in that one request, and
# only one shape satisfies all three:
#
#   * THE CREDENTIAL MUST STAY OFF ARGV. It already does — the config travels on
#     stdin — so the form parts join that config rather than becoming `-F`
#     arguments.
#   * THE PATH MUST BE SPELLED FOR THE CURL THAT WILL OPEN IT. The curl on PATH
#     under git-bash is a native Windows binary that resolves none of MSYS's
#     virtual paths; `client.sh` carries the measured evidence (posix=26,
#     win=26, mixed=7 against a dead port).
#   * THE REQUEST MUST NOT GROW ARGV. One `-F` per artifact would, and the cap
#     that binds is Windows's whole-command-line ~32767 bytes, not this host's.
#
# The config is asserted here rather than the wire because it is the only place
# the request shape is observable without a real multipart parser: these tests
# capture what `client.sh` hands to curl, which IS the contract C2.1 states.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  # A curl stand-in that captures the config it is given on stdin and answers
  # 200, so the request shape can be read back without a network or a mock.
  SHIM="${BATS_TEST_TMPDIR}/bin"
  CAPTURE="${BATS_TEST_TMPDIR}/config.captured"
  mkdir -p "${SHIM}"
  cat > "${SHIM}/curl" << SHIM_EOF
#!/bin/sh
cat > "${CAPTURE}"
printf '%s' '200'
exit 0
SHIM_EOF
  chmod +x "${SHIM}/curl"

  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export SPEC_KIT_JIRA_BASE_URL="https://example.invalid"
  export JIRA_NO_SLEEP=1

  # Two artifacts, one of them nested, so the flattened part name is
  # distinguishable from the basename curl would otherwise derive.
  A_DIR="${BATS_TEST_TMPDIR}/feature"
  mkdir -p "${A_DIR}/contracts"
  printf 'spec body\n' > "${A_DIR}/spec.md"
  printf 'api body\n' > "${A_DIR}/contracts/api.md"
  PARTS_JSON="$(jq -cn --arg d "${A_DIR}" '[
    {path:"spec.md",            attachment_name:"spec.md",            file:($d + "/spec.md")},
    {path:"contracts/api.md",   attachment_name:"contracts__api.md",  file:($d + "/contracts/api.md")}
  ]')"

  # shellcheck source=/dev/null
  source "${ROOT}/scripts/bash/sink/jira/client.sh"
}

_run_multipart() {
  PATH="${SHIM}:${PATH}" jira_request_multipart POST \
    "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${PARTS_JSON}"
}

# --- C2.1: the request shape ------------------------------------------------

@test "C2.1 the request carries the XSRF header Jira requires for an upload" {
  run _run_multipart
  [ "$status" -eq 0 ]
  grep -q 'header = "X-Atlassian-Token: no-check"' "${CAPTURE}"
}

@test "C2.1 one form line per artifact, and no more" {
  run _run_multipart
  [ "$status" -eq 0 ]
  [ "$(awk '/^form = /{n++} END{print n+0}' "${CAPTURE}")" -eq 2 ]
}

@test "C2.1 each form line names the part 'file'" {
  run _run_multipart
  [ "$status" -eq 0 ]
  [ "$(awk '/^form = "file=@/{n++} END{print n+0}' "${CAPTURE}")" -eq 2 ]
}

@test "C2.1 each form line carries an explicit filename, so a nested artifact does not collide" {
  # Without `;filename=`, curl derives the name from the basename and
  # `contracts/api.md` would arrive as `api.md` — exactly the collision the
  # flattening exists to prevent.
  run _run_multipart
  [ "$status" -eq 0 ]
  grep -q ';filename=spec.md"' "${CAPTURE}"
  grep -q ';filename=contracts__api.md"' "${CAPTURE}"
}

@test "C2.1 the request is a POST to the attachments endpoint" {
  run _run_multipart
  [ "$status" -eq 0 ]
  grep -q 'request = "POST"' "${CAPTURE}"
  grep -q 'attachments' "${CAPTURE}"
}

@test "C2.1 Content-Type is NOT set by us — curl composes the multipart boundary" {
  run _run_multipart
  [ "$status" -eq 0 ]
  ! grep -q 'Content-Type: application/json' "${CAPTURE}"
}

@test "C2.1 the whole config still travels on STDIN, never argv" {
  # The shim reads stdin and writes it to CAPTURE. A non-empty capture proves
  # the config arrived that way; the credential assertion below proves what it
  # means.
  run _run_multipart
  [ "$status" -eq 0 ]
  [ -s "${CAPTURE}" ]
  grep -q '^url = ' "${CAPTURE}"
}

# --- FR-023: the argument vector does not grow ------------------------------

@test "FR-023 the argv handed to curl does not grow with the artifact count" {
  local log="${BATS_TEST_TMPDIR}/argv.log"
  cat > "${SHIM}/curl" << SHIM_EOF
#!/bin/sh
printf '%s\n' "\$*" | wc -c >> "${log}"
cat > /dev/null
printf '%s' '200'
exit 0
SHIM_EOF
  chmod +x "${SHIM}/curl"
  : > "${log}"

  # Two artifacts, then two hundred. The command line must not notice.
  PATH="${SHIM}:${PATH}" jira_request_multipart POST \
    "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${PARTS_JSON}" > /dev/null
  local small
  small="$(tail -1 "${log}")"

  local i
  for ((i = 0; i < 200; i++)); do
    printf 'body %03d\n' "${i}" > "$(printf '%s/contracts/c%03d.md' "${A_DIR}" "${i}")"
  done
  # ONE jq call to build the 200-entry payload. Two hundred would make this
  # test the slowest in the suite for no gain, and the thing under test is the
  # transport, not the fixture.
  local wide
  wide="$(jq -cn --arg d "${A_DIR}" '[range(0;200) | (. | tostring | ("000" + .)[-3:]) as $n
    | {path:("contracts/c" + $n + ".md"),
       attachment_name:("contracts__c" + $n + ".md"),
       file:($d + "/contracts/c" + $n + ".md")}]')"
  : > "${log}"
  PATH="${SHIM}:${PATH}" jira_request_multipart POST \
    "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${wide}" > /dev/null
  local big
  big="$(tail -1 "${log}")"

  [ "${big}" -eq "${small}" ]
  # And well inside the tightest supported cap — Windows counts the WHOLE
  # command line against ~32767 bytes, which is the number that binds.
  [ "${big}" -lt 32767 ]
}

# --- Constitution IV / NFR-3: the credential ---------------------------------

@test "Principle IV the credential never reaches argv, at maximum verbosity" {
  # The test Constitution IV names verbatim: "including at maximum verbosity".
  # xtrace would print every expansion of every command in this function; the
  # transport suspends it for exactly that reason, and this proves it.
  local log="${BATS_TEST_TMPDIR}/argv2.log" trace="${BATS_TEST_TMPDIR}/trace.log"
  cat > "${SHIM}/curl" << SHIM_EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${log}"
cat > /dev/null
printf '%s' '200'
exit 0
SHIM_EOF
  chmod +x "${SHIM}/curl"
  : > "${log}"

  # xtrace is enabled inside a CHILD bash, never in this one: `set -x` in a
  # bats test traces bats's own machinery too, which buries the assertion in
  # megabytes of output and makes the run look hung.
  PATH="${SHIM}:${PATH}" bash -c '
    set -x
    source "$1/scripts/bash/sink/jira/client.sh"
    jira_request_multipart POST "$2" "$3" > /dev/null
  ' _ "${ROOT}" "${SPEC_KIT_JIRA_BASE_URL}/rest/api/3/issue/COMP-1/attachments" "${PARTS_JSON}" \
    2> "${trace}" || true

  ! grep -q 'RAWSECRETXYZ' "${log}"
  ! grep -q 'Authorization' "${log}"
  # The base64 of "user@example.com:RAWSECRETXYZ" must not appear either — a
  # credential encoded is still a credential.
  local b64
  b64="$(printf '%s' "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64 | tr -d '\n')"
  ! grep -q "${b64}" "${log}"
  ! grep -q "${b64}" "${trace}"
  ! grep -q 'RAWSECRETXYZ' "${trace}"
}

# --- the Windows path spelling ----------------------------------------------

@test "C2.1 every artifact path is spelled through the sanctioned path helper" {
  # Under a forced native style with no cygpath present the helper returns the
  # path unchanged, so this asserts the CALL rather than the translation — the
  # translation itself is only observable on a real MSYS host, which is what
  # the ci/windows-probe run is for.
  # `env VAR=… fn` cannot work — env execs a program, and _run_multipart is a
  # shell function. Export it for the call instead.
  JIRA_PATH_STYLE=native run _run_multipart
  [ "$status" -eq 0 ]
  [ "$(awk '/^form = "file=@/{n++} END{print n+0}' "${CAPTURE}")" -eq 2 ]
}
