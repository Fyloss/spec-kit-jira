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

# Get-JiraRoleNameList — the closed role set has exactly one source (010,
# contract §1). Deliberately WITHOUT -Force, unlike every other import in the
# port: Hierarchy.psm1 is itself imported -Global and LAST by callers that
# already hold lib/Config.psm1 in session scope, and -Force is a
# Remove-Module + Import-Module pair that would tear that copy out of their
# scope and re-attach it to this module's, taking ConvertFrom-JiraConfigYaml
# and friends with it.
Import-Module (Join-Path $PSScriptRoot '../../lib/Config.psm1')

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

#region Role mapping (010, contracts/role-mapping.md)
# One resolver, invoked once per project, over all three roles —
# specification, story, task — with precedence declared -> operator ->
# derived, evaluating every role before refusing (contract §3.2, research
# R1). Mirror of hierarchy.sh's role_* functions.

function Get-JiraRoleCandidates {
    <#
    .SYNOPSIS
      contract §3.3: the candidate set for one role — non-sub-task types for
      specification/story, sub-task types for task, in discovered order.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of candidate issue types it derives; a singular name would misdescribe the value.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $IssueTypes, [Parameter(Mandatory)][string] $Role)
    if ($Role -eq 'task') { return @($IssueTypes | Where-Object { [bool]$_.subtask }) }
    return @($IssueTypes | Where-Object { -not [bool]$_.subtask })
}

function Resolve-JiraRoleMapping {
    <#
    .SYNOPSIS
      contract §3. Declared/Operator are each a hashtable {specification?;
      story?; task?} -> issue type name, scoped to ONE project. Matching
      (§3.3) searches the WHOLE issue-type list by exact name — never
      pre-scoped to the role's candidate set — so a sub-task type declared
      for `story` is caught by the subtask check below (§6.5/§6.6), not
      reported as an unrelated §6.3 "unknown type". `task` is never derived
      (§3.1) — undeclared and unanswered, it is ABSENT (§3.4).

      Returns a pscustomobject: Roles (hashtable), Unresolved, Unknown,
      Duplicate, SubtaskMisuse, TaskMisuse (arrays), NoParentLevel (string
      or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProjectKey,
        [Parameter(Mandatory)] $IssueTypes,
        $Declared = @{},
        $Operator = @{}
    )
    if ($null -eq $Declared) { $Declared = @{} }
    if ($null -eq $Operator) { $Operator = @{} }

    $ns = @($IssueTypes | Where-Object { -not [bool]$_.subtask })
    $subtaskTypes = @($IssueTypes | Where-Object { [bool]$_.subtask })
    $childLevel = $null
    if ($ns.Count -gt 0) { $childLevel = ($ns | ForEach-Object { [int]$_.hierarchy_level } | Measure-Object -Minimum).Minimum }
    $childCands = @()
    if ($null -ne $childLevel) { $childCands = @($ns | Where-Object { [int]$_.hierarchy_level -eq $childLevel }) }
    $above = @()
    if ($null -ne $childLevel) { $above = @($ns | Where-Object { [int]$_.hierarchy_level -gt $childLevel }) }
    $parentLevel = $null
    if ($above.Count -gt 0) { $parentLevel = ($above | ForEach-Object { [int]$_.hierarchy_level } | Measure-Object -Minimum).Minimum }
    $childList = ($childCands | ForEach-Object { $_.logical_name }) -join ', '

    $roles = [ordered]@{}
    $unresolved = [System.Collections.Generic.List[object]]::new()
    $unknown = [System.Collections.Generic.List[object]]::new()
    $duplicate = [System.Collections.Generic.List[object]]::new()
    $subtaskMisuse = [System.Collections.Generic.List[object]]::new()
    $taskMisuse = [System.Collections.Generic.List[object]]::new()
    $noParentLevel = $null

    function Get-MapValue($Map, [string]$Key) {
        if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)) { return $Map[$Key] }
        return $null
    }

    # The role set is read from Config.psm1, never respelled here — the Bash
    # port binds the same list through `_cfg_role_names_json` (contract §1).
    foreach ($role in (Get-JiraRoleNameList)) {
        $dname = Get-MapValue $Declared $role
        $oname = Get-MapValue $Operator $role
        $answerName = $null
        $answerSource = $null
        if ($null -ne $dname) { $answerName = $dname; $answerSource = 'declared' }
        elseif ($null -ne $oname) { $answerName = $oname; $answerSource = 'operator' }

        if ($null -ne $answerName) {
            # Byte-equal, ordinal comparison (contract §3.3) — NOT `-ceq`,
            # which is case-sensitive but still CULTURE-AWARE and treats an
            # NFD name (combining accent) as equal to its NFC form. jq's `==`
            # on the Bash port is already ordinal; this keeps the two ports
            # byte-identical (research/T072).
            $typeMatches = @($IssueTypes | Where-Object { [string]::Equals([string]$_.logical_name, $answerName, [System.StringComparison]::Ordinal) })
            if ($typeMatches.Count -eq 0) {
                $unknown.Add([pscustomobject]@{ role = $role; name = $answerName; candidates = (Get-JiraRoleCandidates -IssueTypes $IssueTypes -Role $role) })
            }
            elseif ($typeMatches.Count -gt 1) {
                $duplicate.Add([pscustomobject]@{ role = $role; name = $answerName; level = [string]$typeMatches[0].hierarchy_level })
            }
            else {
                $m = $typeMatches[0]
                if ($role -ne 'task' -and [bool]$m.subtask) {
                    $subtaskMisuse.Add([pscustomobject]@{ role = $role; name = $m.logical_name })
                }
                elseif ($role -eq 'task' -and -not [bool]$m.subtask) {
                    $taskMisuse.Add([pscustomobject]@{ name = $m.logical_name; candidates = $subtaskTypes })
                }
                else {
                    $roles[$role] = [ordered]@{
                        logical_name = $m.logical_name; id = $m.id
                        hierarchy_level = [string]$m.hierarchy_level; subtask = [bool]$m.subtask
                        source = $answerSource
                    }
                }
            }
            continue
        }

        if ($role -eq 'task') { continue }
        if ($role -eq 'story') {
            if ($null -eq $childLevel) { continue }
            $lc = @($ns | Where-Object { [int]$_.hierarchy_level -eq $childLevel })
            if ($lc.Count -eq 1) {
                $roles['story'] = [ordered]@{
                    logical_name = $lc[0].logical_name; id = $lc[0].id
                    hierarchy_level = [string]$lc[0].hierarchy_level; subtask = [bool]$lc[0].subtask
                    source = 'derived'
                }
            }
            else {
                $unresolved.Add([pscustomobject]@{ role = 'story'; level = [string]$childLevel; candidates = $lc })
            }
            continue
        }
        # specification
        if ($null -eq $childLevel) { continue }
        if ($null -eq $parentLevel) {
            $noParentLevel = "reconcile: project $ProjectKey offers no issue type above its $childList level, so a specification has nowhere to hang. Its non-sub-task types are: $childList. A parent level must exist in the project before it can be mirrored (zero writes)."
            continue
        }
        $pc = @($above | Where-Object { [int]$_.hierarchy_level -eq $parentLevel })
        if ($pc.Count -eq 1) {
            $roles['specification'] = [ordered]@{
                logical_name = $pc[0].logical_name; id = $pc[0].id
                hierarchy_level = [string]$pc[0].hierarchy_level; subtask = [bool]$pc[0].subtask
                source = 'derived'
            }
        }
        else {
            $unresolved.Add([pscustomobject]@{ role = 'specification'; level = [string]$parentLevel; candidates = $pc })
        }
    }

    return [pscustomobject]@{
        Roles = $roles
        Unresolved = $unresolved.ToArray()
        Unknown = $unknown.ToArray()
        Duplicate = $duplicate.ToArray()
        SubtaskMisuse = $subtaskMisuse.ToArray()
        TaskMisuse = $taskMisuse.ToArray()
        NoParentLevel = $noParentLevel
    }
}

function Test-JiraRoleMappingHasProblems {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the boolean predicate it evaluates; a singular name would misdescribe the check.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)
    return (($Result.Unresolved.Count + $Result.Unknown.Count + $Result.Duplicate.Count `
                + $Result.SubtaskMisuse.Count + $Result.TaskMisuse.Count `
                + $(if ($Result.NoParentLevel) { 1 } else { 0 })) -gt 0)
}

function Get-JiraRoleUnresolvedMessage {
    <# .SYNOPSIS contract §6.2 — the closed question. Two lines. #>
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Role, [string]$Level, $Candidates)
    $list = (@($Candidates) | ForEach-Object { $_.logical_name }) -join ', '
    return "config: project $ProjectKey`: the $Role level ($Level) holds more than one issue type: $list. The bridge will not choose one for you (zero writes).`nconfig: declare it in .specify/jira/config.yml under projects[].hierarchy.$Role, or answer once with --issue-type $ProjectKey=$Role=<one of them>."
}

function ConvertTo-JiraRoleUnresolvedJson {
    <# .SYNOPSIS the structured `unresolved_roles` block (contract §6.2). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][string] $ProjectKey)
    $out = foreach ($u in @($Result.Unresolved)) {
        [ordered]@{
            project = $ProjectKey
            role = $u.role
            level = $u.level
            candidates = @($u.candidates | ForEach-Object { [ordered]@{ logical_name = $_.logical_name; id = $_.id } })
            declaration = "projects[].hierarchy.$($u.role)"
            flag = "--issue-type $ProjectKey=$($u.role)=<name>"
        }
    }
    return , @($out)
}

function Get-JiraRoleUnknownTypeMessage {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Role, [string]$Name, $Candidates)
    $list = (@($Candidates) | ForEach-Object { $_.logical_name }) -join ', '
    return "config: project $ProjectKey`: $Role names issue type `"$Name`", which this project does not offer at that tier. It offers: $list (zero writes)."
}

function Get-JiraRoleDuplicateMessage {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Role, [string]$Name, [string]$Level)
    return "config: project $ProjectKey`: $Role names `"$Name`", which matches more than one issue type at level $Level. The bridge will not choose one for you (zero writes)."
}

function Get-JiraRoleSubtaskMisuseMessage {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Role, [string]$Name)
    return "config: project $ProjectKey`: $Role names `"$Name`", which is a sub-task type in this project. A $Role cannot be a sub-task (zero writes)."
}

function Get-JiraRoleTaskMisuseMessage {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Name, $Candidates)
    $arr = @($Candidates)
    $list = if ($arr.Count -eq 0) { 'none — this project offers no sub-task type' } else { ($arr | ForEach-Object { $_.logical_name }) -join ', ' }
    return "config: project $ProjectKey`: task names `"$Name`", which is not a sub-task type in this project. Its sub-task types are: $list (zero writes)."
}

function Get-JiraRoleOrderingMessage {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$SpecName, [string]$SpecLevel, [string]$StoryName, [string]$StoryLevel)
    return "config: project $ProjectKey`: specification names `"$SpecName`" at level $SpecLevel, which is not above story `"$StoryName`" at level $StoryLevel. A specification must sit above its stories (zero writes)."
}

function Test-JiraRoleMapping {
    <#
    .SYNOPSIS
      contract §4 check 4 (ordering), over the RESOLVED roles map. Checks
      2/3 (subtask flags) are enforced inside Resolve-JiraRoleMapping
      itself; checks 5/6 stay Get-JiraHierarchyMandatoryGate, unchanged.
      Prints the §6.7 message and returns it via -Message; returns $true
      when valid, $false on an inverted ordering.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)] $Roles, [ref] $Message)
    $spec = $null; $story = $null
    if ($Roles -is [System.Collections.IDictionary]) {
        if ($Roles.Contains('specification')) { $spec = $Roles['specification'] }
        if ($Roles.Contains('story')) { $story = $Roles['story'] }
    }
    if ($null -eq $spec -or $null -eq $story) { return $true }
    if ([int]$spec.hierarchy_level -gt [int]$story.hierarchy_level) { return $true }
    if ($Message) {
        $Message.Value = Get-JiraRoleOrderingMessage -ProjectKey $ProjectKey -SpecName $spec.logical_name -SpecLevel ([string]$spec.hierarchy_level) `
            -StoryName $story.logical_name -StoryLevel ([string]$story.hierarchy_level)
    }
    return $false
}

function Get-JiraRoleReconcileOrderingMessage {
    <# .SYNOPSIS the §8 re-validation twin of Get-JiraRoleOrderingMessage — "reconcile:" prefixed since no config.yml write is in progress at that point. #>
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$SpecName, [string]$SpecLevel, [string]$StoryName, [string]$StoryLevel)
    return "reconcile: project $ProjectKey`: specification names `"$SpecName`" at level $SpecLevel, which is not above story `"$StoryName`" at level $StoryLevel. A specification must sit above its stories (zero writes)."
}

function Test-JiraRoleMappingReconcile {
    <#
    .SYNOPSIS
      contract §8 (T052): check 4 (ordering) re-run against the PERSISTED
      binding's roles at reconcile time, with no re-read of the project's
      metadata. Mirrors Test-JiraRoleMapping exactly except for the message
      prefix; an absent specification or story role is non-fatal (§3.4).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)] $Roles, [ref] $Message)
    $spec = $null; $story = $null
    if ($Roles -is [System.Collections.IDictionary]) {
        if ($Roles.Contains('specification')) { $spec = $Roles['specification'] }
        if ($Roles.Contains('story')) { $story = $Roles['story'] }
    }
    elseif ($Roles -is [System.Management.Automation.PSCustomObject]) {
        $spec = Get-JiraHierarchyDerivationProp $Roles 'specification'
        $story = Get-JiraHierarchyDerivationProp $Roles 'story'
    }
    if ($null -eq $spec -or $null -eq $story) { return $true }
    if ([int]$spec.hierarchy_level -gt [int]$story.hierarchy_level) { return $true }
    if ($Message) {
        $Message.Value = Get-JiraRoleReconcileOrderingMessage -ProjectKey $ProjectKey -SpecName $spec.logical_name -SpecLevel ([string]$spec.hierarchy_level) `
            -StoryName $story.logical_name -StoryLevel ([string]$story.hierarchy_level)
    }
    return $false
}

function Get-JiraHierarchyDerivationProp {
    # StrictMode-safe optional property read for a PSCustomObject, mirroring
    # commands/Config.psm1's Get-CmdProp without importing that module here.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-JiraRoleSupersessionNote {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Role, [string]$DeclaredName, [string]$LocalName)
    return "config: project $ProjectKey`: $Role is declared as `"$DeclaredName`" in config.yml; the local answer `"$LocalName`" was superseded."
}

function Get-JiraRolePromotionNote {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Role, [string]$Name)
    return "config: project $ProjectKey`: commit this so your team mirrors identically —`n  hierarchy:`n    $Role`: `"$Name`""
}

function Get-JiraRoleTaskRecordedNote {
    [CmdletBinding()]
    param([string]$ProjectKey, [string]$Name)
    return "config: project $ProjectKey`: task is recorded as `"$Name`" but is not mirrored yet — this release creates no sub-tasks."
}

#endregion

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
    Get-JiraHierarchyUnsatisfiableFields, Get-JiraHierarchyMandatoryGate, `
    Get-JiraRoleCandidates, Resolve-JiraRoleMapping, Test-JiraRoleMappingHasProblems, `
    Get-JiraRoleUnresolvedMessage, ConvertTo-JiraRoleUnresolvedJson, Get-JiraRoleUnknownTypeMessage, `
    Get-JiraRoleDuplicateMessage, Get-JiraRoleSubtaskMisuseMessage, Get-JiraRoleTaskMisuseMessage, `
    Get-JiraRoleOrderingMessage, Test-JiraRoleMapping, Get-JiraRoleSupersessionNote, `
    Get-JiraRolePromotionNote, Get-JiraRoleTaskRecordedNote, Get-JiraRoleReconcileOrderingMessage, `
    Test-JiraRoleMappingReconcile
