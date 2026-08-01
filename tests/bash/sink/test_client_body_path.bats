#!/usr/bin/env bats
# The request BODY's path, as the curl on PATH reads it.
#
# Windows-only defect, found by the conformance probe on a real runner and not
# by any emulation before it. The Bash port's every WRITE failed there while
# every read succeeded: `us10-mention` recorded its three GETs and never its
# PUT, and a dozen reconcile scenarios recorded no call at all and exited
# fail-closed (2) with an empty stdout — the mock never saw the request, so the
# failure happened before the network.
#
# The cause is one path. jira_request keeps the body OFF argv (NFR-3): it writes
# the body to a temporary file and references it from the curl config, which
# travels on stdin:
#
#     data = "@/tmp/tmp.XXXXXX"
#
# On git-bash the curl on PATH is a NATIVE Windows binary (curl 8.x
# x86_64-w64-mingw32). MSYS rewrites the paths it sees in ARGV — which is why
# --output and --dump-header work — but the config is stdin content, just bytes,
# and nothing translates it. curl receives a POSIX path it cannot open, exits
# non-zero, and the transport maps that to fail-closed with zero requests sent.
# A GET carries no body, hence no path, hence no failure: exactly the split the
# probe reported.
#
# The two tests below observe the config curl is actually handed, through a stub
# that captures its stdin. JIRA_PATH_STYLE selects the spelling, and it is
# settable precisely so this guard runs on every host rather than only on the
# one that needs it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/client.sh"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1

  STUB="${BATS_TEST_TMPDIR}/stub"
  CAPTURE="${BATS_TEST_TMPDIR}/curl-config"
  mkdir -p "${STUB}"

  # A curl that answers 200 and keeps the config it was given.
  cat > "${STUB}/curl" << EOF
#!/usr/bin/env bash
cat > "${CAPTURE}"
out=""; hdr=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output) out="\$2"; shift 2 ;;
    --dump-header) hdr="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$out" ] && printf '{}' > "\$out"
[ -n "\$hdr" ] && printf 'HTTP/1.1 200 OK\n' > "\$hdr"
printf '200'
EOF
  chmod +x "${STUB}/curl"

  # cygpath's answer shape matters, not its accuracy: a drive-lettered,
  # backslash-separated path is what a native curl can open and a POSIX one is
  # not, so the assertion is about which spelling reaches the config.
  cat > "${STUB}/cygpath" << 'EOF'
#!/usr/bin/env bash
printf 'C:\\native\\%s' "$(basename "${2:-$1}")"
EOF
  chmod +x "${STUB}/cygpath"
}

@test "a native-path host gets the body file spelled the way its curl reads it" {
  # `hash -r`: curl is almost certainly hashed from an earlier test in the run,
  # and the stub would be bypassed without ever saying so.
  (
    PATH="${STUB}:${PATH}"
    hash -r
    JIRA_PATH_STYLE=native jira_request POST "http://127.0.0.1:1/rest/api/3/issue" '{"fields":{}}'
  ) > /dev/null

  grep -q 'data = "@C:\\native\\' "${CAPTURE}"
  # And the POSIX spelling is gone, not merely accompanied.
  ! grep -q 'data = "@/' "${CAPTURE}" || false
}

@test "a posix host is untouched — the body file keeps its own spelling" {
  (
    PATH="${STUB}:${PATH}"
    hash -r
    JIRA_PATH_STYLE=posix jira_request POST "http://127.0.0.1:1/rest/api/3/issue" '{"fields":{}}'
  ) > /dev/null

  grep -q 'data = "@/' "${CAPTURE}"
}

@test "a request with no body carries no data line at all (the GET path)" {
  (
    PATH="${STUB}:${PATH}"
    hash -r
    JIRA_PATH_STYLE=native jira_request GET "http://127.0.0.1:1/rest/api/3/issue/COMP-1"
  ) > /dev/null

  ! grep -q 'data = ' "${CAPTURE}" || false
}
