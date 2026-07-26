#!/usr/bin/env bash
# commands/config.sh — The config command: the deterministic install ceremony.
#
# `cmd_config` (US1, T044/T046) orchestrates the single `/speckit.jira.config`
# run: it reads the committed team config, discovers each project's metadata by
# API read (US2), persists the resolved-id table into the machine-owned
# config.local.yml with a DETERMINISTIC canonical serialisation (byte-identical
# on re-run, FR-003), and reports the run's THREE effects separately — discovery,
# `after_*` hook registration, and managed-README-block management (FR-054). At
# this increment only the discovery effect performs its write; the hooks and
# README effects are wired in later increments (T085 Phase 12, T065 Phase 8) and
# already appear as distinct summary sections here.
#
# Every step is an API read, a config read, or a closed enumerated question — no
# step is left to model judgement (FR-001); the machine-readable `--json` summary
# and the resolved-id table make the run fully reproducible (FR-002).
#
# Mapping validation (US2) refuses an impossible mapping at config time (FR-007):
# a team-managed project supports only an Epic parent and Sub-task children
# (research §3), so a hierarchy level ABOVE Epic is rejected with EXIT_CONFIG (4).
# The "Epic" tier is identified from the DISCOVERED binding — the top non-subtask
# hierarchy level — never a name compiled into the script (Constitution VII).

[[ -n ${_JIRA_CMD_CONFIG:-} ]] && return 0
_JIRA_CMD_CONFIG=1

_cmd_config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../lib/cli.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../lib/output.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../lib/config.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../sink/jira/discovery.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../hooks/readme_block.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../hooks/register_hooks.sh"

: "${EXIT_CONFIG:=4}"
: "${JIRA_CONFIG_DIR:=.specify/jira}"

# config_validate_mapping <style> <hierarchy-json> <binding-json>
# Refuse a team-managed hierarchy level above the discovered Epic tier (FR-007).
# The top parent is the non-subtask issue type with the greatest hierarchy_level
# in the binding; any configured level positioned above it is impossible. Prints
# a located error naming the level and the style, and returns EXIT_CONFIG (4).
# Company-managed projects carry no such restriction. Returns 0 when valid.
config_validate_mapping() {
  local style="$1" hierarchy="$2" binding="$3"
  [[ "${style}" != "team_managed" ]] && return 0

  local top
  top="$(jq -r '[.issue_types[] | select(.subtask == false)] | max_by(.hierarchy_level) | .logical_name' <<< "${binding}")"

  # Levels listed above the top parent (earlier in the top-down hierarchy list).
  local offenders
  offenders="$(jq -r --arg top "${top}" '
    (. // []) as $h
    | ($h | index($top)) as $ti
    | if $ti == null then empty else $h[0:$ti][] end
  ' <<< "${hierarchy}")"

  if [[ -n "${offenders}" ]]; then
    local first
    first="$(printf '%s\n' "${offenders}" | head -n1)"
    printf "mapping: hierarchy level '%s' sits above %s; team-managed projects support only an %s parent and Sub-task children (project style: team_managed)\n" \
      "${first}" "${top}" "${top}" >&2
    return "${EXIT_CONFIG}"
  fi
  return 0
}

# config_project_mapping <key> <style> <epic_strategy> <task_strategy> [link_type]
# Build the canonical project mapping entry by logical name. When task_strategy is
# `linked_story`, a link_type is REQUIRED (FR-009) — its absence is refused with
# EXIT_CONFIG (4). Prints the canonical project object on stdout.
config_project_mapping() {
  local key="$1" style="$2" epic_strategy="$3" task_strategy="$4" link_type="${5:-}"

  if [[ "${task_strategy}" == "linked_story" && -z "${link_type}" ]]; then
    printf 'mapping: task_strategy=linked_story requires a link_type (FR-009)\n' >&2
    return "${EXIT_CONFIG}"
  fi

  jq -n \
    --arg key "${key}" --arg style "${style}" \
    --arg epic "${epic_strategy}" --arg task "${task_strategy}" \
    --arg link "${link_type}" '
    {key: $key, style: $style, epic_strategy: $epic, task_strategy: $task}
    + (if $link == "" then {} else {link_type: $link} end)
  ' | json_canonical
}

# config_resolved_ids_for <binding-json> — reshape a discovered project binding
# into the resolved-id lookup table the reconcile path consumes: logical name ->
# id for issue types, priorities, and statuses. Prints the canonical object.
config_resolved_ids_for() {
  jq -c '{
    issue_types: ( reduce .issue_types[] as $t ({}; .[$t.logical_name] = $t.id) ),
    priorities:  ( reduce .priorities[] as $p ({}; .[$p.logical_name] = $p.id) ),
    statuses:    ( reduce .statuses[] as $s ({}; .[$s.name] = $s.id) )
  }' <<< "$1" | json_canonical
}

# _config_degraded_run <json:true|false> <dry_run:true|false> <missing-vars>
# The degraded, report-only path (002 US2, FR-008/FR-009): entered ONLY when
# connection parameters are undefined, BEFORE any Jira call. Scans local branch
# names for `<prefix>-<number>/…` shapes (the command layer may read git;
# research §4), proposes the distinct prefixes as PROVISIONAL team candidates,
# prints exactly one warning naming the missing variables plus copy-pasteable
# re-run guidance, and writes NOTHING — every effect reports `skipped` and the
# authoritative resolved-id binding is untouched. Exit 0.
_config_degraded_run() {
  local json="$1" dry_run="$2" missing="$3"
  local branches proposals
  branches="$(git for-each-ref refs/heads --format='%(refname:short)' 2> /dev/null || true)"
  proposals="$(printf '%s\n' "${branches}" \
    | sed -nE 's|^([a-z0-9][a-z0-9-]*)-[0-9]+/.*$|\1|p' \
    | LC_ALL=C sort -u \
    | jq -cR . | jq -cs 'map({team_prefix: ., provisional: true})')"
  [[ -z "${proposals}" ]] && proposals='[]'

  output_warn "degraded mode — Jira introspection is unavailable (undefined: ${missing}); team-name proposals are provisional and nothing was written"
  local rerun="define ${missing}, then re-run: spec-kit-jira config"

  local detail="degraded mode: Jira connection parameters undefined"
  local effects summary
  effects="$(jq -cn --arg d "${detail}" '{
    discovery: {status: "skipped", detail: $d},
    hooks:     {status: "skipped", detail: $d},
    readme:    {status: "skipped", detail: $d}
  }')"
  summary="$(jq -cn --argjson effects "${effects}" --argjson dry "${dry_run}" \
    --argjson prov "${proposals}" --arg rerun "${rerun}" '
    {schema_version: "1.0", command: "config", dry_run: $dry,
     counts: {created: 0, updated: 0, skipped: 0, warnings: 1, errors: 0},
     effects: $effects, provisional: $prov, rerun_guidance: $rerun,
     exit_code: 0}' | json_canonical)"
  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return 0
}

# _config_style_flag_for <project-key> <styles-string> — the operator's --style
# answer for one project (last occurrence wins), or empty when none was given.
_config_style_flag_for() {
  local key="$1" styles="$2" tok out=""
  for tok in ${styles}; do
    [[ "${tok}" == "${key}="* ]] && out="${tok#*=}"
  done
  printf '%s' "${out}"
}

# _config_resolve_style <project-key> <api-style> <committed-style> <style-flag>
# Per-project style resolution (002 US1, FR-001/FR-002): unambiguous API signal
# (agreeing with any committed declaration) -> "api"; otherwise the operator's
# --style answer or, absent an API signal, the committed declaration ->
# "operator"; otherwise fail closed (EXIT_CONFIG) with a located stderr naming
# the project, the reason, and the two valid --style values. Prints
# "<style> <source>" on success.
_config_resolve_style() {
  local pkey="$1" api_style="$2" committed="$3" flag="$4"
  if [[ -n "${api_style}" && (-z "${committed}" || "${committed}" == "${api_style}") ]]; then
    printf '%s api' "${api_style}"
    return 0
  fi
  if [[ -n "${flag}" ]]; then
    printf '%s operator' "${flag}"
    return 0
  fi
  if [[ -z "${api_style}" && -n "${committed}" ]]; then
    printf '%s operator' "${committed}"
    return 0
  fi
  local reason="no unambiguous style signal in the discovery payload"
  [[ -n "${api_style}" ]] && reason="the committed style conflicts with the API signal"
  printf 'config: project %s: style is ambiguous (%s); pass --style %s=company_managed or --style %s=team_managed\n' \
    "${pkey}" "${reason}" "${pkey}" "${pkey}" >&2
  return "${EXIT_CONFIG}"
}

# _config_gitignore_effect <repo-root> <dry_run> — enforce gitignore coverage of
# the gitignored config layer (002 US3, FR-019): config.local.yml, .env, and the
# new personal.yml. Only missing exact lines are appended, idempotently; an
# absent file is created with the three lines. Prints the effect status
# (created|written|unchanged) on stdout; a dry-run computes the status without
# touching the file.
_config_gitignore_effect() {
  local repo_root="$1" dry_run="$2"
  local gi="${SPEC_KIT_JIRA_GITIGNORE:-${repo_root}/.gitignore}"
  local -a lines=(
    ".specify/jira/config.local.yml"
    ".specify/jira/.env"
    ".specify/jira/personal.yml"
  )
  local status
  if [[ ! -f "${gi}" ]]; then
    status="created"
    [[ "${dry_run}" != "true" ]] && printf '%s\n' "${lines[@]}" > "${gi}"
  else
    local -a missing=()
    local l
    for l in "${lines[@]}"; do
      grep -qxF "${l}" "${gi}" 2> /dev/null || missing+=("${l}")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
      status="unchanged"
    else
      status="written"
      if [[ "${dry_run}" != "true" ]]; then
        # Guarantee a trailing newline before appending the missing lines.
        [[ -s "${gi}" && -n "$(tail -c1 "${gi}")" ]] && printf '\n' >> "${gi}"
        printf '%s\n' "${missing[@]}" >> "${gi}"
      fi
    fi
  fi
  printf '%s' "${status}"
}

# cmd_config <argv...> — the deterministic install ceremony (US1). Echoes the run
# summary to stdout and returns the exit code.
cmd_config() {
  # Parse flags (config-read, no model judgement). The dispatcher already handled
  # --help; re-parse here so the command is runnable standalone.
  local parsed json="false" dry_run="false" exit_code="0" error="" styles="" args=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      styles) styles="${value}" ;;
      args) args="${value}" ;;
      exit) exit_code="${value}" ;;
      error) error="${value}" ;;
    esac
  done <<< "${parsed}"
  if [[ "${exit_code}" != "0" ]]; then
    [[ -n "${error}" ]] && printf 'config: %s\n' "${error}" >&2
    return "${exit_code}"
  fi

  local configdir="${JIRA_CONFIG_DIR}"

  # Config read: load and validate the committed team config (US4).
  local cfg
  cfg="$(config_load "${configdir}")" || return $?

  # Degraded-mode trigger (002 US2, FR-008) — tested BEFORE any Jira call and
  # ONLY on ABSENT connection parameters: an unset/empty base URL, or a token
  # that resolves through none of the three rungs. Defined-but-wrong parameters
  # keep the fail-closed auth/network exits below (research §4).
  local degraded_missing=""
  if [[ -z "${SPEC_KIT_JIRA_BASE_URL:-}" ]]; then
    degraded_missing="SPEC_KIT_JIRA_BASE_URL"
  fi
  if ! cred_resolve_token > /dev/null 2>&1; then
    if [[ -n "${degraded_missing}" ]]; then
      degraded_missing="${degraded_missing}, JIRA_API_TOKEN"
    else
      degraded_missing="JIRA_API_TOKEN"
    fi
  fi
  if [[ -n "${degraded_missing}" ]]; then
    _config_degraded_run "${json}" "${dry_run}" "${degraded_missing}"
    return $?
  fi

  # Project-key sourcing (002 US2, FR-004/FR-005): positional argument ->
  # committed non-placeholder keys -> the closed question over the discovered
  # accessible-projects list (unattended: exit 4). Git state plays no role.
  local arg_key="${args%% *}"
  local keys=""
  if [[ -n "${arg_key}" ]]; then
    keys="${arg_key}"
  else
    local ckey
    while IFS= read -r ckey; do
      [[ -z "${ckey}" ]] && continue
      config_key_is_placeholder "${ckey}" && continue
      keys="${keys}${keys:+$'\n'}${ckey}"
    done <<< "$(jq -r '.projects[]?.key // empty' <<< "${cfg}")"
  fi
  if [[ -z "${keys}" ]]; then
    local listing
    listing="$(discovery_list_projects)" || return $?
    {
      printf 'config: no usable project key — config.yml holds no bound key (the %s placeholder counts as unset) and no key argument was given\n' \
        "${JIRA_CONFIG_PLACEHOLDER_KEY}"
      printf 'config: accessible projects (closed question — choose one and re-run: spec-kit-jira config <KEY>):\n'
      jq -r '.[] | "config:   \(.key) — \(.name) (\(.style // "style unknown"))"' <<< "${listing}"
    } >&2
    return "${EXIT_CONFIG}"
  fi

  # Read the machine-owned local layer up front: its prior resolved-id table seeds
  # this run so re-running only (re)binds the currently configured projects while
  # every previously-bound project's mapping is preserved untouched — the config
  # command is incrementally re-runnable (FR-043). Each project's ids land under
  # its own key, so distinct projects never share a namespace (FR-044).
  local localf="${configdir}/config.local.yml" existing="{}"
  [[ -f "${localf}" ]] && existing="$(config_yaml_to_json "${localf}")"

  # API reads: discover each project's metadata (US2) and (re)build its resolved-id
  # entry. Discovery is deterministic, so an unchanged project yields identical
  # bytes on every run (FR-003).
  local resolved nproj=0 pkey binding rids proj_styles='{}'
  local api_style committed style_flag style_resolved style style_source
  resolved="$(jq -c '.resolved_ids // {}' <<< "${existing}")"
  while IFS= read -r pkey; do
    [[ -z "${pkey}" ]] && continue
    binding="$(discover_binding "${pkey}")" || return $?
    # Style resolution (002 US1): api signal -> operator answer/declaration ->
    # fail closed. An ambiguous project refuses BEFORE any write (zero writes).
    api_style="$(jq -r '.style // ""' <<< "${binding}")"
    committed="$(jq -r --arg k "${pkey}" '[.projects[] | select(.key == $k)][0].style // ""' <<< "${cfg}")"
    style_flag="$(_config_style_flag_for "${pkey}" "${styles}")"
    style_resolved="$(_config_resolve_style "${pkey}" "${api_style}" "${committed}" "${style_flag}")" || return $?
    style="${style_resolved%% *}"
    style_source="${style_resolved##* }"
    rids="$(config_resolved_ids_for "${binding}")"
    rids="$(jq -c --arg s "${style}" --arg src "${style_source}" \
      '. + {style: $s, style_source: $src}' <<< "${rids}")"
    resolved="$(jq -c --arg k "${pkey}" --argjson r "${rids}" '. + {($k): $r}' <<< "${resolved}")"
    proj_styles="$(jq -c --arg k "${pkey}" --arg s "${style}" --arg src "${style_source}" \
      '. + {($k): {style: $s, style_source: $src}}' <<< "${proj_styles}")"
    nproj=$((nproj + 1))
  done <<< "${keys}"

  # Merge the resolved-id table into the machine-owned local layer, preserving
  # the operator's site_alias / overrides, and emit deterministic canonical YAML.
  local newlocal yaml
  newlocal="$(jq -cS --argjson r "${resolved}" '. + {resolved_ids: $r}' <<< "${existing}")"
  yaml="$(printf '%s' "${newlocal}" | config_to_yaml)"

  # Discovery-effect status: created / unchanged / written.
  local disc_status="written"
  if [[ ! -f "${localf}" ]]; then
    disc_status="created"
  elif [[ "$(cat "${localf}")" == "${yaml}" ]]; then
    disc_status="unchanged"
  fi
  if [[ "${dry_run}" != "true" ]]; then
    printf '%s\n' "${yaml}" > "${localf}"
  fi

  # Connected-run mismatch surfacing (002 US2, FR-009): when the committed config
  # declares a `teams:` catalogue, check each declared team's project against the
  # accessible-projects list and warn (never block) for any team whose project is
  # not visible. Without a catalogue no extra read is performed.
  local run_warnings=0
  if [[ "$(jq -r '(.teams // []) | length' <<< "${cfg}")" -gt 0 ]]; then
    local accessible
    if accessible="$(discovery_list_projects 2> /dev/null)"; then
      local tid tproj
      while IFS=$'\t' read -r tid tproj; do
        [[ -z "${tid}" ]] && continue
        if ! jq -e --arg p "${tproj}" 'any(.[]; .key == $p)' <<< "${accessible}" > /dev/null; then
          output_warn "team '${tid}': project ${tproj} matches no accessible Jira project — a provisional, branch-derived value may have been accepted into the catalogue; verify or fix config.yml"
          run_warnings=$((run_warnings + 1))
        fi
      done <<< "$(jq -r '.teams[] | "\(.id)\t\(.project)"' <<< "${cfg}")"
    fi
  fi

  # Gitignore effect (002 US3, FR-019): ensure the repository .gitignore covers the
  # gitignored config layer (config.local.yml, .env, personal.yml). Repo root is
  # the parent of the .specify directory (overridable via SPEC_KIT_JIRA_GITIGNORE).
  local repo_root gitignore_status
  repo_root="$(dirname "$(dirname "${configdir}")")"
  gitignore_status="$(_config_gitignore_effect "${repo_root}" "${dry_run}")"

  # README effect (US5, T065): splice the version-marked managed block into the
  # consuming repository's README. The path derives from the config dir's repo
  # root (the parent of .specify), overridable via SPEC_KIT_JIRA_README.
  local readme_path readme_status="skipped" readme_detail
  readme_path="${SPEC_KIT_JIRA_README:-$(dirname "$(dirname "${configdir}")")/README.md}"
  readme_status="$(readme_block_write "${readme_path}" "${dry_run}")" || readme_status="refused"
  case "${readme_status}" in
    created) readme_detail="managed README block created" ;;
    written) readme_detail="managed README block updated" ;;
    unchanged) readme_detail="managed README block unchanged" ;;
    refused) readme_detail="README markers malformed; block not written" ;;
    *) readme_detail="${readme_status}" ;;
  esac

  # Hooks effect (US9, T085): register the after_* lifecycle hooks idempotently in
  # .specify/extensions.yml (FR-054) — the same self-healing write reachable from a
  # run via reconcile --repair-hooks. The path derives from the config dir's parent
  # (.specify), overridable via SPEC_KIT_JIRA_EXTENSIONS_YML.
  local ext_path hooks_status hooks_detail
  ext_path="${SPEC_KIT_JIRA_EXTENSIONS_YML:-$(dirname "${configdir}")/extensions.yml}"
  hooks_status="$(register_hooks_write "${ext_path}" "${dry_run}")" || hooks_status="refused"
  case "${hooks_status}" in
    created) hooks_detail="after_* lifecycle hooks registered" ;;
    repaired) hooks_detail="missing lifecycle hooks repaired" ;;
    unchanged) hooks_detail="lifecycle hooks already registered" ;;
    refused) hooks_detail="extensions.yml markers malformed; hooks not registered" ;;
    *) hooks_detail="${hooks_status}" ;;
  esac

  # Build the three-effect summary (FR-054): discovery, hooks, and README are each
  # reported as a distinct section so the operator sees exactly what was written.
  local effects
  effects="$(jq -cn \
    --arg ds "${disc_status}" --arg dd "${nproj} project(s) discovered" \
    --argjson dp "${proj_styles}" \
    --arg hs "${hooks_status}" --arg hd "${hooks_detail}" \
    --arg rs "${readme_status}" --arg rd "${readme_detail}" \
    --arg gs "${gitignore_status}" '
    {
      discovery: {status: $ds, detail: $dd, projects: $dp},
      hooks:     {status: $hs, detail: $hd},
      readme:    {status: $rs, detail: $rd},
      gitignore: {status: $gs, detail: "personal.yml gitignore coverage"}
    }')"

  local summary
  summary="$(jq -cn --argjson effects "${effects}" --argjson dry "${dry_run}" --argjson w "${run_warnings}" '
    {schema_version: "1.0", command: "config", dry_run: $dry,
     counts: {created: 0, updated: 0, skipped: 0, warnings: $w, errors: 0},
     effects: $effects, exit_code: 0}' | json_canonical)"

  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return 0
}
