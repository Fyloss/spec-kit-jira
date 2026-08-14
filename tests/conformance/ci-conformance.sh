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
export -f _size _byte_at byte_diff

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
  # The observable contract: stdout, exit code, Jira call sequence, and the
  # written repository tree must be byte-identical across ports.
  for artifact in stdout exit calls.log; do
    if ! diff -u "${out_bash}/${artifact}" "${out_ps}/${artifact}"; then
      echo "conformance divergence in ${name} (${artifact})"
      detail="${detail}$(byte_diff "${artifact}" "${out_bash}/${artifact}" "${out_ps}/${artifact}")"$'\n'
      failed=1
    fi
  done
  _normalize_state_base_url "${out_bash}/workdir"
  _normalize_state_base_url "${out_ps}/workdir"
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
    for artifact in stdout exit calls.log; do
      if ! diff -u "${alt_bash}/${artifact}" "${alt_ps}/${artifact}"; then
        echo "conformance divergence in ${name} (after_plan variant, ${artifact})"
        detail="${detail}$(byte_diff "after_plan/${artifact}" "${alt_bash}/${artifact}" "${alt_ps}/${artifact}")"$'\n'
        failed=1
      fi
    done
    _normalize_state_base_url "${alt_bash}/workdir"
    _normalize_state_base_url "${alt_ps}/workdir"
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
  printf '::error title=Conformance divergence (%s scenarios)::%s\n' \
    "${#reports[@]}" \
    "$(printf '%s' "${summary}" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN { ORS = "" } { print $0 "%0A" }')"
fi

exit "${status}"
