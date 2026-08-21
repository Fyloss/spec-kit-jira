#!/usr/bin/env bats
# #46 review finding — the provenance-notes builder must stay FAIL-CLOSED.
#
# `_reconcile_field_default_notes` ends in a jq call whose status IS the
# function's: the dispatcher runs under `set -euo pipefail`, so a jq that cannot
# compose the notes aborts the run rather than yielding an empty result
# (Constitution III, fail-closed on writes).
#
# Routing that jq's input through a temp file (needed because the native jq.exe
# on Windows cannot open an MSYS `/dev/fd/N`) put a cleanup line AFTER it. That
# made `rm -f` the last command, so the function returned 0 for a failed jq and
# the abort silently became an empty notes list. Caught in review, not by a
# test — hence this one.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SHIM="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${SHIM}"
}

_call_notes() {
  # The eight arguments the function documents, with a shape that reaches the
  # jq call: one action carrying a defaulted field.
  run bash -c '
    source "'"${ROOT}"'/scripts/bash/commands/reconcile.sh"
    PATH="'"${SHIM}"':${PATH}"
    _reconcile_field_default_notes "PROJ" "[]" "{}" "{}" "[]" "null" "true" "false" "false"
    printf "rc=%s" "$?"
  '
}

@test "a jq failure in the notes builder is reported, never swallowed (Constitution III)" {
  # A jq that fails on every invocation. `exit 5` is jq's own crash code.
  printf '#!/usr/bin/env bash\nexit 5\n' > "${SHIM}/jq"
  chmod +x "${SHIM}/jq"

  _call_notes
  # The function must not answer 0. Either it returns jq's status, or the
  # sourced script's own `set -e` takes the subshell down — both are
  # fail-closed; returning 0 with empty output is what this pins against.
  [[ "${output}" != *"rc=0"* ]] || {
    printf 'the notes builder returned 0 despite a failing jq:\n%s\n' "${output}" >&2
    return 1
  }
}

@test "the temp file the notes builder creates is removed on the failure path" {
  printf '#!/usr/bin/env bash\nexit 5\n' > "${SHIM}/jq"
  chmod +x "${SHIM}/jq"

  # A PRIVATE TMPDIR, because mktemp honours it. The first version of this test
  # counted the host's shared temp directory and was red the moment the suite
  # ran in parallel — 179901 entries, moving under it constantly. A test whose
  # subject is a global counter measures the other tests, not its own.
  local priv="${BATS_TEST_TMPDIR}/tmproot"
  mkdir -p "${priv}"
  run bash -c '
    source "'"${ROOT}"'/scripts/bash/commands/reconcile.sh"
    PATH="'"${SHIM}"':${PATH}"
    export TMPDIR="'"${priv}"'"
    _reconcile_field_default_notes "PROJ" "[]" "{}" "{}" "[]" "null" "true" "false" "false"
  '
  local left
  left="$(find "${priv}" -type f | wc -l | tr -d ' ')"
  [ "${left}" -eq 0 ] || {
    printf 'the failing call left %s file(s) behind:\n' "${left}" >&2
    find "${priv}" -type f >&2
    return 1
  }
}
