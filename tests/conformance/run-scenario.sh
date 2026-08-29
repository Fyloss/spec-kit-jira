#!/usr/bin/env bash
# T009 — Conformance harness.
#
#   run-scenario.sh <scenario.json> <bash|powershell> [outdir]
#
# Runs one port's entry point against a scenario and captures everything needed
# for a byte-identical cross-port comparison (NFR-1): stdout, stderr, exit code,
# the Jira API call sequence, and the full post-run repository tree. Run the
# same scenario against both ports into two outdirs and `diff -r` them; any
# divergence is a failing conformance test, not a documented quirk.
#
# Scenario schema — see scenarios/README.md. Fields:
#   name    (string)         informational
#   mock    (object)         mock-jira config (projects / faults / fault)
#   fixture (string, opt)    repo dir (relative to repo root) copied into the workdir
#   argv    (array,  opt)    arguments passed to the entry point
#   env     (object, opt)    extra environment variables for the run
#
# The run's environment is the scenario's, never the caller's: every ambient
# SPEC_KIT_JIRA_* / JIRA_* variable is scrubbed before the scenario's own `env`
# is applied. A caller that deliberately needs one more variable for a single
# run declares it in SPEC_KIT_JIRA_HARNESS_ENV as newline-separated KEY=VALUE
# pairs; see the "Environment" section below.
#
# The entry point defaults to the canonical port path but can be overridden with
# SPEC_KIT_JIRA_ENTRY_BASH / SPEC_KIT_JIRA_ENTRY_PWSH (used to pin paths in CI
# and to exercise this harness before the real dispatcher lands, T024).
#
# Captured layout (in outdir): stdout, stderr, exit, calls.log, workdir/.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: run-scenario.sh <scenario.json> <bash|powershell> [outdir]" >&2
  exit 1
fi

SCENARIO="$1"
PORT="$2"
OUTDIR="${3:-$(mktemp -d)}"

CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CONF_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${CONF_DIR}/mock-jira/lib.sh"

[ -f "${SCENARIO}" ] || { echo "scenario not found: ${SCENARIO}" >&2; exit 1; }
mkdir -p "${OUTDIR}"

# Every scalar this harness reads out of jq goes through here.
#
# On Windows the `jq` on PATH is the NATIVE jq.exe, and its stdout is a
# text-mode stream: it terminates each line with CRLF, not LF. Nothing
# downstream removes that CR — `$( )` strips trailing NEWLINES only, and
# `read` strips the delimiter, so the CR rides into the last field of every
# line. A scenario's `SPEC_KIT_JIRA_SPEC_SLUG: 001-billing` then reached the
# port as $'001-billing\r', which fails the anchored slug pattern (in both
# ports' regex flavours `$` tolerates a trailing \n, never a trailing \r) and
# refused the whole run with "spec_ref.spec_slug is malformed".
#
# Stripping here rather than at each consumer is deliberate: the CR is an
# artefact of how this one process emits lines, so it is removed where the
# lines are read. It also covers the ARGV path for BOTH ports — pwsh-invoke.ps1
# already defends its own argv file, but the Bash port receives argv directly
# and had no such guard.
jq_lines() { jq "$@" | sed $'s/\r$//'; }

case "${PORT}" in
  bash)
    ENTRY="${SPEC_KIT_JIRA_ENTRY_BASH:-${REPO_ROOT}/scripts/bash/spec-kit-jira.sh}"
    ;;
  powershell)
    ENTRY="${SPEC_KIT_JIRA_ENTRY_PWSH:-${REPO_ROOT}/scripts/powershell/spec-kit-jira.ps1}"
    ;;
  *)
    echo "unknown port: ${PORT} (expected bash|powershell)" >&2
    exit 1
    ;;
esac
[ -f "${ENTRY}" ] || { echo "entry point not found: ${ENTRY}" >&2; exit 1; }

# Are we git-bash (MSYS) on Windows, about to spawn a NATIVE pwsh.exe? That one
# combination mistranslates a bash argv array into a Windows command line and
# needs the wrapper below; every other host takes the plain invocation. Both
# conditions are required — cygpath also exists under Cygwin, where `uname`
# reports CYGWIN and this translation does not apply the same way.
MSYS_PWSH=""
case "$(uname -s 2> /dev/null || true)" in
  MINGW* | MSYS*) command -v cygpath > /dev/null 2>&1 && MSYS_PWSH=1 ;;
esac

# --- Isolated workdir (the "repository" the port runs against) ---------------
WORKDIR="$(mktemp -d)"
FIXTURE="$(jq_lines -r '.fixture // empty' "${SCENARIO}")"
if [ -n "${FIXTURE}" ]; then
  [ -d "${REPO_ROOT}/${FIXTURE}" ] || { echo "fixture not found: ${FIXTURE}" >&2; exit 1; }
  cp -R "${REPO_ROOT}/${FIXTURE}/." "${WORKDIR}/"
fi

# `cwd` (031, C1.2/C1.4 — the two hosts' path-resolution divergence surface,
# contract §5.2): a directory RELATIVE to the fixture root the entry point is
# invoked from, instead of the fixture root itself — the shape a nested
# checkout needs to prove the walk-upward resolution (T003's
# repo-031-nested/sub/module/). Everything else (the config.yml substitution
# above the WORKDIR itself, the git init below, the post-run tree capture)
# stays rooted at WORKDIR; only the command's own working directory moves.
CWD_REL="$(jq_lines -r '.cwd // empty' "${SCENARIO}")"
RUNDIR="${WORKDIR}"
if [ -n "${CWD_REL}" ]; then
  RUNDIR="${WORKDIR}/${CWD_REL}"
  [ -d "${RUNDIR}" ] || { echo "cwd not found in fixture: ${CWD_REL}" >&2; exit 1; }
fi

# --- @PAT_HANG_COMMAND@ resolution (030, T001, research.md §R11) ------------
# Resolved ONCE per run and handed identically to both ports, so the C3.6
# timeout scenario's failure message names the same command string on either
# backend and the byte diff between them stays clean. No single literal blocks
# on macOS, Linux and Windows alike (`sleep` is absent from a bare Windows
# PATH; `ping` returns in seconds on Windows but hangs forever on Linux), so a
# POSIX host resolves to the `sleep` already on every such runner, and a
# Windows host (MINGW/MSYS/CYGWIN — the git-bash this harness itself needs to
# run at all) resolves to a small .cmd wrapping the `Start-Sleep` cmdlet, which
# every windows-latest runner already carries via `powershell.exe`. `.cmd` is
# directly executable through CreateProcess (Windows resolves it via PATHEXT
# the way POSIX exec() resolves a shebang), so the resolved value is one token
# with no embedded space — no wrapper-script indirection is needed to declare
# it as JIRA_PAT_COMMAND (FR-004).
case "$(uname -s 2> /dev/null || true)" in
  MINGW* | MSYS* | CYGWIN*)
    _pat_hang_cmd="${OUTDIR}/pat-hang.cmd"
    printf '@echo off\r\npowershell -NoProfile -Command "Start-Sleep -Seconds 30"\r\n' > "${_pat_hang_cmd}"
    if command -v cygpath > /dev/null 2>&1; then
      PAT_HANG_COMMAND_RESOLVED="$(cygpath -w "${_pat_hang_cmd}")"
    else
      PAT_HANG_COMMAND_RESOLVED="${_pat_hang_cmd}"
    fi
    ;;
  *)
    PAT_HANG_COMMAND_RESOLVED="sleep 30"
    ;;
esac

# --- Mock double -------------------------------------------------------------
# Backend follows PORT (Decision 2, contracts/mock-driver.md): the Bash port
# is exercised through the curl shim (no process); the PowerShell port needs
# the real socket server, since its native HTTP client cannot reach the
# shim's sentinel MOCK_BASE_URL.
MOCK_CFG="$(mktemp)"
jq '.mock // {}' "${SCENARIO}" > "${MOCK_CFG}"
mock_start "${MOCK_CFG}" "${PORT}"
# Recorded so a caller can identify THIS run's mock precisely — a name-pattern
# scan (pgrep -f mock-server.ps1) also matches every other scenario's mock
# running concurrently under a parallel test suite. Only the real-server
# backend (PowerShell port) has a PID to record.
[ -n "${MOCK_PID:-}" ] && echo "${MOCK_PID}" > "${OUTDIR}/mock.pid"
# From here on every exit path reaps the mock, including the ones `set -e` takes
# on our behalf. An orphan holds each descriptor it inherited, and whoever reads
# the other end then blocks forever rather than failing.
trap mock_stop EXIT

# --- @MOCK_BASE_URL@ substitution (030, T001, research.md §R6/§R10) ---------
# The fixture's `config.yml` (a tracked file — Constitution IV forbids a real
# site URL there) declares `base_url: "@MOCK_BASE_URL@"`; substituted here,
# AFTER mock_start so the mock's OS-assigned loopback port is known, and
# BEFORE the run so config_load sees a resolved, loopback-exempt `http://`
# value rather than the literal sentinel. A fixture with no such file, or no
# sentinel in it, is copied byte-identically — the substitution is a no-op.
_config_yml="${WORKDIR}/.specify/jira/config.yml"
if [ -f "${_config_yml}" ] && grep -q '@MOCK_BASE_URL@' "${_config_yml}" 2> /dev/null; then
  _tmp_cfg="$(mktemp)"
  sed "s|@MOCK_BASE_URL@|${MOCK_BASE_URL}|g" "${_config_yml}" > "${_tmp_cfg}"
  mv "${_tmp_cfg}" "${_config_yml}"
fi

# --- Optional git repository (degraded-mode / branch-state scenarios) --------
# `git_branch` initialises the workdir as a git repo checked out on that branch
# (deterministic default branch so both ports see identical refs).
GIT_BRANCH="$(jq_lines -r '.git_branch // empty' "${SCENARIO}")"
if [ -n "${GIT_BRANCH}" ]; then
  (
    cd "${WORKDIR}"
    git init -q -b main
    git -c user.email=conformance@example.invalid -c user.name=conformance \
      commit -q --allow-empty -m init
    git checkout -q -b "${GIT_BRANCH}"
  )
fi

# --- Environment -------------------------------------------------------------
# A scenario's environment is the one the SCENARIO declares, never the one the
# caller happened to be holding. Both ports read a broad SPEC_KIT_JIRA_* /
# JIRA_* override surface — project key, plan context, hook context, config
# dir, credentials — and any of those left ambient silently rewrites the run.
# A scenario's `env` block can only ADD variables, so without this scrub there
# is no way for a scenario to say "and nothing else".
#
# Not hypothetical: tests/powershell/lib/TokenLeak.Tests.ps1 exports
# SPEC_KIT_JIRA_PROJECT_KEY=PROJ (the shipped placeholder) and never clears it.
# Pester discovers lib/ immediately before conformance/ on the Linux CI host,
# but after commands/ — whose Reconcile.* files scrub that same variable — on
# the author's macOS host. Every reconcile scenario therefore refused with the
# placeholder-key message (exit 4, zero writes) instead of mirroring: four red
# conformance tests in CI, green locally, and nothing in either log naming the
# cause. The leak is fixed at its source too; this is the guard that stops the
# next one costing another CI-only debugging round.
#
# Scrubbing by PREFIX rather than by an enumerated list is deliberate: that
# list grows with every new override the ports read, and a list somebody has to
# remember to extend is one that will be a variable behind the day it matters.
# The exemptions are the variables the HARNESS itself is configured with.
for _ambient in ${!SPEC_KIT_JIRA_@} ${!JIRA_@}; do
  case "${_ambient}" in
    SPEC_KIT_JIRA_ENTRY_BASH | SPEC_KIT_JIRA_ENTRY_PWSH | SPEC_KIT_JIRA_COVERAGE_INPROCESS | SPEC_KIT_JIRA_HARNESS_*) continue ;;
  esac
  unset "${_ambient}"
done
unset _ambient

# The mock base URL is set FIRST so a scenario's env can override it (e.g. to
# the empty string, which the ports treat as unset — the degraded-mode trigger).
export SPEC_KIT_JIRA_BASE_URL="${MOCK_BASE_URL}"
while IFS=$'\t' read -r key value; do
  [ -n "${key}" ] || continue
  # @PAT_HANG_COMMAND@ (030, T001): substituted in env VALUES only, after the
  # resolution above — same string for both ports (research §R11).
  case "${value}" in
    *@PAT_HANG_COMMAND@*) value="${value//@PAT_HANG_COMMAND@/${PAT_HANG_COMMAND_RESOLVED}}" ;;
  esac
  export "${key}=${value}"
done < <(jq_lines -r '(.env // {}) | to_entries[] | [.key, (.value | tostring)] | @tsv' "${SCENARIO}")

# The one way a CALLER may set a port variable for a single run: newline-
# separated KEY=VALUE pairs in SPEC_KIT_JIRA_HARNESS_ENV, applied last so they
# win over the scenario's own env. This exists so that a test running the SAME
# scenario twice — once plain, once under a hook — does not need a second
# scenario file for the one variable that differs (the retired-key refusal,
# T025). Routing it through a named channel is the point: after the scrub
# above, an override that reaches the port is one somebody wrote down, and
# anything else in the ambient environment is a leak by definition.
if [ -n "${SPEC_KIT_JIRA_HARNESS_ENV:-}" ]; then
  while IFS= read -r pair; do
    [ -n "${pair}" ] || continue
    case "${pair}" in
      *=*) export "${pair%%=*}=${pair#*=}" ;;
      *) echo "SPEC_KIT_JIRA_HARNESS_ENV entry is not KEY=VALUE: ${pair}" >&2; exit 1 ;;
    esac
  done <<< "${SPEC_KIT_JIRA_HARNESS_ENV}"
fi

# --- Runs ----------------------------------------------------------------
# A scenario is either a single implicit run (top-level `argv`, unchanged
# behaviour) or an explicit `runs` array — each entry its own `argv` — for
# proving a SECOND invocation's behaviour against state the FIRST left
# behind (US1 idempotency, US2 zero churn): both runs share one workdir and
# one mock process. Captured as stdout.N / stderr.N / exit.N, N = 1-based;
# stdout/stderr/exit (unsuffixed) always mirror the LAST run, so a
# single-run scenario's existing consumers see no difference.
#
# calls.log.N (021, US2, T020) is the SLICE of the shared, cumulative mock
# log written during run N alone — never the log-so-far — because the mock
# process and its call log are shared across every run in the array (see the
# calls.log capture below), so a consumer proving "run 2 issued zero
# requests" needs run 2's own contribution isolated from run 1's.
RUN_COUNT="$(jq_lines '(.runs // []) | length' "${SCENARIO}")"
if [ "${RUN_COUNT}" -eq 0 ]; then RUN_COUNT=1; fi

CALLLOG_PREV_LINES=0
set +e
for ((i = 1; i <= RUN_COUNT; i++)); do
  ARGV=()
  if [ "${RUN_COUNT}" -gt 1 ] || [ "$(jq_lines '(.runs // []) | length' "${SCENARIO}")" -gt 0 ]; then
    # shellcheck disable=SC2016  # $i is a jq variable bound by --argjson, not a
    # shell expansion; shellcheck only recognises that for the literal name `jq`.
    # 032, T028 — the sentinel is substituted in argv too, not only in the
    # fixture's config.yml. A scenario that has to NAME the mock's origin (the
    # --accept-site gesture) cannot pre-bake an OS-assigned port; without this
    # the positive half of SC-008 is unexpressible. A no-op when absent.
    while IFS= read -r arg; do ARGV+=("${arg}"); done < <(jq_lines -r --argjson i "$((i - 1))" '.runs[$i].argv[]? // empty' "${SCENARIO}" | sed "s|@MOCK_BASE_URL@|${MOCK_BASE_URL}|g")
  else
    while IFS= read -r arg; do ARGV+=("${arg}"); done < <(jq_lines -r '.argv[]? // empty' "${SCENARIO}" | sed "s|@MOCK_BASE_URL@|${MOCK_BASE_URL}|g")
  fi

  # `runs[i].before` (021, US2, T021) mutates WORKDIR immediately ahead of
  # run i's own process — the only way to build a fail-open fixture, since
  # base_url inside a recorded run-state document is the mock's OS-assigned
  # port and can never be pre-baked to match a real run's own state file.
  # `write`/`append` extract each key SEPARATELY with plain `jq -r` rather
  # than folding the object through `@tsv`: `@tsv` escapes embedded
  # newlines into literal backslash-n and `read` never un-escapes them,
  # which would corrupt any multi-line file content.
  if [ "${RUN_COUNT}" -gt 1 ]; then
    while IFS= read -r rel_path; do
      [ -z "${rel_path}" ] && continue
      mkdir -p "$(dirname "${WORKDIR}/${rel_path}")"
      # 032, T028 — substitute the sentinel here as well, so a run can rewrite
      # config.yml to point back at the mock. The fixture-copy substitution
      # above runs once, before any `before.write` replaces the file.
      jq_lines -r --argjson i "$((i - 1))" --arg k "${rel_path}" '.runs[$i].before.write[$k]' "${SCENARIO}" | sed "s|@MOCK_BASE_URL@|${MOCK_BASE_URL}|g" > "${WORKDIR}/${rel_path}"
    done < <(jq_lines -r --argjson i "$((i - 1))" '.runs[$i].before.write // {} | keys[]' "${SCENARIO}")

    while IFS= read -r rel_path; do
      [ -z "${rel_path}" ] && continue
      mkdir -p "$(dirname "${WORKDIR}/${rel_path}")"
      jq_lines -r --argjson i "$((i - 1))" --arg k "${rel_path}" '.runs[$i].before.append[$k]' "${SCENARIO}" >> "${WORKDIR}/${rel_path}"
    done < <(jq_lines -r --argjson i "$((i - 1))" '.runs[$i].before.append // {} | keys[]' "${SCENARIO}")

    while IFS= read -r rel_path; do
      [ -z "${rel_path}" ] && continue
      rm -f "${WORKDIR}/${rel_path}"
    done < <(jq_lines -r --argjson i "$((i - 1))" '.runs[$i].before.delete // [] | .[]' "${SCENARIO}")

    # `jq` (021, US2, T021) patches a SINGLE field of a file a prior run in
    # this same scenario already wrote — e.g. the run-state document's
    # `extension_version` — where a static `write` cannot, because the rest
    # of that file's content (its real base_url, its real input hashes) is
    # only known once run i-1 has actually produced it. A target absent at
    # this point (the state phase not yet wired, or the prior run recorded
    # nothing) is silently skipped rather than treated as an error: the run
    # that follows still sees "no state file", itself a fail-open row of
    # contracts/run-state.md §3, so the scenario stays meaningful either way.
    while IFS= read -r rel_path; do
      [ -z "${rel_path}" ] && continue
      target="${WORKDIR}/${rel_path}"
      [ -f "${target}" ] || continue
      filter="$(jq_lines -r --argjson i "$((i - 1))" --arg k "${rel_path}" '.runs[$i].before.jq[$k]' "${SCENARIO}")"
      tmp="$(mktemp)"
      if jq -c "${filter}" "${target}" 2> /dev/null | tr -d '\n' > "${tmp}"; then
        mv "${tmp}" "${target}"
      else
        rm -f "${tmp}"
      fi
    done < <(jq_lines -r --argjson i "$((i - 1))" '.runs[$i].before.jq // {} | keys[]' "${SCENARIO}")
  fi

  if [ "${PORT}" = "bash" ]; then
    if [ -n "${SPEC_KIT_JIRA_COVERAGE_INPROCESS:-}" ]; then
      # Coverage mode only (T097): kcov's bash tracing follows forked subshells but
      # NOT execve'd children, so `bash "${ENTRY}"` measures nothing. Sourcing the
      # entry point in a subshell keeps every observable identical — own cwd, own
      # argv, own redirections, own exit status, and `set -euo pipefail` scoped to
      # the subshell — while making scripts/bash/** visible to the tracer.
      # stderr is deliberately NOT captured in this mode: the tracer streams its
      # PS4 trace on fd 2, so redirecting fd 2 to a file would hide every executed
      # line from it. Coverage mode asserts nothing about stderr.
      # shellcheck source=/dev/null
      ( cd "${RUNDIR}" && source "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout.${i}"
      : > "${OUTDIR}/stderr.${i}"
    else
      ( cd "${RUNDIR}" && bash "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout.${i}" 2> "${OUTDIR}/stderr.${i}"
    fi
  elif [ -z "${MSYS_PWSH:-}" ]; then
    # The plain invocation, unchanged since T009 and green on Linux and macOS
    # for this project's whole history. Everywhere except git-bash-on-Windows
    # this is exactly right, so it stays the default: the workaround below can
    # only ever regress the platform it was written for.
    ( cd "${RUNDIR}" && pwsh -NoProfile -File "${ENTRY}" ${ARGV[@]+"${ARGV[@]}"} ) > "${OUTDIR}/stdout.${i}" 2> "${OUTDIR}/stderr.${i}"
  else
    # git-bash (MSYS) on Windows ONLY. Spawning the NATIVE pwsh.exe with
    # `-File <path> <args...>` loses or mangles trailing simple-word arguments
    # in MSYS's argv-to-Windows-command-line translation, so the entry point
    # and argv travel in FILES and pwsh's command line carries nothing but the
    # wrapper's own path. cygpath spells those paths the way pwsh.exe reads
    # them — bash here speaks POSIX ("/d/a/repo/..."), which it cannot resolve.
    entry_native="$(cygpath -w "${ENTRY}")"
    printf '%s' "${entry_native}" > "${OUTDIR}/entry.${i}"
    printf '%s\n' ${ARGV[@]+"${ARGV[@]}"} > "${OUTDIR}/argv.${i}"
    ( cd "${RUNDIR}" \
      && SPEC_KIT_JIRA_HARNESS_ENTRYFILE="$(cygpath -w "${OUTDIR}/entry.${i}")" \
         SPEC_KIT_JIRA_HARNESS_ARGVFILE="$(cygpath -w "${OUTDIR}/argv.${i}")" \
         pwsh -NoProfile -File "$(cygpath -w "${CONF_DIR}/pwsh-invoke.ps1")" \
    ) > "${OUTDIR}/stdout.${i}" 2> "${OUTDIR}/stderr.${i}"
  fi
  echo "$?" > "${OUTDIR}/exit.${i}"

  calllog_total_lines="$(wc -l < "${MOCK_CALLLOG}" 2> /dev/null || echo 0)"
  tail -n "+$((CALLLOG_PREV_LINES + 1))" "${MOCK_CALLLOG}" > "${OUTDIR}/calls.log.${i}" 2> /dev/null \
    || : > "${OUTDIR}/calls.log.${i}"
  CALLLOG_PREV_LINES="${calllog_total_lines}"
done
set -e
cp "${OUTDIR}/stdout.${RUN_COUNT}" "${OUTDIR}/stdout"
cp "${OUTDIR}/stderr.${RUN_COUNT}" "${OUTDIR}/stderr"
cp "${OUTDIR}/exit.${RUN_COUNT}" "${OUTDIR}/exit"

# The call log must be captured BEFORE mock_stop: mock_stop now removes the
# recorded MOCK_TMPDIR it lives under (contracts/mock-driver.md), so copying
# it after would silently produce an empty capture.
cp "${MOCK_CALLLOG}" "${OUTDIR}/calls.log" 2> /dev/null || : > "${OUTDIR}/calls.log"
mock_stop

# The WORKDIR path itself (031, C1.1/C1.4): every port gets its OWN mktemp -d,
# so a field that legitimately reports an absolute path UNDER it (the
# resolved configuration directory, or a file written beneath it) can never
# be byte-identical across two independent runs even when the RUN ITSELF is —
# the same class of never-agrees value _normalize_state_base_url already
# documents for the mock's ephemeral port. Recorded here so the caller can
# normalise it out of stdout before comparing; nothing in this repository
# reads the file's own content from inside a running scenario.
#
# On windows-latest this ONE directory has SIX distinct byte spellings, and
# either port's own output can use any of them. They vary along three
# independent axes, and a candidate list that fixes one axis while leaving
# another free is how this defect survived four remote round-trips:
#
#   syntax     MSYS (`/tmp/tmp.X`) | mixed (`C:/…`, cygpath -m) |
#              native (`C:\…`, cygpath -w) — the Bash port reports the MSYS
#              form, the PowerShell port the NATIVE one, and until now only
#              the mixed form was recorded, so the two spellings that
#              actually reach a capture were the two nobody masked.
#   name form  short (`C:\Users\RUNNER~1\…`, what the /tmp mount is
#              registered as, because Windows sets %TEMP% to the 8.3 form)
#              vs long (`C:\Users\runneradmin\…`, what a natively-spawned
#              pwsh.exe's own Get-Location resolves the SAME directory to).
#              cygpath spells either on demand: `-l` / `-s`.
#   physical   the `pwd -P` form MSYS bash reports once it `cd`s in — needed
#              for macOS's own /var -> /private/var symlink,
#              [[macos-var-symlink-cross-process-cwd-divergence]]; on Windows
#              it resolves the MSYS /tmp mount instead, giving `/c/Users/…`.
#
# One `wd` value can only ever mask one spelling, so record every candidate
# this host can produce, one per line, and let the caller mask all of them
# (`sort -u` collapses them to a single no-op line on macOS/Linux, where they
# all coincide).
#
# `cygpath -wl`, not a spawned pwsh, is what settles the long-name axis:
# measured on a real Windows host, it reproduces `(Get-Location).Path` byte
# for byte — including a home directory carrying BOTH an 8.3 alias and a
# space — for a fraction of the cost of a pwsh start-up per scenario, on the
# host where this corpus is already the whole job's wall clock.
{
  printf '%s\n' "${WORKDIR}"
  (cd "${WORKDIR}" 2> /dev/null && pwd -P) || true
  if command -v cygpath > /dev/null 2>&1; then
    for _spelling in -m -w -ml -wl -ms -ws; do
      cygpath "${_spelling}" "${WORKDIR}" 2> /dev/null || true
    done
  fi
  true
} | sort -u > "${OUTDIR}/workdir.path"

# --- Snapshot the post-run repository tree (written files) -------------------
rm -rf "${OUTDIR}/workdir"
mkdir -p "${OUTDIR}/workdir"
( cd "${WORKDIR}" && find . -path ./.git -prune -o -type f -print0 | while IFS= read -r -d '' f; do
  mkdir -p "${OUTDIR}/workdir/$(dirname "${f}")"
  cp "${f}" "${OUTDIR}/workdir/${f}"
done )

echo "${OUTDIR}"
