#!/usr/bin/env bats
# T016 — Run-summary rendering: prose default + --json (run-summary.schema.json),
# plus the WARNING channel. Byte-identical across ports (Constitution VI).

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  LIB_DIR="${ROOT}/scripts/bash/lib"
  PS_LIB="${ROOT}/scripts/powershell/lib"
  SCHEMA="${ROOT}/specs/001-jira-reconcile-engine/contracts/run-summary.schema.json"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/output.sh"
}

@test "summary_build_json emits canonical JSON with required keys" {
  run summary_build_json reconcile false 1 2 0 0 0 0
  echo "$output" | jq -e '.schema_version=="1.0" and .command=="reconcile" and .counts.created==1 and .counts.updated==2 and .exit_code==0' > /dev/null
}

@test "summary_build_json validates against run-summary.schema.json (oracle, if available)" {
  json="$(summary_build_json reconcile true 3 0 1 0 0 0)"
  if command -v jsonschema > /dev/null 2>&1; then
    printf '%s' "$json" | jsonschema --instance /dev/stdin "$SCHEMA"
  else
    skip "jsonschema CLI not available"
  fi
}

@test "summary_build_json keys are sorted (canonical)" {
  json="$(summary_build_json config false 0 0 0 0 0 0)"
  # First key after '{' must be 'command' (sorted before 'counts','dry_run','exit_code','schema_version')
  [[ "$json" == '{"command":'* ]]
}

@test "summary_render_prose shows counts and exit" {
  json="$(summary_build_json reconcile false 1 2 3 0 0 0)"
  run bash -c "printf '%s' '$json' | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [[ "$output" == *"reconcile"* ]]
  [[ "$output" == *"Created: 1"* ]]
  [[ "$output" == *"Updated: 2"* ]]
  [[ "$output" == *"Exit: 0"* ]]
}

@test "output_warn writes to the WARNING channel on stderr" {
  run bash -c "source '${LIB_DIR}/output.sh'; output_warn 'a thing happened' 2>&1 1>/dev/null"
  [[ "$output" == "WARNING: a thing happened" ]]
}

@test "summary JSON is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  bash_out="$(summary_build_json reconcile true 2 1 0 1 0 2)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((New-JiraSummaryJson -Command reconcile -DryRun \$true -Created 2 -Updated 1 -Skipped 0 -Warnings 1 -Errors 0 -ExitCode 2))")"
  [ "$bash_out" = "$ps_out" ]
}

@test "prose is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  json="$(summary_build_json config false 0 0 0 0 0 0)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}

# T098 — the per-project style audit (FR-003) lives at
# effects.discovery.projects.<KEY>.{style,style_source}. It must reach the
# DEFAULT output, not only --json: prose is the default rendering.

style_audit_json() {
  # Two projects, deliberately declared out of order, so the renderer's own
  # ordering (project key, ordinal) is what is asserted.
  printf '%s' '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":0},"dry_run":false,"effects":{"discovery":{"detail":"2 project(s) discovered","projects":{"WEX":{"style":"company_managed","style_source":"operator"},"IJT":{"style":"team_managed","style_source":"api"}},"status":"written"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"unchanged"},"readme":{"detail":"block present","status":"unchanged"}},"exit_code":0,"schema_version":"1.0"}'
}

line_of() {
  # line_of <needle> — 1-based line number of the first match in $output
  printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1
}

@test "prose renders the per-project style audit under the discovery effect (T098)" {
  run bash -c "$(declare -f style_audit_json); style_audit_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"    IJT: team_managed (api)"* ]]
  [[ "$output" == *"    WEX: company_managed (operator)"* ]]
}

@test "the style audit is nested under discovery and ordered by project key (T098)" {
  run bash -c "$(declare -f style_audit_json); style_audit_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  disc_ln="$(line_of '  discovery: ')"
  ijt_ln="$(line_of 'IJT: ')"
  wex_ln="$(line_of 'WEX: ')"
  # The boundary marker is the NEXT effect in the renderer's fixed order. It
  # was `hooks` until 034 removed that effect; `readme` now follows discovery.
  next_ln="$(line_of '  readme: ')"
  # discovery < IJT < WEX < readme: ordinal key order, inside the discovery block.
  [ "$disc_ln" -lt "$ijt_ln" ]
  [ "$ijt_ln" -lt "$wex_ln" ]
  [ "$wex_ln" -lt "$next_ln" ]
}

@test "an empty projects map adds no style-audit lines (degraded run) (T098)" {
  json='{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":1},"dry_run":false,"effects":{"discovery":{"detail":"0 project(s) discovered","projects":{},"status":"skipped"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"skipped"}},"exit_code":0,"schema_version":"1.0"}'
  run bash -c "printf '%s' '$json' | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^    ')" -eq 0 ]
}

@test "the style-audit prose is byte-identical across ports (T098)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  json="$(style_audit_json)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}

# --- T083 [Phase 9] — the §7.1 per-role audit, in prose (010) --------------

role_audit_json() {
  printf '%s' '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":0},"dry_run":false,"effects":{"discovery":{"detail":"1 project(s) discovered","projects":{"CONSUMER":{"style":"company_managed","style_source":"api","roles":{"specification":{"logical_name":"Epic","source":"declared"},"story":{"logical_name":"Tâche","source":"derived"},"task":{"logical_name":"Sous-tâche","source":"operator"}}}},"status":"written"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"unchanged"},"readme":{"detail":"block present","status":"unchanged"}},"exit_code":0,"schema_version":"1.0"}'
}

@test "prose renders one role-audit line per resolved role, under the project's style line (010, contract §7.1)" {
  run bash -c "$(declare -f role_audit_json); role_audit_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"specification: Epic (declared)"* ]]
  [[ "$output" == *"story: Tâche (derived)"* ]]
  [[ "$output" == *"task: Sous-tâche (operator)"* ]]
}

@test "the role-audit prose is byte-identical across ports, including non-ASCII names (010)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  json="$(role_audit_json)"
  bash_out="$(printf '%s' "$json" | summary_render_prose)"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse '$json'))")"
  [ "$bash_out" = "$ps_out" ]
}

# =============================================================================
# T054/T055 [Phase 7] — the run summary reports recognised/assigned/skipped
# (Phase 3/4/6), in both JSON and prose form.
# =============================================================================

_output_wrapper() {
  printf '%s' "$1" | summary_render_prose
}

@test "prose renders Recognised/Assigned when the summary carries them (reconcile)" {
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":3,"warnings":0,"errors":0,"recognised":3,"assigned":0},"actions":[],"hook_health":{},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recognised: 3, Assigned: 0"* ]]
  [[ "$output" == *"Skipped: 3"* ]]
}

@test "prose omits Recognised/Assigned for a command that never reports them (config)" {
  local json='{"schema_version":"1.0","command":"config","dry_run":false,"counts":{"created":0,"updated":0,"skipped":0,"warnings":0,"errors":0},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Recognised"* ]]
}

@test "the PowerShell port renders Recognised/Assigned identically (NFR-1)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":3,"warnings":0,"errors":0,"recognised":3,"assigned":0},"actions":[],"hook_health":{},"exit_code":0}'
  local b p
  b="$(printf '%s' "${json}" | summary_render_prose)"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Output.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json '${json}'))")"
  [ "${b}" = "${p}" ]
}

# =============================================================================
# T181 [Phase 14, Convergence] — counts.transitioned reaches the PROSE report
# too, not only --json (FR-037). Conditional presence mirrors counts.transitioned
# itself: present in the JSON, rendered; absent, no "Transitioned" line at all.
# =============================================================================

@test "prose renders Transitioned when the summary carries counts.transitioned" {
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":1,"skipped":0,"warnings":0,"errors":0,"transitioned":2},"actions":[],"hook_health":{},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Transitioned: 2"* ]]
}

@test "prose omits Transitioned when counts.transitioned is absent (no event, or no role declares a step)" {
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":0,"skipped":0,"warnings":0,"errors":0},"actions":[],"hook_health":{},"exit_code":0}'
  run _output_wrapper "${json}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Transitioned"* ]]
}

@test "the PowerShell port renders Transitioned identically (T181)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local json='{"schema_version":"1.0","command":"reconcile","dry_run":false,"counts":{"created":0,"updated":1,"skipped":0,"warnings":0,"errors":0,"transitioned":2},"actions":[],"hook_health":{},"exit_code":0}'
  local b p
  b="$(printf '%s' "${json}" | summary_render_prose)"
  p="$(pwsh -NoProfile -Command "
    Import-Module '${PS_LIB}/Output.psm1' -Force
    [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json '${json}'))")"
  [ "${b}" = "${p}" ]
}

# =============================================================================
# 034 T013 [US1] — the human `Effects:` renderer never names the hook registry
# (FR-002, FR-008).
# =============================================================================
#
# `summary_render_prose` is a THIRD consumer of the effects object, separate
# from the two that assert on the JSON, and it does not iterate the object's own
# keys — it walks a fixed list so both ports render byte-identically. A `hooks`
# entry left in that list survives every JSON-level assertion in the suite while
# still shipping the retired word in the port.
#
# It also degrades silently: the renderer skips an effect whose status is absent,
# so a stale entry in the list breaks nothing and shows nothing. That is exactly
# why it needs its own test rather than being left to the SC-006 grep.

effects_without_hooks_json() {
  printf '%s' '{"command":"config","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":0},"dry_run":false,"effects":{"discovery":{"detail":"2 project(s) discovered","status":"written"},"gitignore":{"detail":"personal.yml gitignore coverage","status":"unchanged"},"personal":{"detail":"per-operator file","status":"created"},"readme":{"detail":"block present","status":"unchanged"}},"exit_code":0,"schema_version":"1.0"}'
}

@test "034 — the prose Effects block renders every effect present and never the word hooks" {
  run bash -c "$(declare -f effects_without_hooks_json); effects_without_hooks_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  # Every effect the summary carries is rendered...
  [[ "$output" == *"  discovery: written"* ]]
  [[ "$output" == *"  readme: unchanged"* ]]
  [[ "$output" == *"  gitignore: unchanged"* ]]
  [[ "$output" == *"  personal: created"* ]]
  # ...and the retired one is not named at all, in any form.
  [[ "$output" != *"hooks"* ]]
}

@test "034 — the renderer's fixed effect list no longer contains hooks (FR-008)" {
  # The assertion above passes while `hooks` merely sits unused in the list,
  # because the renderer skips an absent status. This one reads the list itself,
  # which is the thing that must actually change.
  run grep -nE 'for effect in|foreach \(\$effect in' "${LIB_DIR}/output.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"hooks"* ]]
}

# T111 [036] — the artifact block reaches the DEFAULT output.
#
# `--json` carried `artifacts[]` from the day the feature shipped; prose carried
# nothing. A run that withheld three oversized artifacts printed
# `Warnings: 3, Errors: 0` and not one word about which files, why, or against
# what limit — so FR-021's "report, per artifact, whether it was published,
# unchanged, or skipped, and for a skip, the reason" and FR-017's "a named
# warning stating the artifact, its size and the limit" held only for a caller
# who passed `--json`. Prose is the DEFAULT rendering, and a human reading it is
# what Principle XVI is about.
#
# WHAT IS RENDERED, and why not everything. A counts line always, then one
# detail line per artifact that is NOT `unchanged`. The precedent is `actions`,
# which prose has never rendered: the arrays live in `--json`, the actionable
# summary lives in prose. Printing every `unchanged` entry would put forty lines
# of "nothing happened" on every zero-churn run of a forty-file folder, which is
# the opposite of readable — the tally reports them, and `--json` names them.

_artifacts_json() {
  printf '%s' '{"command":"reconcile","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":3},"dry_run":false,"exit_code":0,"schema_version":"1.0","artifacts":[
    {"action":"published","attachment_name":"research.md","hash":"aaa","path":"research.md"},
    {"action":"revised","attachment_name":"spec.md","hash":"bbb","path":"spec.md"},
    {"action":"unchanged","attachment_name":"plan.md","path":"plan.md"},
    {"action":"withheld","attachment_name":"assets__demo.mov","limit":10485760,"path":"assets/demo.mov","reason":"oversized","size":41943040},
    {"action":"withheld","attachment_name":"contracts__api.md","collides_with":"contracts__api.md","path":"checklists/api.md","reason":"name-collision"}
  ]}'
}

@test "T111 FR-021 prose reports the artifact tally" {
  run bash -c "$(declare -f _artifacts_json); _artifacts_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Artifacts: 1 published, 1 revised, 1 unchanged, 2 withheld"* ]]
}

@test "T111 FR-017 a withheld artifact names itself, its reason and the numbers" {
  run bash -c "$(declare -f _artifacts_json); _artifacts_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  # The size and the limit, both, because FR-017 names both.
  [[ "$output" == *"assets/demo.mov: withheld — oversized (41943040 bytes, limit 10485760)"* ]]
  # The collision names the OTHER path, which is the only thing an operator can
  # act on: one of the two has to be renamed.
  [[ "$output" == *"checklists/api.md: withheld — name-collision (collides with contracts__api.md)"* ]]
}

@test "T111 FR-021 published and revised are named; unchanged is left to the tally" {
  run bash -c "$(declare -f _artifacts_json); _artifacts_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [[ "$output" == *"research.md: published"* ]]
  [[ "$output" == *"spec.md: revised"* ]]
  # …and the forty-lines-of-nothing case does not happen.
  [[ "$output" != *"plan.md: unchanged"* ]]
}

@test "T111 a summary with no artifacts key renders exactly as it did before" {
  # Every pre-036 summary, and every run outside a feature directory, must be
  # byte-for-byte what it was.
  json="$(summary_build_json reconcile false 1 2 3 0 0 0)"
  run bash -c "printf '%s' '$json' | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [[ "$output" != *"Artifacts:"* ]]
}

@test "T111 the artifact block is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local json bash_out ps_out f
  json="$(_artifacts_json)"
  bash_out="$(printf '%s' "${json}" | summary_render_prose)"
  # Through a FILE, never the -Command string: this JSON carries the quote
  # characters two shells each want to interpret, and a mangled argument
  # produces an empty answer that reads exactly like a cross-port divergence.
  f="${BATS_TEST_TMPDIR}/summary.json"
  printf '%s' "${json}" > "${f}"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse ([System.IO.File]::ReadAllText('${f}'))))")"
  [ "${bash_out}" = "${ps_out}" ]
}

# T112 [036] — the publication's own warnings reach the DEFAULT output.
#
# MEASURED FIRST, because the task turned on it: the hook path DOES pass
# `--json` (commands/speckit.jira-mirror.reconcile.md instructs both ports to),
# so FR-018's "surface one actionable warning" was already met where it is
# about — a lifecycle hook. What was not met is the operator running the bridge
# by hand: after T111 they learn WHICH artifacts were withheld and under what
# category, and never that the fix for `upload-failed` is granting the token
# "Create attachments".
#
# Rendered from `artifact_warnings`, a key only the publication phase writes —
# NOT from the shared `warnings` array. That array is written by every feature
# since 021, and rendering it wholesale would change the default output of runs
# 036 never touched; a change that wide needs its own spec (Principle XV).

_artifact_warnings_json() {
  printf '%s' '{"command":"reconcile","counts":{"created":0,"errors":0,"skipped":0,"updated":0,"warnings":1},"dry_run":false,"exit_code":0,"schema_version":"1.0","artifacts":[
    {"action":"withheld","attachment_name":"spec.md","path":"spec.md","reason":"upload-failed"}
  ],"artifact_warnings":["reconcile: the feature artifacts could not be attached to COMP-1 — this Jira token lacks the \"Create attachments\" permission on that project"]}'
}

@test "T112 the publication warning text reaches prose, not only its count" {
  run bash -c "$(declare -f _artifact_warnings_json); _artifact_warnings_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Artifact warnings:"* ]]
  # The REMEDY is the part that only exists in the message — the artifacts
  # block above it already named the file and the category.
  [[ "$output" == *"Create attachments"* ]]
  [[ "$output" == *"COMP-1"* ]]
}

@test "T112 a summary with no artifact_warnings renders no such block" {
  run bash -c "$(declare -f _artifacts_json); _artifacts_json | { source '${LIB_DIR}/output.sh'; summary_render_prose; }"
  [[ "$output" != *"Artifact warnings:"* ]]
}

@test "T112 the artifact-warning block is byte-identical across ports" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local json bash_out ps_out f
  json="$(_artifact_warnings_json)"
  bash_out="$(printf '%s' "${json}" | summary_render_prose)"
  f="${BATS_TEST_TMPDIR}/warn-summary.json"
  printf '%s' "${json}" > "${f}"
  ps_out="$(pwsh -NoProfile -Command "Import-Module '${PS_LIB}/Output.psm1' -Force; [Console]::Out.Write((ConvertTo-JiraSummaryProse ([System.IO.File]::ReadAllText('${f}'))))")"
  [ "${bash_out}" = "${ps_out}" ]
}
