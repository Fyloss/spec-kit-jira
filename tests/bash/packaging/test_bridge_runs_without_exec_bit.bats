#!/usr/bin/env bats
# T016 [026] [US1] — a bridge entry point that exists but lost its executable
# bit is NOT reported as missing, and `bash <path>` still runs it
# (contracts/bridge-invocation.md C2.1/C2.2, FR-016).
#
# `chmod 644` after a real install simulates exactly what research R3 measured
# on a zip install on the declared floor host (`specify` 0.13.0): the archive
# member records 0755, and `ZipFile.extractall` restores it as 0644.
#
# Before the fix this fails: `scripts/bash/lib/prereq.sh:58`'s now-removed `-x`
# clause reported the entry point as missing (exit 5) even though `bash
# <path>` would have worked perfectly.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  BUILDER="${ROOT}/packaging/build-artifact.sh"
  # shellcheck source=tests/bash/helpers/consumer_fixture.bash
  source "${ROOT}/tests/bash/helpers/consumer_fixture.bash"
  fixture_require || skip "${FIXTURE_SKIP_REASON}"
  WORK="$(mktemp -d)"
  REPO=""
  PID=""
}

teardown() {
  # `rm -rf ""` exits 0, which only accidentally keeps this teardown from
  # the same failure the sibling file had: bats treats a nonzero teardown
  # exit as a failure regardless of skip. Never leave that to chance.
  [ -n "${PID}" ] && fixture_stop_server "${PID}"
  [ -n "${REPO}" ] && fixture_cleanup "${REPO}"
  rm -rf "${WORK}"
  true
}

@test "a bridge with a lost executable bit is not reported as missing, and runs via bash <path> (C2.1/C2.2)" {
  "${BUILDER}" "${WORK}/spec-kit-jira.zip" > /dev/null

  read -r port pid < <(fixture_serve "${WORK}")
  PID="${pid}"

  REPO="$(fixture_new_repo)"
  run bash -c "cd '${REPO}' && printf 'y\n' | specify extension add jira-mirror --from 'http://127.0.0.1:${port}/spec-kit-jira.zip'"
  [ "$status" -eq 0 ]

  entry="${REPO}/.specify/extensions/jira-mirror/scripts/bash/spec-kit-jira.sh"
  [ -f "${entry}" ]

  # Simulate the floor host: the exec bit does not survive extraction there.
  chmod 644 "${entry}"
  run stat -f '%Lp' "${entry}" 2> /dev/null
  if [ "$status" -ne 0 ]; then
    run stat -c '%a' "${entry}"
  fi
  [ "$output" = "644" ]

  # The prerequisite gate must NOT report the bridge as missing.
  run bash -c "cd '${REPO}' && SPEC_KIT_JIRA_EXTENSION_ROOT='${REPO}/.specify/extensions/jira-mirror' bash -c 'source \"${ROOT}/scripts/bash/lib/prereq.sh\"; prereq_bridge_missing'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # And `bash <path>` must run it, exactly as the command documents instruct.
  run bash "${entry}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'usage:'* ]]
}
