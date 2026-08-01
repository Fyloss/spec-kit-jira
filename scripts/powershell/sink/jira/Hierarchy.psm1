# sink/jira/Hierarchy.psm1 — Hierarchy derivation and the mandatory-field
# gate (008 T042/T043/T086/T087). Mirror of hierarchy.sh. See
# contracts/hierarchy-resolution.md.
#
# The child level is the lowest hierarchy_level occupied by a non-sub-task
# type; the type at that level is a recorded operator/derived answer, never
# derived here (research R1/R2). The parent level is the lowest level
# strictly above the child level that is occupied by a non-sub-task type;
# UNLIKE the child, the parent TYPE is derived here (contract §3).
#
# No Atlassian default type name, status name or field id appears anywhere
# in this file (Constitution VII).

Set-StrictMode -Version Latest

function Get-JiraHierarchyChildLevel {
    <#
    .SYNOPSIS
      The lowest hierarchy_level over non-sub-task types (contract §2).
      Mirror of hierarchy_child_level. Returns $null when there are none.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $IssueTypes)
    $cand = @($IssueTypes | Where-Object { -not [bool]$_.subtask })
    if ($cand.Count -eq 0) { return $null }
    return ($cand | ForEach-Object { [int]$_.hierarchy_level } | Measure-Object -Minimum).Minimum
}

function Get-JiraHierarchyDerivation {
    <#
    .SYNOPSIS
      The full parent-level derivation (contract §3), plus the child level
      it is measured above. Mirror of hierarchy_derive. Returns a
      pscustomobject; see hierarchy_derive's header for the exact shape
      (as properties: Status, ChildLevel, ParentLevel, Parent, Candidates,
      Message).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)] $IssueTypes)
    $cand = @($IssueTypes | Where-Object { -not [bool]$_.subtask })
    $childLevel = ($cand | ForEach-Object { [int]$_.hierarchy_level } | Measure-Object -Minimum).Minimum
    $childCands = @($cand | Where-Object { [int]$_.hierarchy_level -eq $childLevel })
    $above = @($cand | Where-Object { [int]$_.hierarchy_level -gt $childLevel })
    $childList = ($childCands | ForEach-Object { $_.logical_name }) -join ', '

    if ($above.Count -eq 0) {
        $msg = "reconcile: project $ProjectKey offers no issue type above its $childList level, so a specification has nowhere to hang. Its non-sub-task types are: $childList. A parent level must exist in the project before it can be mirrored (zero writes)."
        return [pscustomobject]@{ Status = 'no-parent-level'; ChildLevel = $childLevel; Message = $msg }
    }

    $parentLevel = ($above | ForEach-Object { [int]$_.hierarchy_level } | Measure-Object -Minimum).Minimum
    $parentCands = @($above | Where-Object { [int]$_.hierarchy_level -eq $parentLevel })
    if ($parentCands.Count -eq 1) {
        return [pscustomobject]@{
            Status     = 'ok'
            ChildLevel = $childLevel
            ParentLevel = $parentLevel
            Parent     = [ordered]@{ logical_name = $parentCands[0].logical_name; id = $parentCands[0].id }
        }
    }
    $parentList = ($parentCands | ForEach-Object { $_.logical_name }) -join ', '
    $msg = "reconcile: project $ProjectKey offers more than one issue type at the level above $childList`: $parentList. The bridge will not choose one for you (zero writes)."
    return [pscustomobject]@{ Status = 'parent-level-ambiguous'; ChildLevel = $childLevel; Candidates = $parentCands; Message = $msg }
}

function Get-JiraHierarchyChildTypeUnresolvedMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey)
    return "reconcile: project $ProjectKey has no recorded issue type for user stories. Run /speckit.jira.config to record it (zero writes)"
}

function Get-JiraHierarchyParentLinkUnavailableMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)][string] $ChildLogicalName)
    return "reconcile: issue type $ChildLogicalName in project $ProjectKey does not accept a parent reference, so its stories cannot hang from a parent (zero writes)"
}

function Get-JiraHierarchyBindingShapeStaleMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey)
    return "reconcile: the local binding for $ProjectKey predates parent support and does not record issue-type hierarchy. The project is bound — its binding is simply a version behind. Run /speckit.jira.config to refresh it (zero writes)"
}

function Get-JiraHierarchyMandatoryFieldsMessage {
    <#
    .SYNOPSIS
      Contract §5. Input: array of {type_name; fields:[...]}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Unsatisfiable)
    $parts = foreach ($u in @($Unsatisfiable)) {
        $fields = (@($u.fields) | ForEach-Object { "`"$_`"" }) -join ', '
        "Issue type `"$($u.type_name)`" requires fields this bridge cannot supply: $fields."
    }
    return ($parts -join ' ')
}

function Get-JiraHierarchyUnsatisfiableFields {
    <#
    .SYNOPSIS
      contract §5: which required fields the bridge can supply. Fields is a
      single type's list [{logical_name; field_id}]. Mirror of
      hierarchy_unsatisfiable_fields.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of unsatisfiable fields it derives; a singular name would misdescribe the value.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Fields, [bool] $HasParentLink = $false)
    $satisfiable = @('summary', 'description', 'issuetype', 'project', 'priority', 'reporter')
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($Fields)) {
        $fid = [string]$f.field_id
        $ok = ($satisfiable -contains $fid) -or ($fid -eq 'parent' -and $HasParentLink)
        if (-not $ok) { $out.Add([string]$f.logical_name) }
    }
    return $out.ToArray()
}

function Get-JiraHierarchyMandatoryGate {
    <#
    .SYNOPSIS
      T086/T087/T088: the parent-link-unavailable refusal (contract §4,
      research R4) and the mandatory-field gate (contract §5), run over BOTH
      written types. Mirror of hierarchy_mandatory_gate. Runs after
      derivation and before recognition, so no read and no write has
      happened yet.

      Binding is the persisted binding's resolved_ids.<KEY> shape —
      {child_type, parent_type, parent_link_available, required_fields}.

      The parent-link check runs FIRST: a structural prerequisite (whether
      the child type's own create metadata offers a `parent` field at all),
      not a per-field satisfiability question — plan_writes sends
      fields.parent on every child creation unconditionally.

      Returns one canonical pscustomobject:
        @{ status = 'ok' }
        @{ status = 'parent-link-unavailable'; reason = '...'; message = '...' }
        @{ status = 'unsatisfiable'; reason = 'mandatory-fields-unsatisfiable'; message = '...' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Binding, [string] $ProjectKey = '')

    $childId = [string]$Binding.child_type.id
    $childName = [string]$Binding.child_type.logical_name
    $parentId = [string]$Binding.parent_type.id
    $parentName = [string]$Binding.parent_type.logical_name

    $pla = $Binding.parent_link_available
    $hasLink = $false
    if ($null -ne $pla -and $pla.PSObject.Properties.Match($childId).Count -gt 0) {
        $hasLink = [bool]$pla.$childId
    }

    if (-not $hasLink) {
        $msg = Get-JiraHierarchyParentLinkUnavailableMessage -ProjectKey $ProjectKey -ChildLogicalName $childName
        return [pscustomobject]@{ status = 'parent-link-unavailable'; reason = 'parent-link-unavailable'; message = $msg }
    }

    $rf = $Binding.required_fields
    $childFields = @()
    if ($null -ne $rf -and $rf.PSObject.Properties.Match($childId).Count -gt 0) { $childFields = @($rf.$childId) }
    $parentFields = @()
    if ($null -ne $rf -and $rf.PSObject.Properties.Match($parentId).Count -gt 0) { $parentFields = @($rf.$parentId) }

    # The parent's own `parent` field, were one ever required, is always
    # unsatisfiable — a parent has no parent (contract §5).
    $childUnsat = @(Get-JiraHierarchyUnsatisfiableFields -Fields $childFields -HasParentLink $true)
    $parentUnsat = @(Get-JiraHierarchyUnsatisfiableFields -Fields $parentFields -HasParentLink $false)

    $unsat = [System.Collections.Generic.List[object]]::new()
    if ($parentUnsat.Count -gt 0) { $unsat.Add([pscustomobject]@{ type_name = $parentName; fields = $parentUnsat }) }
    if ($childUnsat.Count -gt 0) { $unsat.Add([pscustomobject]@{ type_name = $childName; fields = $childUnsat }) }

    if ($unsat.Count -eq 0) {
        return [pscustomobject]@{ status = 'ok' }
    }

    $bodyMsg = Get-JiraHierarchyMandatoryFieldsMessage -Unsatisfiable $unsat.ToArray()
    $msg = "reconcile: $bodyMsg Nothing was written (zero writes). Either make these fields optional for these types in the project's field configuration, or create the parent and its stories by hand and record their keys in specs/…/spec.md."
    return [pscustomobject]@{ status = 'unsatisfiable'; reason = 'mandatory-fields-unsatisfiable'; message = $msg }
}

Export-ModuleMember -Function Get-JiraHierarchyChildLevel, Get-JiraHierarchyDerivation, `
    Get-JiraHierarchyChildTypeUnresolvedMessage, Get-JiraHierarchyParentLinkUnavailableMessage, `
    Get-JiraHierarchyBindingShapeStaleMessage, Get-JiraHierarchyMandatoryFieldsMessage, `
    Get-JiraHierarchyUnsatisfiableFields, Get-JiraHierarchyMandatoryGate
