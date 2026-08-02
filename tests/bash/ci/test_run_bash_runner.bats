#!/usr/bin/env bats
# T010/T010b [009, US1] — Contract test for tests/run-bash.sh, per
# contracts/test-runner.md. Written and observed to FAIL before T011/T011b
# existed (Constitution XIII TDD); now the runner's regression guard.
#
# FR-003/FR-015 regression: without GNU `parallel` on PATH, the runner must
# still execute every discovered test and never report success on 0 tests —
# the silent-false-green defect this feature exists to fix.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  RUNNER="${ROOT}/tests/run-bash.sh"

  # A small, fast fixture suite — NOT the real 955-test suite, so this file
  # stays fast regardless of the real suite's size or health.
  FIXDIR="$(mktemp -d)"
  cat > "${FIXDIR}/test_a.bats" << 'EOF'
#!/usr/bin/env bats
@test "a passes" { [ 1 -eq 1 ]; }
@test "a passes too" { [ 2 -eq 2 ]; }
EOF
  cat > "${FIXDIR}/test_b.bats" << 'EOF'
#!/usr/bin/env bats
@test "b passes" { [ 1 -eq 1 ]; }
EOF

  # A GNU-parallel-free PATH: the exact regression this runner exists to fix.
  NO_PARALLEL_PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | while IFS= read -r d; do
    [ -x "${d}/parallel" ] || printf '%s\n' "${d}"
  done | paste -sd: -)"
}

teardown() {
  rm -rf "${FIXDIR}"
}

@test "runs the full fixture suite without GNU parallel, executed count never 0" {
  run env PATH="${NO_PARALLEL_PATH}" "${RUNNER}" "${FIXDIR}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ tests\ executed:\ [1-9] ]]
  [[ "$output" =~ files\ executed:\ 2 ]]
}

@test "a deliberately failing test makes the runner exit non-zero" {
  cat > "${FIXDIR}/test_fail.bats" << 'EOF'
#!/usr/bin/env bats
@test "this one fails on purpose" { [ 1 -eq 2 ]; }
EOF
  run env PATH="${NO_PARALLEL_PATH}" "${RUNNER}" "${FIXDIR}"
  [ "$status" -ne 0 ]
}

@test "the summary reports a test count greater than zero" {
  run "${RUNNER}" "${FIXDIR}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ tests\ executed:\ 3 ]]
}

@test "an empty directory is refused rather than silently reporting success" {
  local empty; empty="$(mktemp -d)"
  run "${RUNNER}" "${empty}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no test files"* ]]
  rm -rf "${empty}"
}

# --- Change-scoped mode (--since, FR-017, S1-S4) ------------------------------

@test "--since with an undeterminable diff runs the FULL suite (S2, fail-open)" {
  run "${RUNNER}" --since not-a-real-ref-anywhere "${FIXDIR}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ files\ executed:\ 2 ]]
  [[ "$output" == *"FULL"* ]]
}

@test "--since never selects zero files silently (S3): empty selection runs everything" {
  local repo; repo="$(mktemp -d)"
  ( cd "${repo}" \
    && git init -q -b main \
    && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init \
    && mkdir -p tests/bash \
    && cp "${FIXDIR}/test_a.bats" "${FIXDIR}/test_b.bats" tests/bash/ \
    && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m base \
    && printf 'unrelated\n' > README.md \
    && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m docs-only )
  run env -C "${repo}" "${RUNNER}" --since HEAD~1 tests/bash
  [ "$status" -eq 0 ]
  [[ "$output" =~ files\ executed:\ 2 ]]
  rm -rf "${repo}"
}

@test "--since on a single-module diff selects and flags a PARTIAL RUN (S4)" {
  local repo; repo="$(mktemp -d)"
  ( cd "${repo}" \
    && git init -q -b main \
    && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init \
    && mkdir -p tests/bash/sink \
    && cp "${FIXDIR}/test_a.bats" tests/bash/sink/test_a.bats \
    && cp "${FIXDIR}/test_b.bats" tests/bash/test_b.bats \
    && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m base \
    && mkdir -p scripts/bash/sink \
    && printf '#!/usr/bin/env bash\n' > scripts/bash/sink/x.sh \
    && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m sink-change )
  run env -C "${repo}" "${RUNNER}" --since HEAD~1 tests/bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"PARTIAL RUN"* ]]
  [[ "$output" == *"sink/test_a.bats"* ]]
  rm -rf "${repo}"
}

@test "no file under .github/workflows/ invokes run-bash.sh --since (S1)" {
  run grep -rn 'run-bash.sh --since' "${ROOT}/.github/workflows"
  [ "$status" -ne 0 ]
}
