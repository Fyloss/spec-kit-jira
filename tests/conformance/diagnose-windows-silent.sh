#!/usr/bin/env bash
# diagnose-windows-silent.sh — make the SILENT Windows failures talk (#46, category D).
#
# WHY THIS EXISTS
#
# After #47 removed the jq/MSYS-path cause, 21 conformance scenarios still
# diverge on windows-latest. Four are E2BIG and name themselves. Sixteen write
# NOTHING to stderr, so the report added in #47 — which prints each port's
# stderr — is already blind to them. Something ends the run and says nothing.
#
# Each answer from the CI probe costs 45-75 minutes and loses a shard roughly
# one run in two. On a real Windows box the same question costs seconds. This
# script is that question, asked once for every silent scenario.
#
# HOW IT WORKS
#
# `SHELLOPTS=xtrace` cannot be injected: run-scenario.sh exports whatever
# SPEC_KIT_JIRA_HARNESS_ENV carries, and SHELLOPTS is readonly in a running
# shell — the export would fail and take the harness down with it.
#
# BASH_ENV is the way in. Bash sources it for every NON-INTERACTIVE shell, which
# is exactly what `bash <entry>` is. The sourced file below turns xtrace on, but
# only for the port's own entry point, so the mock's curl shim and the harness
# itself stay quiet.
#
# USAGE (from the repository root, in git-bash on Windows)
#
#   bash tests/conformance/diagnose-windows-silent.sh
#
# It writes a single report to stdout. Paste that back — it is the whole point.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
TRACE_LINES="${SKJ_TRACE_LINES:-25}"

# The sixteen silent scenarios, plus the one whose stderr said something the
# report could not classify. Measured on CI run 32530470422 (78b5d06), all four
# shards. Override with: SKJ_SCENARIOS="a b c" bash …
DEFAULT_SCENARIOS="
us022-checklist-crlf
us022-checklist-two-phases
us022-checklist-unchanged-rerun
us023-idempotent-rerun
us027-refuse-exists
us027-three-url-forms
us028-template-form-ac
us2-field-defaults-option-question
us2-field-defaults-question
us2-preserve-human-prefix
us29-feature-designator-reuse-yes-silent
us29-feature-mention-with-designator
us29-feature-reuse-yes-auto-accept
us3-markdown-idempotent
us4-migration-clean
us5-plan-on-parent
us021-state-unchanged
"

# The BASH_ENV hook. `$0` is the script bash was told to run, so the guard keeps
# the trace to the port and off every helper the run spawns.
cat > "${WORK}/trace-hook.sh" << 'HOOK'
case "$0" in
  */spec-kit-jira.sh) ;;
  *) return 0 2> /dev/null || exit 0 ;;
esac
# File and line on every frame — the last one is the answer this script exists
# for. fd 9 keeps the trace off stderr, which the harness captures and compares.
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
exec 9>> "${SKJ_TRACE_FILE}"
export BASH_XTRACEFD=9
set -x
HOOK

printf '=== spec-kit-jira — silent Windows failures (#46 category D) ===\n'
printf 'host:   %s\n' "$(uname -s 2> /dev/null || echo unknown)"
printf 'bash:   %s\n' "${BASH_VERSION}"
printf 'jq:     %s (%s)\n' "$(jq --version 2> /dev/null || echo ABSENT)" "$(command -v jq || echo '-')"
printf 'pwsh:   %s\n' "$(command -v pwsh || echo ABSENT)"
printf 'commit: %s\n\n' "$(git -C "${ROOT}" rev-parse --short HEAD 2> /dev/null || echo unknown)"

scenarios="${SKJ_SCENARIOS:-${DEFAULT_SCENARIOS}}"
for name in ${scenarios}; do
  file="${ROOT}/tests/conformance/scenarios/${name}.json"
  if [ ! -f "${file}" ]; then
    printf -- '--- %s\n    SKIPPED: no such scenario\n\n' "${name}"
    continue
  fi

  out="${WORK}/${name}"
  trace="${WORK}/${name}.trace"
  : > "${trace}"

  SKJ_TRACE_FILE="${trace}" \
  SPEC_KIT_JIRA_HARNESS_ENV="BASH_ENV=${WORK}/trace-hook.sh
SKJ_TRACE_FILE=${trace}" \
    bash "${ROOT}/tests/conformance/run-scenario.sh" "${file}" bash "${out}" \
    > "${WORK}/${name}.harness" 2>&1
  harness_rc=$?

  exit_code="$(cat "${out}/exit" 2> /dev/null || echo '<none>')"
  stdout_size="$(wc -c < "${out}/stdout" 2> /dev/null | tr -d ' ' || echo 0)"
  stderr_size="$(wc -c < "${out}/stderr" 2> /dev/null | tr -d ' ' || echo 0)"

  printf -- '--- %s\n' "${name}"
  printf '    harness rc=%s  port exit=%s  stdout=%s bytes  stderr=%s bytes\n' \
    "${harness_rc}" "${exit_code}" "${stdout_size}" "${stderr_size}"

  if [ "${stderr_size}" -gt 0 ]; then
    printf '    stderr (first 300 bytes):\n'
    head -c 300 "${out}/stderr" | sed 's/^/      /'
    printf '\n'
  fi

  if [ -s "${trace}" ]; then
    printf '    last %s traced frames — the run stopped at the LAST one:\n' "${TRACE_LINES}"
    tail -n "${TRACE_LINES}" "${trace}" | sed 's/^/      /'
  else
    printf '    NO TRACE — the port never started, or BASH_ENV was not honoured.\n'
    printf '    (harness output, last 5 lines:)\n'
    tail -n 5 "${WORK}/${name}.harness" 2> /dev/null | sed 's/^/      /'
  fi
  printf '\n'
done

printf '=== end of report ===\n'
printf 'workdir kept for inspection: %s\n' "${WORK}"
