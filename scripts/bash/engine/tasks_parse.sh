#!/usr/bin/env bash
# engine/tasks_parse.sh — Neutral tasks.md reader (Phase 2, T019/T022/T024a;
# contracts/task-tier.md §2; data-model.md §2).
#
# Turns tasks.md into neutral task content only: no Jira identifier, no issue
# type, no project key ever crosses this layer (FR-005) — the boundary grep
# enforces it. The sink alone knows what a sub-task is.
#
# All functions read tasks.md on stdin and emit canonical JSON. The
# PowerShell port (TasksParse.psm1) is byte-identical.

[[ -n ${_JIRA_ENGINE_TASKS_PARSE:-} ]] && return 0
_JIRA_ENGINE_TASKS_PARSE=1

_tp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_tp_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_tp_dir}/task_marker.sh" # the durable identifier's grammar and anchor scan
# shellcheck source=/dev/null
source "${_tp_dir}/markdown.sh" # a task's own text is author prose (016, FR-017)

# A task line: checkbox, task reference, then the rest of the line.
_TP_TASK_LINE_CAPTURE_RE='^-[[:space:]]+\[([ xX])\][[:space:]]+(T[0-9]+[A-Za-z]?)[[:space:]]*(.*)$'
_TP_PHASE_HEADING_RE='^##[[:space:]]+(Phase.*)$'
_TP_HEADING_RE='^#{1,6}[[:space:]]'
_TP_USER_STORY_ORDINAL_RE='User[[:space:]]Story[[:space:]]+([0-9]+)'
_TP_MARKER_LINE_RE='^[[:space:]]*<!--[[:space:]]+speckit-jira[[:space:]]+.*-->[[:space:]]*$'

# _tp_trim <string> — strip leading and trailing whitespace.
_tp_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# _tp_local_id_for_marker <marker-info-json> — mirror of parse.sh's
# _parse_local_id_for_marker: the task's local_id derived from its marker.
_tp_local_id_for_marker() {
  local info="$1" state
  state="$(jq -r '.state' <<< "${info}")"
  case "${state}" in
    absent) printf '' ;;
    duplicate) story_marker_generate_id ;;
    *) jq -r '.id' <<< "${info}" ;;
  esac
}

# _tp_extract_files <text> — backtick-quoted spans that look like a file
# path: no whitespace, contains a "/". A bare HTTP verb + URL span
# ("`GET /rest/api/...`") is naturally excluded because it contains a space.
_tp_extract_files() {
  local text="$1" rest="${1}" span acc="[]"
  while [[ "${rest}" == *'`'*'`'* ]]; do
    rest="${rest#*\`}"
    span="${rest%%\`*}"
    rest="${rest#*\`}"
    if [[ "${span}" != *' '* && "${span}" == */* ]]; then
      acc="$(jq -c --arg v "${span}" '. + [$v]' <<< "${acc}")"
    fi
  done
  printf '%s' "${acc}"
}

# _tp_extract_depends_on <text> — the trailing "(depends on T012, T013)"
# clause, as a JSON array of task references.
_tp_extract_depends_on() {
  local text="$1"
  if [[ "${text}" =~ \(depends[[:space:]]on[[:space:]]([^\)]+)\) ]]; then
    local list="${BASH_REMATCH[1]}" acc="[]" tok
    IFS=',' read -ra toks <<< "${list}"
    for tok in "${toks[@]}"; do
      tok="$(_tp_trim "${tok}")"
      [[ "${tok}" =~ ^T[0-9]+[A-Za-z]?$ ]] && acc="$(jq -c --arg v "${tok}" '. + [$v]' <<< "${acc}")"
    done
    printf '%s' "${acc}"
  else
    printf '[]'
  fi
}

# _tp_strip_tags <text> — remove a leading `[P]` and/or `[US<N>]` token from
# the front of a task's own line text (in either order), then trim.
_tp_strip_tags() {
  local s="$1"
  local changed=1
  while ((changed)); do
    changed=0
    local t; t="$(_tp_trim "${s}")"
    if [[ "${t}" =~ ^\[P\][[:space:]]*(.*)$ ]]; then
      s="${BASH_REMATCH[1]}"; changed=1
    elif [[ "${t}" =~ ^\[US[0-9]+\][[:space:]]*(.*)$ ]]; then
      s="${BASH_REMATCH[1]}"; changed=1
    else
      s="${t}"
    fi
  done
  _tp_trim "${s}"
}

# _tp_strip_depends_on <text> — remove a trailing "(depends on ...)" clause.
_tp_strip_depends_on() {
  local s="$1"
  if [[ "${s}" =~ ^(.*)\(depends[[:space:]]on[[:space:]][^\)]+\)[[:space:]]*$ ]]; then
    _tp_trim "${BASH_REMATCH[1]}"
  else
    printf '%s' "${s}"
  fi
}

# tasks_parse_document — read tasks.md on stdin; emit
# {"tasks":[...], "skipped":[{"task_ref":"..","reason":".."}, ...]}
# (data-model.md §2). Empty when the file holds no recognisable task line
# (Edge Cases). A task whose title is empty once markup is removed produces
# no entry and is reported in "skipped" (contract §2).
tasks_parse_document() {
  local doc; doc="$(cat)"
  [[ -z "${doc}" ]] && { printf '{"skipped":[],"tasks":[]}'; return 0; }

  local total_lines; total_lines="$(marker_splice_line_count "${doc}")"

  # Pass 1: collect task anchors with their checkbox/ref/rest-of-line and the
  # enclosing phase heading text + story ordinal, walking the whole document
  # once so phase context is correct at each anchor.
  local -a anchor_lines=() anchor_done=() anchor_ref=() anchor_rest=() anchor_phase=() anchor_phase_ordinal=()
  local lineno=0 line lc phase_text="" phase_ordinal=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    lc="${line%$'\r'}"
    if [[ "${lc}" =~ ${_TP_PHASE_HEADING_RE} ]]; then
      phase_text="$(_tp_trim "${BASH_REMATCH[1]}")"
      if [[ "${phase_text}" =~ ${_TP_USER_STORY_ORDINAL_RE} ]]; then
        phase_ordinal="${BASH_REMATCH[1]}"
      else
        phase_ordinal=""
      fi
      continue
    fi
    if [[ "${lc}" =~ ${_TP_TASK_LINE_CAPTURE_RE} ]]; then
      anchor_lines+=("${lineno}")
      anchor_done+=("${BASH_REMATCH[1]}")
      anchor_ref+=("${BASH_REMATCH[2]}")
      anchor_rest+=("${BASH_REMATCH[3]}")
      anchor_phase+=("${phase_text}")
      anchor_phase_ordinal+=("${phase_ordinal}")
    fi
  done <<< "${doc}"

  local n=${#anchor_lines[@]}
  if ((n == 0)); then
    printf '{"skipped":[],"tasks":[]}'
    return 0
  fi

  local tasks="[]" skipped="[]" i
  for ((i = 0; i < n; i++)); do
    local a="${anchor_lines[i]}" span_end
    if ((i + 1 < n)); then span_end=$((anchor_lines[i + 1] - 1)); else span_end="${total_lines}"; fi

    local minfo; minfo="$(task_marker_section_info "${doc}" "$((a + 1))" "${span_end}")"
    local local_id; local_id="$(_tp_local_id_for_marker "${minfo}")"

    # Collect continuation lines: contiguous non-blank, non-marker,
    # non-heading lines immediately following the task line (and its
    # marker, if any).
    local -a cont=()
    local j started=0
    for ((j = a + 1; j <= span_end; j++)); do
      local cl; cl="$(sed -n "${j}p" <<< "${doc}")"
      cl="${cl%$'\r'}"
      if [[ "${cl}" =~ ${_TP_MARKER_LINE_RE} ]]; then continue; fi
      local ct; ct="$(_tp_trim "${cl}")"
      if [[ -z "${ct}" ]]; then
        ((started)) && break
        continue
      fi
      if [[ "${cl}" =~ ${_TP_HEADING_RE} ]]; then break; fi
      cont+=("${ct}")
      started=1
    done

    local rest="${anchor_rest[i]}"
    local full_text="${rest}"
    local c
    for c in "${cont[@]:-}"; do
      [[ -n "${c}" ]] && full_text="${full_text} ${c}"
    done

    local parallel="false"
    [[ "${rest}" =~ \[P\] ]] && parallel="true"

    local tag_ordinal="" attribution_source="none"
    if [[ "${rest}" =~ \[US([0-9]+)\] ]]; then
      tag_ordinal="${BASH_REMATCH[1]}"
      attribution_source="tag"
    elif [[ -n "${anchor_phase_ordinal[i]}" ]]; then
      tag_ordinal="${anchor_phase_ordinal[i]}"
      attribution_source="heading"
    fi

    local files depends_on
    files="$(_tp_extract_files "${full_text}")"
    depends_on="$(_tp_extract_depends_on "${full_text}")"

    local title; title="$(_tp_strip_tags "${rest}")"
    title="$(_tp_strip_depends_on "${title}")"
    for c in "${cont[@]:-}"; do
      [[ -n "${c}" ]] || continue
      local cc; cc="$(_tp_strip_depends_on "${c}")"
      [[ -n "${cc}" ]] && title="${title} ${cc}"
    done
    title="$(_tp_trim "${title}")"

    local task_ref="${anchor_ref[i]}"
    if [[ -z "${title}" ]]; then
      skipped="$(jq -c --arg r "${task_ref}" --arg reason "empty title" '. + [{task_ref:$r, reason:$reason}]' <<< "${skipped}")"
      continue
    fi

    local done_bool="false"
    [[ "${anchor_done[i]}" == "x" || "${anchor_done[i]}" == "X" ]] && done_bool="true"

    # 016, FR-017: the task's own text is author prose and carries the same
    # markup spec prose does (backtick-quoted paths above all), so it is
    # tokenized into marked spans here rather than shipped as a raw string.
    # `title` itself stays verbatim — it becomes the Jira summary, a plain-text
    # field where no rich text is possible (data-model.md §3, FR-018).
    local desc_blocks
    desc_blocks="$(jq -cn --argjson s "$(markdown_tokenize_inline "${title}")" '[{type:"paragraph", spans:$s}]')"

    local ordinal_json="null"
    [[ -n "${tag_ordinal}" ]] && ordinal_json="${tag_ordinal}"

    local task
    task="$(jq -cn \
      --arg local_id "${local_id}" --arg task_ref "${task_ref}" --arg title "${title}" \
      --argjson desc "${desc_blocks}" --argjson ordinal "${ordinal_json}" --arg src "${attribution_source}" \
      --arg phase "${anchor_phase[i]}" --argjson parallel "${parallel}" --argjson files "${files}" \
      --argjson deps "${depends_on}" --argjson is_done "${done_bool}" --argjson marker "${minfo}" '
      {
        local_id: $local_id, task_ref: $task_ref, title: $title,
        description: {blocks: $desc},
        attribution: {story_ordinal: $ordinal, source: $src},
        phase: $phase, parallel: $parallel, files: $files, depends_on: $deps,
        done: $is_done, marker: $marker
      }')"
    tasks="$(jq -c --argjson t "${task}" '. + [$t]' <<< "${tasks}")"
  done

  jq -cn --argjson tasks "${tasks}" --argjson skipped "${skipped}" '{skipped:$skipped, tasks:$tasks}' | json_canonical
}
