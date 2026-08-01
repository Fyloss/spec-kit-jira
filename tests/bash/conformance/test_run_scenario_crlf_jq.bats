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
"${REAL_JQ}" "\$@" | sed \$'s/\$/\\r/'
EOF
  chmod +x "${STUB_DIR}/jq"
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
