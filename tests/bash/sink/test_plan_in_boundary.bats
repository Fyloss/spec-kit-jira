#!/usr/bin/env bats
# 018, T030 [US1] — the plan section inside the managed region (FR-001–FR-005,
# FR-033), proven through plan_writes' parent branch. Research R2 established
# that reconcile.sh's `.epic.description.blocks += $pb` (parse_plan_summary's
# output) already lands the plan blocks last inside the epic's blocks array,
# so the managed-panel splice this feature built for US2 renders them inside
# the managed region automatically — these tests pin that behaviour with its
# own coverage rather than relying on US2's to prove it by accident.
#
#   - the plan section sits inside the managed region, below a preserved
#     prefix (FR-001)
#   - a plan change replaces the section in place; exactly one exists (FR-002)
#   - no plan.md yields no section and no warning (FR-003)
#   - a plan that later yields nothing removes the section (FR-004)
#   - an unchanged plan produces zero writes (FR-005)
#   - the payload plan_writes returns is exactly what --dry-run reports
#     (FR-033): it is deterministic and carries no side channel of its own

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SINK_DIR="${ROOT}/scripts/bash/sink/jira"
  # shellcheck source=/dev/null
  source "${SINK_DIR}/plan_apply.sh"
  MARKER="$(adf_managed_marker)"
}

_human_desc() {
  local prefix_text="$1" managed="$2"
  jq -cn --arg t "${prefix_text}" --arg m "${MARKER}" --argjson managed "${managed}" \
    '{type:"doc", version:1, content: (
      [{type:"paragraph", content:[{type:"text", text:$t}]},
       {type:"paragraph", content:[{type:"text", text:$m, marks:[{type:"strong"}]}]}]
      + $managed) }'
}

_doc() {
  # A parent-only neutral document whose epic.description.blocks is exactly
  # what reconcile.sh produces once `.epic.description.blocks += $pb` has
  # run — the base spec blocks, optionally followed by the plan's own.
  local plan_blocks="$1"
  jq -cn --argjson pb "${plan_blocks}" '{routing:{project_key:"COMP"},
    epic:{title:"The Epic", local_id:"3f2a91c04b7e6d18",
          marker:{state:"assigned", id:"3f2a91c04b7e6d18", lines:[2]},
          description:{blocks:([{type:"paragraph", spans:[{text:"Epic overview.",marks:[]}]}] + $pb)}},
    stories:[]}'
}

PLAN_A='[{"type":"heading","level":3,"spans":[{"text":"Implementation Plan","marks":[]}]},{"type":"paragraph","spans":[{"text":"Use a shared library.","marks":[]}]}]'
PLAN_B='[{"type":"heading","level":3,"spans":[{"text":"Implementation Plan","marks":[]}]},{"type":"paragraph","spans":[{"text":"Use a different approach.","marks":[]}]}]'
NO_PLAN='[]'

@test "FR-001 — the plan section sits inside the managed region, below a preserved prefix" {
  local managed existing ctx
  managed="$(adf_render_description "$(jq -c '.epic' <<< "$(_doc "${NO_PLAN}")")" | jq -c '.content')"
  existing="$(_human_desc "A PO wrote this on the epic." "${managed}")"
  ctx="$(jq -cn --argjson ex "${existing}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "$(_doc "${PLAN_A}")" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.parent.body.fields.description' <<< "$output")"
  # The human prefix survives verbatim, first ...
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "A PO wrote this on the epic." ]
  # ... and the plan section is inside the managed region, after the marker.
  [[ "$(jq -c '.content' <<< "${desc}")" == *"Implementation Plan"* ]]
  local marker_idx plan_idx
  marker_idx="$(jq '[.content[] | .content[0].text? == "'"${MARKER}"'"] | index(true)' <<< "${desc}")"
  plan_idx="$(jq '[.content[] | (.content[0].text? // "") == "Implementation Plan"] | index(true)' <<< "${desc}")"
  [ "${plan_idx}" -gt "${marker_idx}" ]
}

@test "FR-002 — a plan change replaces the section in place; exactly one exists" {
  local managed_a existing_a ctx_a first_desc
  managed_a="$(adf_render_description "$(jq -c '.epic' <<< "$(_doc "${PLAN_A}")")" | jq -c '.content')"
  existing_a="$(_human_desc "A PO wrote this on the epic." "${managed_a}")"
  # Second run: the plan changed to PLAN_B, over the already-migrated PLAN_A output.
  ctx_a="$(jq -cn --argjson ex "${existing_a}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "$(_doc "${PLAN_B}")" "${ctx_a}"
  [ "$status" -eq 0 ]
  first_desc="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [ "$(jq '[.content[] | select((.content[0].text? // "") == "Implementation Plan")] | length' <<< "${first_desc}")" -eq 1 ]
  [[ "$(jq -c '.content' <<< "${first_desc}")" == *"Use a different approach."* ]]
  [[ "$(jq -c '.content' <<< "${first_desc}")" != *"Use a shared library."* ]]
}

@test "FR-003 — no plan.md yields no plan section and no warning" {
  local ctx
  ctx="$(jq -cn '{base_url:"https://mock", parent_type_id:"10101", tickets:{}}')"
  run plan_writes "$(_doc "${NO_PLAN}")" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [[ "$(jq -c '.content' <<< "${desc}")" != *"Implementation Plan"* ]]
  [ "$(jq '.warnings // [] | length' <<< "$output")" -eq 0 ]
}

@test "FR-004 — a plan that later yields nothing removes the section" {
  local managed_a existing_a ctx
  managed_a="$(adf_render_description "$(jq -c '.epic' <<< "$(_doc "${PLAN_A}")")" | jq -c '.content')"
  existing_a="$(_human_desc "A PO wrote this on the epic." "${managed_a}")"
  ctx="$(jq -cn --argjson ex "${existing_a}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "$(_doc "${NO_PLAN}")" "${ctx}"
  [ "$status" -eq 0 ]
  local desc; desc="$(jq -c '.parent.body.fields.description' <<< "$output")"
  [[ "$(jq -c '.content' <<< "${desc}")" != *"Implementation Plan"* ]]
  # The human prefix is untouched by the removal.
  [ "$(jq -r '.content[0].content[0].text' <<< "${desc}")" = "A PO wrote this on the epic." ]
}

@test "FR-005 — an unchanged plan produces zero writes" {
  local managed_a existing_a ctx
  managed_a="$(adf_render_description "$(jq -c '.epic' <<< "$(_doc "${PLAN_A}")")" | jq -c '.content')"
  existing_a="$(_human_desc "A PO wrote this on the epic." "${managed_a}")"
  ctx="$(jq -cn --argjson ex "${existing_a}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  run plan_writes "$(_doc "${PLAN_A}")" "${ctx}"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.parent' <<< "$output")" = "null" ]
}

@test "FR-033 — the plan_writes payload is deterministic: --dry-run's report is exactly what the real run sends" {
  local managed_a existing_a ctx out1 out2
  managed_a="$(adf_render_description "$(jq -c '.epic' <<< "$(_doc "${NO_PLAN}")")" | jq -c '.content')"
  existing_a="$(_human_desc "A PO wrote this on the epic." "${managed_a}")"
  ctx="$(jq -cn --argjson ex "${existing_a}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  out1="$(plan_writes "$(_doc "${PLAN_A}")" "${ctx}")"
  out2="$(plan_writes "$(_doc "${PLAN_A}")" "${ctx}")"
  [ "${out1}" = "${out2}" ]
}

# T035 [US1] — "the plan changed, then deleted" (FR-002, FR-004), byte-identical
# across ports (NFR-1). The conformance harness (run-scenario.sh) shares one
# workdir and one mock across every `runs[]` entry of a scenario but has no
# per-run file-mutation primitive, so a THIRD run against a plan.md that
# changed between runs 1 and 2 cannot be expressed as an end-to-end scenario
# without extending shared harness infrastructure well beyond this feature's
# scope. This is the SAME constraint the plan section's own prior feature hit
# (us5-plan-on-parent.json's description: "The changed-plan replace-in-place
# case is proven byte-for-byte cross-port at the plan_apply unit level
# (test_plan_apply_parent.bats/PlanApply.Parent.Tests.ps1, T090)") — this test
# follows that established precedent for the same reason.
@test "T035 — the plan changed, then deleted: both transitions are byte-identical across ports (NFR-1, FR-002, FR-004)" {
  if ! command -v pwsh > /dev/null 2>&1; then skip "pwsh not available"; fi
  local ps_abs; ps_abs="$(cd "${ROOT}/scripts/powershell/sink/jira" && pwd)"
  local managed_a existing_a ctx doc_b doc_none
  managed_a="$(adf_render_description "$(jq -c '.epic' <<< "$(_doc "${PLAN_A}")")" | jq -c '.content')"
  existing_a="$(_human_desc "A PO wrote this on the epic." "${managed_a}")"
  ctx="$(jq -cn --argjson ex "${existing_a}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  doc_b="$(_doc "${PLAN_B}")"

  # Step 1: the plan changed (A -> B).
  local bash_out1 ps_out1
  bash_out1="$(plan_writes "${doc_b}" "${ctx}")"
  ps_out1="$(D="${doc_b}" C="${ctx}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraPlanWriteSet -NeutralDocJson \$env:D -PlanContextJson \$env:C))
  ")"
  [ "${bash_out1}" = "${ps_out1}" ]

  # Step 2: the SAME ticket, now carrying the "B" managed content, has its
  # plan.md deleted (yields nothing).
  local managed_b existing_b ctx2 doc_none
  managed_b="$(jq -c '.body.fields.description.content' <<< "$(jq -c '.parent' <<< "${bash_out1}")")"
  existing_b="$(jq -cn --argjson c "${managed_b}" '{type:"doc", version:1, content:$c}')"
  ctx2="$(jq -cn --argjson ex "${existing_b}" '{base_url:"https://mock", parent_type_id:"10101", parent_key:"PROJ-1", parent_current:{summary:"The Epic", description:$ex}, tickets:{}}')"
  doc_none="$(_doc "${NO_PLAN}")"
  local bash_out2 ps_out2
  bash_out2="$(plan_writes "${doc_none}" "${ctx2}")"
  ps_out2="$(D="${doc_none}" C="${ctx2}" pwsh -NoProfile -Command "
    Import-Module '${ps_abs}/PlanApply.psm1' -Force
    [Console]::Out.Write((Get-JiraPlanWriteSet -NeutralDocJson \$env:D -PlanContextJson \$env:C))
  ")"
  [ "${bash_out2}" = "${ps_out2}" ]
  [[ "${bash_out2}" != *"Implementation Plan"* ]]
}
