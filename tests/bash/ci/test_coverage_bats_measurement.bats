#!/usr/bin/env bats
# Coverage-measurement guard (T103): the gate measured the wrong thing, against
# an inflated denominator, and reported 59.24% for a port whose unit suites
# cover far more than that.
#
#   1. Constitution XIII computes coverage on the MOCKED UNIT SUITES. kcov
#      cannot run them — it instruments bats-core's own DEBUG-trap tracing and
#      the two feed each other an unbounded trace — so the gate measured only
#      the conformance corpus, which never drives the error paths that
#      credentials.sh, drift.sh, client.sh and interchange.sh are unit-tested
#      for. The bats suite is now measured by tracing it on a dedicated fd,
#      which no tracer of kcov's is involved in, and merging what it hit with
#      what kcov measured.
#   2. The port is annotated with `kcov-excl-start/stop` around multi-line jq
#      literals, whose continuation lines kcov's line parser counts as
#      statements that can never be hit. Without `--exclude-region` those ~533
#      lines sit permanently in the denominator, capping drift.sh at ~17%.
#   3. `PS4` must survive `set -u`. `${BASH_SOURCE}` (no default) makes every
#      traced `bash -c` child print "BASH_SOURCE: unbound variable" on ITS
#      stderr, which lands in the output bats captured and fails the assertion —
#      tracing must never change what the suite sees.
#
# The shape assertions exist because the merge only reproduces on a Linux host
# with kcov; the merge arithmetic itself is behavioural and runs anywhere.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  COVERAGE="${ROOT}/tests/coverage/bash-coverage.sh"
  WORKFLOWS="${ROOT}/.github/workflows"
}

@test "the kcov run excludes the regions the port annotates as non-statements" {
  run grep -q -- "--exclude-region=.*kcov-excl-start:kcov-excl-stop" "${COVERAGE}"
  [ "$status" -eq 0 ]
}

@test "no workflow drives bats under kcov — that pair never terminates" {
  offenders=""
  for wf in "${WORKFLOWS}"/*.yml; do
    # Continuations are joined first: the runaway invocation is written across
    # four backslash-continued lines, and a per-line grep never sees it.
    if awk '{ line = line $0
              if (line ~ /\\$/) { sub(/\\$/, " ", line); next }
              print line; line = "" }
            END { if (line != "") print line }' "${wf}" \
      | grep -qE '^[^#]*\bkcov\b[^#]*\bbats\b'; then
      offenders="${offenders}${wf}"$'\n'
    fi
  done
  [ -z "${offenders}" ] || {
    printf 'these workflows run bats under kcov:\n%s\n' "${offenders}"
    false
  }
}

@test "the bats suite is traced on a dedicated fd, never fd 1, 2 or bats's own 3" {
  fd="$(grep -oE 'BASH_XTRACEFD=[0-9]+' "${COVERAGE}" | head -1 | cut -d= -f2)"
  [ -n "${fd}" ]
  [ "${fd}" -gt 3 ]
  # `exec` cannot take a variable descriptor, so the same number is spelled out
  # where the fd is opened; a mismatch would send the trace nowhere.
  run grep -qE "exec ${fd}> " "${COVERAGE}"
  [ "$status" -eq 0 ]
}

@test "the trace marker survives set -u in every traced child" {
  ps4="$(grep -m1 "PS4=" "${COVERAGE}")"
  [ -n "${ps4}" ]
  [[ "${ps4}" == *'${BASH_SOURCE:-}'* ]]
  [[ "${ps4}" != *'${BASH_SOURCE}'* ]]
}

@test "the bats phase is wall-clock bounded like the kcov phase" {
  run grep -Eq 'run_bounded "\$\{BATS_TIMEOUT\}"' "${COVERAGE}"
  [ "$status" -eq 0 ]
}

# --- The extraction: bash repeats PS4's FIRST CHARACTER once per nesting depth,
# so a naive `grep -o` on the whole marker drops every frame deeper than one and
# makes the modules called from inside other functions look untouched.

@test "extraction reads a trace frame at any nesting depth" {
  cat > "${BATS_TEST_TMPDIR}/trace" <<EOF
#skjcov#${ROOT}/scripts/bash/lib/config.sh:12#skjcov# config_load
##skjcov#${ROOT}/scripts/bash/lib/config.sh:34#skjcov# local x=1
####skjcov#${ROOT}/scripts/bash/engine/drift.sh:49#skjcov# drift_evaluate
EOF
  run bash "${COVERAGE}" --extract-trace < "${BATS_TEST_TMPDIR}/trace"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"scripts/bash/lib/config.sh:12"* ]]
  [[ "${output}" == *"scripts/bash/lib/config.sh:34"* ]]
  [[ "${output}" == *"scripts/bash/engine/drift.sh:49"* ]]
}

@test "extraction resolves the relative paths a sourced module reports" {
  # A module sourced as ../lib/config.sh from commands/ reports exactly that.
  printf '#skjcov#%s/scripts/bash/commands/../lib/config.sh:12#skjcov# x\n' "${ROOT}" \
    > "${BATS_TEST_TMPDIR}/trace"
  run bash "${COVERAGE}" --extract-trace < "${BATS_TEST_TMPDIR}/trace"
  [ "$status" -eq 0 ]
  [ "${output}" = "scripts/bash/lib/config.sh:12" ]
}

@test "extraction drops everything that is not port source" {
  printf '#skjcov#/opt/bats-core/lib/tracing.bash:88#skjcov# x\n#skjcov#:1#skjcov# y\n' \
    > "${BATS_TEST_TMPDIR}/trace"
  run bash "${COVERAGE}" --extract-trace < "${BATS_TEST_TMPDIR}/trace"
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

# --- The merge: kcov owns the denominator (which lines are statements), the two
# exercises jointly own the numerator (which of them ran).

merge_fixture() {
  # 4 statements in one file: kcov hit line 10, the bats trace hit 20 and 30,
  # nobody hit 40. Line 99 is traced but is NOT a kcov statement (it is the
  # opening line of an excluded jq literal) and must not inflate anything.
  cat > "${BATS_TEST_TMPDIR}/cobertura.xml" <<EOF
<?xml version="1.0" ?>
<coverage line-rate="0.25" lines-covered="1" lines-valid="4">
  <sources>
    <source>${ROOT}/scripts/bash/</source>
  </sources>
  <packages>
    <package name="x">
      <classes>
        <class name="config_sh" filename="lib/config.sh">
          <lines>
            <line number="10" hits="3"/>
            <line number="20" hits="0"/>
            <line number="30" hits="0"/>
            <line number="40" hits="0"/>
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>
EOF
  printf 'scripts/bash/lib/config.sh:20\nscripts/bash/lib/config.sh:30\nscripts/bash/lib/config.sh:99\n' \
    > "${BATS_TEST_TMPDIR}/traced"
}

@test "a line counts as covered when either exercise ran it" {
  merge_fixture
  run bash "${COVERAGE}" --merge-report \
    "${BATS_TEST_TMPDIR}/cobertura.xml" "${BATS_TEST_TMPDIR}/traced" --threshold 75
  [ "$status" -eq 0 ]
  [[ "${output}" == *"75.00% (3/4 lines)"* ]]
}

@test "a traced line kcov does not count as a statement inflates nothing" {
  merge_fixture
  run bash "${COVERAGE}" --merge-report \
    "${BATS_TEST_TMPDIR}/cobertura.xml" "${BATS_TEST_TMPDIR}/traced" --threshold 75
  [[ "${output}" == *"(3/4 lines)"* ]]
  [[ "${output}" != *"/5 lines"* ]]
}

@test "the merged percentage is what the gate decides on" {
  merge_fixture
  run bash "${COVERAGE}" --merge-report \
    "${BATS_TEST_TMPDIR}/cobertura.xml" "${BATS_TEST_TMPDIR}/traced" --threshold 80
  [ "$status" -eq 1 ]
  [[ "${output}${stderr:-}" == *"below the 80% gate"* ]] || [[ "${output}" == *"FAIL"* ]]
}

@test "an empty trace leaves the kcov measurement untouched" {
  merge_fixture
  : > "${BATS_TEST_TMPDIR}/traced"
  run bash "${COVERAGE}" --merge-report \
    "${BATS_TEST_TMPDIR}/cobertura.xml" "${BATS_TEST_TMPDIR}/traced" --threshold 25
  [ "$status" -eq 0 ]
  [[ "${output}" == *"25.00% (1/4 lines)"* ]]
}
