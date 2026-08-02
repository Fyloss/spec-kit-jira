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
  #
  # `@test` must never sit at column 0 inside this file's own heredocs or
  # format strings: the OUTER bats preprocesses this whole source file before
  # bash ever parses it, and bats 1.10 (Debian/Ubuntu's package) rewrites any
  # line-start `@test` — heredoc bodies included — into its preprocessed
  # form. The fixture then reaches the inner bats with no `@test` left and
  # runs as `1..0`. Assembling the keyword at run time keeps the fixture
  # literal on every bats version.
  T='@test'
  FIXDIR="$(mktemp -d)"
  printf '#!/usr/bin/env bats\n%s "a passes" { [ 1 -eq 1 ]; }\n%s "a passes too" { [ 2 -eq 2 ]; }\n' \
    "${T}" "${T}" > "${FIXDIR}/test_a.bats"
  printf '#!/usr/bin/env bats\n%s "b passes" { [ 1 -eq 1 ]; }\n' \
    "${T}" > "${FIXDIR}/test_b.bats"

  # A GNU-parallel-free PATH: the exact regression this runner exists to fix.
  # Dropping every directory that happens to contain `parallel` is not an
  # option: Debian's bats package pulls GNU parallel into /usr/bin
  # (Recommends), and removing /usr/bin removes bash itself — the runner then
  # dies with exit 127 before proving anything. A directory that ships
  # `parallel` is replaced by a shadow directory symlinking everything else
  # it contains.
  SHADOW_DIRS=()
  NO_PARALLEL_PATH=""
  local d shadow
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    if [ -x "${d}/parallel" ]; then
      shadow="$(mktemp -d)"
      SHADOW_DIRS+=("${shadow}")
      ln -s "${d}"/* "${shadow}/" 2> /dev/null || true
      rm -f "${shadow}/parallel"
      NO_PARALLEL_PATH="${NO_PARALLEL_PATH:+${NO_PARALLEL_PATH}:}${shadow}"
    else
      NO_PARALLEL_PATH="${NO_PARALLEL_PATH:+${NO_PARALLEL_PATH}:}${d}"
    fi
  done < <(printf '%s\n' "${PATH}" | tr ':' '\n')
}

teardown() {
  rm -rf "${FIXDIR}"
  # `|| :`, never `&&`: on a host with no GNU parallel anywhere on PATH
  # (the GitHub macOS runner), SHADOW_DIRS is empty and `${SHADOW_DIRS[@]:-}`
  # expands to one empty string — an `[ -n ] && rm` last line then exits 1,
  # and a non-zero teardown fails every test in the file.
  local s
  for s in "${SHADOW_DIRS[@]:-}"; do
    [ -z "${s}" ] || rm -rf "${s}"
  done
}

@test "runs the full fixture suite without GNU parallel, executed count never 0" {
  run env PATH="${NO_PARALLEL_PATH}" "${RUNNER}" "${FIXDIR}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ tests\ executed:\ [1-9] ]]
  [[ "$output" =~ files\ executed:\ 2 ]]
}

@test "a deliberately failing test makes the runner exit non-zero" {
  printf '#!/usr/bin/env bats\n%s "this one fails on purpose" { [ 1 -eq 2 ]; }\n' \
    "${T}" > "${FIXDIR}/test_fail.bats"
  run env PATH="${NO_PARALLEL_PATH}" "${RUNNER}" "${FIXDIR}"
  [ "$status" -ne 0 ]
}

@test "the summary reports a test count greater than zero" {
  run "${RUNNER}" "${FIXDIR}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ tests\ executed:\ 3 ]]
}

@test "an outer bats' injected libexec dir never leaks into the workers (Debian split packaging)" {
  # An outer bats prepends its private libexec dir to PATH and exports it as
  # BATS_LIBEXEC. Debian/Ubuntu package that libexec `bats` WITHOUT the
  # wrapper's environment, so resolved bare it silently discovers 0 tests
  # (`1..0`, exit 0) — which turned every nested runner invocation on the CI
  # ubuntu images into "0 tests executed". The worker must strip the injected
  # dir so the real wrapper is found. Simulated here so the defect is
  # reproducible on hosts whose bats has no such split.
  local libexec
  libexec="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "1..0\\n"\n' > "${libexec}/bats"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${libexec}/bats-exec-suite"
  chmod +x "${libexec}/bats" "${libexec}/bats-exec-suite"
  run env BATS_LIBEXEC="${libexec}" PATH="${libexec}:${PATH}" "${RUNNER}" "${FIXDIR}"
  rm -rf "${libexec}"
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
