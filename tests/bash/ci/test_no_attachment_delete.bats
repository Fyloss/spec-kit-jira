#!/usr/bin/env bats
# T082 [Phase 5, 036] — no code path in either port issues a DELETE against an
# attachment, in any mode (C6, Principle I, FR-014).
#
# Principle I: the bridge does not destroy. A superseded attachment is a
# previous version of the specification, and the fact that this extension
# uploaded it does not make it ours to remove — a reader looking for what the
# feature said last month has nowhere else to look.
#
# This is a STATIC guard on purpose. A runtime test can only prove that the
# paths it exercised issued no DELETE; the guarded re-mode, an error branch, a
# future cleanup someone adds in good faith are all outside its reach. The
# obligation is "no code path", and only reading the code can say that.
#
# The guard is proven RED in this same file, against a planted call, because
# this repository has shipped guards that were inert — two of three, once.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
}

# _scan <file>… — print one line per suspect: a DELETE whose target names an
# attachment. Silence means clean.
#
# Two shapes, because the two ports spell a request differently: the Bash port
# passes the method as an argument (`jira_request DELETE …`), the PowerShell
# port as a parameter (`-Method 'DELETE'`). A pattern that knew only one would
# be half a guard.
_scan() {
  local f
  for f in "$@"; do
    # The method and the target can sit on different lines, so the file is read
    # as one string and the window between them is bounded rather than assumed
    # to be a single line.
    awk -v name="${f}" '
      /DELETE/ { del_line = NR; del_text = $0 }
      del_line && NR - del_line <= 3 && /attachment/ {
        printf "%s:%d: DELETE near an attachment target: %s\n", name, del_line, del_text
        del_line = 0
      }
    ' "${f}"
  done
}

@test "T082 C6 no DELETE against an attachment exists anywhere in either port" {
  local suspects
  suspects="$(_scan $(find "${ROOT}/scripts/bash" -name '*.sh') \
    $(find "${ROOT}/scripts/powershell" -name '*.psm1' -o -name '*.ps1'))"
  if [[ -n "${suspects}" ]]; then
    printf 'a port issues DELETE against an attachment (C6, Principle I):\n%s\n' "${suspects}" >&2
    return 1
  fi
}

@test "T082 the guard is RED against a planted call — proven, not assumed" {
  # A guard nobody has watched fail is not known to work. Both spellings are
  # planted, so a pattern that caught only the Bash one would fail here.
  local bash_planted="${BATS_TEST_TMPDIR}/planted.sh"
  cat > "${bash_planted}" << 'EOS'
attachments_purge() {
  jira_request DELETE "${base}/rest/api/3/attachment/${id}"
}
EOS
  run _scan "${bash_planted}"
  [ -n "${output}" ]

  local ps_planted="${BATS_TEST_TMPDIR}/Planted.psm1"
  cat > "${ps_planted}" << 'EOS'
function Remove-JiraArtifactAttachment {
    $r = Invoke-JiraRequest -Method 'DELETE' `
        -Url "$BaseUrl/rest/api/3/attachment/$Id"
}
EOS
  run _scan "${ps_planted}"
  [ -n "${output}" ]
}

@test "T082 the guard does not fire on the reads the feature legitimately makes" {
  # `GET …?fields=attachment` (C1.3, the trust rule) and `POST …/attachments`
  # (C1.4) both name an attachment and must stay clean, or the guard would be
  # unlandable and someone would weaken it rather than fix the code.
  local innocent="${BATS_TEST_TMPDIR}/innocent.sh"
  cat > "${innocent}" << 'EOS'
attachments_ticket_ids() {
  jira_request GET "${base}/rest/api/3/issue/${key}?fields=attachment"
}
attachments_upload() {
  jira_request_multipart POST "${base}/rest/api/3/issue/${key}/attachments" "${parts}"
}
EOS
  run _scan "${innocent}"
  [ -z "${output}" ]
}
