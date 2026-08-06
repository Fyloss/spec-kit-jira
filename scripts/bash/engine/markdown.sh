#!/usr/bin/env bash
# engine/markdown.sh — Markdown subset -> neutral blocks + marked spans (016).
#
# Implements specs/016-jira-markdown-rendering/contracts/markdown-subset.md:
# Part B (block segmentation), Part C (inline tokenization), Part D (emission).
# NEUTRAL layer: zero Jira identifiers, never sources sink/ (Constitution VIII).
# The mark vocabulary is bold/italic/monospace/strikethrough/link — deliberately
# not ADF's strong/em/code/strike (research §1); the sink owns that map.
#
# Pure function from bytes to a neutral tree: this module never opens a file for
# writing (FR-000). Every jq call in this module is avoided by design — spans are
# accumulated with plain Bash string operations (research §3's "zero additional
# subprocess spawns" budget), and the single JSON serialisation happens once, in
# Bash string form, ready to be embedded by a caller's own jq/json_canonical pass.

[[ -n ${_JIRA_ENGINE_MARKDOWN:-} ]] && return 0
_JIRA_ENGINE_MARKDOWN=1

# _md_json_escape <text> — JSON-string-escape TEXT exactly as jq/json_canonical
# would: " \ and the named control escapes, \u00XX for other C0 controls, raw
# UTF-8 otherwise (non-ASCII is never \u-escaped). No subprocess.
_md_json_escape() {
  local s="$1" out="" c code i n
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    case "${c}" in
      '"') out+='\"' ;;
      $'\\') out+=$'\\\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        printf -v code '%d' "'${c}"
        if ((code < 32)); then
          printf -v c '\\u%04x' "${code}"
          out+="${c}"
        else
          out+="${c}"
        fi
        ;;
    esac
  done
  printf '%s' "${out}"
}

# _md_is_space_char <char> — A2: tabs count as whitespace wherever whitespace
# is tested.
_md_is_space_char() {
  case "$1" in
    ' ' | $'\t') return 0 ;;
    *) return 1 ;;
  esac
}

# _md_is_punct_char <char> — A3: ASCII punctuation.
_md_is_punct_char() {
  case "$1" in
    '!' | '"' | '#' | '$' | '%' | '&' | "'" | '(' | ')' | '*' | '+' | ',' | '-' | '.' | '/' | ':' | ';' | '<' | '=' | '>' | '?' | '@' | '[' | $'\\' | ']' | '^' | '_' | '`' | '{' | '|' | '}' | '~') return 0 ;;
    *) return 1 ;;
  esac
}

# _md_marks_add <marks-csv> <kind> — insert KIND into MARKS-CSV, keeping the
# canonical alphabetical order (D2) and idempotent on a kind already present.
_md_marks_add() {
  local csv="$1" kind="$2"
  case ",${csv}," in *",${kind},"*) printf '%s' "${csv}"; return 0 ;; esac
  local -a all=(bold italic link monospace strikethrough)
  local present="" k
  for k in "${all[@]}"; do
    if [[ "${k}" == "${kind}" ]] || [[ ",${csv}," == *",${k},"* ]]; then
      [[ -n "${present}" ]] && present+=","
      present+="${k}"
    fi
  done
  printf '%s' "${present}"
}

# _md_marks_csv_to_json <marks-csv> <href> — render a marks-csv (plus the one
# href active at this span, iff "link" is present) to a JSON array of mark
# objects (D2: always emitted, [] when empty).
_md_marks_csv_to_json() {
  local csv="$1" href="$2"
  [[ -z "${csv}" ]] && { printf '[]'; return 0; }
  local -a arr=()
  IFS=',' read -ra arr <<< "${csv}"
  local out="[" first=1 k
  for k in "${arr[@]}"; do
    [[ -z "${k}" ]] && continue
    ((!first)) && out+=","
    if [[ "${k}" == "link" ]]; then
      out+="{\"href\":\"$(_md_json_escape "${href}")\",\"kind\":\"link\"}"
    else
      out+="{\"kind\":\"${k}\"}"
    fi
    first=0
  done
  out+="]"
  printf '%s' "${out}"
}

# --- The scanner --------------------------------------------------------------
#
# _md_scan appends directly into the three parallel globals below (never
# forks a subprocess to do so); markdown_tokenize_inline resets them, scans,
# then applies D1/D3 and serialises once.
_MD_OUT_TEXT=()
_MD_OUT_MCSV=()
_MD_OUT_HREF=()

# _md_emit <text> <marks-csv> <href>
_md_emit() {
  _MD_OUT_TEXT+=("$1")
  _MD_OUT_MCSV+=("$2")
  _MD_OUT_HREF+=("$3")
}

# _md_find_unescaped <text> <start> <n> <char> — index of the first CHAR at or
# after START that is not preceded by a backslash escape, or empty on failure.
_md_find_unescaped() {
  local text="$1" start="$2" n="$3" ch="$4"
  local k=${start}
  while ((k < n)); do
    if [[ "${text:k:1}" == $'\\' ]] && ((k + 1 < n)); then
      k=$((k + 2))
      continue
    fi
    if [[ "${text:k:1}" == "${ch}" ]]; then
      printf '%d' "${k}"
      return 0
    fi
    k=$((k + 1))
  done
  return 1
}

# _md_try_delim <text> <i> <n> <delim> <kind> <marks-csv> <depth>
# C6/C7/C8, governed by C9. PURE MATCH ONLY — no emission, so a caller can
# flush its pending literal run before any content is scanned (emission order
# matters: the recursive scan below would otherwise emit before the caller's
# own pending run, reordering output). On success sets _MD_DELIM_CONTENT,
# _MD_DELIM_NEW_MARKS and _MD_NEXT_I and returns 0; on failure returns 1
# without side effects.
_md_try_delim() {
  local text="$1" i="$2" n="$3" delim="$4" kind="$5" marks="$6" depth="$7"
  local dlen=${#delim}
  ((depth >= 8)) && return 1 # C9.6 depth cap
  [[ "${text:i:dlen}" != "${delim}" ]] && return 1
  local open_end=$((i + dlen))
  ((open_end >= n)) && return 1 # C9.1: opener must be followed by something
  local first_inner="${text:open_end:1}"
  _md_is_space_char "${first_inner}" && return 1 # C9.1

  local underscore=0
  [[ "${delim}" == "_" || "${delim}" == "__" ]] && underscore=1
  if ((underscore)) && ((i > 0)); then # C9.3, opener side
    local before="${text:i-1:1}"
    if ! _md_is_space_char "${before}" && ! _md_is_punct_char "${before}"; then
      return 1
    fi
  fi

  local search=${open_end} close_start=-1 close_end=-1
  while ((search <= n - dlen)); do
    if [[ "${text:search:dlen}" == "${delim}" ]]; then
      local pc="${text:search-1:1}"
      if ! _md_is_space_char "${pc}"; then # C9.2
        local ok=1
        if ((underscore)); then # C9.3, closer side
          local after=$((search + dlen))
          if ((after < n)); then
            local ac="${text:after:1}"
            if ! _md_is_space_char "${ac}" && ! _md_is_punct_char "${ac}"; then
              ok=0
            fi
          fi
        fi
        if ((ok)); then
          close_start=${search}
          close_end=$((search + dlen))
          break
        fi
      fi
    fi
    search=$((search + 1))
  done
  ((close_start < 0)) && return 1 # C9.4

  _MD_DELIM_CONTENT="${text:open_end:close_start - open_end}"
  _MD_DELIM_NEW_MARKS="$(_md_marks_add "${marks}" "${kind}")"
  _MD_NEXT_I=${close_end}
  return 0
}

# _md_scan <text> <marks-csv> <href> <depth> <no_link> — Part C, tried in order
# C1..C10, C11 fallthrough. Appends spans into the globals via _md_emit.
_md_scan() {
  local text="$1" marks="$2" href="$3" depth="$4" no_link="$5"
  local n=${#text} i=0 run="" c

  while ((i < n)); do
    c="${text:i:1}"

    # C1 — backslash escape.
    if [[ "${c}" == $'\\' ]]; then
      if ((i + 1 < n)); then
        local nc="${text:i + 1:1}"
        if _md_is_punct_char "${nc}"; then
          run+="${nc}"
        else
          run+="\\${nc}"
        fi
        i=$((i + 2))
        continue
      else
        run+=$'\\'
        i=$((i + 1))
        continue
      fi
    fi

    # C2 — code span: a run of N backticks, closed by exactly N.
    if [[ "${c}" == '`' ]]; then
      local j=${i} run_len=0
      while ((j < n)) && [[ "${text:j:1}" == '`' ]]; do
        run_len=$((run_len + 1))
        j=$((j + 1))
      done
      local search=${j} close_start=-1 close_end=-1
      while ((search < n)); do
        if [[ "${text:search:1}" == '`' ]]; then
          local k=${search} klen=0
          while ((k < n)) && [[ "${text:k:1}" == '`' ]]; do
            klen=$((klen + 1))
            k=$((k + 1))
          done
          if ((klen == run_len)); then
            close_start=${search}
            close_end=${k}
            break
          fi
          search=${k}
        else
          search=$((search + 1))
        fi
      done
      if ((close_start >= 0)); then
        if [[ -n "${run}" ]]; then
          _md_emit "${run}" "${marks}" "${href}"
          run=""
        fi
        local content="${text:j:close_start - j}"
        local code_marks
        code_marks="$(_md_marks_add "${marks}" monospace)"
        _md_emit "${content}" "${code_marks}" "${href}"
        i=${close_end}
        continue
      else
        run+="${text:i:run_len}"
        i=$((i + run_len))
        continue
      fi
    fi

    # C3 — autolink: <http(s)://...>.
    if [[ "${c}" == '<' ]]; then
      local rest="${text:i}"
      if [[ "${rest}" =~ ^\<(https?://[^\>[:space:]]+)\> ]]; then
        local url="${BASH_REMATCH[1]}"
        if [[ -n "${run}" ]]; then
          _md_emit "${run}" "${marks}" "${href}"
          run=""
        fi
        local link_marks
        link_marks="$(_md_marks_add "${marks}" link)"
        _md_emit "${url}" "${link_marks}" "${url}"
        i=$((i + 2 + ${#url}))
        continue
      fi
    fi

    # C4 — image: ![alt](target).
    if [[ "${c}" == '!' ]] && ((i + 1 < n)) && [[ "${text:i + 1:1}" == '[' ]]; then
      local alt_close
      if alt_close="$(_md_find_unescaped "${text}" "$((i + 2))" "${n}" ']')" \
        && ((alt_close + 1 < n)) && [[ "${text:alt_close + 1:1}" == '(' ]]; then
        local tgt_close
        if tgt_close="$(_md_find_unescaped "${text}" "$((alt_close + 2))" "${n}" ')')"; then
          local alt="${text:i + 2:alt_close - (i + 2)}"
          local tgt="${text:alt_close + 2:tgt_close - (alt_close + 2)}"
          if [[ -n "${run}" ]]; then
            _md_emit "${run}" "${marks}" "${href}"
            run=""
          fi
          local show="${alt}"
          [[ -z "${show}" ]] && show="${tgt}"
          _md_emit "${show}" "${marks}" "${href}"
          i=$((tgt_close + 1))
          continue
        fi
      fi
    fi

    # C5 — link: [label](target).
    if [[ "${c}" == '[' ]] && ((no_link == 0)); then
      local lbl_close
      if lbl_close="$(_md_find_unescaped "${text}" "$((i + 1))" "${n}" ']')" \
        && ((lbl_close + 1 < n)) && [[ "${text:lbl_close + 1:1}" == '(' ]]; then
        local tgt_close
        if tgt_close="$(_md_find_unescaped "${text}" "$((lbl_close + 2))" "${n}" ')')"; then
          local label="${text:i + 1:lbl_close - (i + 1)}"
          local target="${text:lbl_close + 2:tgt_close - (lbl_close + 2)}"
          local trimmed="${target#"${target%%[![:space:]]*}"}"
          trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
          if [[ -n "${run}" ]]; then
            _md_emit "${run}" "${marks}" "${href}"
            run=""
          fi
          if [[ "${trimmed}" =~ ^https?://[^[:space:]]+$ ]]; then
            local save_text=("${_MD_OUT_TEXT[@]}") save_mcsv=("${_MD_OUT_MCSV[@]}") save_href=("${_MD_OUT_HREF[@]}")
            _MD_OUT_TEXT=()
            _MD_OUT_MCSV=()
            _MD_OUT_HREF=()
            _md_scan "${label}" "${marks}" "${href}" "${depth}" 1
            local -a lbl_text=("${_MD_OUT_TEXT[@]}") lbl_mcsv=("${_MD_OUT_MCSV[@]}")
            _MD_OUT_TEXT=("${save_text[@]}")
            _MD_OUT_MCSV=("${save_mcsv[@]}")
            _MD_OUT_HREF=("${save_href[@]}")
            local li lm
            for ((li = 0; li < ${#lbl_text[@]}; li++)); do
              lm="$(_md_marks_add "${lbl_mcsv[li]}" link)"
              _md_emit "${lbl_text[li]}" "${lm}" "${trimmed}"
            done
          else
            local degraded="${label} (${target})"
            _md_scan "${degraded}" "${marks}" "${href}" "${depth}" "${no_link}"
          fi
          i=$((tgt_close + 1))
          continue
        fi
      fi
    fi

    # C6 — strikethrough (~~), C7 — strong (** / __), C8 — emphasis (* / _).
    # _md_try_delim only matches (no side effects); flush the pending run
    # BEFORE the recursive scan below, or the recursion's emits (which happen
    # first) would land ahead of the caller's own pending text in the output.
    if [[ "${c}" == '~' ]] && [[ "${text:i:2}" == '~~' ]]; then
      if _md_try_delim "${text}" "${i}" "${n}" '~~' strikethrough "${marks}" "${depth}"; then
        if [[ -n "${run}" ]]; then
          _md_emit "${run}" "${marks}" "${href}"
          run=""
        fi
        # _MD_NEXT_I is a single global: capture it BEFORE the recursive scan
        # below, whose own nested delimiter matches would otherwise overwrite
        # it before this frame reads it back.
        local next_i=${_MD_NEXT_I}
        _md_scan "${_MD_DELIM_CONTENT}" "${_MD_DELIM_NEW_MARKS}" "${href}" "$((depth + 1))" "${no_link}"
        i=${next_i}
        continue
      fi
    fi
    # A position beginning a run of 2 of the same char only ever tries bold
    # there (never italic on top of the same run): once C7 has first refusal
    # over "**"/"__" and fails to close, both characters fall through to
    # literal one at a time — the second one then gets its own, independent
    # italic attempt on the NEXT iteration. Without this split, single-char
    # italic could re-split an already-rejected "**" into an opener+closer
    # pair with empty content, silently swallowing both asterisks (E10).
    if [[ "${c}" == '*' || "${c}" == '_' ]]; then
      local d2="${text:i:2}"
      if [[ "${d2}" == "**" || "${d2}" == "__" ]]; then
        if _md_try_delim "${text}" "${i}" "${n}" "${d2}" bold "${marks}" "${depth}"; then
          if [[ -n "${run}" ]]; then
            _md_emit "${run}" "${marks}" "${href}"
            run=""
          fi
          local next_i=${_MD_NEXT_I}
          _md_scan "${_MD_DELIM_CONTENT}" "${_MD_DELIM_NEW_MARKS}" "${href}" "$((depth + 1))" "${no_link}"
          i=${next_i}
          continue
        fi
      elif _md_try_delim "${text}" "${i}" "${n}" "${c}" italic "${marks}" "${depth}"; then
        if [[ -n "${run}" ]]; then
          _md_emit "${run}" "${marks}" "${href}"
          run=""
        fi
        local next_i=${_MD_NEXT_I}
        _md_scan "${_MD_DELIM_CONTENT}" "${_MD_DELIM_NEW_MARKS}" "${href}" "$((depth + 1))" "${no_link}"
        i=${next_i}
        continue
      fi
    fi

    # C10 — raw HTML tag: discarded; inner text scans normally.
    if [[ "${c}" == '<' ]]; then
      local nx="${text:i + 1:1}"
      if [[ "${nx}" == '/' ]] || [[ "${nx}" =~ [A-Za-z] ]]; then
        local gt_close
        if gt_close="$(_md_find_unescaped "${text}" "$((i + 1))" "${n}" '>')"; then
          i=$((gt_close + 1))
          continue
        fi
      fi
    fi

    # C11 — literal fallthrough.
    run+="${c}"
    i=$((i + 1))
  done
  if [[ -n "${run}" ]]; then
    _md_emit "${run}" "${marks}" "${href}"
  fi
}

# markdown_tokenize_inline <text> — Part C + Part D. Returns a JSON array of
# spans ({text, marks}), D1-merged and D3-trimmed.
markdown_tokenize_inline() {
  local text="$1"
  _MD_OUT_TEXT=()
  _MD_OUT_MCSV=()
  _MD_OUT_HREF=()
  _md_scan "${text}" "" "" 0 0

  local -a ft=() fcsv=() fhref=()
  local i n=${#_MD_OUT_TEXT[@]}
  for ((i = 0; i < n; i++)); do
    local t="${_MD_OUT_TEXT[i]}" m="${_MD_OUT_MCSV[i]}" h="${_MD_OUT_HREF[i]}"
    local last=$((${#ft[@]} - 1))
    if ((last >= 0)) && [[ "${fcsv[last]}" == "${m}" ]] && [[ "${fhref[last]}" == "${h}" ]]; then
      ft[last]="${ft[last]}${t}"
    else
      ft+=("${t}")
      fcsv+=("${m}")
      fhref+=("${h}")
    fi
  done

  local out="[" first=1
  for ((i = 0; i < ${#ft[@]}; i++)); do
    [[ -z "${ft[i]}" ]] && continue
    ((!first)) && out+=","
    out+="{\"text\":\"$(_md_json_escape "${ft[i]}")\",\"marks\":$(_md_marks_csv_to_json "${fcsv[i]}" "${fhref[i]}")}"
    first=0
  done
  out+="]"
  printf '%s' "${out}"
}

# markdown_inline_plain <text> — a single unmarked span wrapping the whole of
# TEXT verbatim (no tokenization). D3 still applies: empty text -> [].
markdown_inline_plain() {
  local text="$1"
  if [[ -z "${text}" ]]; then
    printf '[]'
    return 0
  fi
  printf '[{"text":"%s","marks":[]}]' "$(_md_json_escape "${text}")"
}

# --- Part B — block segmentation ----------------------------------------------

# _md_strip_cr <line> — A1: the tokenizer never sees a line terminator.
_md_strip_cr() {
  printf '%s' "${1%$'\r'}"
}

# _md_trim <s>
_md_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# markdown_parse_blocks <text> — Part B, B1-B8 (the B9 cap is the caller's —
# data-model.md §4). Returns a JSON array of block objects.
markdown_parse_blocks() {
  local doc="$1" line
  local out="[" first=1
  local mode="" # "", paragraph, bullet_list, ordered_list, code, blockquote-reentry
  local para=""
  local -a list_items=()
  local -a code_lines=()
  local in_fence=0

  _md_emit_block() {
    ((!first)) && out+=","
    out+="$1"
    first=0
  }

  _md_close_open_block() {
    if [[ "${mode}" == "paragraph" ]] && [[ -n "${para}" ]]; then
      _md_emit_block "{\"type\":\"paragraph\",\"spans\":$(markdown_tokenize_inline "${para}")}"
    elif [[ "${mode}" == "bullet_list" ]] && ((${#list_items[@]} > 0)); then
      local items="[" ifirst=1 it
      for it in "${list_items[@]}"; do
        ((!ifirst)) && items+=","
        items+="$(markdown_tokenize_inline "${it}")"
        ifirst=0
      done
      items+="]"
      _md_emit_block "{\"type\":\"bullet_list\",\"items\":${items}}"
    elif [[ "${mode}" == "ordered_list" ]] && ((${#list_items[@]} > 0)); then
      local items="[" ifirst=1 it
      for it in "${list_items[@]}"; do
        ((!ifirst)) && items+=","
        items+="$(markdown_tokenize_inline "${it}")"
        ifirst=0
      done
      items+="]"
      _md_emit_block "{\"type\":\"ordered_list\",\"items\":${items}}"
    fi
    mode=""
    para=""
    list_items=()
  }

  # A single pass, re-entrant for blockquote-stripped lines (B5).
  local -a lines=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lines+=("$(_md_strip_cr "${line}")")
  done <<< "${doc}"

  local li=0 nlines=${#lines[@]}
  while ((li < nlines)); do
    line="${lines[li]}"

    # B5 — blockquote: strip prefix, re-enter segmentation on the remainder.
    if [[ "${line}" =~ ^[[:space:]]*'>'[[:space:]]?(.*)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi

    # B1 — fenced code.
    if ((!in_fence)) && [[ "${line}" =~ ^[[:space:]]*(\`\`\`+) ]]; then
      _md_close_open_block
      in_fence=1
      mode="code"
      code_lines=()
      li=$((li + 1))
      continue
    fi
    if ((in_fence)); then
      if [[ "${line}" =~ ^[[:space:]]*(\`\`\`+) ]]; then
        local body
        body="$(printf '%s\n' "${code_lines[@]}")"
        [[ ${#code_lines[@]} -gt 0 ]] && body="${body%$'\n'}"
        [[ ${#code_lines[@]} -eq 0 ]] && body=""
        _md_emit_block "{\"type\":\"code\",\"text\":\"$(_md_json_escape "${body}")\"}"
        mode=""
        in_fence=0
        li=$((li + 1))
        continue
      fi
      code_lines+=("${line}")
      li=$((li + 1))
      continue
    fi

    local t
    t="$(_md_trim "${line}")"

    # B7 — blank line.
    if [[ -z "${t}" ]]; then
      _md_close_open_block
      li=$((li + 1))
      continue
    fi

    # B2 — ATX heading.
    if [[ "${t}" =~ ^(#{1,6})[[:space:]]+(.*)$ ]]; then
      _md_close_open_block
      local level=${#BASH_REMATCH[1]} htext="${BASH_REMATCH[2]}"
      htext="${htext%%*([[:space:]]#*(#))}"
      htext="$(_md_trim "${htext}")"
      _md_emit_block "{\"type\":\"heading\",\"level\":${level},\"spans\":$(markdown_tokenize_inline "${htext}")}"
      li=$((li + 1))
      continue
    fi

    # B3 — bullet item.
    if [[ "${t}" =~ ^[-*+][[:space:]]+(.*)$ ]]; then
      if [[ "${mode}" != "bullet_list" ]]; then
        _md_close_open_block
        mode="bullet_list"
      fi
      list_items+=("${BASH_REMATCH[1]}")
      li=$((li + 1))
      continue
    fi

    # B4 — ordered item.
    if [[ "${t}" =~ ^[0-9]{1,9}[.\)][[:space:]]+(.*)$ ]]; then
      if [[ "${mode}" != "ordered_list" ]]; then
        _md_close_open_block
        mode="ordered_list"
      fi
      list_items+=("${BASH_REMATCH[1]}")
      li=$((li + 1))
      continue
    fi

    # B6 — table row.
    if [[ "${t}" =~ ^\|.*\|[[:space:]]*$ || "${t}" =~ ^\|.* ]] && [[ "${t}" == \|*\| ]]; then
      _md_close_open_block
      # Split on unescaped '|'.
      local -a cells=() cur="" k=0 nT=${#t}
      while ((k < nT)); do
        local ch="${t:k:1}"
        if [[ "${ch}" == $'\\' ]] && ((k + 1 < nT)); then
          cur+="${t:k:2}"
          k=$((k + 2))
          continue
        fi
        if [[ "${ch}" == '|' ]]; then
          cells+=("${cur}")
          cur=""
          k=$((k + 1))
          continue
        fi
        cur+="${ch}"
        k=$((k + 1))
      done
      cells+=("${cur}")
      # Drop empty leading/trailing cells (from the outer pipes).
      local ncells=${#cells[@]}
      local -a trimmedcells=()
      local ci
      for ((ci = 0; ci < ncells; ci++)); do
        if ((ci == 0 || ci == ncells - 1)) && [[ -z "$(_md_trim "${cells[ci]}")" ]]; then
          continue
        fi
        trimmedcells+=("$(_md_trim "${cells[ci]}")")
      done
      # Delimiter row: cells contain only -, : and whitespace, at least one -.
      local is_delim=1 has_dash=0 tc
      for tc in "${trimmedcells[@]}"; do
        [[ "${tc}" =~ ^[-:[:space:]]+$ ]] || is_delim=0
        [[ "${tc}" == *-* ]] && has_dash=1
      done
      ((${#trimmedcells[@]} == 0)) && is_delim=0
      if ((is_delim && has_dash)); then
        li=$((li + 1))
        continue
      fi
      local joined="" jfirst=1
      for tc in "${trimmedcells[@]}"; do
        ((!jfirst)) && joined+=" — "
        joined+="${tc}"
        jfirst=0
      done
      _md_emit_block "{\"type\":\"paragraph\",\"spans\":$(markdown_tokenize_inline "${joined}")}"
      li=$((li + 1))
      continue
    fi

    # B8 — paragraph (fallthrough). A list closes at a non-matching line: it
    # already did above (mode reset by _md_close_open_block on other matches);
    # here we join into an open paragraph, or open one.
    if [[ "${mode}" == "bullet_list" || "${mode}" == "ordered_list" ]]; then
      _md_close_open_block
    fi
    mode="paragraph"
    if [[ -n "${para}" ]]; then para="${para} ${t}"; else para="${t}"; fi
    li=$((li + 1))
  done
  # Unclosed fence still emits its content (B1).
  if ((in_fence)); then
    local body
    body="$(printf '%s\n' "${code_lines[@]}")"
    [[ ${#code_lines[@]} -gt 0 ]] && body="${body%$'\n'}"
    [[ ${#code_lines[@]} -eq 0 ]] && body=""
    _md_emit_block "{\"type\":\"code\",\"text\":\"$(_md_json_escape "${body}")\"}"
  else
    _md_close_open_block
  fi
  out+="]"
  printf '%s' "${out}"
}
