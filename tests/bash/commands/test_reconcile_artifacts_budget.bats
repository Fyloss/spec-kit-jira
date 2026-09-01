#!/usr/bin/env bats
# T096/T097 [Phase 7, 036] — the process budget and the wall clock, end to end
# (FR-023, SC-009, docs/11-process-budget.md).
#
# T096's STATIC half lives in tests/bash/ci/test_argv_whole_spec_aggregate.bats,
# which forbids the spelling. This is the behavioural half: a whole reconcile
# over a wide feature directory, measured. The two are not substitutes — the
# static guard cannot see a loop that spawns per artifact, and this one cannot
# see a payload spelled into argv on a host whose cap it does not reach.
#
# THE TWO MEASUREMENTS CANNOT SHARE A RUN (research R4). The counting shim
# costs a process per call and distorted the reference scenario's wall clock by
# 61%. The spawn assertions and the SC-009 timing therefore run separately, and
# the timing run must never inherit the shim's PATH.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CMD_DIR="${ROOT}/scripts/bash/commands"
  MOCK="${ROOT}/tests/conformance/mock-jira"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/spawn_count.bash"
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/artifact_fixture.bash"
  # shellcheck source=/dev/null
  source "${MOCK}/lib.sh"
  # shellcheck source=/dev/null
  source "${CMD_DIR}/reconcile.sh"

  WORK="${BATS_TEST_TMPDIR}/repo"
  helper_make_artifact_repo "${WORK}"
  mkdir -p "${WORK}/.specify/jira"
  # The RESOLVED identifiers, taken from the fixture that already carries them.
  # Without `config.local.yml` the run answers "this repository is not bound to
  # a Jira project yet" and does nothing — and a budget measured over a run
  # that did nothing passes against an instrument pointed at an empty room.
  cp "${ROOT}/tests/conformance/fixtures/repo-with-mirrored-spec/.specify/jira/config.local.yml" \
    "${WORK}/.specify/jira/config.local.yml"
  cat > "${WORK}/.specify/jira/config.yml" << 'YAML'
projects:
  - key: COMP
    style: company_managed
    priority_map:
      P1: Highest
      P2: Medium
      P3: Low
routing:
  - match:
      folder_prefix: "001-"
    project: COMP
routing_default: COMP
YAML

  export JIRA_CONFIG_DIR="${WORK}/.specify/jira"
  export SPEC_KIT_JIRA_REPO="acme/app"
  # Set HERE, not in _make_wide: that helper's output is captured with `$( … )`,
  # so an `export` inside it happens in a subshell and never reaches the run.
  # Without it routing does not bind, the reconcile reports "not bound to a Jira
  # project yet", and the two budget assertions below measure a run that did
  # nothing at all — passing against an instrument pointed at an empty room.
  export SPEC_KIT_JIRA_SPEC_SLUG="001-wide"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_TOKEN="RAWSECRETXYZ"
  export JIRA_NO_SLEEP=1
  export SPEC_KIT_JIRA_ID_SOURCE="1111111111111111 2222222222222222 3333333333333333 4444444444444444"
  unset SPEC_KIT_JIRA_PLAN_CONTEXT SPEC_KIT_JIRA_LIFECYCLE SPEC_KIT_JIRA_HOOK_CONTEXT
}

teardown() {
  mock_stop
  unset SPEC_KIT_JIRA_BASE_URL
}

# _make_wide <count> — a feature directory holding <count> artifacts plus a
# spec.md the reconcile can actually parse, and print the spec path.
_make_wide() {
  local count="$1" name="001-wide" dir="${WORK}/specs/001-wide" i
  mkdir -p "${dir}/contracts"
  printf '%s\n' '# Feature Specification: Wide' '' \
    'A directory with many artifacts.' '' \
    '### User Story 1 - The core story (Priority: P1)' '' \
    '- **Given** a user' '- **When** they act' '- **Then** it works' > "${dir}/spec.md"
  for ((i = 0; i < count; i++)); do
    printf 'contract %03d\n' "${i}" > "$(printf '%s/contracts/c%03d.md' "${dir}" "${i}")"
  done
  printf '%s' "${dir}/spec.md"
}

@test "T096 FR-023 a whole reconcile spawns no process per artifact" {
  # The comparison is between two directory sizes, not against an absolute
  # number: the reconcile's own parse and apply phases dominate the count, and
  # a fixed ceiling would either be so loose it proved nothing or so tight it
  # broke on an unrelated change. What FR-023 forbids is GROWTH with the
  # artifact count, and growth is what is measured.
  local spec_small spec_wide shim counts n_small n_wide
  shim="${BATS_TEST_TMPDIR}/shim"
  counts="${BATS_TEST_TMPDIR}/counts"

  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"

  spec_small="$(_make_wide 4)"
  helper_spawn_count_setup "${shim}" "${counts}" git
  # The instrument is probed FIRST: measure in-process and it reports 0
  # forever, which passes a budget assertion against a dead shim.
  PATH="${shim}:${PATH}" cmd_reconcile reconcile "${spec_small}" --json > /dev/null 2>&1
  n_small="$(helper_spawn_count_total "${counts}")"
  [ "${n_small}" -gt 0 ]

  # A second, wider directory in its own repository, so nothing is carried over.
  rm -rf "${WORK}/specs/001-wide"
  spec_wide="$(_make_wide 40)"
  helper_spawn_count_setup "${shim}" "${counts}" git
  PATH="${shim}:${PATH}" cmd_reconcile reconcile "${spec_wide}" --json > /dev/null 2>&1
  n_wide="$(helper_spawn_count_total "${counts}")"

  # 36 more artifacts. A per-artifact implementation costs at least one process
  # each; the allowance below is generous enough to absorb the handful of extra
  # calls a longer decision set legitimately produces, and far tighter than 36.
  printf 'DEBUG wide:  %s\n' "$(sort "${counts}" | uniq -c | tr '\n' ' ')" >&3
  if ((n_wide > n_small + 12)); then
    printf 'the reconcile spawns per artifact: %d processes for 4 artifacts, %d for 40\n' \
      "${n_small}" "${n_wide}" >&2
    return 1
  fi
}

@test "T096 FR-023 no command line grows with the artifact count, at the WINDOWS cap" {
  # The behavioural complement to the static guard. Measured against the
  # tightest cap across supported hosts — never the host's own, which on macOS
  # is no cap at all and on Linux is four times looser than Windows'.
  # shellcheck source=/dev/null
  source "${ROOT}/tests/bash/helpers/argv_size.bash"

  local spec shim report
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  spec="$(_make_wide 40)"

  shim="${BATS_TEST_TMPDIR}/argv-shim"
  report="${BATS_TEST_TMPDIR}/argv.log"
  helper_argv_size_setup "${shim}" "${report}"
  PATH="${shim}:${PATH}" cmd_reconcile reconcile "${spec}" --json > /dev/null 2>&1

  # The report holds one line per argument over the limit. Empty is the pass.
  if [ -s "${report}" ]; then
    printf 'an argument exceeds the Windows command-line cap:\n%s\n' "$(cat "${report}")" >&2
    return 1
  fi
}

@test "T097 SC-009 a first publication of a 20-artifact directory completes in under 60s" {
  # The user-facing number the specification actually promises. The spawn
  # invariant above is the durable constraint — it is what stays true as hosts
  # change — but nothing else measures the promise itself, and a run that meets
  # the budget while taking four minutes has still broken it.
  #
  # NO SHIM ON PATH here: the counting shim distorted the reference scenario's
  # wall clock by 61%, so a timing read from a counted run is not a timing.
  local spec started ended elapsed
  mock_start "${MOCK}/configs/default.json"
  export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
  spec="$(_make_wide 19)" # 19 contracts + spec.md = 20 artifacts

  started="$(date +%s)"
  run cmd_reconcile reconcile "${spec}" --json
  ended="$(date +%s)"
  [ "$status" -eq 0 ]

  # It really did publish all twenty — a run that withheld everything would be
  # fast for the wrong reason.
  [ "$(jq -r '[.artifacts[] | select(.action == "published")] | length' <<< "${output}")" -eq 20 ]

  elapsed=$((ended - started))
  printf '# SC-009: 20 artifacts published in %ss (limit 60s)\n' "${elapsed}" >&3
  [ "${elapsed}" -lt 60 ]
}
