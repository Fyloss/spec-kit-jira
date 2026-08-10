#!/usr/bin/env bash
# commands/config.sh — The config command: the deterministic install ceremony.
#
# `cmd_config` (US1, T044/T046) orchestrates the single `/speckit.jira.config`
# run: it reads the committed team config, discovers each project's metadata by
# API read (US2), persists the resolved-id table into the machine-owned
# config.local.yml with a DETERMINISTIC canonical serialisation (byte-identical
# on re-run, FR-003), and reports the run's effects separately — discovery, hook
# VERIFICATION, the managed README block, and gitignore coverage (FR-054).
#
# The hooks effect no longer registers anything (003 US6). The manifest declares
# the seven lifecycle events and `specify extension add` writes them; this
# ceremony READS the registry, classifies every event, and reports. It never
# creates, modifies, reorders or reformats `.specify/extensions.yml`, in any
# state, so every run leaves that file byte-identical, comments included
# (003 FR-022, FR-023). The one thing it does write is our own gitignored local
# binding, where the operator's disable decision is recorded so a reinstall
# cannot erase it (003 FR-029, research R5).
#
# Every step is an API read, a config read, or a closed enumerated question — no
# step is left to model judgement (FR-001); the machine-readable `--json` summary
# and the resolved-id table make the run fully reproducible (FR-002).
#
# Mapping validation (US2) refuses an impossible mapping at config time (FR-007):
# a team-managed project supports only an Epic parent and Sub-task children
# (research §3), so a hierarchy level ABOVE Epic is rejected with EXIT_CONFIG (4).
# The Epic tier is identified from the DISCOVERED binding — the top non-subtask
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
source "${_cmd_config_dir}/../sink/jira/hierarchy.sh"
# shellcheck source=/dev/null
source "${_cmd_config_dir}/../sink/jira/plan_apply.sh" # plan_resolve_field_defaults — label->id resolution for the gate (011)
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

# config_project_mapping <key> <style> — build the canonical project mapping
# entry by logical name. Prints the canonical project object on stdout. Three
# keys and their linked-story requirement are retired (008 T028, FR-030).
config_project_mapping() {
  local key="$1" style="$2"
  jq -n --arg key "${key}" --arg style "${style}" '{key: $key, style: $style}' | json_canonical
}

# config_resolved_ids_for <binding-json> — reshape a discovered project binding
# into the resolved-id table the reconcile path consumes. Issue types keep
# their hierarchy_level and subtask flag as a LIST, in discovered order
# (data-model.md §3, R5) — a name-to-id map discarded both the moment they
# became durable, which is exactly the defect this feature repairs. Priorities
# and statuses are unaffected: logical name -> id / name -> id maps, as before.
# hierarchy_level is carried as a STRING like every other identifier here —
# the YAML writer's scalar round-trip has no number type (config_to_yaml
# emits a bare numeral, and the reader reads a bare numeral back as a string),
# so hierarchy.sh converts with `tonumber` at every comparison site instead of
# relying on a type the persisted file cannot actually preserve.
config_resolved_ids_for() {
  jq -c '{
    issue_types: [ .issue_types[] | {
      logical_name: .logical_name, id: .id,
      hierarchy_level: (.hierarchy_level | tostring), subtask: .subtask
    } ],
    priorities:  ( reduce .priorities[] as $p ({}; .[$p.logical_name] = $p.id) ),
    statuses:    ( reduce .statuses[] as $s ({}; .[$s.name] = $s.id) )
  }
  # required_fields and parent_link_available (T017-T020) carry straight
  # through — discovery already shapes them keyed by issue-type id — and are
  # omitted rather than emitted empty when discovery resolved neither type
  # (the ambiguous-child case), so an old-style call site building this
  # object by hand does not have to know about them. defaultable_fields
  # (011, T011) gets the same treatment: a binding written before this
  # feature simply carries no such key, and keeps loading (data-model.md §2).
  + (if (.required_fields // {}) != {} then {required_fields: .required_fields} else {} end)
  + (if (.parent_link_available // {}) != {} then {parent_link_available: .parent_link_available} else {} end)
  + (if (.defaultable_fields // {}) != {} then {defaultable_fields: .defaultable_fields} else {} end)
  ' <<< "$1" | json_canonical
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
  local json="$1" dry_run="$2" missing="$3" hooks_status="$4" hooks_detail="$5"
  local branches proposals
  branches="$(git for-each-ref refs/heads --format='%(refname:short)' 2> /dev/null || true)"
  proposals="$(printf '%s\n' "${branches}" \
    | sed -nE 's|^([a-z0-9][a-z0-9-]*)-[0-9]+/.*$|\1|p' \
    | LC_ALL=C sort -u \
    | jq -cR . | jq -cs 'map({team_prefix: ., provisional: true})')"
  [[ -z "${proposals}" ]] && proposals='[]'

  output_warn "degraded mode — Jira introspection is unavailable (undefined: ${missing}); team-name proposals are provisional and nothing was written"
  local rerun
  rerun="define ${missing}, then re-run: $(output_bridge_invocation config)"

  local detail="degraded mode: Jira connection parameters undefined"
  local effects summary
  # The hooks effect is reported even here. It needs no Jira at all — it reads
  # two local files — and an operator running the ceremony to release a held
  # event with --enable-hook is very likely to be doing it before the credentials
  # are in place. Reporting it "skipped" would have been a lie about work that
  # was in fact performed.
  effects="$(jq -cn --arg d "${detail}" --arg hs "${hooks_status}" --arg hd "${hooks_detail}" '{
    discovery: {status: "skipped", detail: $d},
    hooks:     {status: $hs, detail: $hd},
    readme:    {status: "skipped", detail: $d},
    gitignore: {status: "skipped", detail: $d}
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

# _config_task_mirror_flag_for <project-key> <task-mirrors-string> — the
# operator's --task-mirror answer for one project (last occurrence wins), or
# empty when none was given this run (022, contract §4). Mirrors
# _config_style_flag_for.
_config_task_mirror_flag_for() {
  local key="$1" task_mirrors="$2" tok out=""
  for tok in ${task_mirrors}; do
    [[ "${tok}" == "${key}="* ]] && out="${tok#*=}"
  done
  printf '%s' "${out}"
}

# _config_task_mirror_question <project-key> — the closed question line
# (022, contract §5 "Asked"), reported per project when nothing is recorded
# for it, whether or not a task role is declared (FR-005/FR-008).
_config_task_mirror_question() {
  local pkey="$1"
  printf "config: project %s: how should tasks be mirrored — choose one of: subtask, checklist (answer with --task-mirror '%s=checklist'). Recording nothing keeps today's behaviour: one sub-task per task when a task role is declared, and no task tier otherwise." \
    "${pkey}" "${pkey}"
}

# _config_task_mirror_fr012_note <project-key> — reported at config time
# (022, contract §5 "FR-012 check") when the recorded value is 'subtask' and
# no sub-task issue type can be resolved for the project.
_config_task_mirror_fr012_note() {
  local pkey="$1"
  printf "config: project %s: task_mirror is 'subtask' but no sub-task issue type is resolved for this project — declare hierarchy.task, or switch with --task-mirror '%s=checklist'" \
    "${pkey}" "${pkey}"
}

# _config_task_mirror_effect_line <project-key> <effective-value> <status> —
# the ceremony's per-project effect line (022, contract §6), reported
# alongside the effects the run already reports separately (FR-013).
_config_task_mirror_effect_line() {
  local pkey="$1" effective="$2" status="$3"
  if [[ -z "${effective}" ]]; then
    printf "Task mirror: %s — not recorded; today's behaviour applies" "${pkey}"
  else
    printf 'Task mirror: %s — %s (%s)' "${pkey}" "${effective}" "${status}"
  fi
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

# _config_declared_hierarchy_for <project-key> <cfg-json> — the committed
# `projects[].hierarchy` mapping for one project (010, contract §2.1), or
# `{}` when the project declares none.
_config_declared_hierarchy_for() {
  local key="$1" cfg="$2"
  jq -c --arg k "${key}" '[.projects[]? | select(.key == $k)][0].hierarchy // {}' <<< "${cfg}"
}

# _config_operator_roles_for <project-key> <issue-types-string> — the
# operator's --issue-type / --child-type answers for one project, reduced to
# {role: name} (010, contract §2.2). `issue_types` is cli_parse's merged,
# space-separated `KEY=role=name` stream (--child-type is already translated
# to role=story by lib/cli.sh); last occurrence per (KEY, role) wins because
# later tokens simply overwrite earlier ones in the fold below.
_config_operator_roles_for() {
  local key="$1" issue_types="$2" tok rest role name out='{}'
  for tok in ${issue_types}; do
    [[ "${tok}" == "${key}="* ]] || continue
    rest="${tok#*=}"
    role="${rest%%=*}"
    name="${rest#*=}"
    out="$(jq -c --arg r "${role}" --arg n "${name}" '. + {($r): $n}' <<< "${out}")"
  done
  printf '%s' "${out}"
}

# _config_field_answers_for <project-key> <field-defaults-string> — this run's
# --field-default answers for one project (011, contract §2.4), reduced to
# `[{type, label, value}]` in argv order. `field_defaults` is cli_parse's
# \x1f-joined stream (NOT space-joined like every other repeatable flag —
# lib/cli.sh:cli_parse — a field VALUE may itself contain spaces).
_config_field_answers_for() {
  cli_field_answers_for "$1" "$2"
}

# _config_field_default_answer_problems <itypes-json> <defaultable-by-type-json>
# <answers-json> — every §2.4 refusal a THIS-RUN answer produces: unknown
# issue-type name (listing the discovered types), unknown field label
# (listing that type's defaultable fields), a field whose shape cannot be
# defaulted (naming its `undefaultable_reason`, US3 scenario 3), an empty
# value, a value outside `allowed_values`, or a credential-shaped value
# (Principle IV — the value itself is never in the problem). Batched, never
# one refusal per answer, mirroring role_resolve's own "evaluate everything
# before refusing". Prints a JSON array, empty when every answer is valid.
_config_field_default_answer_problems() {
  local itypes="${1:-}" defaultable="${2:-}" answers="${3:-}"
  [[ -z "${itypes}" ]] && itypes='[]'
  [[ -z "${defaultable}" ]] && defaultable='{}'
  [[ -z "${answers}" ]] && answers='[]'
  local structural
  structural="$(jq -cn --argjson itypes "${itypes}" --argjson df "${defaultable}" --argjson ans "${answers}" '
    def typeId($name): (first($itypes[] | select(.logical_name == $name)) // null) | .id;
    def fieldFor($tid; $label): (first((($df[$tid]) // [])[] | select(.logical_name == $label)) // null);
    [ $ans[]
      | (.type) as $t | (.label) as $l | (.value) as $v | (typeId($t)) as $tid
      | if $tid == null then
          {kind: "unknown_type", type: $t, label: $l, candidates: [$itypes[].logical_name]}
        else
          (fieldFor($tid; $l)) as $f
          | if $f == null then
              {kind: "unknown_label", type: $t, label: $l, candidates: [(($df[$tid]) // [])[].logical_name]}
            elif ($f.defaultable != true) then
              {kind: "undefaultable", type: $t, label: $l, reason: $f.undefaultable_reason}
            elif ($v == "") then
              {kind: "empty_value", type: $t, label: $l}
            elif ((($f.allowed_values // []) | length) > 0 and (($f.allowed_values) | index($v)) == null) then
              {kind: "outside_allowed", type: $t, label: $l, candidates: $f.allowed_values}
            else empty
            end
        end
    ]
  ')"
  local credential
  credential="$(jq -c '.[]' <<< "${answers}" | while IFS= read -r a; do
    local type label value shape
    type="$(jq -r '.type' <<< "${a}")"
    label="$(jq -r '.label' <<< "${a}")"
    value="$(jq -r '.value' <<< "${a}")"
    shape="$(jq -cn --arg v "${value}" '{value: $v}' | _cfg_credential_errors)"
    [[ -z "${shape}" ]] && continue
    jq -cn --arg t "${type}" --arg l "${label}" --arg s "${shape#*: }" \
      '{kind: "credential", type: $t, label: $l, shape: $s}'
  done | jq -cs '.')"
  jq -cn --argjson a "${structural}" --argjson b "${credential}" '$a + $b'
}

# _config_field_default_merge <recorded-json> <answers-json> — the union of
# §2.6: the project's recorded entry (minus `ask`) re-emitted, with each
# THIS-RUN answer overwriting the matching (type, label) entry; every other
# entry carries forward unchanged. Pure structural merge — validation is
# `_config_field_default_answer_problems`'s job, not this one's.
_config_field_default_merge() {
  local recorded="${1:-}" answers="${2:-}"
  [[ -z "${recorded}" ]] && recorded='{}'
  [[ -z "${answers}" ]] && answers='[]'
  jq -cn --argjson rec "${recorded}" --argjson ans "${answers}" '
    ($rec | del(.ask)) as $base
    | reduce $ans[] as $a ($base; .[$a.type][$a.label] = $a.value)
  '
}

# _config_field_default_report <itypes-json> <defaultable-by-type-json>
# <ask-types-json> <merged-json> <bridge-written-type-ids-json> — three
# non-blocking reports plus two refusal triggers, computed over the merged
# (already-valid) field_defaults entry:
#   - orphaned: a recorded type or field label the project no longer offers
#     (contract §2.8, FR-008) — never blocks.
#   - not_yet_consumed: a recorded type that exists but the bridge does not
#     write (contract §2.8, FR-027) — never blocks.
#   - undefaultable_required: a required field of an in-scope type whose
#     shape cannot be defaulted, reported once (contract §2.3) — the
#     pre-existing mandatory gate refuses it unchanged (US3 scenario 3).
#   - pending: a required, DEFAULTABLE field of an in-scope type with
#     neither a recorded value nor a this-run answer — the ceremony's own
#     closed question (contract §2.1-§2.3); a non-empty result is this
#     function's one refusal trigger.
#   - outside_allowed (015, research R5, contract §6, data-model.md §7): a
#     MERGED entry — recorded or this-run, either can reach here — whose
#     value is not one of its field's `allowed_values`. Examined only when
#     the type name resolves (A1), the label resolves to a defaultable field
#     of that type (A2), that field's `allowed_values` is non-empty (A3),
#     and the recorded value is a STRING (A4) — an entry failing A1/A2 stays
#     classified `orphaned` and never blocks (011 FR-008), and an absent
#     list is not an empty one. A4 keeps FR-006's escape hatch open: a value
#     an operator wrote as an object or an array is the shape the bridge
#     does not derive, obeyed literally, and it can never be a member of an
#     `allowed_values` list that holds option labels — checking it would
#     refuse exactly the value the spec promises to pass through. A
#     non-empty result is a refusal trigger, like `pending`; the recorded
#     value itself never appears in the entry, only the label, the type,
#     and the candidates (Principle IV).
_config_field_default_report() {
  local itypes="${1:-}" defaultable="${2:-}" ask_types="${3:-}" merged="${4:-}" bridge="${5:-}"
  [[ -z "${itypes}" ]] && itypes='[]'
  [[ -z "${defaultable}" ]] && defaultable='{}'
  [[ -z "${ask_types}" ]] && ask_types='[]'
  [[ -z "${merged}" ]] && merged='{}'
  [[ -z "${bridge}" ]] && bridge='[]'
  jq -cn --argjson itypes "${itypes}" --argjson df "${defaultable}" --argjson ask "${ask_types}" \
      --argjson merged "${merged}" --argjson bridge "${bridge}" '
    def typeId($name): (first($itypes[] | select(.logical_name == $name)) // null) | .id;
    def labelOk($tid; $l): (($df[$tid]) // []) | any(.logical_name == $l);

    ( [ ($merged | to_entries)[]
        | (.key) as $tname | (.value) as $labels | (typeId($tname)) as $tid
        | if $tid == null then
            [{kind: "orphaned_type", type: $tname}]
          else
            ( [ $labels | keys[] | select(labelOk($tid; .) | not) ] | map({kind: "orphaned_label", type: $tname, label: .}) ) as $orph
            | ( if ($tid | IN($bridge[])) then [] else [{kind: "not_yet_consumed", type: $tname}] end ) as $nyc
            | ($orph + $nyc)
          end
      ] | flatten
    ) as $reports
    | {
        orphaned: [ $reports[] | select(.kind == "orphaned_type" or .kind == "orphaned_label") ],
        not_yet_consumed: [ $reports[] | select(.kind == "not_yet_consumed") ],
        undefaultable_required: [
          $ask[] as $tname | (typeId($tname)) as $tid | (($df[$tid]) // [])[]
          | select(.required == true and .defaultable == false)
          | {type: $tname, label: .logical_name, reason: .undefaultable_reason}
        ],
        pending: [
          $ask[] as $tname | (typeId($tname)) as $tid | (($df[$tid]) // [])[]
          | select(.required == true and .defaultable == true)
          | select( ($merged[$tname][.logical_name] // null) == null )
          | {type: $tname, label: .logical_name, allowed_values: (.allowed_values // [])}
        ],
        outside_allowed: [
          ($merged | to_entries)[] as $te
          | ($te.key) as $tname | ($te.value) as $labels | (typeId($tname)) as $tid
          | select($tid != null)
          | ($labels | to_entries)[] as $le
          | ($le.key) as $lbl | ($le.value) as $val
          | (first((($df[$tid]) // [])[] | select(.logical_name == $lbl)) // null) as $meta
          | select($meta != null)
          | ($meta.allowed_values // []) as $av
          | select(($val | type) == "string")
          | select(($av | length) > 0 and ($av | index($val)) == null)
          | {type: $tname, label: $lbl, candidates: $av}
        ]
      }
  '
}

# _config_report_role_problems <project-key> <resolve-result-json> <json:true|false>
# Render every problem role_resolve found (010, contract §6): one block per
# unresolved role in role order, then unknown/duplicate/subtask-misuse/
# task-misuse/no-parent-level — all to stderr — plus, in --json mode, the
# structured `unresolved_roles` block on stdout (§6.2), through
# json_canonical rather than a bare jq call (research R10).
_config_report_role_problems() {
  local key="$1" result="$2" json="$3"
  local role level name lvl
  while IFS=$'\t' read -r role level; do
    [[ -z "${role}" ]] && continue
    local cands
    cands="$(jq -c --arg r "${role}" '[.unresolved[] | select(.role == $r)][0].candidates' <<< "${result}")"
    role_unresolved_message "${key}" "${role}" "${level}" "${cands}" >&2
    printf '\n' >&2
  done <<< "$(jq -r '.unresolved[] | "\(.role)\t\(.level)"' <<< "${result}")"

  while IFS=$'\t' read -r role name; do
    [[ -z "${role}" ]] && continue
    local cands
    cands="$(jq -c --arg r "${role}" --arg n "${name}" '[.unknown[] | select(.role == $r and .name == $n)][0].candidates' <<< "${result}")"
    role_unknown_type_message "${key}" "${role}" "${name}" "${cands}" >&2
    printf '\n' >&2
  done <<< "$(jq -r '.unknown[] | "\(.role)\t\(.name)"' <<< "${result}")"

  while IFS=$'\t' read -r role name lvl; do
    [[ -z "${role}" ]] && continue
    role_duplicate_message "${key}" "${role}" "${name}" "${lvl}" >&2
    printf '\n' >&2
  done <<< "$(jq -r '.duplicate[] | "\(.role)\t\(.name)\t\(.level)"' <<< "${result}")"

  while IFS=$'\t' read -r role name; do
    [[ -z "${role}" ]] && continue
    role_subtask_misuse_message "${key}" "${role}" "${name}" >&2
    printf '\n' >&2
  done <<< "$(jq -r '.subtask_misuse[] | "\(.role)\t\(.name)"' <<< "${result}")"

  while IFS=$'\t' read -r name; do
    [[ -z "${name}" ]] && continue
    local cands
    cands="$(jq -c --arg n "${name}" '[.task_misuse[] | select(.name == $n)][0].candidates' <<< "${result}")"
    role_task_misuse_message "${key}" "${name}" "${cands}" >&2
    printf '\n' >&2
  done <<< "$(jq -r '.task_misuse[] | .name' <<< "${result}")"

  local no_parent
  no_parent="$(jq -r '.no_parent_level // empty' <<< "${result}")"
  [[ -n "${no_parent}" ]] && printf '%s\n' "${no_parent}" >&2

  if [[ "${json}" == "true" && "$(jq -r '.unresolved | length' <<< "${result}")" -gt 0 ]]; then
    local block
    block="$(role_unresolved_json "${result}" "${key}")"
    printf '%s\n' "$(jq -cn --argjson u "${block}" '{unresolved_roles: $u}' | json_canonical)"
  fi
}

# _config_report_field_default_problems <pkey> <problems-json> <json> —
# refuse this run's --field-default answers (contract §2.4): one message per
# problem to stderr, plus a structured block on stdout in --json mode. Zero
# writes — the caller returns EXIT_CONFIG right after calling this.
_config_report_field_default_problems() {
  local pkey="$1" problems="$2" json="$3" n i
  n="$(jq -r 'length' <<< "${problems}")"
  for ((i = 0; i < n; i++)); do
    local p kind type label
    p="$(jq -c ".[${i}]" <<< "${problems}")"
    kind="$(jq -r '.kind' <<< "${p}")"
    type="$(jq -r '.type' <<< "${p}")"
    label="$(jq -r '.label' <<< "${p}")"
    case "${kind}" in
      unknown_type)
        printf 'config: project %s: --field-default names an issue type this project does not offer: %s (discovered types: %s)\n' \
          "${pkey}" "${type}" "$(jq -r '.candidates | join(", ")' <<< "${p}")" >&2
        ;;
      unknown_label)
        printf 'config: project %s: issue type %s has no field named %s (defaultable fields: %s)\n' \
          "${pkey}" "${type}" "${label}" "$(jq -r '.candidates | join(", ")' <<< "${p}")" >&2
        ;;
      undefaultable)
        printf 'config: project %s: %s (%s) cannot be defaulted — %s\n' \
          "${pkey}" "${label}" "${type}" "$(jq -r '.reason' <<< "${p}")" >&2
        ;;
      empty_value)
        printf 'config: project %s: %s (%s) — a default may not be empty\n' "${pkey}" "${label}" "${type}" >&2
        ;;
      outside_allowed)
        printf 'config: project %s: %s (%s) must be one of: %s\n' \
          "${pkey}" "${label}" "${type}" "$(jq -r '.candidates | join(", ")' <<< "${p}")" >&2
        ;;
      credential)
        printf 'config: project %s: %s (%s) looks like a %s and is refused — it never becomes a recorded default\n' \
          "${pkey}" "${label}" "${type}" "$(jq -r '.shape' <<< "${p}")" >&2
        ;;
    esac
    printf '\n' >&2
  done
  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "$(jq -cn --argjson p "${problems}" '{field_default_problems: $p}' | json_canonical)"
  fi
}

# _config_field_default_notes <pkey> <report-json> — the three non-blocking
# reports (contract §2.8, §2.3), newline-joined, empty when there is nothing
# to report. Never a warning, never a refusal — mirrors role_notes.
_config_field_default_notes() {
  local pkey="$1" report="$2" out="" n i
  n="$(jq -r '.orphaned | length' <<< "${report}")"
  for ((i = 0; i < n; i++)); do
    local o kind type label
    o="$(jq -c ".orphaned[${i}]" <<< "${report}")"
    kind="$(jq -r '.kind' <<< "${o}")"
    type="$(jq -r '.type' <<< "${o}")"
    if [[ "${kind}" == "orphaned_type" ]]; then
      out="${out}${out:+$'\n'}config: project ${pkey}: field_defaults records issue type '${type}', which the project no longer offers — remove it (orphaned entry, FR-008)"
    else
      label="$(jq -r '.label' <<< "${o}")"
      out="${out}${out:+$'\n'}config: project ${pkey}, type ${type}: field_defaults records '${label}', which the type no longer offers — remove it (orphaned entry, FR-008)"
    fi
  done
  n="$(jq -r '.not_yet_consumed | length' <<< "${report}")"
  for ((i = 0; i < n; i++)); do
    local type
    type="$(jq -r ".not_yet_consumed[${i}].type" <<< "${report}")"
    out="${out}${out:+$'\n'}config: project ${pkey}: field_defaults records issue type '${type}', which the bridge does not write yet — recorded, not yet consumed (FR-027)"
  done
  n="$(jq -r '.undefaultable_required | length' <<< "${report}")"
  for ((i = 0; i < n; i++)); do
    local u type label reason
    u="$(jq -c ".undefaultable_required[${i}]" <<< "${report}")"
    type="$(jq -r '.type' <<< "${u}")"
    label="$(jq -r '.label' <<< "${u}")"
    reason="$(jq -r '.reason' <<< "${u}")"
    out="${out}${out:+$'\n'}config: project ${pkey}, type ${type}: ${label} cannot be defaulted — ${reason} (the pre-existing mandatory-field refusal applies unchanged)"
  done
  n="$(jq -r '.pending | length' <<< "${report}")"
  for ((i = 0; i < n; i++)); do
    local q type label allowed
    q="$(jq -c ".pending[${i}]" <<< "${report}")"
    type="$(jq -r '.type' <<< "${q}")"
    label="$(jq -r '.label' <<< "${q}")"
    allowed="$(jq -r '.allowed_values | join(", ")' <<< "${q}")"
    if [[ -n "${allowed}" ]]; then
      out="${out}${out:+$'\n'}config: project ${pkey}, type ${type} requires a value for ${label} — choose one of: ${allowed} (answer with --field-default '${pkey}=${type}=${label}=<value>')"
    else
      out="${out}${out:+$'\n'}config: project ${pkey}, type ${type} requires a value for ${label} (answer with --field-default '${pkey}=${type}=${label}=<value>')"
    fi
  done
  printf '%s' "${out}"
}

# Marker tokens for the field_defaults managed region (011, T044). Substrings,
# not full lines — mirrors README_BLOCK_BEGIN_TOKEN's convention.
_CONFIG_FIELD_DEFAULTS_BEGIN='# --- spec-kit-jira:field_defaults:begin ---'
_CONFIG_FIELD_DEFAULTS_END='# --- spec-kit-jira:field_defaults:end ---'

# _config_field_defaults_block <map-json> — the region's full text (markers
# included), no trailing newline (mirrors readme_block_render).
_config_field_defaults_block() {
  local map="${1:-}"
  [[ -z "${map}" ]] && map='{}'
  local yaml
  yaml="$(config_field_defaults_yaml "${map}")" || return $?
  cat <<BLOCK
${_CONFIG_FIELD_DEFAULTS_BEGIN}
# Recorded defaults for custom fields on ticket creation (011), written by
# \`/speckit.jira.config\`. Edit a value here by hand if you like — keep it
# between these markers; an entry outside them is a duplicate top-level key
# and the next read refuses it (exit 4).
${yaml}
${_CONFIG_FIELD_DEFAULTS_END}
BLOCK
}

# _config_field_defaults_write <config.yml-path> <map-json> <dry_run> —
# splice the resolved field_defaults map into the team config through the
# existing managed_section_splice (research R1), mirroring readme_block_write.
# Prints a status token (created|written|unchanged|refused|inert) and returns
# 0, or EXIT_CONFIG (4) on malformed markers (zero writes). `inert` (research
# R6, FR-028): an empty map and a file that has never carried the region are
# left completely untouched — the key is never introduced for a team that has
# recorded nothing.
_config_field_defaults_write() {
  local path="$1" map="${2:-}" dry="${3:-false}"
  [[ -z "${map}" ]] && map='{}'

  local current="" existed="false"
  if [[ -f "${path}" ]]; then
    existed="true"
    current="$(cat "${path}"; printf x)"; current="${current%x}"
  fi

  if [[ "$(jq -r 'length' <<< "${map}")" -eq 0 && "${current}" != *"${_CONFIG_FIELD_DEFAULTS_BEGIN}"* ]]; then
    printf 'inert'
    return 0
  fi

  local block
  block="$(_config_field_defaults_block "${map}")" || return $?

  local tmp
  tmp="$(mktemp)"
  if ! printf '%s' "${current}" | managed_section_splice \
      "${_CONFIG_FIELD_DEFAULTS_BEGIN}" "${_CONFIG_FIELD_DEFAULTS_END}" "${block}" > "${tmp}"; then
    rm -f "${tmp}"
    printf 'refused'
    return "${EXIT_CONFIG}"
  fi

  local status
  if [[ "${existed}" == "true" ]] && cmp -s "${tmp}" "${path}"; then
    status="unchanged"
  elif [[ "${existed}" == "false" ]]; then
    status="created"
  else
    status="written"
  fi

  if [[ "${dry}" != "true" && "${status}" != "unchanged" ]]; then
    mv "${tmp}" "${path}"
  else
    rm -f "${tmp}"
  fi
  printf '%s' "${status}"
  return 0
}

# Marker tokens for the task_mirror managed region (022, contract §3).
# Substrings, not full lines — mirrors _CONFIG_FIELD_DEFAULTS_BEGIN's
# convention.
_CONFIG_TASK_MIRROR_BEGIN='# --- spec-kit-jira:task_mirror:begin ---'
_CONFIG_TASK_MIRROR_END='# --- spec-kit-jira:task_mirror:end ---'

# _config_task_mirror_block <map-json> — the region's full text (markers
# included), no trailing newline. Mirrors _config_field_defaults_block.
_config_task_mirror_block() {
  local map="${1:-}"
  [[ -z "${map}" ]] && map='{}'
  local yaml
  yaml="$(config_task_mirror_yaml "${map}")" || return $?
  cat <<BLOCK
${_CONFIG_TASK_MIRROR_BEGIN}
# How each project's task list reaches Jira (022), written by
# \`/speckit.jira.config\`. \`subtask\` creates one sub-task per task;
# \`checklist\` writes one checklist into each story instead. Edit a value
# here by hand if you like — keep it between these markers; an entry outside
# them is a duplicate top-level key and the next read refuses it (exit 4).
${yaml}
${_CONFIG_TASK_MIRROR_END}
BLOCK
}

# _config_task_mirror_write <config.yml-path> <map-json> <dry_run> — splice
# the resolved task_mirror map into the team config through the existing
# managed_section_splice, mirroring _config_field_defaults_write exactly.
# Prints a status token (created|written|unchanged|refused|inert) and
# returns 0, or EXIT_CONFIG (4) on malformed markers (zero writes). `inert`:
# an empty map and a file that has never carried the region are left
# completely untouched — the key is never introduced for a team that has
# recorded nothing (FR-002, FR-011).
_config_task_mirror_write() {
  local path="$1" map="${2:-}" dry="${3:-false}"
  [[ -z "${map}" ]] && map='{}'

  local current="" existed="false"
  if [[ -f "${path}" ]]; then
    existed="true"
    current="$(cat "${path}"; printf x)"; current="${current%x}"
  fi

  if [[ "$(jq -r 'length' <<< "${map}")" -eq 0 && "${current}" != *"${_CONFIG_TASK_MIRROR_BEGIN}"* ]]; then
    printf 'inert'
    return 0
  fi

  local block
  block="$(_config_task_mirror_block "${map}")" || return $?

  local tmp
  tmp="$(mktemp)"
  if ! printf '%s' "${current}" | managed_section_splice \
      "${_CONFIG_TASK_MIRROR_BEGIN}" "${_CONFIG_TASK_MIRROR_END}" "${block}" > "${tmp}"; then
    rm -f "${tmp}"
    printf 'refused'
    return "${EXIT_CONFIG}"
  fi

  local status
  if [[ "${existed}" == "true" ]] && cmp -s "${tmp}" "${path}"; then
    status="unchanged"
  elif [[ "${existed}" == "false" ]]; then
    status="created"
  else
    status="written"
  fi

  if [[ "${dry}" != "true" && "${status}" != "unchanged" ]]; then
    mv "${tmp}" "${path}"
  else
    rm -f "${tmp}"
  fi
  printf '%s' "${status}"
  return 0
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
    # Strip CR before probing so a CRLF .gitignore (core.autocrlf checkouts)
    # matches like the PowerShell twin's `r?`n split — otherwise every run
    # re-appends the three lines forever (FR-019 idempotency).
    local content
    content="$(tr -d '\r' < "${gi}" 2> /dev/null || true)"
    local -a missing=()
    local l
    for l in "${lines[@]}"; do
      grep -qxF "${l}" <<< "${content}" || missing+=("${l}")
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

# =============================================================================
# The hooks effect (003 US6, FR-021 – FR-025, FR-028, FR-029)
# =============================================================================

# The three values _config_hooks_effect produces: a status token, a prose detail,
# and the health object the run summary carries.
#
# They are returned through globals, and the function MUST NOT be invoked through
# command substitution: a subshell would compute all three and then discard them
# with the subshell itself. That is the same trap lib/config.sh documents for its
# recursive parsers, and it produced a silently empty hook_health here first.
_CONFIG_HOOKS_STATUS=''
_CONFIG_HOOKS_DETAIL=''
_CONFIG_HOOKS_HEALTH='{}'

# _config_hooks_effect <registry-path> <config-dir> <dry-run> <enable-hooks>
# Read the hook registry, classify every declared event, record what needs
# recording in OUR file, and set _CONFIG_HOOKS_STATUS / _CONFIG_HOOKS_DETAIL /
# _CONFIG_HOOKS_HEALTH. Call it DIRECTLY, never in `$(...)`. The registry itself is never
# opened for writing — in any state, including this one (FR-022).
#
# Two writes happen here, and both are to the gitignored local binding, never to
# the registry:
#   * an entry the registry shows as `enabled: false` is RECORDED, so the
#     operator's decision survives the next `specify extension add`, which
#     rewrites `enabled: true` unconditionally (research R5 step 1);
#   * each `--enable-hook <event>` clears one recorded event (FR-029).
# The health classification itself writes nothing anywhere; the ceremony performs
# the write, on the same terms as its other writes — predicted by --dry-run,
# never performed by it (Constitution XI).
_config_hooks_effect() {
  local ext_path="$1" configdir="$2" dry_run="$3" enable_hooks="$4"
  local health event

  # The operator's explicit releases come FIRST, so a release and the report that
  # names it cannot disagree within one run.
  local released=""
  for event in ${enable_hooks}; do
    [[ -z "${event}" ]] && continue
    local status
    status="$(config_hooks_disabled_remove "${event}" "${configdir}" "${dry_run}")"
    [[ "${status}" == "released" ]] && released="${released}${released:+, }${event}"
  done

  # The reader returns EXIT_CONFIG for an unreadable registry, which is a
  # REPORT here rather than a failure — `|| true` keeps it from aborting the run
  # under the dispatcher's `set -e`, and the `unreadable` flag below is what the
  # branch actually keys on.
  health="$(register_hooks_health "${ext_path}" "$(config_hooks_disabled_read "${configdir}" 2> /dev/null)")" || true

  if [[ "$(jq -r '.unreadable // false' <<< "${health}")" == "true" ]]; then
    _CONFIG_HOOKS_HEALTH="${health}"
    _CONFIG_HOOKS_DETAIL="$(jq -r '.repair_hint' <<< "${health}")"
    _CONFIG_HOOKS_STATUS='unreadable'
    return 0
  fi

  # Record every entry the registry shows as disabled. This is the capture the
  # whole disable record depends on: the extension only ever learns of the
  # operator's decision by reading the file, and the next install erases the
  # evidence (data-model § Operator disable record, Capture window).
  while IFS= read -r event; do
    [[ -z "${event}" ]] && continue
    config_hooks_disabled_add "${event}" "${configdir}" "${dry_run}" > /dev/null
  done <<< "$(jq -r '.disabled[]?' <<< "${health}")"

  # Re-read so the reported health reflects what this run just recorded.
  health="$(register_hooks_health "${ext_path}" "$(config_hooks_disabled_read "${configdir}" 2> /dev/null)")" || true
  _CONFIG_HOOKS_HEALTH="${health}"

  local n_missing n_dup n_held hint
  n_missing="$(jq -r '.missing | length' <<< "${health}")"
  n_dup="$(jq -r '.duplicated | length' <<< "${health}")"
  n_held="$(jq -r '(.disabled + .held_disabled) | unique | length' <<< "${health}")"
  hint="$(jq -r '.repair_hint // ""' <<< "${health}")"

  # One status token, chosen by severity: a missing entry means the mirror is not
  # wired at all, a leftover means the next install will duplicate it, and a held
  # event is a deliberate operator choice rather than a fault. The detail carries
  # every applicable clause, so nothing is hidden by the precedence.
  local status
  if ((n_missing > 0)); then
    status="incomplete"
  elif ((n_dup > 0)); then
    status="duplicated"
  elif ((n_held > 0)); then
    status="held_disabled"
  else
    status="healthy"
  fi

  local detail
  case "${status}" in
    healthy) detail="all seven lifecycle hooks present and enabled; the registry was not modified" ;;
    *) detail="${hint}" ;;
  esac
  [[ -n "${released}" ]] && detail="${detail}; released: ${released}"
  _CONFIG_HOOKS_DETAIL="${detail}"
  _CONFIG_HOOKS_STATUS="${status}"
}

# cmd_config <argv...> — the deterministic install ceremony (US1). Echoes the run
# summary to stdout and returns the exit code.
cmd_config() {
  # Parse flags (config-read, no model judgement). The dispatcher already handled
  # --help; re-parse here so the command is runnable standalone.
  local parsed json="false" dry_run="false" exit_code="0" error="" styles="" args="" enable_hooks="" issue_types=""
  local field_defaults=""
  local task_mirrors=""
  parsed="$(cli_parse "$@")"
  while IFS='=' read -r key value; do
    case "${key}" in
      json) json="${value}" ;;
      dry_run) dry_run="${value}" ;;
      styles) styles="${value}" ;;
      issue_types) issue_types="${value}" ;;
      enable_hooks) enable_hooks="${value}" ;;
      field_defaults) field_defaults="${value}" ;;
      task_mirrors) task_mirrors="${value}" ;;
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

  # Hooks effect (003 US6): computed UP FRONT, because it needs no Jira and no
  # committed config — it reads the registry and the local binding, and nothing
  # else. Computing it here means the report is truthful in the degraded run too,
  # and that `--enable-hook` works in a repository that is not yet connected,
  # which is exactly where an operator is most likely to reach for it.
  local ext_path hooks_status hooks_detail hooks_health
  ext_path="${SPEC_KIT_JIRA_EXTENSIONS_YML:-$(dirname "${configdir}")/extensions.yml}"
  _config_hooks_effect "${ext_path}" "${configdir}" "${dry_run}" "${enable_hooks}"
  hooks_status="${_CONFIG_HOOKS_STATUS}"
  hooks_health="${_CONFIG_HOOKS_HEALTH}"
  hooks_detail="${_CONFIG_HOOKS_DETAIL}"

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
    _config_degraded_run "${json}" "${dry_run}" "${degraded_missing}" \
      "${hooks_status}" "${hooks_detail}"
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
      printf 'config: accessible projects (closed question — choose one and re-run: %s):\n' \
        "$(output_bridge_invocation 'config <KEY>')"
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
  local proj_roles='{}' role_notes="" proj_field_defaults='{}' fd_notes=""
  local proj_task_mirror='{}' tm_notes=""
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

    # Role mapping (010, contracts/role-mapping.md): one resolver call per
    # project, over all three roles — declared -> operator -> derived,
    # evaluating every role before refusing (contract §3.2). Replaces the
    # two separate 008 calls (hierarchy_derive then _config_resolve_child_type)
    # that made the specification tier's refusal hide the story tier's
    # (research R1).
    local itypes declared_h operator_h resolve_result
    itypes="$(jq -c '.issue_types // []' <<< "${binding}")"
    declared_h="$(_config_declared_hierarchy_for "${pkey}" "${cfg}")"
    operator_h="$(_config_operator_roles_for "${pkey}" "${issue_types}")"
    resolve_result="$(role_resolve "${pkey}" "${itypes}" "${declared_h}" "${operator_h}")"
    if [[ "$(role_has_problems "${resolve_result}")" == "true" ]]; then
      _config_report_role_problems "${pkey}" "${resolve_result}" "${json}"
      return "${EXIT_CONFIG}"
    fi

    local roles ordering_msg
    roles="$(jq -c '.roles' <<< "${resolve_result}")"
    if ! ordering_msg="$(role_validate "${pkey}" "${roles}")"; then
      printf '%s\n' "${ordering_msg}" >&2
      return "${EXIT_CONFIG}"
    fi

    # Task-mirror ceremony (022, contract §5/§6): resolve this project's
    # effective value (this run's --task-mirror answer, else whatever is
    # already recorded), report the closed question when nothing ends up
    # recorded, the FR-012 remedy when 'subtask' has no resolvable sub-task
    # type, and the per-project effect line — always, in every case.
    local tm_recorded tm_flag tm_effective tm_status
    tm_recorded="$(config_task_mirror_for "${pkey}" "${cfg}")"
    tm_flag="$(_config_task_mirror_flag_for "${pkey}" "${task_mirrors}")"
    tm_effective="${tm_flag:-${tm_recorded}}"
    if [[ -z "${tm_effective}" ]]; then
      tm_notes="${tm_notes}${tm_notes:+$'\n'}$(_config_task_mirror_question "${pkey}")"
    fi
    if [[ "${tm_effective}" == "subtask" ]]; then
      local tm_task_role_id
      tm_task_role_id="$(jq -r '.task.id // empty' <<< "${roles}")"
      if [[ -z "${tm_task_role_id}" ]]; then
        tm_notes="${tm_notes}${tm_notes:+$'\n'}$(_config_task_mirror_fr012_note "${pkey}")"
      fi
    fi
    if [[ -n "${tm_effective}" ]]; then
      if [[ "${tm_effective}" != "${tm_recorded}" ]]; then tm_status="recorded"; else tm_status="unchanged"; fi
      proj_task_mirror="$(jq -c --arg k "${pkey}" --arg v "${tm_effective}" '. + {($k): $v}' <<< "${proj_task_mirror}")"
    else
      tm_status=""
    fi
    tm_notes="${tm_notes}${tm_notes:+$'\n'}$(_config_task_mirror_effect_line "${pkey}" "${tm_effective}" "${tm_status}")"

    # Fetch required_fields / parent_link_available for every role id the
    # resolver selected that the initial discovery did not already cover
    # (T050/T051) — the ordinary case once a mapping is declared or
    # answered rather than derived from a single-candidate level.
    local rf_map pla_map df_map role_key role_id type_meta
    rf_map="$(jq -c '.required_fields // {}' <<< "${rids}")"
    pla_map="$(jq -c '.parent_link_available // {}' <<< "${rids}")"
    df_map="$(jq -c '.defaultable_fields // {}' <<< "${rids}")"
    for role_key in "${JIRA_ROLE_NAMES[@]}"; do
      role_id="$(jq -r --arg r "${role_key}" '.[$r].id // empty' <<< "${roles}")"
      [[ -z "${role_id}" ]] && continue
      [[ "$(jq -r --arg t "${role_id}" 'has($t)' <<< "${rf_map}")" == "true" ]] && continue
      type_meta="$(discovery_type_metadata "${pkey}" "${role_id}")" || return $?
      rf_map="$(jq -c --arg t "${role_id}" --argjson m "$(jq -c '.required_fields' <<< "${type_meta}")" '. + {($t): $m}' <<< "${rf_map}")"
      pla_map="$(jq -c --arg t "${role_id}" --argjson h "$(jq -c '.parent_link_available' <<< "${type_meta}")" '. + {($t): $h}' <<< "${pla_map}")"
      df_map="$(jq -c --arg t "${role_id}" --argjson m "$(jq -c '.defaultable_fields' <<< "${type_meta}")" '. + {($t): $m}' <<< "${df_map}")"
    done

    rids="$(jq -c --argjson roles "${roles}" --argjson rf "${rf_map}" --argjson pla "${pla_map}" --argjson df "${df_map}" \
      '. + {roles: $roles, required_fields: $rf, parent_link_available: $pla}
       + (if ($df|length) > 0 then {defaultable_fields: $df} else {} end)
       + (if ($roles.story) then {child_type: ($roles.story | {logical_name, id, source})} else {} end)
       + (if ($roles.specification) then {parent_type: ($roles.specification | {logical_name, id, source})} else {} end)' \
      <<< "${rids}")"

    # Field-defaults ceremony (011, contract §2): validate this run's
    # --field-default answers for this project (§2.4), merge them with the
    # project's recorded entry (§2.6), ask about any required+defaultable
    # field of an in-scope type still unanswered (§2.1-§2.3, research R4 —
    # the script refuses, the agent asks, the agent re-invokes), and collect
    # the three non-blocking reports (§2.8). In scope: the specification and
    # story roles, plus any type an answer names this run (FR-026).
    local fd_answers fd_recorded fd_problems
    fd_answers="$(_config_field_answers_for "${pkey}" "${field_defaults}")"
    fd_recorded="$(config_field_defaults_for "${pkey}" "${cfg}")"
    fd_problems="$(_config_field_default_answer_problems "${itypes}" "${df_map}" "${fd_answers}")"
    if [[ "$(jq -r 'length' <<< "${fd_problems}")" -gt 0 ]]; then
      _config_report_field_default_problems "${pkey}" "${fd_problems}" "${json}"
      return "${EXIT_CONFIG}"
    fi

    local fd_merged fd_ask_types fd_bridge_ids fd_report
    fd_merged="$(_config_field_default_merge "${fd_recorded}" "${fd_answers}")"
    # 012: the task role joins the specification and story types on the
    # same closed-question terms — a declared sub-task role's own required
    # field is asked about too (FR-035).
    fd_ask_types="$(jq -cn --argjson roles "${roles}" --argjson ans "${fd_answers}" \
      '([$roles.specification, $roles.story, $roles.task] | map(select(. != null) | .logical_name)) + [$ans[].type] | unique')"
    # 012: the task role joins the bridge-written set now that the tier
    # ships — a recorded field default for the sub-task type is consumed,
    # not merely recorded (FR-012).
    fd_bridge_ids="$(jq -cn --argjson roles "${roles}" '[$roles.specification, $roles.story, $roles.task] | map(select(. != null) | .id)')"
    fd_report="$(_config_field_default_report "${itypes}" "${df_map}" "${fd_ask_types}" "${fd_merged}" "${fd_bridge_ids}")"
    # 015, research R5, contract §6.3: a recorded value outside its field's
    # allowed_values refuses HERE, at configuration time — the whole point of
    # US4 is that this check no longer waits for a hook to fire mid-task.
    # Reuses the flag path's own "outside_allowed" message and exit code
    # (`_config_report_field_default_problems`), so a refusal from the file
    # is indistinguishable from one from a flag; the recorded value itself
    # never reaches the message or any structured output. Zero writes: this
    # runs before the loop's own config.yml/local.yml write, below.
    local fd_outside_allowed
    fd_outside_allowed="$(jq -cn --argjson r "${fd_report}" '[$r.outside_allowed[] | . + {kind:"outside_allowed"}]')"
    if [[ "$(jq -r 'length' <<< "${fd_outside_allowed}")" -gt 0 ]]; then
      _config_report_field_default_problems "${pkey}" "${fd_outside_allowed}" "${json}"
      return "${EXIT_CONFIG}"
    fi
    # A pending question (contract §6: "consolidated question pending | 0 —
    # not a failure") is NON-BLOCKING at config time: the ceremony's role is
    # discovery and recording, not gating a creation. Whether the run can
    # still be reached at all is what Phase 4's reconcile-time gate (US2/US3,
    # contract §3.3/§3.6) judges, over the discovered defaultable_fields this
    # run persists regardless of what remains unanswered — FR-013/FR-028
    # would otherwise be unreachable, since reconcile could never see a
    # modern binding with an unresolved required field if config refused
    # before ever writing one. `_config_field_default_notes` reports every
    # pending field by its remedy line, folded in below.
    fd_notes="${fd_notes}${fd_notes:+$'\n'}$(_config_field_default_notes "${pkey}" "${fd_report}")"
    # Absence is the off switch (research R6, FR-028): a project with
    # nothing recorded and no this-run answer must never gain a bare
    # {ask: true} entry it never had — that would introduce the key for
    # every team that has not touched this feature. A project that ALREADY
    # carries an entry is carried forward even if the merge is now empty
    # (an operator's hand-edit removing the last field, §5.2).
    if [[ "$(jq -r 'length' <<< "${fd_merged}")" -gt 0 || "$(jq -r --arg k "${pkey}" '(.field_defaults // {}) | has($k)' <<< "${cfg}")" == "true" ]]; then
      proj_field_defaults="$(jq -c --arg k "${pkey}" --argjson ask "$(jq -c '.ask' <<< "${fd_recorded}")" --argjson m "${fd_merged}" \
        '. + {($k): ({ask: $ask} + $m)}' <<< "${proj_field_defaults}")"
    fi

    # Mandatory-field / parent-link gate, pulled to configuration time
    # (T050/T051, contract §4 checks 5/6): the same existing gate, run over
    # the roles this mapping just selected — including one derivation would
    # never have chosen. (011, research R5): a field with a recorded default
    # or a this-run answer is now satisfiable; a required field whose shape
    # cannot be defaulted still refuses here, unchanged (US3 scenario 3).
    local fd_defaults_by_type gate_result gate_status
    fd_defaults_by_type="$(plan_resolve_field_defaults "${itypes}" "${df_map}" "${fd_merged}" '[]' | jq -c '.field_defaults')"
    gate_result="$(hierarchy_mandatory_gate "${rids}" "${pkey}" "${fd_defaults_by_type}")"
    gate_status="$(jq -r '.status' <<< "${gate_result}")"
    if [[ "${gate_status}" != "ok" ]]; then
      jq -r '.message' <<< "${gate_result}" >&2
      return "${EXIT_CONFIG}"
    fi

    # §7.2/§7.3 notes: supersession (a committed declaration overriding a
    # recorded operator answer) and promotion (any role resolved from an
    # operator answer this run). §7.4's "task recorded, not yet mirrored"
    # status line stopped firing (012, FR-012): the task tier ships now.
    local prior_roles
    prior_roles="$(jq -c --arg k "${pkey}" '.resolved_ids[$k].roles // {}' <<< "${existing}")"
    for role_key in "${JIRA_ROLE_NAMES[@]}"; do
      local new_source new_name prior_source prior_name
      new_source="$(jq -r --arg r "${role_key}" '.[$r].source // empty' <<< "${roles}")"
      [[ -z "${new_source}" ]] && continue
      new_name="$(jq -r --arg r "${role_key}" '.[$r].logical_name' <<< "${roles}")"
      if [[ "${new_source}" == "declared" ]]; then
        prior_source="$(jq -r --arg r "${role_key}" '.[$r].source // empty' <<< "${prior_roles}")"
        if [[ "${prior_source}" == "operator" ]]; then
          prior_name="$(jq -r --arg r "${role_key}" '.[$r].logical_name // empty' <<< "${prior_roles}")"
          if [[ "${prior_name}" != "${new_name}" ]]; then
            role_notes="${role_notes}${role_notes:+$'\n'}$(role_supersession_note "${pkey}" "${role_key}" "${new_name}" "${prior_name}")"
          fi
        fi
      fi
      if [[ "${new_source}" == "operator" ]]; then
        role_notes="${role_notes}${role_notes:+$'\n'}$(role_promotion_note "${pkey}" "${role_key}" "${new_name}")"
      fi
    done
    proj_roles="$(jq -c --arg k "${pkey}" --argjson r "${roles}" '. + {($k): $r}' <<< "${proj_roles}")"

    resolved="$(jq -c --arg k "${pkey}" --argjson r "${rids}" '. + {($k): $r}' <<< "${resolved}")"
    proj_styles="$(jq -c --arg k "${pkey}" --arg s "${style}" --arg src "${style_source}" \
      '. + {($k): {style: $s, style_source: $src}}' <<< "${proj_styles}")"
    nproj=$((nproj + 1))
  done <<< "${keys}"

  # The three non-blocking field-defaults reports (§2.8, §2.3): never a
  # warning, never a refusal — printed alongside the role notes.
  [[ -n "${fd_notes}" ]] && printf '%s\n' "${fd_notes}" >&2

  # Field-defaults write (011, T042/T044): the union of every processed
  # project's resolved entry, overlaid onto whatever the committed config
  # already held for OTHER projects this run did not touch — a run over one
  # project never erases another project's recorded defaults. Absence is the
  # off switch (research R6, FR-028): `_config_field_defaults_write` never
  # introduces the key when there is nothing to record and the region has
  # never existed.
  local fd_all fd_write_status
  fd_all="$(jq -cn --argjson base "$(jq -c '.field_defaults // {}' <<< "${cfg}")" --argjson upd "${proj_field_defaults}" '$base + $upd')"
  fd_write_status="$(_config_field_defaults_write "${configdir}/config.yml" "${fd_all}" "${dry_run}")" || return $?

  # The task-mirror ceremony's per-project notes (022, contract §5/§6):
  # never a warning, never a refusal — printed alongside the field-defaults
  # and role notes.
  [[ -n "${tm_notes}" ]] && printf '%s\n' "${tm_notes}" >&2

  # Task-mirror write (022, contract §3): the union of every processed
  # project's resolved value, overlaid onto whatever the committed config
  # already held for OTHER projects this run did not touch. Absence is the
  # off switch (FR-002, FR-011): `_config_task_mirror_write` never
  # introduces the key when there is nothing to record and the region has
  # never existed.
  local tm_all tm_write_status
  tm_all="$(jq -cn --argjson base "$(jq -c '.task_mirror // {}' <<< "${cfg}")" --argjson upd "${proj_task_mirror}" '$base + $upd')"
  tm_write_status="$(_config_task_mirror_write "${configdir}/config.yml" "${tm_all}" "${dry_run}")" || return $?

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

  # Build the three-effect summary (FR-054): discovery, hooks, and README are each
  # reported as a distinct section so the operator sees exactly what was written.
  # The per-role provenance audit (010, contract §7.1) merges into each
  # project's discovery entry — `<role>: <logical_name> (<source>)` in prose,
  # `{"roles":{...}}` in --json.
  local dp
  dp="$(jq -cS --argjson roles "${proj_roles}" '
    . as $styles
    | reduce ($roles|keys[]) as $k ($styles;
        .[$k] = (.[$k] // {}) + {roles: ($roles[$k] | with_entries(.value |= {logical_name, source}))})
  ' <<< "${proj_styles}")"
  local effects
  effects="$(jq -cn \
    --arg ds "${disc_status}" --arg dd "${nproj} project(s) discovered" \
    --argjson dp "${dp}" \
    --arg hs "${hooks_status}" --arg hd "${hooks_detail}" \
    --arg rs "${readme_status}" --arg rd "${readme_detail}" \
    --arg gs "${gitignore_status}" \
    --arg fs "${fd_write_status}" \
    --arg tms "${tm_write_status}" '
    {
      discovery: {status: $ds, detail: $dd, projects: $dp},
      hooks:     {status: $hs, detail: $hd},
      readme:    {status: $rs, detail: $rd},
      gitignore: {status: $gs, detail: "personal.yml gitignore coverage"},
      field_defaults: {status: $fs, detail: "recorded field defaults in config.yml"},
      task_mirror: {status: $tms, detail: "recorded task mirror mode in config.yml"}
    }')"

  # §7.2/§7.3 notes (supersession, promotion): never a warning, never a
  # non-zero exit — the run succeeded.
  [[ -n "${role_notes}" ]] && printf '%s\n' "${role_notes}" >&2

  local summary
  summary="$(jq -cn --argjson effects "${effects}" --argjson dry "${dry_run}" --argjson w "${run_warnings}" \
    --argjson hooks "${hooks_health}" '
    {schema_version: "1.0", command: "config", dry_run: $dry,
     counts: {created: 0, updated: 0, skipped: 0, warnings: $w, errors: 0},
     effects: $effects, hook_health: $hooks, exit_code: 0}' | json_canonical)"

  if [[ "${json}" == "true" ]]; then
    printf '%s\n' "${summary}"
  else
    printf '%s' "${summary}" | summary_render_prose
  fi
  return 0
}
