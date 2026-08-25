#!/usr/bin/env bash
# tests/conformance/ci-conformance.sh — runs the whole conformance corpus
# against both ports and diffs the captures (NFR-1). Extracted out of
# .github/workflows/ci.yml (008 T103) so the SAME script runs on every host
# in the three-OS matrix, not just Linux — a divergence that only a real
# Windows or macOS host exposes (path separators, line endings, shell
# quoting) is exactly what a single-OS conformance run cannot catch.
#
# When THIS script fails on windows-latest and nowhere else, do not reach for a
# local emulation of Windows: two were tried (a stub jq on PATH reproducing
# jq.exe's text-mode CRLF stdout, and the CR guard in lib/output.sh forced on
# against the real jq) and both passed the whole corpus while the runner failed
# fifteen scenarios. Use .github/workflows/windows-conformance.yml instead — it
# runs this script, and only this script, on a real Windows host from a
# throwaway branch, without opening a pull request. Its header carries the
# invocation.
# Every function here reaches its call site indirectly — through `bash -c`
# under xargs, or from a function that does — which shellcheck reads as never
# invoked.
# shellcheck disable=SC2329
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
harness="${ROOT}/tests/conformance/run-scenario.sh"
scenarios=("${ROOT}"/tests/conformance/scenarios/*.json)
if [ ${#scenarios[@]} -eq 0 ]; then
  echo "conformance corpus is empty — nothing to compare (scenarios land per user story)"
  exit 0
fi

# Optional sharding, for a matrix of runners splitting one corpus.
#
# On windows-latest the corpus is the whole cost — 33 of a 33-minute job, with
# setup and checkout accounting for eight seconds between them — and the reason
# is structural: every scenario pays for a PowerShell mock server, a native
# pwsh.exe and MSYS's emulated fork, on a host where the in-runner parallelism
# is capped at 2 because a wider fan-out killed the runner outright. Splitting
# across runners buys back the wall clock that cap costs without reintroducing
# the pressure that made it necessary.
#
# The slice is round-robin rather than contiguous: the glob is alphabetical, so
# scenarios cluster by user story, and consecutive blocks would hand one runner
# every reconcile case (four HTTP writes and a second run apiece) while another
# gets a handful of refusals that exit before their first request.
shard_total="${SPEC_KIT_JIRA_SHARD_TOTAL:-1}"
shard_index="${SPEC_KIT_JIRA_SHARD_INDEX:-0}"
if [ "${shard_total}" -gt 1 ]; then
  sharded=()
  for i in "${!scenarios[@]}"; do
    [ "$((i % shard_total))" -eq "${shard_index}" ] && sharded+=("${scenarios[i]}")
  done
  scenarios=(${sharded[@]+"${sharded[@]}"})
  printf 'shard %s of %s — %s scenarios\n' "${shard_index}" "${shard_total}" "${#scenarios[@]}"
  if [ ${#scenarios[@]} -eq 0 ]; then
    echo "this shard has no scenarios — nothing to compare"
    exit 0
  fi
fi

# One report file per failing scenario, folded into a SINGLE annotation at the
# end (see the summary block). Per-scenario annotations were the obvious shape
# and the wrong one: GitHub keeps only the first ten per check run, so with
# fifteen scenarios failing the later ones vanish.
#
# Which is also why the per-scenario lines below are plain output and NOT
# `::error::`. Emitting both was tried on the first real Windows probe: the ten
# per-scenario annotations consumed the whole budget and the summary — the one
# carrying the actual bytes, and the only channel that survives a job log
# needing admin rights to read — was dropped on the floor.
REPORT_DIR="$(mktemp -d)"
trap 'rm -rf "${REPORT_DIR}"' EXIT
export REPORT_DIR

# Portable core count: nproc (Linux), sysctl (macOS), NUMBER_OF_PROCESSORS
# (set by every GitHub-hosted Windows runner) — falls back to 4 rather than
# failing when none of the above resolves.
#
# Git-bash on Windows is capped hard, and deliberately. A scenario there costs
# far more than a process: MSYS emulates fork, every scenario spawns a
# PowerShell mock server plus a native pwsh.exe, and the text-mode-jq guard in
# lib/output.sh doubles the process count of the Bash port on that host alone.
# Run unthrottled, the windows-latest job died with "the hosted runner lost
# communication with the server" partway through the corpus — which also meant
# the divergences after that point were never reported at all, and a partial
# log read as a short list of failures rather than a truncated one.
core_count() {
  case "$(uname -s 2> /dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*) printf '2'; return 0 ;;
  esac
  if command -v nproc > /dev/null 2>&1; then nproc
  elif command -v sysctl > /dev/null 2>&1; then sysctl -n hw.ncpu
  elif [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then printf '%s' "${NUMBER_OF_PROCESSORS}"
  else printf '4'
  fi
}

# _size <file> — the file's length in bytes, or `absent`.
_size() {
  if [ -f "$1" ]; then wc -c < "$1" | tr -d '[:space:]'; else printf 'absent'; fi
}

# _byte_at <file> <1-based offset> — that byte in hex, or `EOF` past the end.
_byte_at() {
  local hex
  hex="$(dd if="$1" bs=1 skip="$(($2 - 1))" count=1 2> /dev/null | od -An -tx1 | tr -d '[:space:]')"
  if [ -n "${hex}" ]; then printf '%s' "${hex}"; else printf 'EOF'; fi
}

# byte_diff <label> <bash-capture> <pwsh-capture> — one line naming the FIRST
# differing byte and both sides' lengths.
#
# `diff -u` is what a reader wants when the two sides differ in CONTENT, and it
# is useless when they differ in a byte that does not render: the divergence
# that started this — a CRLF where the twin wrote LF — printed fifty-five
# identical-looking lines on both sides of the diff and named nothing. The hex
# here is the part that cannot be misread.
byte_diff() {
  local label="$1" a="$2" b="$3" loc off
  loc="$(cmp "${a}" "${b}" 2>&1 || true)"
  # Both spellings on purpose: GNU cmp reports "byte 9", BSD cmp "char 9". A
  # pattern for one of them alone reads as "no offset found" on the other host,
  # which is how a report meant to survive a cross-platform diff would have
  # gone quiet on exactly half the platforms it exists for.
  off="$(printf '%s' "${loc}" | sed -E -n 's/.*(byte|char) ([0-9]+).*/\2/p')"
  # cmp names both captures by absolute path; the reader wants the port.
  loc="${loc//${a}/bash}"
  loc="${loc//${b}/pwsh}"
  if [ -n "${off}" ]; then
    printf '  %s: first difference at byte %s — bash=%s pwsh=%s (sizes %s / %s)\n' \
      "${label}" "${off}" "$(_byte_at "${a}" "${off}")" "$(_byte_at "${b}" "${off}")" \
      "$(_size "${a}")" "$(_size "${b}")"
  else
    printf '  %s: %s (sizes %s / %s)\n' \
      "${label}" "${loc}" "$(_size "${a}")" "$(_size "${b}")"
  fi
}
# stderr_note <bash-capture> <pwsh-capture> — the ports' own explanations, for a
# scenario that has ALREADY failed.
#
# stderr is deliberately absent from the artifact comparison below: the two ports
# owe each other byte-identical stdout, exit code, call sequence and written
# tree, never identically phrased diagnostics. But the harness captures it, and
# on a failing scenario it is the one file that says WHY — and it was being
# discarded on every failing run. Measured 2026-08-20 (issue #46): 89 of 231
# scenarios diverge on windows-latest, 76 of them reporting only "bash wrote 1
# byte of stdout", and not one of them said what bash had complained about.
#
# Bounded on purpose. A workflow annotation is truncated as a whole, so an
# unbounded tail here is paid for by the scenarios reported after it. Newlines
# are folded to `|` for the same reason — one scenario, one line per port.
stderr_note() {
  local a="$1" b="$2" port f
  for port in bash pwsh; do
    if [ "${port}" = bash ]; then f="${a}"; else f="${b}"; fi
    [ -s "${f}" ] || continue
    # The fixture token is masked even though it is a literal in a public
    # corpus: this text lands in an annotation, and a diagnostic channel that
    # learns to print secrets is a habit, not an accident (NFR-3).
    printf '  %s stderr: %s\n' "${port}" \
      "$(head -c 400 "${f}" | tr '\n' '|' | sed -e 's/RAWSECRET[A-Za-z0-9]*/<redacted>/g' -e 's/[[:cntrl:]]/./g')"
  done
}
export -f _size _byte_at byte_diff stderr_note

# _normalize_state_base_url <workdir> — masks the one field a recorded
# run-state document (021, contracts/run-state.md) can never agree on across
# ports: `base_url` is the mock's OS-assigned port for the PowerShell port's
# real socket server, and the curl shim's fixed sentinel for the Bash port
# (Decision 2, contracts/mock-driver.md) — run-scenario.sh's own comment on
# `runs[i].before.jq` already documents this as "can never be pre-baked to
# match". Every other field (the input hashes, email, on_drift, schema,
# extension_version) is a genuine cross-port claim and stays fully compared;
# only this one is masked, on BOTH sides identically, immediately before the
# written-files diff.
_normalize_state_base_url() {
  local dir="$1" f masked
  [ -d "${dir}" ] || return 0
  while IFS= read -r -d '' f; do
    # Only rewrite a document jq could actually parse. Emptying one it could
    # not would corrupt BOTH captures identically, and a symmetric corruption
    # diffs CLEAN — it would mask the very divergence this corpus exists to
    # catch, and us021-state-corrupt.json produces such a document on purpose.
    if masked="$(jq -cS '.base_url = "MOCK_BASE_URL"' "${f}" 2> /dev/null)" && [ -n "${masked}" ]; then
      printf '%s' "${masked}" > "${f}"
    fi
  done < <(find "${dir}" -path '*/jira/state/*.json' -print0 2> /dev/null)
}
export -f _normalize_state_base_url

# _normalize_config_yaml_base_url <workdir> — masks the SAME field
# _normalize_state_base_url masks, in the OTHER place it lands: a tracked
# config.yml the @MOCK_BASE_URL@ substitution (research.md §R6/§R10, T001)
# wrote into the copied fixture BEFORE either port ever ran. The Bash port's
# curl-shim backend and the PowerShell port's real socket server resolve the
# sentinel to two DIFFERENT literal `http://127.0.0.1:<port>` strings
# (contracts/mock-driver.md Decision 2), so a scenario whose config.yml
# declares `base_url` diverges on this one field even though the run itself
# is byte-identical. `sed`, not `jq`: config.yml is YAML, not JSON.
_normalize_config_yaml_base_url() {
  local dir="$1" f
  [ -d "${dir}" ] || return 0
  while IFS= read -r -d '' f; do
    sed -i.bak -E 's#http://127\.0\.0\.1:[0-9]+#http://127.0.0.1:MOCK_PORT#g' "${f}" 2> /dev/null
    rm -f "${f}.bak"
  done < <(find "${dir}" -path '*/jira/config.yml' -print0 2> /dev/null)
}
export -f _normalize_config_yaml_base_url

# _normalize_workdir_path <outdir> — masks EACH PORT'S OWN randomly-named
# workdir (031, C1.1/C1.4) wherever it appears literally in stdout, stderr, or
# calls.log. run-scenario.sh gives every port invocation its OWN `mktemp -d`,
# so a value that legitimately reports an absolute path BENEATH it — the
# resolved configuration directory a `no-repository`/`config-unloadable`
# report names, or the `seed_material` file feature.sh writes under it — can
# never agree across two independent runs even when the run itself is
# byte-identical. <outdir>/workdir.path is run-scenario.sh's own record of
# the string(s) being masked (031, T027) — ONE line per candidate spelling,
# because on windows-latest the SAME directory can reach a port's own output
# under up to three different byte spellings (the raw MSYS form, the
# `pwd -P`-resolved form, and the native `cygpath -m` form — see
# run-scenario.sh's comment above where it writes this file). Mask every
# candidate; on macOS/Linux, where they all coincide, the extra passes are
# harmless no-ops. Same technique as _normalize_state_base_url, applied to
# the three places an absolute path can reach: stdout, calls.log, and stderr
# — 031's own diagnostics (FR-009's "path consulted", the --verbose report)
# land on stderr, and code review (PR #55) found it excluded here while the
# comparison loop below folded it in, an inconsistency that let a
# path-bearing divergence on stderr pass silently.
_normalize_workdir_path() {
  local outdir="$1" wd f
  if [ -f "${outdir}/workdir.path" ]; then
    while IFS= read -r wd; do
      [ -n "${wd}" ] || continue
      for f in "${outdir}/stdout" "${outdir}/calls.log" "${outdir}/stderr"; do
        [ -f "${f}" ] || continue
        sed -i.bak "s#${wd}#WORKDIR#g" "${f}" 2> /dev/null
        rm -f "${f}.bak"
      done
    done < "${outdir}/workdir.path"
  fi
  # Fallback pass, unconditional: even the three recorded candidates above
  # missed a windows-latest divergence (us29-feature-reuse-yes-auto-accept's
  # seed_material field, code review PR #55) — a natively-spawned pwsh.exe's
  # own GetFullPath/Get-Location resolved the SAME mktemp -d directory to a
  # FOURTH byte spelling none of raw/pwd-P/cygpath-m produced (short-name vs
  # long-name, or a reparse point cygpath's string mapping never queries).
  # Every conformance scenario resolves its config dir by discovering
  # `.specify/jira` from the fixture (none sets JIRA_CONFIG_DIR explicitly —
  # `grep -l JIRA_CONFIG_DIR tests/conformance/scenarios/*.json` is empty),
  # so the STRUCTURAL pattern is a safer anchor than any enumerated spelling:
  # collapse whatever path-like prefix immediately precedes `.specify/jira`
  # (either separator, either side) down to `WORKDIR/.specify/jira`,
  # regardless of which of the port's own byte spellings produced it.
  for f in "${outdir}/stdout" "${outdir}/calls.log" "${outdir}/stderr"; do
    [ -f "${f}" ] || continue
    sed -i.bak -E 's#[^[:space:]"]*[/\\]\.specify[/\\]jira#WORKDIR/.specify/jira#g' "${f}" 2> /dev/null
    rm -f "${f}.bak"
  done
  # us031-no-project (FR-008, the no-repository state) has no .specify/jira
  # suffix to anchor on at all — the reported path IS the bare workdir, and
  # the fourth candidate above still didn't cover it on windows-latest.
  # Feature.psm1/feature.sh both spell this ONE message identically
  # ("... no ancestor of <path> contains .specify/ ..."), so masking the
  # exact template is a safe, narrow anchor of last resort — narrower than
  # the .specify/jira structural pass above, but the message text itself
  # (not a path guess) is what's stable here.
  for f in "${outdir}/stdout" "${outdir}/calls.log" "${outdir}/stderr"; do
    [ -f "${f}" ] || continue
    sed -i.bak -E 's#no ancestor of [^[:space:]"]* contains#no ancestor of WORKDIR contains#g' "${f}" 2> /dev/null
    rm -f "${f}.bak"
  done
}
export -f _normalize_workdir_path

# Scenarios are independent (each gets its own mktemp workdir and an
# OS-assigned ephemeral mock port, per run-scenario.sh), so they run
# concurrently across cores instead of one after another. xargs -P exits 123
# if any invocation of run_scenario fails, which this script turns into its
# own failure below — no manual result-collection needed.
run_scenario() {
  local scenario="$1" name out_bash out_ps failed=0 detail="" line f rel
  local off_bash off_ps expect got_bf port on_dir off_dir on_lines off_lines
  name="$(basename "${scenario}" .json)"
  out_bash="$(mktemp -d)"
  out_ps="$(mktemp -d)"
  "${harness}" "${scenario}" bash "${out_bash}"
  "${harness}" "${scenario}" powershell "${out_ps}"
  _normalize_workdir_path "${out_bash}"
  _normalize_workdir_path "${out_ps}"
  # The observable contract: stdout, exit code, Jira call sequence, and the
  # written repository tree must be byte-identical across ports. stderr is
  # NOT in this list — measured (code review, PR #55): turning it on for the
  # whole corpus surfaces 9 PRE-EXISTING, 031-unrelated divergences (e.g. a
  # credential-resolution warning bash emits that pwsh does not, for the
  # same scenario, with byte-identical stdout/exit/calls.log either side of
  # it) that are a separate investigation, not a regression this loop should
  # gate on. What FR-009 actually requires — a us031-* scenario's own
  # report, verbatim, on both ports — is asserted narrowly below instead.
  for artifact in stdout exit calls.log; do
    if ! diff -u "${out_bash}/${artifact}" "${out_ps}/${artifact}"; then
      echo "conformance divergence in ${name} (${artifact})"
      detail="${detail}$(byte_diff "${artifact}" "${out_bash}/${artifact}" "${out_ps}/${artifact}")"$'\n'
      # Diagnostic of last resort (code review, PR #55): if the workdir
      # masking above missed this port's own byte spelling AGAIN, the next
      # thing to know is what candidates run-scenario.sh actually recorded
      # for it — never guess a fifth one blind.
      if [ -f "${out_ps}/workdir.path" ]; then
        detail="${detail}  pwsh workdir.path candidates: $(tr '\n' '|' < "${out_ps}/workdir.path")"$'\n'
      fi
      failed=1
    fi
  done
  # 031, FR-009/C5.1 (code review, PR #55): THIS feature's own reports are a
  # documented byte-identical obligation (tasks.md T015 — "the report is
  # byte-identical across ports") and they land on stderr, so a corpus that
  # excludes stderr everywhere could never have caught a divergence in the
  # one thing 031 actually promises. Scoped to us031-* rather than every
  # scenario — see the comment above for why the wider net is unsafe today.
  if [[ "${name}" == us031-* ]] && ! diff -u "${out_bash}/stderr" "${out_ps}/stderr"; then
    echo "conformance divergence in ${name} (stderr)"
    detail="${detail}$(byte_diff "stderr" "${out_bash}/stderr" "${out_ps}/stderr")"$'\n'
    failed=1
  fi
  _normalize_state_base_url "${out_bash}/workdir"
  _normalize_state_base_url "${out_ps}/workdir"
  _normalize_config_yaml_base_url "${out_bash}/workdir"
  _normalize_config_yaml_base_url "${out_ps}/workdir"
  if ! diff -ru "${out_bash}/workdir" "${out_ps}/workdir"; then
    echo "conformance divergence in ${name} (written files)"
    while IFS= read -r line; do
      case "${line}" in
        "Files "*" and "*" differ")
          f="${line#Files }"
          f="${f%% and *}"
          rel="${f#"${out_bash}/workdir/"}"
          detail="${detail}$(byte_diff "workdir/${rel}" "${f}" "${out_ps}/workdir/${rel}")"$'\n'
          ;;
        *) detail="${detail}  ${line}"$'\n' ;;
      esac
    done < <(diff -rq "${out_bash}/workdir" "${out_ps}/workdir" 2>&1 || true)
    failed=1
  fi

  # Only for a scenario that has already failed above: never a comparison, and
  # never a reason to fail on its own.
  if [ "${failed}" -ne 0 ]; then
    detail="${detail}$(stderr_note "${out_bash}/stderr" "${out_ps}/stderr")"$'\n'
  fi

  # 021 US4, contracts/recognition-prefetch.md §6 (T049-T051): the SECOND,
  # orthogonal axis this corpus proves for a `us021-prefetch-*` scenario —
  # not bash-vs-powershell (above), but the SAME port run twice, prefetch on
  # (the `out_*` captures already taken above) and prefetch off
  # (`_RECOGNITION_NO_PREFETCH=1`, threaded through the one caller-side
  # channel run-scenario.sh recognises, SPEC_KIT_JIRA_HARNESS_ENV). The
  # governing rule is byte-identical stdout/stderr/exit/tree; only calls.log
  # may differ, and only by shrinking — every line the prefetch run kept
  # beyond its own bulkfetch request(s) must also appear in the unprefetched
  # run's own calls.log (a fall-through read the prefetch left unresolved).
  if [[ "${name}" == us021-prefetch-* ]]; then
    off_bash="$(mktemp -d)"
    off_ps="$(mktemp -d)"
    SPEC_KIT_JIRA_HARNESS_ENV="_RECOGNITION_NO_PREFETCH=1" "${harness}" "${scenario}" bash "${off_bash}"
    SPEC_KIT_JIRA_HARNESS_ENV="_RECOGNITION_NO_PREFETCH=1" "${harness}" "${scenario}" powershell "${off_ps}"
    _normalize_workdir_path "${off_bash}"
    _normalize_workdir_path "${off_ps}"
    for port in bash powershell; do
      if [ "${port}" = bash ]; then on_dir="${out_bash}"; off_dir="${off_bash}"; else on_dir="${out_ps}"; off_dir="${off_ps}"; fi
      for artifact in stdout stderr exit; do
        if ! diff -u "${on_dir}/${artifact}" "${off_dir}/${artifact}"; then
          echo "prefetch differential divergence in ${name} (${port}, ${artifact}, prefetch on vs off)"
          detail="${detail}  ${port}: ${artifact} differs between prefetch on and off"$'\n'
          failed=1
        fi
      done
      _normalize_state_base_url "${on_dir}/workdir"
      _normalize_state_base_url "${off_dir}/workdir"
      _normalize_config_yaml_base_url "${on_dir}/workdir"
      _normalize_config_yaml_base_url "${off_dir}/workdir"
      if ! diff -rq "${on_dir}/workdir" "${off_dir}/workdir" > /dev/null 2>&1; then
        echo "prefetch differential divergence in ${name} (${port}, written files differ prefetch on vs off)"
        detail="${detail}  ${port}: written files differ between prefetch on and off"$'\n'
        failed=1
      fi
      on_lines="$(wc -l < "${on_dir}/calls.log" | tr -d '[:space:]')"
      off_lines="$(wc -l < "${off_dir}/calls.log" | tr -d '[:space:]')"
      if [ "${on_lines}" -gt "${off_lines}" ]; then
        echo "prefetch differential divergence in ${name} (${port}, calls.log grew: ${on_lines} lines with the prefetch, ${off_lines} without)"
        detail="${detail}  ${port}: calls.log has ${on_lines} lines with the prefetch vs ${off_lines} without — must never be more"$'\n'
        failed=1
      fi
      while IFS= read -r line; do
        [ -z "${line}" ] && continue
        case "${line}" in
          "POST "*"/issue/bulkfetch") continue ;;
        esac
        if ! grep -qxF "${line}" "${off_dir}/calls.log"; then
          echo "prefetch differential divergence in ${name} (${port}, calls.log line is neither the prefetch nor a fall-through read: ${line})"
          detail="${detail}  ${port}: unexplained calls.log line: ${line}"$'\n'
          failed=1
        fi
      done < "${on_dir}/calls.log"
    done
    # Optional scenario field `read_requests` (T051): the exact count of
    # read-phase requests — bulkfetch chunks PLUS the individual per-key GET
    # fallbacks a deleted/forbidden key still costs — the prefetch-on bash
    # capture's calls.log must carry. The counting cases (chunking at 100,
    # a fall-through, zero keys).
    expect="$(jq -r '.read_requests // empty' "${scenario}")"
    if [ -n "${expect}" ]; then
      local bf_count get_count
      bf_count="$(grep -c '^POST .*/issue/bulkfetch$' "${out_bash}/calls.log" || true)"
      get_count="$(grep -cE '^GET [^ ]+/issue/[^/?]+\?' "${out_bash}/calls.log" || true)"
      got_bf="$((bf_count + get_count))"
      if [ "${got_bf}" != "${expect}" ]; then
        echo "prefetch differential divergence in ${name} (expected ${expect} read request(s), saw ${got_bf})"
        detail="${detail}  read request count ${got_bf} != expected ${expect}"$'\n'
        failed=1
      fi
    fi
    rm -rf "${off_bash}" "${off_ps}"
  fi

  # 023, Phase 3, US2, T030, contract lifecycle-event.md §6: the SAME
  # scenario reconciled a second time under a DIFFERENT declared event
  # (SPEC_KIT_JIRA_HOOK_EVENT, threaded through SPEC_KIT_JIRA_HARNESS_ENV —
  # the one caller-side channel, same mechanism the prefetch differential
  # above uses). The captures already taken above are the scenario's own
  # `env` event (after_specify); this second pair is after_plan. Governing
  # rule: bash and PowerShell agree on EACH event's own resolved step
  # (byte-identical stdout/exit/calls.log per port pair), and the two
  # events resolve to DIFFERENT outcomes from one another — proving the
  # step actually came from the event, not a shared default.
  if [[ "${name}" == us023-event-selects-step ]]; then
    local alt_bash alt_ps
    alt_bash="$(mktemp -d)"
    alt_ps="$(mktemp -d)"
    SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_HOOK_EVENT=after_plan" "${harness}" "${scenario}" bash "${alt_bash}"
    SPEC_KIT_JIRA_HARNESS_ENV="SPEC_KIT_JIRA_HOOK_EVENT=after_plan" "${harness}" "${scenario}" powershell "${alt_ps}"
    _normalize_workdir_path "${alt_bash}"
    _normalize_workdir_path "${alt_ps}"
    for artifact in stdout exit calls.log; do
      if ! diff -u "${alt_bash}/${artifact}" "${alt_ps}/${artifact}"; then
        echo "conformance divergence in ${name} (after_plan variant, ${artifact})"
        detail="${detail}$(byte_diff "after_plan/${artifact}" "${alt_bash}/${artifact}" "${alt_ps}/${artifact}")"$'\n'
        failed=1
      fi
    done
    _normalize_state_base_url "${alt_bash}/workdir"
    _normalize_state_base_url "${alt_ps}/workdir"
    _normalize_config_yaml_base_url "${alt_bash}/workdir"
    _normalize_config_yaml_base_url "${alt_ps}/workdir"
    if ! diff -rq "${alt_bash}/workdir" "${alt_ps}/workdir" > /dev/null 2>&1; then
      echo "conformance divergence in ${name} (after_plan variant, written files)"
      detail="${detail}  after_plan variant: written files differ between ports"$'\n'
      failed=1
    fi
    if diff -q "${out_bash}/calls.log" "${alt_bash}/calls.log" > /dev/null 2>&1; then
      echo "event-selects-step divergence in ${name} (after_specify and after_plan produced the SAME call sequence — the event never actually selected a distinct step)"
      detail="${detail}  after_specify and after_plan produced identical calls.log; the two events did not resolve distinct steps"$'\n'
      failed=1
    fi
    rm -rf "${alt_bash}" "${alt_ps}"
  fi

  if [ "${failed}" -ne 0 ]; then
    { printf '%s\n' "${name}"; printf '%s' "${detail}"; } > "${REPORT_DIR}/${name}"
  fi
  return "${failed}"
}
export -f run_scenario
export harness

status=0
printf '%s\n' "${scenarios[@]}" \
  | xargs -P "$(core_count)" -I{} bash -c 'run_scenario "$@"' _ {} || status=$?

# One annotation carrying the whole report. A workflow command is a single
# line, so the newlines are percent-encoded (`%` first, or the encoding would
# eat its own escapes); GitHub renders them back.
reports=("${REPORT_DIR}"/*)
if [ ${#reports[@]} -gt 0 ]; then
  summary="$(cat "${reports[@]}")"
  printf '\n===== byte-level divergence report (%s scenarios) =====\n%s\n' \
    "${#reports[@]}" "${summary}"
  # The annotation stays: it is the channel a reader without repository admin
  # rights can see. But GitHub truncates it AS A WHOLE, so a corpus with many
  # divergences loses its tail — measured 2026-08-20, run 32392779765, where
  # adding each port's stderr cut the scenarios that fitted from 89 to 34. The
  # file below is the same report with nothing dropped; the workflow uploads it
  # as an artifact so depth and breadth stop competing for one budget.
  if [ -n "${SPEC_KIT_JIRA_CONFORMANCE_REPORT_DIR:-}" ]; then
    mkdir -p "${SPEC_KIT_JIRA_CONFORMANCE_REPORT_DIR}"
    # Named per shard: four shards write into one uploaded directory, and an
    # unsuffixed name would have them overwrite each other's findings.
    printf '%s\n' "${summary}" \
      > "${SPEC_KIT_JIRA_CONFORMANCE_REPORT_DIR}/divergences-shard-${SPEC_KIT_JIRA_SHARD_INDEX:-all}.txt"
  fi
  printf '::error title=Conformance divergence (%s scenarios)::%s\n' \
    "${#reports[@]}" \
    "$(printf '%s' "${summary}" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN { ORS = "" } { print $0 "%0A" }')"
fi

exit "${status}"
