#!/usr/bin/env bats
# Guard for the harness's jq reads against a CRLF-emitting jq.
#
# On Windows the `jq` on PATH is the native jq.exe, whose stdout is a text-mode
# stream: every line it writes is terminated CRLF, not LF. Nothing downstream
# strips that CR — `$( )` removes trailing NEWLINES only, and `read` consumes
# the delimiter but leaves the CR on the last field. A scenario declaring
#
#   "env": { "SPEC_KIT_JIRA_SPEC_SLUG": "001-billing" }
#
# therefore reached the port as $'001-billing\r', which fails the anchored slug
# pattern in BOTH ports (`$` tolerates a trailing \n, never a trailing \r), and
# the run refused with "spec_ref.spec_slug is malformed" — three conformance
# cases red on windows-latest, green on Linux and macOS.
#
# POSIX hosts cannot reproduce that natively, so the text-mode stream is
# supplied by a stub `jq` on PATH: the real jq, with a CR appended to each
# output line. That is a faithful emulation and it makes the defect
# deterministic on every host — without the fix in run-scenario.sh the run
# below refuses, with it the run succeeds.
#
# The refusal arrives EARLIER here than it did on Windows, and that difference
# is itself the reason the bug survived so long: a POSIX host rejects
# "<fixture>\r" outright, so the unfixed harness dies at its own fixture check,
# whereas Win32 tolerates the trailing CR in a path — the fixture copied
# cleanly there and the CR only surfaced much later, on the one value checked
# against an anchored pattern. Either way the assertions below separate the
# fixed harness from the broken one.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  HARNESS="${ROOT}/tests/conformance/run-scenario.sh"
  SCENARIO="${ROOT}/tests/conformance/scenarios/us1-hierarchy-french.json"

  # `command jq` would re-enter this stub, so resolve the real binary by path
  # BEFORE the stub shadows the name.
  REAL_JQ="$(command -v jq)"
  STUB_DIR="${BATS_TEST_TMPDIR}/stub"
  mkdir -p "${STUB_DIR}"
  cat > "${STUB_DIR}/jq" << EOF
#!/usr/bin/env bash
set -o pipefail
"${REAL_JQ}" "\$@" | sed \$'s/\$/\\r/'
EOF
  chmod +x "${STUB_DIR}/jq"

  # A second stub for the tests that drive a PORT rather than the harness, and
  # the difference between the two is the whole reason the port's own defect
  # hid behind this one. MSYS bash — the bash the ports run under on Windows —
  # strips a trailing CRLF from command substitution, so a `$(jq -r ...)`
  # SCALAR arrives clean and only the newlines INSIDE a multi-line document
  # survive as CR. The stub above appends a CR to every line including the
  # last, which is right for the harness's `read`-from-a-pipeline loops but
  # would hand the port a CR on every scalar it captures — a state Windows
  # never produces, and one that refuses the run long before anything is
  # written. This stub models what the port actually observes there.
  #
  # `set -o pipefail` is what makes it an emulation rather than a second bug:
  # without it the stub reports SED's status and swallows jq's, so every
  # `jq -e` predicate in the port reads TRUE and the run fails for a reason
  # the real jq.exe would never produce.
  PORT_STUB_DIR="${BATS_TEST_TMPDIR}/stub-port"
  mkdir -p "${PORT_STUB_DIR}"
  cat > "${PORT_STUB_DIR}/jq" << EOF
#!/usr/bin/env bash
set -o pipefail
"${REAL_JQ}" "\$@" | sed -e \$'\$!s/\$/\\r/'
EOF
  chmod +x "${PORT_STUB_DIR}/jq"
}

@test "a CRLF-emitting jq does not corrupt the scenario env (Windows text-mode stdout)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local out="${BATS_TEST_TMPDIR}/out"
  PATH="${STUB_DIR}:${PATH}" bash "${HARNESS}" "${SCENARIO}" powershell "${out}" > /dev/null

  # The scenario declares SPEC_KIT_JIRA_SPEC_SLUG=001-checkout. A CR riding on
  # it refuses the whole run at the interchange gate, so the exit code alone
  # tells the two states apart.
  [ "$(cat "${out}/exit")" = "0" ]
  ! grep -q 'spec_slug is malformed' "${out}/stderr"
}

# The same text-mode stream reaches the BASH PORT's own jq, and there it lands
# somewhere the harness cannot repair: a file the port writes. config_to_yaml
# captures a MULTI-LINE jq document and writes it verbatim, so on windows-latest
# config.local.yml came out CRLF-terminated while the PowerShell twin — which
# joins with an explicit `n and writes through File::WriteAllText — wrote LF.
# ci-conformance.sh diffs the written tree byte for byte, so the pair failed
# with 55 identical-looking lines on both sides of the diff (NFR-1).
#
# Asserted over the WHOLE written tree rather than the one known file: the
# defect is a class — any jq output with embedded newlines that reaches disk —
# and this catches the next member of it on every host, not just on Windows.
# lib/output.sh's jq_lines is the guard the whole class now goes through.
@test "a CRLF-emitting jq leaves no CR in anything the Bash port writes" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local out="${BATS_TEST_TMPDIR}/out-written"
  local scenario="${ROOT}/tests/conformance/scenarios/sc009-core-untouched.json"
  PATH="${PORT_STUB_DIR}:${PATH}" bash "${HARNESS}" "${scenario}" bash "${out}" > /dev/null

  [ "$(cat "${out}/exit")" = "0" ]
  [ -f "${out}/workdir/.specify/jira/config.local.yml" ]
  local crs
  crs="$(find "${out}/workdir" -type f -exec cat {} + | LC_ALL=C tr -dc '\r' | wc -c | tr -d '[:space:]')"
  [ "${crs}" -eq 0 ]
}

# The written tree is only half of it. A jq read with embedded newlines also
# feeds control flow, and the corruption there is not cosmetic: this scenario's
# config.yml declares TWO projects, so the key list arrives as $'COMP\r' then
# 'TEAM' and the first key names a project that does not exist. On Windows the
# run refused (exit 2) where the PowerShell twin succeeded — a divergence in the
# exit code, before any file was written.
@test "a CRLF-emitting jq does not corrupt a multi-project key list" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local out="${BATS_TEST_TMPDIR}/out-multi"
  local scenario="${ROOT}/tests/conformance/scenarios/us8-mixed-routing.json"
  PATH="${PORT_STUB_DIR}:${PATH}" bash "${HARNESS}" "${scenario}" bash "${out}" > /dev/null

  [ "$(cat "${out}/exit")" = "0" ]
  # Both declared projects reached the resolved-id table, spelled correctly.
  grep -q '"COMP":' "${out}/workdir/.specify/jira/config.local.yml"
  grep -q '"TEAM":' "${out}/workdir/.specify/jira/config.local.yml"
}

@test "a CRLF-emitting jq does not corrupt argv either" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local out="${BATS_TEST_TMPDIR}/out-argv"
  PATH="${STUB_DIR}:${PATH}" bash "${HARNESS}" "${SCENARIO}" powershell "${out}" > /dev/null

  # --dry-run and --json both come from the scenario's argv array. A CR on
  # either is an unknown flag (exit 1), and a CR on the spec path makes it
  # unreadable (also exit 1) — none of which can produce the dry-run report.
  [ "$(cat "${out}/exit")" = "0" ]
  [ "$(jq -r '.dry_run' "${out}/stdout")" = "true" ]
  [ "$(jq -r '[.actions[] | select(.role=="story") | .body.fields.issuetype.id] | unique | join(",")' "${out}/stdout")" = "10302" ]
}
