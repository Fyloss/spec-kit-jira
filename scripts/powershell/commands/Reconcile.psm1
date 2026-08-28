# commands/Reconcile.psm1 — The reconcile command. Mirror of commands/reconcile.sh
# (US3, T059).
#
# Wires the neutral ENGINE to the Jira SINK: parse a specification into neutral
# content, assemble and schema-VALIDATE the neutral document (a validation failure
# blocks every write, Constitution VIII), plan the ordered action set, and apply
# it through the mandatory pre-write BLOCK guard (US11). Estimation is create-only
# (FR-018). Writes the run summary via the [Console] streams and returns ONLY its
# numeric exit code. Byte-identical to the Bash port (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/Parse.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/Interchange.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/MarkerSplice.psm1') -Force # Write-JiraMarkerSpliceFile — a nested import inside StoryMarker.psm1 is not enough (module-scope, not session)
Import-Module (Join-Path $PSScriptRoot '../engine/SpecMarker.psm1') -Force # the parent marker's same splice (Phase 5, US2) — a nested import inside PlanApply.psm1 is not enough
Import-Module (Join-Path $PSScriptRoot '../engine/TaskMarker.psm1') -Force -Global # Phase 3, US1 — the task tier's own marker grammar
Import-Module (Join-Path $PSScriptRoot '../engine/TasksParse.psm1') -Force # Phase 3, US1 — reading tasks.md
Import-Module (Join-Path $PSScriptRoot '../engine/StoryMarker.psm1') -Force -Global # R5 step 1 — assign identifiers
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Recognition.psm1') -Force # R5 step 2 — recognise recorded tickets
# No -Force: Recognition.psm1 (imported above) already loads this module
# internally; a second -Force reimport here would tear its exports out of
# Recognition.psm1's scope and reattach them to this one instead.
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Prefetch.psm1')        # 021 US4 — the recognition prefetch
Import-Module (Join-Path $PSScriptRoot '../sink/jira/PlanApply.psm1') -Force
# No -Force on either of the next two: PlanApply.psm1 (imported above)
# already loads both internally — a second -Force reimport here would tear
# their exports out of PlanApply.psm1's own scope and reattach them to this
# one instead (the same hazard the Prefetch.psm1 comment above documents).
# 023, US4: the task-role mapping's own due set (Get-JiraDriftDecision,
# Import-JiraTransitions/Get-JiraTransitionRecord/Resolve-JiraTransition)
# is resolved directly in this module now, mirroring reconcile.sh, which
# gets both transitively for free from bash's lack of real module scoping.
Import-Module (Join-Path $PSScriptRoot '../engine/Drift.psm1')
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Transitions.psm1')
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Discovery.psm1') -Force # Phase 8, US5 — the completion pass's transitions read
Import-Module (Join-Path $PSScriptRoot '../sink/jira/DuplicateProbe.psm1') -Force # US4, droppable — the second, best-effort guard
Import-Module (Join-Path $PSScriptRoot '../hooks/RegisterHooks.psm1') -Force # hook health — READ ONLY (003 FR-022)
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force          # the operator disable record
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Hierarchy.psm1') -Force -Global # the mandatory-field gate — a nested import inside lib/Config.psm1 is not enough
Import-Module (Join-Path $PSScriptRoot '../lib/Prereq.psm1') -Force          # the bridge-unavailable cause
Import-Module (Join-Path $PSScriptRoot '../lib/Timing.psm1') -Force          # phase timing (021, T015)
Import-Module (Join-Path $PSScriptRoot '../lib/RunState.psm1') -Force        # the run-state short-circuit (021, T030)
# No -Force (024, T046/T047): Recognition.psm1 (imported above) already loads
# this module internally; a -Force reimport here would tear its
# $script:JiraRequestCount out of Recognition.psm1's (and every other sink
# module's) scope and reattach a fresh, zeroed one to this scope instead —
# the exact defect this comment used to justify with -Force, reasoning
# backwards from the symptom. See project memory:
# powershell-import-force-clobbers-caller-scope.
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Client.psm1')
# No -Force: a nested import inside PlanApply.psm1 is not enough (module-scope,
# not session) to reach Test-JiraAdfContentHasChecklist/Get-JiraAdfChecklistSlice
# from here — but -Force here would tear Adf.psm1 out of a caller that already
# imported it directly (see project memory: powershell-import-force-clobbers-caller-scope).
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Adf.psm1')

$script:ReconcileExitConfig = 4

function Test-JiraReconcileHeld {
    <#
    .SYNOPSIS
      $true when the operator disabled this lifecycle event. Mirror of
      _reconcile_is_held.

      Read at DISPATCH, before any prerequisite check and before any network
      work, so the decision holds even in the window between an install that
      re-enabled the registry entry and the next ceremony (003 FR-007, FR-020,
      research R5 step 2). The registry's own `enabled` field is deliberately NOT
      consulted here: the install rewrites it to `true` unconditionally, so it
      cannot carry the answer.
    #>
    param([string] $LifecycleEvent)
    if ([string]::IsNullOrEmpty($LifecycleEvent)) { return $false }
    $recorded = @((Get-JiraHooksDisabled) | ConvertFrom-Json)
    return ($recorded -ccontains $LifecycleEvent)
}

function Write-JiraReconcileNotice {
    # The SINGLE message a degraded run is allowed (FR-016). Everything goes to
    # stderr so it never contaminates a --json summary, and the caller emits it
    # exactly once per run. Mirror of _reconcile_notice.
    param([string[]] $Lines)
    foreach ($l in $Lines) { [Console]::Error.WriteLine($l) }
}

function Get-JiraReconcileFaultCode {
    <#
    .SYNOPSIS
      Report one bridge fault and return the code the caller should return.
      Mirror of _reconcile_fault.

      In HOOK CONTEXT that code is always 0: under `optional: false` the agent
      performs this step as part of the host command, and FR-015 admits no
      exception — a hook failure of ANY kind must leave the host command's outcome
      untouched. Every early-return failure path goes through here for that
      reason. The downgrade used to happen at one point near the end of the run,
      which meant the faults that returned early — an unparseable spec, an invalid
      lifecycle payload — still failed the host command. Outside hook context the
      mapped exit code is returned unchanged, so a direct invocation still fails
      closed (Constitution III).
    #>
    param([int] $Code, [string] $Message)
    # Phase 6, US4 (T053 audit): in hook context every early-return fault
    # gets the SAME standardised WARNING wording the late apply-failure path
    # uses — the caller's specific message is kept, just wrapped, so every
    # degraded path reads identically under a hook (FR-016).
    if ($env:SPEC_KIT_JIRA_HOOK_CONTEXT) {
        [Console]::Error.WriteLine("WARNING: $Message (exit $Code). This spec-kit command completed normally.")
        return 0
    }
    [Console]::Error.WriteLine($Message)
    return $Code
}

function Get-JiraReconcilePlanContext {
    # The plan context: base_url plus any caller overrides from
    # SPEC_KIT_JIRA_PLAN_CONTEXT (JSON). base_url always wins. Mirror of
    # _reconcile_plan_context.
    param([string] $BaseUrl)
    $extra = if ($env:SPEC_KIT_JIRA_PLAN_CONTEXT) { $env:SPEC_KIT_JIRA_PLAN_CONTEXT } else { '{}' }
    $obj = $extra | ConvertFrom-Json -Depth 100
    $map = [ordered]@{}
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    $map['base_url'] = $BaseUrl
    return (ConvertTo-JiraJsonValue $map)
}

function Resolve-JiraReconcileRouting {
    <#
    .SYNOPSIS
      Resolve this run's project key from the merged team config (US1,
      FR-001–FR-004). Mirror of _reconcile_resolve_routing. Labels are not yet
      extracted by the parser (Assumptions: "extending what the parser
      extracts is out of scope"), so folder-prefix rules and routing_default
      are what this resolves in practice. Returns { ExitCode; ProjectKey }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [string] $ConfigJson)
    return (Resolve-JiraRouting -FolderName (Split-Path -Leaf $Folder) -LabelsJson '[]' -RoutingConfigJson $ConfigJson)
}

function Get-JiraReconcilePhaseStatusMap {
    <#
    .SYNOPSIS
      The resolved, PER-ROLE phase->status map (023, contracts/
      role-lifecycle-config.md §2/§4): all three role keys always present, an
      empty object where the project declares nothing for that role. Both
      accepted shapes normalise to this one — a project's committed
      role-blind mapping (every key a lifecycle event) routes wholesale to
      the `story` role (FR-020, back-compatible by construction); a per-role
      mapping (every key a hierarchy role) is used as-is. Config.psm1's
      schema validator has already refused anything mixed or unknown before
      this ever runs, so only the two valid shapes and the empty map reach
      here. Mirror of _reconcile_phase_status_map.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] [string] $ConfigJson)
    $cfg = $ConfigJson | ConvertFrom-Json -Depth 100
    $projectsVal = Get-JiraPlanPropSafe $cfg 'projects'
    $projects = if ($null -ne $projectsVal) { @($projectsVal) } else { @() }
    $v = $null
    foreach ($p in $projects) {
        if ([string](Get-JiraPlanPropSafe $p 'key') -eq $ProjectKey) {
            $v = Get-JiraPlanPropSafe $p 'phase_status_map'
            break
        }
    }
    $roleNames = Get-JiraRoleNameList
    $perRole = [ordered]@{}
    if ($v -is [System.Management.Automation.PSCustomObject]) {
        $ks = @($v.PSObject.Properties.Name)
        if ($ks.Count -gt 0 -and (@($ks | Where-Object { $roleNames -notcontains $_ })).Count -eq 0) {
            # Already per-role.
            foreach ($k in $ks) { $perRole[$k] = (Get-JiraPlanPropSafe $v $k) }
        }
        elseif ($ks.Count -gt 0) {
            # Role-blind — routes wholesale to `story`.
            $perRole['story'] = $v
        }
    }
    $out = [ordered]@{}
    foreach ($r in $roleNames) {
        $out[$r] = if ($perRole.Contains($r)) { $perRole[$r] } else { [ordered]@{} }
    }
    return (ConvertTo-JiraJsonValue $out)
}

function Get-JiraReconcileHaltedStatuses {
    <#
    .SYNOPSIS
      The resolved project's declared operator stop-states (Phase 6, US4),
      or [] when none. Mirror of _reconcile_halted_statuses.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of halted statuses it derives; a singular name would misdescribe the value.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] [string] $ConfigJson)
    $cfg = $ConfigJson | ConvertFrom-Json -Depth 100
    $projectsVal = Get-JiraPlanPropSafe $cfg 'projects'
    $projects = if ($null -ne $projectsVal) { @($projectsVal) } else { @() }
    foreach ($p in $projects) {
        if ([string](Get-JiraPlanPropSafe $p 'key') -eq $ProjectKey) {
            $v = Get-JiraPlanPropSafe $p 'halted_statuses'
            if ($null -ne $v) { return (ConvertTo-JiraJsonValue @($v)) }
        }
    }
    return '[]'
}

function Get-JiraReconcilePhaseOrder {
    <#
    .SYNOPSIS
      The DISTINCT statuses EACH ROLE's own map resolves to, IN THE FIXED
      CANONICAL LIFECYCLE-EVENT ORDER (extension.yml's own hook list) —
      deliberately NOT Get-JiraPhaseStatusTargetSet, whose own tested
      contract accepts arbitrary phase names and therefore returns them
      SORTED, not chronologically (Import-JiraConfig's merge also sorts the
      map's own keys, so declaration order can never be recovered from the
      map alone). Reconcile's phase names ARE the fixed lifecycle events, so
      this local helper can use that closed vocabulary to restore the true
      chronological order drift's ahead/behind comparison depends on
      (Phase 6, US4, research R9).

      023, data-model.md §1: `order` is now derived PER ROLE — a
      specification and a story on different workflows are never compared
      against each other's step order (contract role-lifecycle-config.md §5
      I1). PhaseStatusMapJson must already be the RESOLVED per-role shape
      (Get-JiraReconcilePhaseStatusMap's own output). Returns
      {specification:[...], story:[...], task:[...]}. Mirror of
      _reconcile_phase_order.
    #>
    [CmdletBinding()]
    param([string] $PhaseStatusMapJson = '{}')
    $pm = $PhaseStatusMapJson | ConvertFrom-Json -Depth 100
    $canonicalOrder = @('before_specify', 'after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')
    $roleNames = Get-JiraRoleNameList
    $out = [ordered]@{}
    foreach ($role in $roleNames) {
        $roleMap = Get-JiraPlanPropSafe $pm $role
        $distinct = [System.Collections.Generic.List[string]]::new()
        foreach ($phaseEvent in $canonicalOrder) {
            if ($roleMap -isnot [System.Management.Automation.PSCustomObject]) { continue }
            $member = $roleMap.PSObject.Properties[$phaseEvent]
            if ($null -eq $member) { continue }
            $v = [string]$member.Value
            if ([string]::IsNullOrEmpty($v)) { continue }
            if (-not $distinct.Contains($v)) { $distinct.Add($v) }
        }
        $out[$role] = $distinct
    }
    return (ConvertTo-JiraJsonValue $out)
}

function Get-JiraReconcileFieldDefaultNote {
    <#
    .SYNOPSIS
      011, contract §4.1/§4.2: mirror of _reconcile_field_default_notes. For
      every field this run actually sent that came from a recorded default or
      a this-run answer (never a bridge-supplied field), one provenance line
      naming the field, the value, and its source; for an `operator-answer`
      source, one further line with the `/speckit.jira-mirror.config --field-default
      …` command that would make the override permanent (FR-021).
      Deduplicated by (type, field) — reported once per run, not once per
      creation. When at least one field was filled AND the confirmation
      question never fired — `ask` is off, `--accept-defaults` was given, or
      this is a `-DryRun` — one final line states which reason applied
      (§4.2, FR-015). Returns an array of strings, empty when nothing was
      defaulted this run (FR-028 — the off switch).
    #>
    [CmdletBinding()]
    param(
        [string] $ProjectKey,
        [string] $IssueTypesJson = '[]',
        [string] $DefaultableFieldsByTypeJson = '{}',
        [string] $ResolvedJson = '{}',
        [string] $ActionsJson = '[]',
        [string] $ParentActionJson = 'null',
        [bool] $Ask,
        [bool] $AcceptDefaults,
        [bool] $DryRun
    )
    if ([string]::IsNullOrEmpty($IssueTypesJson)) { $IssueTypesJson = '[]' }
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($ResolvedJson)) { $ResolvedJson = '{}' }
    if ([string]::IsNullOrEmpty($ActionsJson)) { $ActionsJson = '[]' }
    if ([string]::IsNullOrEmpty($ParentActionJson)) { $ParentActionJson = 'null' }

    $itypes = @($IssueTypesJson | ConvertFrom-Json -Depth 100)
    $df = $DefaultableFieldsByTypeJson | ConvertFrom-Json -Depth 100
    $resolved = $ResolvedJson | ConvertFrom-Json -Depth 100
    $actions = @($ActionsJson | ConvertFrom-Json -Depth 100)
    $parent = $ParentActionJson | ConvertFrom-Json -Depth 100

    function Resolve-RfdnTypeName([string] $TypeId) {
        foreach ($t in $itypes) { if ([string]$t.id -eq $TypeId) { return [string]$t.logical_name } }
        return $TypeId
    }
    function Resolve-RfdnLabel([string] $TypeId, [string] $FieldId) {
        $listProp = $df.PSObject.Properties[$TypeId]
        if ($null -ne $listProp) {
            foreach ($f in @($listProp.Value)) { if ([string]$f.field_id -eq $FieldId) { return [string]$f.logical_name } }
        }
        return $FieldId
    }

    $creates = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $parent -and [string]$parent.method -eq 'POST' -and ([string]$parent.url).EndsWith('/issue')) { $creates.Add($parent) }
    foreach ($a in $actions) {
        if ($null -ne $a -and [string]$a.method -eq 'POST' -and ([string]$a.url).EndsWith('/issue')) { $creates.Add($a) }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $creates) {
        $tid = [string]$c.body.fields.issuetype.id
        $fdForType = Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $resolved 'field_defaults') $tid
        if ($null -eq $fdForType) { continue }
        foreach ($p in $fdForType.PSObject.Properties) {
            $fid = $p.Name
            $key = "$tid|$fid"
            if ($seen.Contains($key)) { continue }
            $seen.Add($key) | Out-Null
            $srcForType = Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $resolved 'field_default_sources') $tid
            $source = if ($null -ne $srcForType) { $srcMember = $srcForType.PSObject.Properties[$fid]; if ($srcMember) { [string]$srcMember.Value } else { 'team-config' } } else { 'team-config' }
            $entries.Add([ordered]@{ tid = $tid; fid = $fid; value = $p.Value; source = $source })
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        $label = Resolve-RfdnLabel $e.tid $e.fid
        $typeName = Resolve-RfdnTypeName $e.tid
        $lines.Add("config: project ${ProjectKey}: $label ($typeName) = `"$($e.value)`" — sent from $($e.source)")
    }
    foreach ($e in $entries) {
        if ($e.source -ne 'operator-answer') { continue }
        $label = Resolve-RfdnLabel $e.tid $e.fid
        $typeName = Resolve-RfdnTypeName $e.tid
        $lines.Add("config: project ${ProjectKey}: make this override permanent — /speckit.jira-mirror.config $ProjectKey --field-default '$ProjectKey=$typeName=$label=$($e.value)'")
    }
    if ($entries.Count -gt 0) {
        if ($DryRun) {
            $lines.Add("config: project ${ProjectKey}: this is a preview (--dry-run) — no question was asked and nothing was written")
        }
        elseif ($AcceptDefaults) {
            $lines.Add("config: project ${ProjectKey}: the confirmation question was skipped — --accept-defaults was given")
        }
        elseif (-not $Ask) {
            $lines.Add("config: project ${ProjectKey}: the confirmation question was skipped — field-defaults confirmation is off for this project (ask: false)")
        }
    }
    return $lines
}

function Get-JiraPlanPropSafe {
    # Safe property read (an empty PSCustomObject throws under StrictMode when
    # indexing a member that does not exist).
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    return $member.Value
}

function Get-JiraReconcileLocalBindingFor {
    <#
    .SYNOPSIS
      The persisted binding's resolved_ids entry for one project, read
      directly from the machine-owned local layer (independent of config.yml).
      Mirror of _reconcile_local_binding_for. Returns { ExitCode; Json }:
      ExitCode 0 on success; 2 when the local layer is missing ENTIRELY (never
      bound at all); 3 when the file exists but holds no entry for this
      project (FR-010, project-not-bound); 4 (EXIT_CONFIG) when the file
      exists but cannot be read — distinct from both 2 and 3, propagated
      rather than treated as "not bound" (Constitution III).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] [string] $ConfigDir)
    $path = Get-CfgLocalPath -ConfigDir $ConfigDir
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ ExitCode = 2; Json = '' } }
    # Get-CfgLocalObject returns nested IDictionary (OrderedDictionary) nodes,
    # not PSCustomObjects — indexed by key, not by .PSObject.Properties.
    try { $obj = Get-CfgLocalObject -ConfigDir $ConfigDir }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        return [pscustomobject]@{ ExitCode = 4; Json = '' }
    }
    $entry = $null
    if ($obj -is [System.Collections.IDictionary] -and $obj.Contains('resolved_ids')) {
        $resolvedIds = $obj['resolved_ids']
        if ($resolvedIds -is [System.Collections.IDictionary] -and $resolvedIds.Contains($ProjectKey)) {
            $entry = $resolvedIds[$ProjectKey]
        }
    }
    if ($null -eq $entry) { return [pscustomobject]@{ ExitCode = 3; Json = '' } }
    # binding-shape-stale (008 T016, research R5): a binding written before
    # this feature stores issue_types as a name-to-id MAP, not the hierarchy-
    # carrying list (data-model.md §3). Detected here, before any type
    # resolution is attempted, so an old binding never falls through to
    # plan_writes with an empty issue type — it refuses with its OWN message
    # instead, never the "not bound yet" text.
    if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('issue_types') -and $entry['issue_types'] -is [System.Collections.IDictionary]) {
        return [pscustomobject]@{ ExitCode = 6; Json = '' }
    }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-Json -InputObject $entry -Compress -Depth 20) }
}

function Get-JiraReconcilePlanContextFromBinding {
    <#
    .SYNOPSIS
      The plan context (US2, FR-007–FR-011, FR-013): base_url plus either the
      caller's SPEC_KIT_JIRA_PLAN_CONTEXT override (wholesale) or the creation
      context built from the resolved project's persisted binding —
      story_type_id, the two-step-resolved priority_ids, and
      estimation_field_id. Mirror of _reconcile_plan_context. Returns
      { ExitCode; Json }; ExitCode is 2/3 exactly as
      Get-JiraReconcileLocalBindingFor when no override is set and the
      binding cannot be read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [Parameter(Mandatory)] [string] $ConfigJson,
        [string] $RecognitionJson = '{}',
        [string] $FieldValues = '',
        [string] $TasksRecognitionJson = '{}'
    )
    if ($env:SPEC_KIT_JIRA_PLAN_CONTEXT) {
        return [pscustomobject]@{ ExitCode = 0; Json = (Get-JiraReconcilePlanContext -BaseUrl $BaseUrl) }
    }

    $bindingResult = Get-JiraReconcileLocalBindingFor -ProjectKey $ProjectKey -ConfigDir $ConfigDir
    if ($bindingResult.ExitCode -ne 0) { return [pscustomobject]@{ ExitCode = $bindingResult.ExitCode; Json = '' } }
    $binding = $bindingResult.Json | ConvertFrom-Json -Depth 100

    # child_type.id, not the literal .issue_types.Story (008 T046/R5): the
    # binding's issue_types is a hierarchy-carrying LIST now, and the child
    # type is whatever the persisted binding recorded — derived or an
    # operator answer (contracts/hierarchy-resolution.md §2). A binding with
    # no child_type (old shape, or not yet configured) yields empty.
    $storyType = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $binding 'child_type') 'id')
    # child-type-unresolved (contract §6): a binding in the new shape but
    # with no recorded child_type refuses by name — never a silent empty
    # story type reaching plan_writes far later (research R5).
    if ([string]::IsNullOrEmpty($storyType)) { return [pscustomobject]@{ ExitCode = 7; Json = '' } }
    $parentTypeId = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $binding 'parent_type') 'id')
    $parentLinkAvail = Get-JiraPlanPropSafe $binding 'parent_link_available'
    $parentSupportsLink = [bool](Get-JiraPlanPropSafe $parentLinkAvail $storyType)
    $cfg = $ConfigJson | ConvertFrom-Json -Depth 100
    $priorityMap = $null
    $projectsVal = Get-JiraPlanPropSafe $cfg 'projects'
    $projects = if ($null -ne $projectsVal) { @($projectsVal) } else { @() }
    foreach ($p in $projects) {
        if ([string](Get-JiraPlanPropSafe $p 'key') -eq $ProjectKey) { $priorityMap = Get-JiraPlanPropSafe $p 'priority_map'; break }
    }
    $priorities = Get-JiraPlanPropSafe $binding 'priorities'
    $estField = [string](Get-JiraPlanPropSafe $binding 'estimation_field_id')

    # Recorded field defaults (011, research R2): resolved to {issue-type-id:
    # {field-id: value}} at plan time, the same shape Get-JiraCreateFieldsBase
    # merges into a create payload. Absence is the off switch (FR-028) — with
    # nothing recorded and no --field-value answer this resolves to {}, and
    # the omitted key below leaves Get-JiraPlanWriteSet's output
    # byte-identical to before this feature.
    $fdItypesRaw = Get-JiraPlanPropSafe $binding 'issue_types'
    $fdItypesJson = if ($null -ne $fdItypesRaw) { ConvertTo-JiraJsonValue @($fdItypesRaw) } else { '[]' }
    $fdDfRaw = Get-JiraPlanPropSafe $binding 'defaultable_fields'
    $fdDfJson = if ($null -ne $fdDfRaw) { ConvertTo-JiraJsonValue $fdDfRaw } else { '{}' }
    $fdRecordedJson = Get-JiraFieldDefaultsFor -ProjectKey $ProjectKey -ConfigJson $ConfigJson
    $fdAnswersJson = Get-JiraFieldAnswersFor -ProjectKey $ProjectKey -FieldFlags $FieldValues
    # 015, research R1/R2, contract §2: the plan context is the SENDING side —
    # it reads the encoded map, shaped for the wire, while every display-facing
    # consumer elsewhere in this file keeps reading the recorded map unchanged.
    $fieldDefaultsJson = (Get-JiraPlanResolveFieldDefault -IssueTypesJson $fdItypesJson -DefaultableFieldsByTypeJson $fdDfJson `
            -RecordedJson $fdRecordedJson -AnswersJson $fdAnswersJson | ConvertFrom-Json -Depth 100).field_defaults_encoded

    # Two-step priority resolution (FR-008): level -> logical name (team
    # config) -> identifier (persisted binding). Either step yielding nothing
    # omits the level rather than blocking the run (FR-011).
    $priorityIds = [ordered]@{}
    foreach ($lvl in @('P1', 'P2', 'P3')) {
        $logical = [string](Get-JiraPlanPropSafe $priorityMap $lvl)
        if ([string]::IsNullOrEmpty($logical)) { continue }
        $id = [string](Get-JiraPlanPropSafe $priorities $logical)
        if ([string]::IsNullOrEmpty($id)) { continue }
        $priorityIds[$lvl] = $id
    }

    # Phase 3, US1: tickets/ticket_origins/ticket_descriptions come from
    # recognition's `bound` map instead of only from the override
    # (data-model.md "Plan context").
    $recog = $RecognitionJson | ConvertFrom-Json -Depth 100
    $boundVal = Get-JiraPlanPropSafe $recog 'bound'
    $tickets = [ordered]@{}
    $ticketOrigins = [ordered]@{}
    $ticketDescriptions = [ordered]@{}
    # ticket_parents (T109): only the entries whose CURRENT parent is
    # non-null — a flat mirror with no parent at all is left alone (plan.md
    # "No migration"); a child linked to the wrong parent is what
    # Get-JiraPlanWriteSet corrects.
    $ticketParents = [ordered]@{}
    # ticket_labels (017, US2, contracts/provenance-label.md §2/§3): each
    # recognised ticket's CURRENT labels, already unique-normalised by
    # recognition — omitted entirely when empty, like every neighbouring map.
    $ticketLabels = [ordered]@{}
    # ticket_summaries / ticket_last_summaries (018, T047; contracts/
    # summary-record.md §2/§3): the CURRENT summary Jira holds, and the
    # summary this mirror last WROTE (from the identity marker), per bound
    # ticket. ticketLastSummaries omits an entry for a marker predating the
    # record, exactly as Recognition.psm1's own last_summary is omitted.
    $ticketSummaries = [ordered]@{}
    $ticketLastSummaries = [ordered]@{}
    # ticket_last_checklists (022, data-model.md §3): mirrors
    # ticket_last_summaries exactly, one field over.
    $ticketLastChecklists = [ordered]@{}
    if ($boundVal) {
        foreach ($p in $boundVal.PSObject.Properties) {
            $tickets[$p.Name] = [string](Get-JiraPlanPropSafe $p.Value 'key')
            # 018, T025: populated for EVERY recognised ticket now — the
            # managed-panel splice is origin-independent (contract §3) and
            # routes through the SAME resolution regardless of "bridge" or
            # "human". Before this feature, "bridge" was excluded here
            # because Get-JiraPlanWriteSet owned the whole description on
            # that origin; that discriminator is gone.
            $originVal = [string](Get-JiraPlanPropSafe $p.Value 'origin')
            $ticketOrigins[$p.Name] = $originVal
            $current = Get-JiraPlanPropSafe $p.Value 'current'
            $ticketDescriptions[$p.Name] = Get-JiraPlanPropSafe $current 'description'
            $currentParent = Get-JiraPlanPropSafe $current 'parent'
            if ($null -ne $currentParent) { $ticketParents[$p.Name] = [string]$currentParent }
            $ticketLabels[$p.Name] = @(Get-JiraPlanPropSafe $current 'labels')
            $ticketSummaries[$p.Name] = [string](Get-JiraPlanPropSafe $current 'summary')
            $lastSummaryVal = Get-JiraPlanPropSafe $p.Value 'last_summary'
            if ($null -ne $lastSummaryVal) { $ticketLastSummaries[$p.Name] = [string]$lastSummaryVal }
            $lastChecklistVal = Get-JiraPlanPropSafe $p.Value 'last_checklist'
            if ($null -ne $lastChecklistVal) { $ticketLastChecklists[$p.Name] = [string]$lastChecklistVal }
        }
    }

    # Phase 3, US1: the task tier's own type id and the recognised
    # sub-tasks' keys/current content, merged into the SAME tickets map
    # (safe — task and story local_ids are disjoint by construction) plus
    # a task-only ticket_current map that Get-JiraPlanTaskWriteSet compares
    # against for zero churn (contract §4 rule 3). Both are empty, and
    # task_type_id absent, when no `task` role resolved — leaving this
    # function's output byte-identical to before this feature (FR-011).
    $rolesVal = Get-JiraPlanPropSafe $binding 'roles'
    $taskTypeId = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $rolesVal 'task') 'id')
    # 022, data-model.md §1, T020: the resolved task_mirror mode, carried
    # into the plan context beside the resolved facts above — the SAME
    # resolution $taskTierMode uses in cmd_reconcile (contract §7), so a
    # recorded 'checklist' wins over a declared role, and nothing recorded
    # falls back to feature 012's behaviour byte-for-byte (FR-002).
    $taskMirrorRecordedPc = Get-JiraTaskMirrorFor -ProjectKey $ProjectKey -ConfigJson $ConfigJson
    $taskMirrorPc = ''
    if ($taskMirrorRecordedPc -eq 'checklist') {
        $taskMirrorPc = 'checklist'
    } elseif (-not [string]::IsNullOrEmpty($taskTypeId)) {
        $taskMirrorPc = 'subtask'
    }
    $tasksRecog = $TasksRecognitionJson | ConvertFrom-Json -Depth 100
    $tasksBoundVal = Get-JiraPlanPropSafe $tasksRecog 'bound'
    $ticketCurrent = [ordered]@{}
    if ($tasksBoundVal) {
        foreach ($p in $tasksBoundVal.PSObject.Properties) {
            $tickets[$p.Name] = [string](Get-JiraPlanPropSafe $p.Value 'key')
            $taskCurrent = Get-JiraPlanPropSafe $p.Value 'current'
            $ticketCurrent[$p.Name] = $taskCurrent
            $ticketSummaries[$p.Name] = [string](Get-JiraPlanPropSafe $taskCurrent 'summary')
            $taskLastSummaryVal = Get-JiraPlanPropSafe $p.Value 'last_summary'
            if ($null -ne $taskLastSummaryVal) { $ticketLastSummaries[$p.Name] = [string]$taskLastSummaryVal }
            # ticket_origins also carries the task tier (018, T049).
            $ticketOrigins[$p.Name] = [string](Get-JiraPlanPropSafe $p.Value 'origin')
        }
    }

    $result = [ordered]@{ base_url = $BaseUrl }
    if (-not [string]::IsNullOrEmpty($storyType)) { $result['story_type_id'] = $storyType }
    if (-not [string]::IsNullOrEmpty($parentTypeId)) { $result['parent_type_id'] = $parentTypeId }
    $result['parent_supports_link'] = $parentSupportsLink
    if ($priorityIds.Count -gt 0) { $result['priority_ids'] = $priorityIds }
    if (-not [string]::IsNullOrEmpty($estField)) { $result['estimation_field_id'] = $estField }
    if ($tickets.Count -gt 0) { $result['tickets'] = $tickets }
    if ($ticketOrigins.Count -gt 0) { $result['ticket_origins'] = $ticketOrigins }
    if ($ticketDescriptions.Count -gt 0) { $result['ticket_descriptions'] = $ticketDescriptions }
    if ($ticketParents.Count -gt 0) { $result['ticket_parents'] = $ticketParents }
    if ($ticketLabels.Count -gt 0) { $result['ticket_labels'] = $ticketLabels }
    # defaultable_fields_by_type / issue_types (017, contract §4): the RAW
    # per-type map discovery already records, plus the type-id -> logical-name
    # list — threaded through so Get-JiraPlanApplyLabelDecision can answer
    # "does this type's create screen offer labels at all" without a second
    # discovery pass. Omitted when the binding predates them (mirror of
    # _reconcile_plan_context; R6's "not recorded at all ⇒ send" branch reads
    # this same absence).
    if ($null -ne $fdDfRaw -and @($fdDfRaw.PSObject.Properties).Count -gt 0) { $result['defaultable_fields_by_type'] = $fdDfRaw }
    if ($null -ne $fdItypesRaw -and @($fdItypesRaw).Count -gt 0) { $result['issue_types'] = @($fdItypesRaw) }
    if (@($fieldDefaultsJson.PSObject.Properties).Count -gt 0) { $result['field_defaults'] = $fieldDefaultsJson }
    if (-not [string]::IsNullOrEmpty($taskTypeId)) { $result['task_type_id'] = $taskTypeId }
    if (-not [string]::IsNullOrEmpty($taskMirrorPc)) { $result['task_mirror'] = $taskMirrorPc }
    if ($ticketCurrent.Count -gt 0) { $result['ticket_current'] = $ticketCurrent }
    if ($ticketSummaries.Count -gt 0) { $result['ticket_summaries'] = $ticketSummaries }
    if ($ticketLastSummaries.Count -gt 0) { $result['ticket_last_summaries'] = $ticketLastSummaries }
    if ($ticketLastChecklists.Count -gt 0) { $result['ticket_last_checklists'] = $ticketLastChecklists }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-Json -InputObject $result -Compress -Depth 20) }
}

function Invoke-JiraReconcile {
    <#
    .SYNOPSIS
      Reconcile one specification into its Jira project. Writes the run summary via
      the [Console] streams and returns ONLY its numeric exit code.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    try {
        return (Invoke-JiraReconcileRun -Arguments $Arguments)
    }
    finally {
        Write-JiraTimingReport
    }
}

# Invoke-JiraReconcileRun — thin-wrapped by Invoke-JiraReconcile so the timing
# report (contracts/timing-report.md) fires on every one of this function's
# many return paths, not only the final one (021, T015). Mirror of the Bash
# port's _reconcile_run.
function Invoke-JiraReconcileRun {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("reconcile: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'
    $force = $state['force'] -eq 'true'
    $onDrift = if ($state.ContainsKey('on_drift') -and $state['on_drift']) { $state['on_drift'] } else { 'abort' }
    $fieldValues = if ($state.ContainsKey('field_values')) { $state['field_values'] } else { '' }
    $acceptDefaults = $state['accept_defaults'] -eq 'true'

    Start-JiraTimingPhase -Phase 'prereq' -RequestCount (Get-JiraRequestCount)

    # (0) DISPATCH GUARD — the operator's disable decision, honoured before any
    # prerequisite check, any config read and any network call (FR-020). The exit
    # is INERT: no Jira call, and no warning either. A warning here would be noise
    # on every single lifecycle command for an event the operator deliberately
    # turned off, which is precisely what FR-020 forbids.
    $hookEvent = if ($env:SPEC_KIT_JIRA_HOOK_EVENT) { $env:SPEC_KIT_JIRA_HOOK_EVENT } else { '' }
    try {
        if (Test-JiraReconcileHeld -LifecycleEvent $hookEvent) { return 0 }
    }
    catch {
        # An unreadable disable record is not evidence that nothing is
        # disabled (Constitution X) — propagate rather than silently
        # proceeding as if the event were not held.
        [Console]::Error.WriteLine($_.Exception.Message)
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the operator disable record could not be read (zero writes)')
    }

    # The spec file is the first positional argument.
    $specFile = ''
    foreach ($a in $Arguments) {
        if ($a -eq 'reconcile' -or $a.StartsWith('-')) { continue }
        $specFile = $a; break
    }
    # -PathType Leaf (NOT a bare Test-Path): a directory exists as a path but
    # is not a readable FILE, and must keep this message rather than falling
    # through to the target guard below (contracts/target-guard.md §5 T11) —
    # the mirror of the Bash port's `-f` test, which a bare Test-Path is not.
    if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path -LiteralPath $specFile -PathType Leaf)) {
        return (Get-JiraReconcileFaultCode -Code ([int](Get-JiraExitCode 'usage')) -Message 'reconcile: a readable spec file argument is required')
    }

    # TARGET GUARD (User Story 1, FR-001–FR-008, contracts/target-guard.md
    # §1–§3): only a feature folder's own spec.md is ever mirrored. This runs
    # before any configuration read, any network call and any file write —
    # the earliest point at which the target is known (research R1: after
    # the dispatch guard above, so an event the operator disabled stays
    # silent). Split-Path -Leaf ONLY — never a glob or a suffix test
    # (research R3) — and -cne for byte-equal, case-sensitive comparison; the
    # native `specs\001-x\spec.md` separator spelling passes here because
    # Split-Path -Leaf is this port's own path-splitting primitive.
    $targetName = Split-Path -Leaf $specFile
    if ($targetName -cne 'spec.md') {
        # The parent is cut out of the caller's OWN bytes — never through
        # Split-Path -Parent, and never through Join-Path. Both go through the
        # FileSystem provider, which rewrites every separator to the host's
        # native one (`/` becomes `\` on Windows), and contract §3 requires
        # <sibling> to be spelled the way the caller spelled the target.
        # Splitting on the last separator the argument itself carries, then
        # re-joining with that same character, keeps the refusal byte-identical
        # to the Bash twin's `dirname` on every host (FR-027).
        $cut = $specFile.LastIndexOfAny([char[]]@('/', '\'))
        if ($cut -lt 0) {
            $targetDir = '.'
            $sep = '/'
        }
        else {
            $sep = $specFile[$cut]
            $targetDir = $specFile.Substring(0, $cut)
            # A root-level target ("/plan.md") leaves nothing to the left of the
            # cut; `dirname` answers the root itself, and the Bash twin's
            # "$(dirname …)/spec.md" then doubles the separator. Mirrored here
            # rather than tidied, because the corpus compares bytes.
            if ($targetDir -eq '') { $targetDir = [string]$sep }
        }
        $siblingSpec = "$targetDir$sep" + 'spec.md'
        if (Test-Path -LiteralPath $siblingSpec -PathType Leaf) {
            $targetMsg = "reconcile: `"$specFile`" is not a feature specification — only a feature folder's spec.md is ever mirrored (zero writes); the target for this folder is `"$siblingSpec`""
        }
        else {
            $targetMsg = "reconcile: `"$specFile`" is not a feature specification — only a feature folder's spec.md is ever mirrored (zero writes); no spec.md exists in that folder"
        }
        return (Get-JiraReconcileFaultCode -Code ([int](Get-JiraExitCode 'usage')) -Message $targetMsg)
    }

    # The resolution chokepoint (030, plan.md §Key design decision): seed
    # SPEC_KIT_JIRA_BASE_URL / JIRA_EMAIL from config.yml / personal.yml,
    # environment first. Runs before the base-url check just below.
    if ((Resolve-JiraConnection -ConfigDir (Get-JiraConfigDirPath)) -ne 0) {
        # 032, C5.2 — relay the destination pin's OWN message. This call site
        # substitutes a generic line for whatever the library reported, which
        # would otherwise discard the located refusal (both origins named, plus
        # the accepting invocation) on exactly the path a lifecycle hook takes.
        # The status is consulted rather than the message being composed in the
        # library, because only this layer knows how to report through the fault
        # path that keeps the host command's outcome intact.
        if ((Get-JiraConnectionPinStatus) -ne 'proceed') {
            return (Get-JiraReconcileFaultCode -Code ([int](Get-JiraExitCode 'config')) -Message (Get-JiraConnectionPinMessage -ConfigDir (Get-JiraConfigDirPath)))
        }
        return (Get-JiraReconcileFaultCode -Code ([int](Get-JiraExitCode 'config')) -Message 'reconcile: the team configuration could not be loaded (zero writes)')
    }

    # NOT YET CONFIGURED (FR-017 first cause, FR-019). This is the normal state of
    # a freshly installed repository, not an error: the lifecycle step behaves
    # exactly as it would without the extension, apart from one notice. At most
    # three lines, exit 0 — a hook must never turn "you haven't set this up yet"
    # into a failed spec-kit command.
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    if ([string]::IsNullOrEmpty($base)) {
        Write-JiraReconcileNotice -Lines @(
            'Jira mirror skipped: this repository is not bound to a Jira project yet.',
            'Nothing was mirrored, and this spec-kit command completed normally.',
            'To bind it, run /speckit.jira-mirror.config.')
        return 0
    }

    # BRIDGE UNAVAILABLE (FR-017 sixth cause, T090). Reported as its OWN cause and
    # never folded into "not configured" above or the generic prerequisite gate: a
    # missing entry point is an incomplete install with an install remedy. The
    # state where NEITHER port starts cannot be reported from here at all —
    # nothing of ours is running — which is why the command documents carry the
    # verbatim fallback block for it (FR-030).
    $bridgeMissing = Get-JiraMissingBridgeEntry
    if ($bridgeMissing) {
        Write-JiraReconcileNotice -Lines @(
            "Jira mirror skipped: the bridge entry point $bridgeMissing was not found; the extension install is incomplete. This spec-kit command completed normally and nothing was mirrored to Jira. Restore it with: specify extension add jira-mirror --from https://github.com/Fyloss/spec-kit-jira-mirror/releases/latest/download/spec-kit-jira-mirror.zip --force (it will ask you to confirm an untrusted-source prompt — answer y)")
        return 0
    }

    Stop-JiraTimingPhase -Phase 'prereq' -RequestCount (Get-JiraRequestCount)

    # `state` — the run-state short-circuit (Phase 4, US2, contracts/run-state.md
    # §2–§3). Runs after the dispatch and target guards and before the config
    # phase, composing from hashed inputs only — there is no resolved project
    # key here. `-Force` and `-DryRun` both skip the read entirely (full
    # reconcile in both cases, §3); every other run compares against the
    # recorded document and, on a byte match, short-circuits with zero Jira
    # requests and zero writes.
    Start-JiraTimingPhase -Phase 'state' -RequestCount (Get-JiraRequestCount)
    $shortCircuited = $false
    $email = if ($env:JIRA_EMAIL) { $env:JIRA_EMAIL } else { '' }
    if (-not $force -and -not $dryRun) {
        if (Test-JiraRunStateMatch -SpecPath $specFile -BaseUrl $base -Email $email -OnDrift $onDrift -HookEvent $hookEvent -FieldValues $fieldValues) {
            $shortCircuited = $true
        }
    }
    Stop-JiraTimingPhase -Phase 'state' -RequestCount (Get-JiraRequestCount)

    if ($shortCircuited) {
        $scSummaryObj = [ordered]@{
            schema_version  = '1.0'
            command         = 'reconcile'
            dry_run         = $false
            short_circuited = $true
            state_file      = (Get-JiraRunStatePath -SpecPath $specFile)
            counts          = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = 0; errors = 0 }
            actions         = @()
            exit_code       = 0
        }
        $scSummary = ConvertTo-JiraJsonValue $scSummaryObj
        if ($json) {
            [Console]::Out.Write($scSummary + "`n")
        }
        else {
            [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $scSummary))
        }
        return 0
    }

    Start-JiraTimingPhase -Phase 'config' -RequestCount (Get-JiraRequestCount)

    # Split-Path -Parent yields '' for a bare filename and for a root-level path,
    # where the Bash port's dirname yields '.' and '/' — map those the same way
    # so both ports resolve the folder (NFR-1) instead of failing the schema.
    $specParent = Split-Path -Parent $specFile
    if ([string]::IsNullOrEmpty($specParent)) {
        $specParent = if ($specFile.StartsWith('/')) { '/' } else { '.' }
    }
    $folder = (Resolve-Path -LiteralPath $specParent).Path
    $slug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { Split-Path -Leaf $folder }
    $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }

    # Routing + creation-context resolution (US1/US2, FR-001–FR-013): per
    # value, an explicit override wins; otherwise the value is derived from
    # the repository's own config, read exactly once and only when something
    # needs it — a run whose project key, epic strategy AND plan context are
    # ALL overridden never reads config.yml at all (contract "Precedence"). A
    # run overriding only the project key and epic strategy still needs
    # config.yml for priority_map, since the plan context (unless itself
    # overridden) is built from it (T057, FR-008). config.yml's absence maps
    # to the same not-configured notice as a missing base URL; a
    # present-but-invalid config.yml surfaces through Import-JiraConfig's own
    # EXIT_CONFIG path.
    $overrideProject = $env:SPEC_KIT_JIRA_PROJECT_KEY
    $cfgDir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }
    $cfg = '{}'
    if ([string]::IsNullOrEmpty($overrideProject) -or [string]::IsNullOrEmpty($env:SPEC_KIT_JIRA_PLAN_CONTEXT)) {
        if (-not (Test-Path -LiteralPath (Join-Path $cfgDir 'config.yml'))) {
            Write-JiraReconcileNotice -Lines @(
                'Jira mirror skipped: this repository is not bound to a Jira project yet.',
                'Nothing was mirrored, and this spec-kit command completed normally.',
                'To bind it, run /speckit.jira-mirror.config.')
            return 0
        }
        $loaded = Import-JiraConfig -ConfigDir $cfgDir
        if ($loaded.ExitCode -ne 0) {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the team configuration could not be loaded (zero writes)')
        }
        $cfg = $loaded.Json
    }

    $projectFromConfig = $false
    if (-not [string]::IsNullOrEmpty($overrideProject)) {
        $projectKey = $overrideProject
    }
    else {
        $routed = Resolve-JiraReconcileRouting -Folder $folder -ConfigJson $cfg
        if ($routed.ExitCode -ne 0) {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: routing could not be resolved — no rule in $cfgDir/config.yml matched `"$(Split-Path -Leaf $folder)`" and no routing_default is configured; add routing_default to config.yml")
        }
        $projectKey = $routed.ProjectKey
        $projectFromConfig = $true
    }

    # FR-005: refuse an absent, syntactically invalid, or placeholder key —
    # before any network call, so zero writes ever occur for it.
    if ([string]::IsNullOrEmpty($projectKey) -or $projectKey -cnotmatch '^[A-Z][A-Z0-9_]+$') {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the resolved project key is missing or syntactically invalid (zero writes)')
    }
    if (Test-JiraPlaceholderKey -Key $projectKey) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: the project is still set to the shipped placeholder `"$projectKey`" — run /speckit.jira-mirror.config to bind a real project (zero writes)")
    }

    # US3 unknown-project: a routing rule (or routing_default/team route) named
    # a project the team config never declares in projects[] — distinct from
    # an override, which may legitimately name a project outside config.yml.
    if ($projectFromConfig) {
        $cfgObj = $cfg | ConvertFrom-Json -Depth 100
        $projectsVal = Get-JiraPlanPropSafe $cfgObj 'projects'
        $declaredProjects = if ($null -ne $projectsVal) { @($projectsVal) } else { @() }
        $declared = $false
        foreach ($p in $declaredProjects) {
            if ([string](Get-JiraPlanPropSafe $p 'key') -eq $projectKey) { $declared = $true; break }
        }
        if (-not $declared) {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: a routing rule names project `"$projectKey`", which is not declared in $cfgDir/config.yml's projects[] — correct the rule in config.yml (zero writes)")
        }
    }

    $specRef = [ordered]@{ repo = $repo; spec_slug = $slug; folder = $folder }
    $specRefJson = ConvertTo-JiraJsonValue $specRef

    # Stray-marker scan (FR-007, contracts/target-guard.md §4): runs on every
    # valid target, dry-run included, and never changes the exit code.
    # Computed once, here, and folded into the run summary's warnings array
    # below.
    $strayFiles = Get-JiraMarkerSpliceStrayFile -Folder $folder

    # Phase 6, US4: the phase->status map and halted-status list this run's
    # lifecycle-safety rules resolve against — declared per project, exactly
    # like priority_map (FR-006). Absent a declaration both default to empty.
    $phaseStatusMap = Get-JiraReconcilePhaseStatusMap -ProjectKey $projectKey -ConfigJson $cfg
    $haltedStatuses = Get-JiraReconcileHaltedStatuses -ProjectKey $projectKey -ConfigJson $cfg

    Stop-JiraTimingPhase -Phase 'config' -RequestCount (Get-JiraRequestCount)
    Start-JiraTimingPhase -Phase 'gate' -RequestCount (Get-JiraRequestCount)

    # Mandatory-field gate (Phase 6, US3, T086/T087/T088; contracts/
    # hierarchy-resolution.md §4/§5), moved ahead of spec-marker assignment
    # by Phase 4 (US2, T066): a run that turns out to stop for the
    # consolidated question (below) must write NEITHER spec.md's markers NOR
    # anything to Jira, so the marker file write further down is gated on
    # $fdAskPending too. Runs after derivation and before recognition, so no
    # read and no write has happened yet. Reads the SAME persisted binding
    # the plan context reads later; a binding that cannot be read yet, or
    # resolves to no bound project, is reported exactly as the plan-context
    # path already reports it — that error surfaces at its usual point below
    # rather than being duplicated here.
    $fdAskPending = $false
    $fdItypesJson = '[]'
    $fdDfJson = '{}'
    $fdDefaultsByTypeJson = '{}'
    $gateResult = $null
    $gateResolved = $null
    $gateAsk = $true
    # Phase 3, US1: the task tier's own type id, read from the SAME
    # binding — its presence is what "a task role is declared" means
    # (FR-011). Reading tasks.md is gated on this, further down, never on
    # the file's mere existence.
    $taskTypeIdCandidate = ''
    $gateBindingResult = Get-JiraReconcileLocalBindingFor -ProjectKey $projectKey -ConfigDir $cfgDir
    if ($gateBindingResult.ExitCode -eq 0) {
        $gateBinding = $gateBindingResult.Json | ConvertFrom-Json -Depth 100
        $gateRolesForTask = Get-JiraPlanPropSafe $gateBinding 'roles'
        $taskTypeIdCandidate = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $gateRolesForTask 'task') 'id')
        $gateChildType = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $gateBinding 'child_type') 'id')
        if (-not [string]::IsNullOrEmpty($gateChildType)) {
            # Recorded field defaults (011, research R2/R5, contract §3.3/
            # §3.4/§3.10): a required field with a recorded default or a
            # this-run --field-value answer is now satisfiable. A required
            # field that remains unsatisfiable still refuses here UNCHANGED
            # when the operator cannot be asked — `ask` is off,
            # --accept-defaults was given, or this is a --dry-run (§4.3: the
            # preview never asks, only ever previews or refuses). Otherwise
            # the refusal is DEFERRED to the consolidated question below
            # ($fdAskPending), fired only once the plan shows a creation is
            # actually pending (FR-013) — never merely offered (FR-028).
            $gateItypesRaw = Get-JiraPlanPropSafe $gateBinding 'issue_types'
            $fdItypesJson = if ($null -ne $gateItypesRaw) { ConvertTo-JiraJsonValue @($gateItypesRaw) } else { '[]' }
            $gateDfRaw = Get-JiraPlanPropSafe $gateBinding 'defaultable_fields'
            $fdDfJson = if ($null -ne $gateDfRaw) { ConvertTo-JiraJsonValue $gateDfRaw } else { '{}' }
            $gateRecordedJson = Get-JiraFieldDefaultsFor -ProjectKey $projectKey -ConfigJson $cfg
            $gateAnswersJson = Get-JiraFieldAnswersFor -ProjectKey $projectKey -FieldFlags $fieldValues
            $gateResolved = Get-JiraPlanResolveFieldDefault -IssueTypesJson $fdItypesJson -DefaultableFieldsByTypeJson $fdDfJson `
                -RecordedJson $gateRecordedJson -AnswersJson $gateAnswersJson | ConvertFrom-Json -Depth 100
            $fdDefaultsByTypeJson = ConvertTo-JiraJsonValue $gateResolved.field_defaults
            $gateAsk = [bool]($gateRecordedJson | ConvertFrom-Json -Depth 100).ask

            $gateResult = Get-JiraHierarchyMandatoryGate -Binding $gateBinding -ProjectKey $projectKey -DefaultsByType ($fdDefaultsByTypeJson | ConvertFrom-Json -Depth 100)
            $gateAskable = $gateAsk -and (-not $acceptDefaults) -and (-not $dryRun)
            if ($gateResult.status -eq 'unsatisfiable' -and $gateAskable) {
                $fdAskPending = $true
            }
            elseif ($gateResult.status -ne 'ok') {
                return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message $gateResult.message)
            }
            elseif ($gateAskable -and (@(($fdDefaultsByTypeJson | ConvertFrom-Json -Depth 100).PSObject.Properties).Count -gt 0)) {
                # gate status == ok but at least one default is resolved: a
                # recorded default might be about to land on a pending
                # creation (§3.3 trigger 1) — confirmed once the plan is
                # known, below.
                $fdAskPending = $true
            }
        }

        # §8 re-validation (Phase 6, US4, T052; contract §8): check 4
        # (ordering) re-run against the PERSISTED binding's roles,
        # `reconcile:` prefixed, no re-read of the project's metadata.
        # Checks 5/6 are already re-validated above via
        # Get-JiraHierarchyMandatoryGate, which reads the same
        # dual-written child_type/parent_type keys regardless of this
        # feature. A binding with no `roles` property — written before
        # 010, or a project whose mapping was never resolved past style —
        # stays non-fatal.
        $gateRoles = Get-JiraPlanPropSafe $gateBinding 'roles'
        if ($null -ne $gateRoles) {
            $reconcileOrderingMessage = $null
            if (-not (Test-JiraRoleMappingReconcile -ProjectKey $projectKey -Roles $gateRoles -Message ([ref]$reconcileOrderingMessage))) {
                return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message $reconcileOrderingMessage)
            }
        }
    }

    # 022, research.md §6: the ONE gate above splits into three independent
    # conditions once task_mirror is in play. $taskTierMode is the single
    # resolved source of truth for all three: '' (no tier), 'subtask'
    # (feature 012 unchanged), or 'checklist' (022). A recorded 'checklist'
    # wins over a declared role (contract §7, FR-007) — the role is
    # reported as recorded and not consumed, never both mirrored. With
    # nothing recorded, this is BYTE-IDENTICAL to the pre-022 single
    # condition (FR-002).
    $taskMirrorRecorded = Get-JiraTaskMirrorFor -ProjectKey $projectKey -ConfigJson $cfg
    $taskTierMode = ''
    if ($taskMirrorRecorded -eq 'checklist') {
        $taskTierMode = 'checklist'
    } elseif (-not [string]::IsNullOrEmpty($taskTypeIdCandidate)) {
        $taskTierMode = 'subtask'
    }

    Stop-JiraTimingPhase -Phase 'gate' -RequestCount (Get-JiraRequestCount)
    Start-JiraTimingPhase -Phase 'parse' -RequestCount (Get-JiraRequestCount)

    # R5 step 1 — ASSIGN (Phase 2/3, contracts/story-marker.md, research R5):
    # every story section with no marker at all gets a durable identifier,
    # spliced into spec.md. A dry run computes the SAME assignment but never
    # writes it (FR-016) — the in-memory assigned text is what the rest of
    # THIS run parses, so a dry run predicts the exact identifiers a
    # following real run would use. An unwritable spec.md fails closed
    # BEFORE any Jira write (FR-012).
    $rawSpec = Get-Content -Raw -LiteralPath $specFile
    if ($null -eq $rawSpec) { $rawSpec = '' }
    try { $preParse = Get-JiraParsedSpec -Text $rawSpec -FolderSlug $slug }
    catch {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the specification could not be parsed (zero writes)')
    }
    $preParseObj = $preParse | ConvertFrom-Json -Depth 100
    $assignedCount = @($preParseObj.stories | Where-Object {
            $m = Get-JiraPlanPropSafe $_ 'marker'
            $st = if ($m) { [string](Get-JiraPlanPropSafe $m 'state') } else { 'absent' }
            $st -eq 'absent'
        }).Count

    $preEpicMarker = Get-JiraPlanPropSafe $preParseObj 'epic'
    $preEpicMarkerState = if ($preEpicMarker) { [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $preEpicMarker 'marker') 'state') } else { 'absent' }
    if ([string]::IsNullOrEmpty($preEpicMarkerState)) { $preEpicMarkerState = 'absent' }
    $parentNeedsAssign = $preEpicMarkerState -eq 'absent'

    # Ordering within one run, step 1/2 (contracts/parent-marker.md): stories
    # first, the parent second — same pass, same file, ONE splice.
    $assignedSpec = $rawSpec
    $needWrite = $false
    if ($assignedCount -gt 0) {
        $assignedSpec = Set-JiraStoryMarkerAssign -Text $assignedSpec
        $needWrite = $true
    }
    if ($parentNeedsAssign) {
        $assignedSpec = Set-JiraSpecMarkerAssign -Text $assignedSpec
        $needWrite = $true
    }
    if ($needWrite -and -not $dryRun -and -not $fdAskPending) {
        try { Write-JiraMarkerSpliceFile -Path $specFile -NewContent $assignedSpec | Out-Null }
        catch {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: $specFile could not be written — no ticket may be created before its identifier is recorded (zero writes)")
        }
    }

    # ENGINE: parse the spec into neutral content, then assemble + validate. Every
    # step is GUARDED so a failure surfaces the mapped error path — never a raw
    # unhandled exception (FR-032: mapped exits, zero writes; mirrors the Bash
    # port's guarded substitutions).
    try { $parse = Get-JiraParsedSpec -Text $assignedSpec -FolderSlug $slug }
    catch {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the specification could not be parsed (zero writes)')
    }
    $ctx = ConvertTo-JiraJsonValue ([ordered]@{ spec_ref = $specRef; project_key = $projectKey })
    $built = Build-JiraNeutralDocument -ParseJson $parse -ContextJson $ctx
    if (-not $built.Valid) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the specification could not be assembled into a valid neutral document (zero writes)')
    }

    $docObj = $built.Document | ConvertFrom-Json -Depth 100

    # The implementation plan (Phase 7, US5; data-model.md §7; spec FR-026/
    # FR-027/FR-028): plan.md sits alongside spec.md in the same feature
    # folder. A missing file, or a file with no `## Summary` section, yields
    # no blocks and no warning (FR-028) — Get-JiraParsedPlanSummary already
    # handles both.
    $specDir = Split-Path -Parent $specFile
    if ([string]::IsNullOrEmpty($specDir)) { $specDir = '.' }
    $planFile = Join-Path $specDir 'plan.md'
    $planBlocksJson = if (Test-Path -LiteralPath $planFile) {
        Get-JiraParsedPlanSummary -Text (Get-Content -Raw -LiteralPath $planFile)
    }
    else { '[]' }
    $planBlocks = @($planBlocksJson | ConvertFrom-Json -Depth 100)
    if ($planBlocks.Count -gt 0) {
        $docObj.epic.description.blocks = @($docObj.epic.description.blocks) + $planBlocks
    }

    Stop-JiraTimingPhase -Phase 'parse' -RequestCount (Get-JiraRequestCount)

    # 024, contracts/request-counting.md C2.3: recognition's own phase window
    # opens here, wrapping the prefetch bulk read below — it is recognition's
    # request, issued on recognition's behalf (021 US4), and a request issued
    # between two phases rather than inside one would escape every phase's
    # count while still landing in the run total, breaking FR-036's "the
    # summed per-phase counts equal the number of requests issued" (SC-014).
    # Mirror of the bash port's equivalent move in reconcile.sh.
    Start-JiraTimingPhase -Phase 'recognition' -RequestCount (Get-JiraRequestCount)

    # 021 US4, contracts/recognition-prefetch.md: gather every recorded key
    # this run is about to read — parent, stories, tasks — and prime the
    # prefetch cache with ONE bulk read before the per-key phase begins.
    # Tasks are read from the UNMODIFIED tasks.md text: a side-effect-free
    # look-ahead, never the authoritative parse (that happens further below,
    # after marker assignment/splice) — a key it misses simply falls through
    # to today's GET unchanged (contract §3).
    $prefetchKeys = [System.Collections.Generic.List[string]]::new()
    $prefetchEpicObj = Get-JiraPlanPropSafe $docObj 'epic'
    $prefetchEpicMarker = Get-JiraPlanPropSafe $prefetchEpicObj 'marker'
    if ([string](Get-JiraPlanPropSafe $prefetchEpicMarker 'state') -eq 'bound') {
        $prefetchKeys.Add([string](Get-JiraPlanPropSafe $prefetchEpicMarker 'ticket'))
    }
    foreach ($s in @($docObj.stories)) {
        $prefetchStoryMarker = Get-JiraPlanPropSafe $s 'marker'
        if ([string](Get-JiraPlanPropSafe $prefetchStoryMarker 'state') -eq 'bound') {
            $prefetchKeys.Add([string](Get-JiraPlanPropSafe $prefetchStoryMarker 'ticket'))
        }
    }
    # 022, research.md §6: bulk-prefetching bound task keys only serves
    # sub-task recognition, which checklist mode never performs — gated on
    # the effective mode, not merely on a declared role.
    if ($taskTierMode -eq 'subtask') {
        $prefetchTasksParent = (Split-Path -Parent $specFile) -replace '\\', '/'
        if ([string]::IsNullOrEmpty($prefetchTasksParent)) {
            $prefetchTasksParent = if ($specFile.StartsWith('/')) { '/' } else { '.' }
        }
        $prefetchTasksFile = "$prefetchTasksParent/tasks.md"
        if (Test-Path -LiteralPath $prefetchTasksFile) {
            $prefetchTasksRaw = Get-Content -Raw -LiteralPath $prefetchTasksFile
            if ($null -eq $prefetchTasksRaw) { $prefetchTasksRaw = '' }
            $prefetchTasksParsed = ConvertTo-JiraTasksParseDocument -Text $prefetchTasksRaw | ConvertFrom-Json -Depth 100
            foreach ($t in @($prefetchTasksParsed.tasks)) {
                $prefetchTaskMarker = Get-JiraPlanPropSafe $t 'marker'
                if ([string](Get-JiraPlanPropSafe $prefetchTaskMarker 'state') -eq 'bound') {
                    $prefetchKeys.Add([string](Get-JiraPlanPropSafe $prefetchTaskMarker 'ticket'))
                }
            }
        }
    }
    Invoke-JiraPrefetchLoad -Keys $prefetchKeys.ToArray()

    # R5 step 2a — RECOGNISE THE PARENT (Phase 5, US2, T070/T077;
    # contracts/parent-marker.md "Ordering within one run" step 5). One read
    # by the recorded key, before any story is recognised. A blocked parent
    # blocks the WHOLE specification — no story is planned (FR-012).
    $epicObj = Get-JiraPlanPropSafe $docObj 'epic'
    $epicMarkerJson = ConvertTo-JiraJsonValue (Get-JiraPlanPropSafe $epicObj 'marker')
    $recogParentResult = Invoke-JiraRecognitionParentRun -MarkerInfoJson $epicMarkerJson -SpecRefJson $specRefJson -ProjectKey $projectKey -SpecPath $specFile
    if ($recogParentResult.ExitCode -ne 0) {
        return (Get-JiraReconcileFaultCode -Code $recogParentResult.ExitCode -Message 'reconcile: the parent could not be recognised (zero writes)')
    }
    $recogParent = $recogParentResult.Json | ConvertFrom-Json -Depth 100
    $parentState = [string]$recogParent.state
    if ($parentState -eq 'blocked') {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: $($recogParent.detail)")
    }

    $dupProbeWarning = ''

    # R5 step 2b — RECOGNISE the stories (Phase 3, US1;
    # contracts/recognition-contract.md): one read per recorded ticket,
    # verified against the SAME identity marker the read returns. A read
    # failure is NEVER downgraded to "no ticket exists" (FR-004) — it fails
    # the WHOLE specification closed here.
    $storiesSlim = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($docObj.stories)) { $storiesSlim.Add([ordered]@{ local_id = $s.local_id; marker = (Get-JiraPlanPropSafe $s 'marker') }) }
    $storiesSlimJson = ConvertTo-JiraJsonValue $storiesSlim
    $recogResult = Invoke-JiraRecognitionRun -StoriesJson $storiesSlimJson -SpecRefJson $specRefJson -ProjectKey $projectKey -SpecPath $specFile
    if ($recogResult.ExitCode -ne 0) {
        return (Get-JiraReconcileFaultCode -Code $recogResult.ExitCode -Message 'reconcile: a ticket could not be recognised (zero writes)')
    }
    $recogJson = $recogResult.Json
    $recog = $recogJson | ConvertFrom-Json -Depth 100

    # FR-011/FR-016/FR-021: a blocked story is excluded from the document
    # handed to Get-JiraPlanWriteSet — a blocked story never blocks its siblings.
    $blockedIds = @(($recog.blocked) | ForEach-Object { [string]$_.story })
    $docForWriteObj = $docObj.PSObject.Copy()
    $filteredStories = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($docObj.stories)) { if ($blockedIds -notcontains [string]$s.local_id) { $filteredStories.Add($s) } }
    $docForWriteObj.stories = $filteredStories
    $docForWriteJson = ConvertTo-JiraJsonValue $docForWriteObj

    # Phase 3, US1 (contract 1-3): the task tier. tasks.md is read ONLY when
    # a `task` role resolved in the binding ($taskTypeIdCandidate) — its
    # mere presence on disk is never enough (FR-011). Its absence, once
    # the role IS declared, is a silent no-op (FR-001).
    $tasksFile = ''
    $tasksRaw = ''
    $tasksActionsJson = '[]'
    $tasksRecogJson = '{"bound":{},"new":[],"blocked":[]}'
    $taskRoleActive = $false
    $taskWarns = [System.Collections.Generic.List[string]]::new()
    $taskWithheldCount = 0
    $taskSkipNotes = [System.Collections.Generic.List[string]]::new()
    # Edge Cases, T084: a task checked before its sub-task has ever been
    # created — the completion pass below has no key to read transitions for
    # yet, so it defers here; resolved once the create below (if it completes)
    # stamps a key into tasksFile.
    $pendingCreateCompleteIds = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($taskTierMode)) {
        # Twin of the Bash port's `"$(dirname "${spec_file}")/tasks.md"`
        # (reconcile.sh). Spelled with '/', NEVER through Join-Path: this path is
        # operator-facing — the four task notes below embed it verbatim — so on
        # Windows Join-Path's '\' made every task-tier scenario diverge from the
        # Bash capture, and JSON-escaping it to '\\' made the captures differ in
        # size too (T099: 8 divergences, all bash=2f pwsh=5c). The I/O uses below
        # are unaffected; PowerShell's file cmdlets accept '/' on Windows.
        # Split-Path -Parent yields '' for a bare filename and for a root-level
        # path, where dirname yields '.' and '/' — mapped the same way as the
        # spec file's own parent above (NFR-1).
        $tasksParent = (Split-Path -Parent $specFile) -replace '\\', '/'
        if ([string]::IsNullOrEmpty($tasksParent)) {
            $tasksParent = if ($specFile.StartsWith('/')) { '/' } else { '.' }
        }
        $candidateTasksFile = "$tasksParent/tasks.md"
        if (Test-Path -LiteralPath $candidateTasksFile) {
            $taskRoleActive = $true
            $tasksFile = $candidateTasksFile
            $tasksRaw = Get-Content -Raw -LiteralPath $tasksFile
            if ($null -eq $tasksRaw) { $tasksRaw = '' }

            if ($taskTierMode -ne 'subtask') {
            # 022, US5 (FR-005): checklist mode needs no resolvable sub-task
            # issue type and assigns no durable identifier (FR-031) — read and
            # nest only, through the SAME shared parse/nest/skip-notes/validate
            # path subtask mode uses below.
            $tasksForDoc = $tasksRaw
                $tasksParsed = ConvertTo-JiraTasksParseDocument -Text $tasksForDoc | ConvertFrom-Json -Depth 100

                # Attribution resolves against the specification's OWN stories,
                # in document order (contract 3): an ordinal outside that range
                # is dangling (FR-004), no ordinal at all is unattributed
                # (FR-028) — neither ever reaches the document. Nesting a task
                # under its story's own `tasks` array is what makes "attributed
                # to a story this specification does not contain"
                # unrepresentable downstream.
                $allTasks = @($tasksParsed.tasks)
                $storyCount = @($docForWriteObj.stories).Count
                $attributed = @($allTasks | Where-Object {
                        $ord = Get-JiraPlanPropSafe $_.attribution 'story_ordinal'
                        ($null -ne $ord) -and ($ord -ge 1) -and ($ord -le $storyCount)
                    })
                $ord = 0
                foreach ($s in @($docForWriteObj.stories)) {
                    $ord++
                    $ts = @($attributed | Where-Object { (Get-JiraPlanPropSafe $_.attribution 'story_ordinal') -eq $ord })
                    if ($ts.Count -gt 0) {
                        $s | Add-Member -MemberType NoteProperty -Name 'tasks' -Value $ts -Force
                    }
                }
                $docForWriteJson = ConvertTo-JiraJsonValue $docForWriteObj

                # Neither an unattributed nor a dangling task ever reaches the
                # document (contract 3): this is the only place either can
                # still be named, by task_ref, with its reason (FR-004,
                # FR-028).
                foreach ($t in $allTasks) {
                    $tOrd = Get-JiraPlanPropSafe $t.attribution 'story_ordinal'
                    $taskRef = [string]$t.task_ref
                    if ($null -eq $tOrd) {
                        $taskSkipNotes.Add("$taskRef in $candidateTasksFile carries no story attribution and was not mirrored.")
                    }
                    elseif ($tOrd -lt 1 -or $tOrd -gt $storyCount) {
                        $taskSkipNotes.Add("$taskRef in $candidateTasksFile is attributed to User Story $tOrd, which $specFile does not contain, and was not mirrored.")
                    }
                }

                # A task-tier schema violation (FR-018's duplicate identifier,
                # most commonly) withholds the WHOLE tier rather than the whole
                # run — declaring a `task` role must never make the mirror
                # worse than not declaring one. The specification and story
                # tiers keep reconciling.
                if (-not (Test-JiraInterchange -Json $docForWriteJson)) {
                    foreach ($s in @($docForWriteObj.stories)) { $s.PSObject.Properties.Remove('tasks') }
                    $docForWriteJson = ConvertTo-JiraJsonValue $docForWriteObj
                    $taskWarns.Add('reconcile: the task tier could not be validated (a malformed or duplicate task identifier) and was withheld this run; the specification and story tiers still reconciled')
                    $taskRoleActive = $false
                }
            }

            # 022, research.md §6: `subtask` mode only — checklist mode needs no
            # resolvable sub-task type and never calls this gate.
            if ($taskTierMode -eq 'subtask') {
            # Task-tier verdict (Phase 5, US6, T066; data-model.md 5): a
            # THIRD gate, separate from Get-JiraHierarchyMandatoryGate, over
            # the single type carrying the `task` role alone. Run BEFORE any
            # marker is assigned or spliced into tasks.md, so a withheld
            # task is never given a durable identifier (FR-039) — and
            # before the lifecycle filter, so the whole tier is dropped by
            # construction (FR-038) rather than by omission further down.
            $taskGateResult = Get-JiraHierarchyTaskGate -Binding $gateBinding -ProjectKey $projectKey -DefaultsByType ($fdDefaultsByTypeJson | ConvertFrom-Json -Depth 100)
            $taskGateStatus = [string]$taskGateResult.status

            if ($taskGateStatus -ne 'ok') {
                # Attribute against the RAW, unmarked text — purely to
                # learn whether any task would actually have been written
                # this run. A tier with nothing to mirror in the first
                # place is not "withheld": the note, and the per-field
                # detail below, fire only when at least one task is
                # attributed.
                $tasksParsedRaw = ConvertTo-JiraTasksParseDocument -Text $tasksRaw | ConvertFrom-Json -Depth 100
                $storyCountRaw = @($docForWriteObj.stories).Count
                $withheldAttributed = @(@($tasksParsedRaw.tasks) | Where-Object {
                        $ord = Get-JiraPlanPropSafe $_.attribution 'story_ordinal'
                        ($null -ne $ord) -and ($ord -ge 1) -and ($ord -le $storyCountRaw)
                    })
                $taskWithheldCount = $withheldAttributed.Count
                if ($taskWithheldCount -gt 0) {
                    $taskTypeName = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $gateBinding.roles 'task') 'logical_name')
                    foreach ($fieldEntry in @($taskGateResult.fields)) {
                        $fieldName = [string]$fieldEntry.logical_name
                        if ($fieldEntry.PSObject.Properties.Match('reason').Count -gt 0) {
                            $line = Get-JiraHierarchyTaskFieldUndefaultableLine -LogicalName $fieldName -Reason ([string]$fieldEntry.reason) -TypeName $taskTypeName
                        }
                        else {
                            $line = Get-JiraHierarchyTaskFieldUnsatisfiableLine -LogicalName $fieldName -ProjectKey $projectKey -TypeName $taskTypeName
                        }
                        $taskWarns.Add($line)
                    }
                    $taskWarns.Add('reconcile: the task tier was withheld this run — a required field of its issue type could not be satisfied; the specification and story tiers still reconciled')
                }
            }
            else {
                $tasksAssigned = Set-JiraTaskMarkerAssign -Text $tasksRaw
                if ($tasksAssigned -ne $tasksRaw -and -not $dryRun) {
                    # Mirror of reconcile.sh's `|| true`: an unwritable tasks.md
                    # withholds identifier assignment for THIS run (the next run
                    # retries) rather than failing the whole reconcile — unlike
                    # spec.md's assign-write above, which fails closed, because
                    # the task tier must never make the mirror worse than not
                    # declaring the role at all (FR-011).
                    try { Write-JiraMarkerSpliceFile -Path $tasksFile -NewContent $tasksAssigned | Out-Null }
                    catch { $null = $_ }
                }
                $tasksForDoc = if ($dryRun) { $tasksRaw } else { $tasksAssigned }

                $tasksParsed = ConvertTo-JiraTasksParseDocument -Text $tasksForDoc | ConvertFrom-Json -Depth 100

                # Attribution resolves against the specification's OWN stories,
                # in document order (contract 3): an ordinal outside that range
                # is dangling (FR-004), no ordinal at all is unattributed
                # (FR-028) — neither ever reaches the document. Nesting a task
                # under its story's own `tasks` array is what makes "attributed
                # to a story this specification does not contain"
                # unrepresentable downstream.
                $allTasks = @($tasksParsed.tasks)
                $storyCount = @($docForWriteObj.stories).Count
                $attributed = @($allTasks | Where-Object {
                        $ord = Get-JiraPlanPropSafe $_.attribution 'story_ordinal'
                        ($null -ne $ord) -and ($ord -ge 1) -and ($ord -le $storyCount)
                    })
                $ord = 0
                foreach ($s in @($docForWriteObj.stories)) {
                    $ord++
                    $ts = @($attributed | Where-Object { (Get-JiraPlanPropSafe $_.attribution 'story_ordinal') -eq $ord })
                    if ($ts.Count -gt 0) {
                        $s | Add-Member -MemberType NoteProperty -Name 'tasks' -Value $ts -Force
                    }
                }
                $docForWriteJson = ConvertTo-JiraJsonValue $docForWriteObj

                # Neither an unattributed nor a dangling task ever reaches the
                # document (contract 3): this is the only place either can
                # still be named, by task_ref, with its reason (FR-004,
                # FR-028).
                foreach ($t in $allTasks) {
                    $tOrd = Get-JiraPlanPropSafe $t.attribution 'story_ordinal'
                    $taskRef = [string]$t.task_ref
                    if ($null -eq $tOrd) {
                        $taskSkipNotes.Add("$taskRef in $candidateTasksFile carries no story attribution and was not mirrored.")
                    }
                    elseif ($tOrd -lt 1 -or $tOrd -gt $storyCount) {
                        $taskSkipNotes.Add("$taskRef in $candidateTasksFile is attributed to User Story $tOrd, which $specFile does not contain, and was not mirrored.")
                    }
                }

                # A task-tier schema violation (FR-018's duplicate identifier,
                # most commonly) withholds the WHOLE tier rather than the whole
                # run — declaring a `task` role must never make the mirror
                # worse than not declaring one. The specification and story
                # tiers keep reconciling.
                if (-not (Test-JiraInterchange -Json $docForWriteJson)) {
                    foreach ($s in @($docForWriteObj.stories)) { $s.PSObject.Properties.Remove('tasks') }
                    $docForWriteJson = ConvertTo-JiraJsonValue $docForWriteObj
                    $taskWarns.Add('reconcile: the task tier could not be validated (a malformed or duplicate task identifier) and was withheld this run; the specification and story tiers still reconciled')
                    $taskRoleActive = $false
                }
                else {
                    # R5 step 2c — recognise the tasks, on the SAME terms as a
                    # story: one read per recorded key, verified against the
                    # SAME identity marker the read returns.
                    $tasksSlim = [System.Collections.Generic.List[object]]::new()
                    foreach ($s in @($docForWriteObj.stories)) {
                        $sTasksForSlim = Get-JiraPlanPropSafe $s 'tasks'
                        if ($null -eq $sTasksForSlim) { continue }
                        foreach ($t in @($sTasksForSlim)) {
                            $tasksSlim.Add([ordered]@{ local_id = $t.local_id; marker = (Get-JiraPlanPropSafe $t 'marker') })
                        }
                    }
                    if ($tasksSlim.Count -gt 0) {
                        $tasksSlimJson = ConvertTo-JiraJsonValue $tasksSlim
                        $tasksRecogResult = Invoke-JiraRecognitionRun -StoriesJson $tasksSlimJson -SpecRefJson $specRefJson -ProjectKey $projectKey -SpecPath $tasksFile -Kind 'task'
                        if ($tasksRecogResult.ExitCode -ne 0) {
                            return (Get-JiraReconcileFaultCode -Code $tasksRecogResult.ExitCode -Message 'reconcile: a sub-task could not be recognised (zero writes)')
                        }
                        $tasksRecogJson = $tasksRecogResult.Json
                        $tasksRecogObj = $tasksRecogJson | ConvertFrom-Json -Depth 100
                        $tasksBlockedIds = @(($tasksRecogObj.blocked) | ForEach-Object { [string]$_.story })
                        foreach ($s in @($docForWriteObj.stories)) {
                            $sTasks = Get-JiraPlanPropSafe $s 'tasks'
                            if ($null -ne $sTasks) {
                                $keptTasks = @($sTasks | Where-Object { $tasksBlockedIds -notcontains [string]$_.local_id })
                                $s.tasks = $keptTasks
                            }
                        }
                        $docForWriteJson = ConvertTo-JiraJsonValue $docForWriteObj
                        foreach ($bw in @($tasksRecogObj.blocked)) { $taskWarns.Add([string]$bw.detail) }
                    }
                }
            }
            }
        }
    }

    # US3 (T073): orphan (FR-021) and re-attribution (FR-022) reporting —
    # both pure notes, never a write. Mirror of reconcile.sh's own block; see
    # there for the full rationale.
    $taskNotes = [System.Collections.Generic.List[string]]::new()
    # 023, US4, I4/I5: a DECLARED `task` mapping that currently has no
    # effect produces exactly ONE note per run — never a warning, never
    # per ticket. Two inert cases: `checklist` mode, and no task role
    # resolved at all ($taskTierMode is empty). An EMPTY mapping stays
    # silent instead (I2's general rule). Mirror of reconcile.sh.
    $taskRoleMapForNote = Get-JiraPlanPropSafe ($phaseStatusMap | ConvertFrom-Json -Depth 100) 'task'
    $taskRoleMapForNoteCount = if ($taskRoleMapForNote) { @($taskRoleMapForNote.PSObject.Properties).Count } else { 0 }
    if ($taskRoleMapForNoteCount -gt 0 -and $taskTierMode -ne 'subtask') {
        if ($taskTierMode -eq 'checklist') {
            $taskNotes.Add("the task-role lifecycle mapping for $projectKey has no effect while its tasks are mirrored as a checklist")
        }
        else {
            $taskNotes.Add("the task-role lifecycle mapping for $projectKey has no effect: the project declares no task role")
        }
    }
    if ($taskTierMode -eq 'subtask') {
        $tasksRecogForNotes = $tasksRecogJson | ConvertFrom-Json -Depth 100
        $tasksRecogBoundForNotes = Get-JiraPlanPropSafe $tasksRecogForNotes 'bound'
        $recogBoundForNotes = Get-JiraPlanPropSafe $recog 'bound'
        foreach ($s in @($docForWriteObj.stories)) {
            $sid = [string]$s.local_id
            $storyEntry = if ($recogBoundForNotes) { Get-JiraPlanPropSafe $recogBoundForNotes $sid } else { $null }
            $skey = if ($storyEntry) { [string](Get-JiraPlanPropSafe $storyEntry 'key') } else { $null }
            if ([string]::IsNullOrEmpty($skey)) { continue }

            $subs = @(Get-JiraPlanPropSafe $storyEntry 'subtasks')
            $sTasksRaw = Get-JiraPlanPropSafe $s 'tasks'
            $sTasks = if ($null -eq $sTasksRaw) { @() } else { @($sTasksRaw) }
            $expected = [System.Collections.Generic.List[string]]::new()
            foreach ($t in $sTasks) {
                $tEntry = if ($tasksRecogBoundForNotes) { Get-JiraPlanPropSafe $tasksRecogBoundForNotes ([string]$t.local_id) } else { $null }
                $tkey = if ($tEntry) { [string](Get-JiraPlanPropSafe $tEntry 'key') } else { $null }
                if (-not [string]::IsNullOrEmpty($tkey)) { $expected.Add($tkey) }
            }
            foreach ($sub in $subs) {
                $subItId = [string](Get-JiraPlanPropSafe $sub 'issuetype_id')
                if ($subItId -ne $taskTypeIdCandidate) { continue }
                $subKey = [string](Get-JiraPlanPropSafe $sub 'key')
                if ($expected -notcontains $subKey) {
                    $taskNotes.Add("$subKey is recorded in Jira as a sub-task of $skey, but $candidateTasksFile no longer attributes any task to it; nothing was changed in Jira.")
                }
            }

            foreach ($t in $sTasks) {
                $tEntry = if ($tasksRecogBoundForNotes) { Get-JiraPlanPropSafe $tasksRecogBoundForNotes ([string]$t.local_id) } else { $null }
                if ($null -eq $tEntry) { continue }
                $tkey = [string](Get-JiraPlanPropSafe $tEntry 'key')
                $tCurrent = Get-JiraPlanPropSafe $tEntry 'current'
                $curParent = if ($tCurrent) { Get-JiraPlanPropSafe $tCurrent 'parent' } else { $null }
                if ([string]::IsNullOrEmpty($curParent)) { continue }
                if ([string]$curParent -ne $skey) {
                    $taskNotes.Add("$tkey is attributed to $skey in $candidateTasksFile, but is recorded in Jira under $curParent; nothing was re-parented.")
                }
            }
        }
    }
    foreach ($n in $taskSkipNotes) { $taskNotes.Add($n) }

    # 022, FR-033/FR-034, research.md §6 — the outbound switch (subtask ->
    # checklist), detected with no extra Jira read: FR-031 leaves every
    # durable identifier already recorded in tasks.md untouched, so a BOUND
    # task marker under checklist mode is exactly the record of a sub-task
    # this run no longer maintains (FR-033 already holds by construction —
    # taskTierMode != 'subtask' plans zero sub-task writes). Reported once,
    # naming the stories affected and a copy-pasteable `issue in (…)` query
    # over exactly the keys the mirror itself created.
    if ($taskTierMode -eq 'checklist' -and -not [string]::IsNullOrEmpty($tasksRaw)) {
        $switchOutParsed = ConvertTo-JiraTasksParseDocument -Text $tasksRaw | ConvertFrom-Json -Depth 100
        $switchOutBound = @($switchOutParsed.tasks | Where-Object { $_.marker.state -eq 'bound' })
        if ($switchOutBound.Count -gt 0) {
            $switchOutOrdinals = @($switchOutBound | ForEach-Object { $_.attribution.story_ordinal } | Sort-Object -Unique)
            $switchOutStoryNames = @($switchOutOrdinals | ForEach-Object { [string]$docForWriteObj.stories[$_ - 1].title }) -join ', '
            $switchOutKeys = @($switchOutBound | ForEach-Object { [string]$_.marker.ticket }) -join ', '
            $taskNotes.Add("reconcile: switched to checklist mode — $($switchOutBound.Count) sub-task(s) across $switchOutStoryNames are no longer maintained by this mirror; issue in ($switchOutKeys) selects exactly them for cleanup")
        }
    }

    # 022, FR-007, spec Edge Cases, data-model.md §4 — a declared `task` role
    # alongside checklist mode is recorded, never consumed: this replaces
    # feature 012's status line in this mode rather than adding a second one.
    if ($taskTierMode -eq 'checklist' -and -not [string]::IsNullOrEmpty($taskTypeIdCandidate)) {
        $taskNotes.Add("reconcile: project $($projectKey): a task role is declared but task_mirror is 'checklist' — the role is recorded, not consumed; every task list still mirrors as a checklist")
    }

    Stop-JiraTimingPhase -Phase 'recognition' -RequestCount (Get-JiraRequestCount)
    Start-JiraTimingPhase -Phase 'plan' -RequestCount (Get-JiraRequestCount)

    # SINK: the plan context (US2, FR-007–FR-011; Phase 3, US1: tickets/
    # ticket_origins/ticket_descriptions now come from recognition's `bound`
    # map). An explicit SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived
    # object wholesale; otherwise it is built from the resolved project's
    # persisted binding.
    $planCtxResult = Get-JiraReconcilePlanContextFromBinding -BaseUrl $base -ProjectKey $projectKey -ConfigDir $cfgDir -ConfigJson $cfg -RecognitionJson $recogJson -FieldValues $fieldValues -TasksRecognitionJson $tasksRecogJson
    if ($planCtxResult.ExitCode -eq 2) {
        Write-JiraReconcileNotice -Lines @(
            'Jira mirror skipped: this repository is not bound to a Jira project yet.',
            'Nothing was mirrored, and this spec-kit command completed normally.',
            'To bind it, run /speckit.jira-mirror.config.')
        return 0
    }
    elseif ($planCtxResult.ExitCode -eq 3) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: the project `"$projectKey`" has not been bound yet — run /speckit.jira-mirror.config to discover its issue types and priorities (zero writes)")
    }
    elseif ($planCtxResult.ExitCode -eq 6) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: the local binding for $projectKey predates parent support and does not record issue-type hierarchy. The project is bound — its binding is simply a version behind. Run /speckit.jira-mirror.config to refresh it (zero writes)")
    }
    elseif ($planCtxResult.ExitCode -eq 7) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: project $projectKey has no recorded issue type for user stories. Run /speckit.jira-mirror.config to record it (zero writes)")
    }
    elseif ($planCtxResult.ExitCode -eq $script:ReconcileExitConfig) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the local Jira binding could not be read (zero writes)')
    }
    $planCtx = $planCtxResult.Json
    # on_drift (018, T047; contracts/summary-record.md §4): the SAME
    # --on-drift the lifecycle context already carries — Get-JiraPlanWriteSet's
    # summary decision reads it from here rather than a second flag.
    $planCtxWithDrift = [ordered]@{}
    foreach ($p in ($planCtx | ConvertFrom-Json -Depth 100).PSObject.Properties) { $planCtxWithDrift[$p.Name] = $p.Value }
    $planCtxWithDrift['on_drift'] = $onDrift
    $planCtx = ConvertTo-JiraJsonValue $planCtxWithDrift

    # Merge the parent's recognition facts into the plan context (T077): a
    # bound parent carries its key, current content (for zero churn) and
    # origin; a new/absent parent contributes nothing extra.
    if ($parentState -eq 'bound') {
        $planCtxObj = $planCtx | ConvertFrom-Json -Depth 100
        $planCtxMap = [ordered]@{}
        foreach ($p in $planCtxObj.PSObject.Properties) { $planCtxMap[$p.Name] = $p.Value }
        $planCtxMap['parent_key'] = [string]$recogParent.key
        $planCtxMap['parent_current'] = $recogParent.current
        $parentOriginKnown = [string]$recogParent.origin
        if ([string]::IsNullOrEmpty($parentOriginKnown)) { $parentOriginKnown = 'bridge' }
        $planCtxMap['parent_origin'] = $parentOriginKnown
        # parent_last_summary (018, T047; contracts/summary-record.md §2/§5:
        # every tier, including the parent) — omitted for a marker
        # predating it.
        $parentLastSummaryVal = Get-JiraPlanPropSafe $recogParent 'last_summary'
        if ($null -ne $parentLastSummaryVal) { $planCtxMap['parent_last_summary'] = [string]$parentLastSummaryVal }
        $planCtx = ConvertTo-JiraJsonValue $planCtxMap
    }

    # 022, FR-034, research.md §6 — the reverse switch (checklist -> subtask),
    # detected from the story's ALREADY-READ current description (no extra
    # Jira read): a checklist section still on the ticket while this run
    # computes subtask mode is exactly the record of a story about to have it
    # stripped by the ordinary zero-churn description update (FR-035 — no
    # special-cased removal needed, the existing managed-section diff already
    # does it). Reported once, naming the stories and the count of sub-tasks
    # re-bound rather than orphaned (T093a) — no query, since nothing here is
    # abandoned.
    if ($taskTierMode -eq 'subtask' -and -not [string]::IsNullOrEmpty($tasksRaw)) {
        $switchBackParsed = ConvertTo-JiraTasksParseDocument -Text $tasksRaw | ConvertFrom-Json -Depth 100
        $switchBackN = 0
        $switchBackStories = [System.Collections.Generic.List[string]]::new()
        $planCtxForSwitch = $planCtx | ConvertFrom-Json -Depth 100
        $ticketDescriptions = Get-JiraPlanPropSafe $planCtxForSwitch 'ticket_descriptions'
        foreach ($s in @($docForWriteObj.stories)) {
            $existingValue = Get-JiraPlanPropSafe $ticketDescriptions $s.local_id
            if ($null -eq $existingValue) { continue }
            $existingJson = ConvertTo-JiraJsonValue $existingValue
            if (-not (Test-JiraAdfContentHasChecklist -ExistingJson $existingJson)) { continue }
            $ordinal = (@($docForWriteObj.stories) | ForEach-Object { $_.local_id }).IndexOf($s.local_id) + 1
            $bound = @($switchBackParsed.tasks | Where-Object { $_.attribution.story_ordinal -eq $ordinal -and $_.marker.state -eq 'bound' })
            if ($bound.Count -eq 0) { continue }
            $switchBackStories.Add([string]$s.title)
            $switchBackN += $bound.Count
        }
        if ($switchBackN -gt 0) {
            $switchBackNames = $switchBackStories -join ', '
            $taskNotes.Add("reconcile: switched back to subtask mode — $switchBackN sub-task(s) across $switchBackNames were re-bound by their preserved identifiers, not duplicated")
        }
    }

    # DUPLICATE PROBE (User Story 4, P3, droppable; FR-022-FR-026,
    # contracts/duplicate-probe.md §2): fires only when about to CREATE a
    # parent -- parentState "new" (no marker recorded) AND the plan context
    # actually resolved a parent_type_id (a hierarchy with no parent type
    # never creates one) -- and only once every OTHER pre-write refusal
    # above (routing, project validity, the stale-binding read) has already
    # cleared, so a run that was going to refuse anyway never issues this
    # read first. At most one request per run. Read-only, best-effort -- a
    # false negative here leaves today's behaviour unchanged (SC-001 rests
    # on the marker line, not on this).
    $planCtxForProbe = $planCtx | ConvertFrom-Json -Depth 100
    $probeParentTypeId = [string](Get-JiraPlanPropSafe $planCtxForProbe 'parent_type_id')
    if ($parentState -eq 'new' -and -not [string]::IsNullOrEmpty($probeParentTypeId)) {
        $dupLabel = "speckit-$slug"
        $dupResult = Get-JiraDuplicateProbeResult -BaseUrl $base -ProjectKey $projectKey -Label $dupLabel
        if ($dupResult.Verdict -eq 'hit') {
            $dupKeys = ($dupResult.Keys -join ', ')
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: project $projectKey already holds tickets labelled `"$dupLabel`" ($dupKeys) but this specification records no ticket of its own — bind each with the bridge's ``mention <issue-key>`` command, or remove the label from them (zero writes)")
        }
        elseif ($dupResult.Verdict -eq 'unavailable') {
            $dupProbeWarning = 'the duplicate-label check could not be performed on this site; the run proceeded on its recorded markers alone'
        }
    }

    try { $planJson = Get-JiraPlanWriteSet -NeutralDocJson $docForWriteJson -PlanContextJson $planCtx }
    catch {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the write plan could not be assembled (zero writes)')
    }
    $planObj = $planJson | ConvertFrom-Json -Depth 100
    $parentAction = Get-JiraPlanPropSafe $planObj 'parent'
    $actionsJson = ConvertTo-JiraJsonValue @(Get-JiraPlanPropSafe $planObj 'stories')
    # 017, contract §4: the label-degradation warnings Get-JiraPlanWriteSet
    # returns alongside the action set — mirror of the bash port's
    # plan_label_warnings, folded into the run summary's warnings below.
    $planLabelWarningsRaw = Get-JiraPlanPropSafe $planObj 'warnings'
    $planLabelWarnings = if ($null -eq $planLabelWarningsRaw) { @() } else { @($planLabelWarningsRaw) }
    # The task type's resolved provenance token (017 FR-009 on 012's tier),
    # decided inside Get-JiraPlanWriteSet beside the story's and the parent's
    # so its own degradation warning travels with theirs. Empty when no
    # `task` role resolved, or when the type cannot hold the label.
    $taskLabel = [string](Get-JiraPlanPropSafe $planObj 'task_label')
    # 022, data-model.md §4: the checklist tallies Get-JiraPlanWriteSet
    # computed, present only in checklist mode.
    $checklistCounts = Get-JiraPlanPropSafe $planObj 'checklist_counts'

    # Phase 3, US1 (contract 4): the task tier's own plan, over the SAME
    # document and context — never through Get-JiraLifecyclePlan, which
    # only knows the two existing tiers. Skipped whenever the tier is
    # inactive, so $tasksActionsJson stays the '[]' it was initialised to
    # and every downstream read of it is a no-op (FR-011).
    if ($taskRoleActive -and $taskTierMode -eq 'subtask') {
        try {
            $tasksPlan = Get-JiraPlanTaskWriteSet -DocJson $docForWriteJson -ContextJson $planCtx -TaskLabel $taskLabel | ConvertFrom-Json -Depth 100
            $tasksActionsJson = ConvertTo-JiraJsonValue @($tasksPlan.actions)
            # 018, T027: the boundary's own warnings (malformed / ambiguous
            # migration) on the task tier, through the same channel every
            # other task-tier warning already uses.
            foreach ($w in @($tasksPlan.warnings)) { $taskWarns.Add([string]$w) }
        }
        catch {
            $taskWarns.Add("reconcile: the task tier's write plan could not be assembled and was withheld this run")
            $tasksActionsJson = '[]'
        }
    }

    # Phase 8, US5 (contract §6; research R5): the task tier's own completion
    # pass. Scoped to a task ALREADY bound this run (tasksRecogJson.bound) — a
    # task whose sub-task does not yet exist is skipped entirely (a future run
    # completes it once it does; T084 is the same-run case, not yet resolved).
    # A task whose `done` bit already agrees with its sub-task's classification
    # contributes no entry at all, so this loop issues zero reads for it
    # (FR-031's "an unchanged re-run issues none"). The backward pull is
    # resolved here, never inside the PURE Get-JiraTaskLifecyclePlan: only the
    # command layer knows --on-drift. Mirror of reconcile.sh.
    if ($taskRoleActive -and $taskTierMode -eq 'subtask') {
        # 023, US4, I4/I7: the `task` role's own declared mapping, resolved
        # once up front. Mirror of reconcile.sh.
        $phaseStatusMapObj = $phaseStatusMap | ConvertFrom-Json -Depth 100
        $taskRoleMapObj = Get-JiraPlanPropSafe $phaseStatusMapObj 'task'
        # Get-JiraPlanPropSafe indexes .PSObject.Properties[$Name] directly,
        # which throws under StrictMode for an EMPTY string name — the
        # ubiquitous "no event" case ($hookEvent = ''). Guard here rather
        # than widen the shared helper's contract for every other caller.
        $taskLcTarget = if ($hookEvent) { [string](Get-JiraPlanPropSafe $taskRoleMapObj $hookEvent) } else { '' }
        $taskLcMapped = if ($taskRoleMapObj) { @($taskRoleMapObj.PSObject.Properties | ForEach-Object { [string]$_.Value }) } else { @() }
        $taskLcOrder = @((Get-JiraReconcilePhaseOrder -PhaseStatusMapJson $phaseStatusMap | ConvertFrom-Json -Depth 100).task)
        $taskDueMeta = [ordered]@{}

        $tasksRecogForCompletion = $tasksRecogJson | ConvertFrom-Json -Depth 100
        $tasksRecogBoundForCompletion = Get-JiraPlanPropSafe $tasksRecogForCompletion 'bound'
        $completionTasks = [ordered]@{}
        foreach ($s in @($docForWriteObj.stories)) {
            $sTasksForCompletion = Get-JiraPlanPropSafe $s 'tasks'
            if ($null -eq $sTasksForCompletion) { continue }
            foreach ($t in @($sTasksForCompletion)) {
                $cId = [string]$t.local_id
                # An in-memory dry-run parse (no marker splice, contract 1) carries
                # no local_id at all — never a real recognition key, so this is a
                # skip, not a lookup miss. Mirror of reconcile.sh's `[[ -z "${completion_id}" ]] && continue`.
                if ([string]::IsNullOrEmpty($cId)) { continue }
                $cBound = if ($tasksRecogBoundForCompletion) { Get-JiraPlanPropSafe $tasksRecogBoundForCompletion $cId } else { $null }
                if ($null -eq $cBound) {
                    if ([bool](Get-JiraPlanPropSafe $t 'done')) { $pendingCreateCompleteIds.Add($cId) }
                    continue
                }
                $cKey = [string](Get-JiraPlanPropSafe $cBound 'key')
                $cStatusCategory = [string](Get-JiraPlanPropSafe $cBound 'status_category')
                $cBlockersRaw = Get-JiraPlanPropSafe $cBound 'blockers'
                $cBlockers = if ($null -eq $cBlockersRaw) { @() } else { @($cBlockersRaw) }
                $cDone = [bool](Get-JiraPlanPropSafe $t 'done')
                $cEntry = $null

                if ($cDone -and $cStatusCategory -ne 'done') {
                    $fwdResult = Get-JiraDiscoveryTaskTransitionResult -IssueKey $cKey -Direction 'forward'
                    if ($fwdResult.ExitCode -ne 0) {
                        return (Get-JiraReconcileFaultCode -Code $fwdResult.ExitCode -Message "reconcile: sub-task ${cKey}'s available transitions could not be read (zero writes)")
                    }
                    $cEntry = [ordered]@{ key = $cKey; blockers = $cBlockers; forward = ($fwdResult.Transition | ConvertFrom-Json -Depth 100) }
                }
                elseif ((-not $cDone) -and $cStatusCategory -eq 'done') {
                    $cBwd = $null
                    if ($onDrift -eq 'proceed') {
                        $bwdResult = Get-JiraDiscoveryTaskTransitionResult -IssueKey $cKey -Direction 'backward'
                        if ($bwdResult.ExitCode -ne 0) {
                            return (Get-JiraReconcileFaultCode -Code $bwdResult.ExitCode -Message "reconcile: sub-task ${cKey}'s available transitions could not be read (zero writes)")
                        }
                        $cBwd = $bwdResult.Transition | ConvertFrom-Json -Depth 100
                    }
                    $cEntry = [ordered]@{ key = $cKey; blockers = $cBlockers; already_done_diverged = $true; backward = $cBwd }
                }
                elseif ((-not $cDone) -and $taskLcTarget) {
                    # 023, US4: a genuinely unchecked sub-task (not diverged
                    # into a done status — that case is handled above), with
                    # the task role declaring a step for this event. Same
                    # drift/Flagged safety a story or the parent already
                    # runs through (research R6). Mirror of reconcile.sh.
                    $cStatus = [string](Get-JiraPlanPropSafe $cBound 'status')
                    $cFlagged = [bool](Get-JiraPlanPropSafe $cBound 'flagged')
                    if ($cStatus -and $cStatus -ne $taskLcTarget) {
                        if ($cFlagged) {
                            $taskWarns.Add("sub-task $cKey carries the Flagged (impediment) marker; its transition is withheld and the flag is left untouched")
                        }
                        else {
                            $tCategory = if ($taskLcMapped -contains $cStatus) { 'mapped' } else { 'unknown' }
                            $tDi = ConvertTo-JiraJsonValue ([ordered]@{ current_status = $cStatus; current_category = $tCategory; target_status = $taskLcTarget; order = $taskLcOrder; on_drift = $onDrift })
                            $tDec = Get-JiraDriftDecision -InputJson $tDi | ConvertFrom-Json -Depth 100
                            foreach ($dw in @($tDec.warnings)) { $taskWarns.Add([string]$dw) }
                            if ([string]$tDec.decision -eq 'transition') {
                                $taskDueMeta[$cId] = [ordered]@{ key = $cKey; target = $taskLcTarget; status = $cStatus; blockers = $cBlockers }
                            }
                        }
                    }
                }

                if ($null -ne $cEntry) { $completionTasks[$cId] = $cEntry }
            }
        }

        if ($completionTasks.Count -gt 0) {
            $completionCtxJson = ConvertTo-JiraJsonValue ([ordered]@{ base_url = $base; tasks = $completionTasks })
            $completionResultJson = Get-JiraTaskLifecyclePlan -ContentActionsJson $tasksActionsJson -CompletionContextJson $completionCtxJson
            $completionResult = $completionResultJson | ConvertFrom-Json -Depth 100
            $tasksActionsJson = ConvertTo-JiraJsonValue @(Get-JiraPlanPropSafe $completionResult 'actions')
            foreach ($w in @(Get-JiraPlanPropSafe $completionResult 'warnings')) { $taskWarns.Add([string]$w) }
            foreach ($n in @(Get-JiraPlanPropSafe $completionResult 'notes')) { $taskNotes.Add([string]$n) }
        }

        # 023, US4: the task-role due set resolved by DESTINATION NAME
        # (contract transition-resolution.md §1-§4) — the SAME resolution
        # engine the story tier uses, one read for the whole due set.
        if ($taskDueMeta.Count -gt 0) {
            $taskDueKeys = @($taskDueMeta.Values | ForEach-Object { [string]$_.key })
            $rcTtl = Import-JiraTransitions -Key $taskDueKeys
            if ($rcTtl -ne 0) {
                return (Get-JiraReconcileFaultCode -Code $rcTtl -Message 'reconcile: sub-task transitions could not be read (zero writes)')
            }
            foreach ($tdueId in $taskDueMeta.Keys) {
                $tmeta = $taskDueMeta[$tdueId]
                $trecord = Get-JiraTransitionRecord -Key ([string]$tmeta.key)
                if ($null -eq $trecord) { continue }
                $toutcome = Resolve-JiraTransition -RecordJson $trecord -DeclaredStep ([string]$tmeta.target) | ConvertFrom-Json -Depth 100
                if ([string]$toutcome.outcome -eq 'move') {
                    $tres = Get-JiraTransitionAction -BaseUrl $base -Key ([string]$tmeta.key) -TransitionId ([string]$toutcome.transition_id) -Blockers $tmeta.blockers -Label $tdueId -Role 'task' -DeclaredStep ([string]$tmeta.target)
                    $tasksActionsJson = ConvertTo-JiraJsonValue (@(($tasksActionsJson | ConvertFrom-Json -Depth 100)) + $tres.Action)
                    if ($tres.Note) { $taskNotes.Add($tres.Note) }
                }
                else {
                    $taskWarns.Add((Get-JiraTransitionWarning -Outcome $toutcome -Role 'task' -Key ([string]$tmeta.key) -Declared ([string]$tmeta.target) -Current ([string]$tmeta.status)))
                }
            }
        }
    }

    # US6 lifecycle safety: when the current-Jira facts are supplied (the seam the
    # config/discovery integration fills from a fail-closed read), fold in
    # zero-churn idempotency, status-category drift, Flagged withholding, and the
    # blocker note. Runs in BOTH dry-run and real mode so the --dry-run report
    # equals the real run's action set exactly (FR-033). Mirror of reconcile.sh.
    # US6 lifecycle safety (Phase 4, US2): the lifecycle context is now built
    # from recognition's `bound` map on EVERY run — not only under the
    # SPEC_KIT_JIRA_LIFECYCLE test override, which continues to win wholesale
    # (unchanged seam). Zero-churn dropping (FR-030) fires whenever a ticket
    # was recognised; the drift/Flagged/blocker rules stay inert until
    # Phase 6 supplies a `target`.
    $warnsJson = '[]'
    $notesJson = '[]'
    $hasOverrideLifecycle = $false
    if ($env:SPEC_KIT_JIRA_LIFECYCLE) {
        $hasOverrideLifecycle = $true
        try { $lcObj = $env:SPEC_KIT_JIRA_LIFECYCLE | ConvertFrom-Json -Depth 100 }
        catch {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: SPEC_KIT_JIRA_LIFECYCLE is not valid JSON (zero writes)')
        }
        $lcMap = [ordered]@{}
        if ($lcObj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $lcObj.PSObject.Properties) { $lcMap[$p.Name] = $p.Value }
        }
        $lcMap['base_url'] = $base
        $lcMap['on_drift'] = $onDrift
        $lcJson = ConvertTo-JiraJsonValue $lcMap
    }
    else {
        # origin (018, T025): included for EVERY recognised ticket now,
        # mirroring the plan context's ticket_origins above — the
        # managed-panel comparison is origin-independent (contract §3), so
        # there is no longer a "bridge" value that would route a ticket
        # incorrectly.
        # target (Phase 6, US4, research R9; 023 role-lifecycle-config.md
        # §4): the status the CURRENT lifecycle event maps to, via the
        # routed project's phase_status_map — resolved PER ROLE now, empty
        # when this run has no hook event or that role's map has no
        # declared step for it (R9's inert fallback). category classifies
        # each recognised ticket's OWN status against ITS OWN ROLE's mapped
        # targets (contract §5 I1) the same way Get-JiraStatusClassification
        # seeds it: mapped (a declared phase target) overrides an
        # operator-designated halted state, which overrides Jira's own
        # "done" statusCategory (post-scope), else unknown. role: "story"
        # for every entry here — the ticket tier `.bound` always names
        # (parent/task have their own entries).
        $phaseMapObj = $phaseStatusMap | ConvertFrom-Json -Depth 100
        $storyMap = Get-JiraPlanPropSafe $phaseMapObj 'story'
        $mappedTargets = @()
        if ($storyMap -is [System.Management.Automation.PSCustomObject]) {
            $mappedTargets = @($storyMap.PSObject.Properties | ForEach-Object { [string]$_.Value })
        }
        # 023, data-model.md §1: `order` is now PER ROLE — passed through as
        # the resolved {specification;story;task} object, never flattened.
        $order = Get-JiraReconcilePhaseOrder -PhaseStatusMapJson $phaseStatusMap | ConvertFrom-Json -Depth 100
        $target = ''
        if ($storyMap -is [System.Management.Automation.PSCustomObject] -and -not [string]::IsNullOrEmpty($hookEvent)) {
            $target = [string](Get-JiraPlanPropSafe $storyMap $hookEvent)
        }
        $haltedList = @($haltedStatuses | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })

        $lcTickets = [ordered]@{}
        $boundVal2 = Get-JiraPlanPropSafe $recog 'bound'
        if ($boundVal2) {
            foreach ($p in $boundVal2.PSObject.Properties) {
                $statusVal = [string](Get-JiraPlanPropSafe $p.Value 'status')
                $statusCategoryVal = [string](Get-JiraPlanPropSafe $p.Value 'status_category')
                $category = 'unknown'
                if ($mappedTargets -contains $statusVal) { $category = 'mapped' }
                elseif ($haltedList -contains $statusVal) { $category = 'halted' }
                elseif ($statusCategoryVal -eq 'done') { $category = 'post-scope' }
                $entry = [ordered]@{
                    key      = Get-JiraPlanPropSafe $p.Value 'key'
                    current  = Get-JiraPlanPropSafe $p.Value 'current'
                    status   = $statusVal
                    category = $category
                    target   = $target
                    role     = 'story'
                    flagged  = Get-JiraPlanPropSafe $p.Value 'flagged'
                    blockers = Get-JiraPlanPropSafe $p.Value 'blockers'
                }
                $entry['origin'] = [string](Get-JiraPlanPropSafe $p.Value 'origin')
                $lcTickets[$p.Name] = $entry
            }
        }

        $lcMap2 = [ordered]@{ base_url = $base; on_drift = $onDrift; order = $order; tickets = $lcTickets }

        # 023, research R6: the parent's own lifecycle context entry, keyed
        # by its durable local identifier (epic.local_id — the same key the
        # parent-content write already uses), role "specification". Only for
        # a RECOGNISED parent — a not-yet-created one has no status to
        # evaluate drift against (D3).
        $parentLocalIdCtx = ''
        if ($docForWriteObj -and (Get-JiraPlanPropSafe $docForWriteObj 'epic')) {
            $parentLocalIdCtx = [string](Get-JiraPlanPropSafe (Get-JiraPlanPropSafe $docForWriteObj 'epic') 'local_id')
        }
        if ($parentState -eq 'bound' -and -not [string]::IsNullOrEmpty($parentLocalIdCtx)) {
            $specMap = Get-JiraPlanPropSafe $phaseMapObj 'specification'
            $pTarget = ''
            if ($specMap -is [System.Management.Automation.PSCustomObject] -and -not [string]::IsNullOrEmpty($hookEvent)) {
                $pTarget = [string](Get-JiraPlanPropSafe $specMap $hookEvent)
            }
            $pMappedTargets = @()
            if ($specMap -is [System.Management.Automation.PSCustomObject]) {
                $pMappedTargets = @($specMap.PSObject.Properties | ForEach-Object { [string]$_.Value })
            }
            $pStatus = [string](Get-JiraPlanPropSafe $recogParent 'status')
            $pStatusCategory = [string](Get-JiraPlanPropSafe $recogParent 'status_category')
            $pCategory = 'unknown'
            if ($pMappedTargets -contains $pStatus) { $pCategory = 'mapped' }
            elseif ($haltedList -contains $pStatus) { $pCategory = 'halted' }
            elseif ($pStatusCategory -eq 'done') { $pCategory = 'post-scope' }
            $pEntry = [ordered]@{
                key      = [string](Get-JiraPlanPropSafe $recogParent 'key')
                current  = $null
                blockers = Get-JiraPlanPropSafe $recogParent 'blockers'
                status   = $pStatus
                category = $pCategory
                target   = $pTarget
                role     = 'specification'
                flagged  = Get-JiraPlanPropSafe $recogParent 'flagged'
                origin   = 'bridge'
            }
            $lcMap2['parent_local_id'] = $parentLocalIdCtx
            $lcTickets[$parentLocalIdCtx] = $pEntry
        }

        $lcJson = ConvertTo-JiraJsonValue $lcMap2
    }
    try {
        $lresult = Get-JiraLifecyclePlan -ContentActionsJson $actionsJson -NeutralDocJson $docForWriteJson -LifecycleContextJson $lcJson -ParentActionJson (ConvertTo-JiraJsonValue $parentAction) | ConvertFrom-Json -Depth 100
    }
    catch {
        # 023, contract transition-resolution.md §2 F2: a transitions-read
        # failure fails closed for the WHOLE specification. Get-JiraLifecyclePlan
        # throws naming the failing key, prefixed "RC=<n>:" carrying the
        # REAL transport exit code (fail_closed=2, auth=3, ...) -- an
        # exception cannot carry a structured exit code natively, and a
        # message-only throw here previously HARDCODED EXIT_CONFIG (4)
        # regardless of what the read actually failed with, diverging from
        # reconcile.sh's own _reconcile_fault "${lc_rc}" ..., which passes
        # the real code straight through. The prefix is stripped from the
        # user-facing message; a message with no prefix (any OTHER
        # assembly failure) falls back to EXIT_CONFIG.
        $msg = [string]$_.Exception.Message
        if ($msg -match '^RC=(\d+):(.*)$') {
            return (Get-JiraReconcileFaultCode -Code ([int]$Matches[1]) -Message "reconcile: $($Matches[2])")
        }
        if ($msg -match "'s available moves could not be read") {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: $msg")
        }
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the lifecycle plan could not be assembled (zero writes)')
    }
    $actionsJson = ConvertTo-JiraJsonValue $lresult.actions
    $warnsJson = ConvertTo-JiraJsonValue $lresult.warnings
    $notesJson = ConvertTo-JiraJsonValue $lresult.notes
    # 023, U8: the parent's content write is a SEPARATE code path from
    # $kept (Reconcile.psm1's own parent-first write, PlanApply.psm1's
    # per-ticket loop unconditionally excludes it) — so a halted parent's
    # content_writes:false decision, computed inside Get-JiraLifecyclePlan
    # but with nowhere else to surface, must be applied here or the parent
    # silently keeps writing content a halted STORY would have withheld.
    # Every downstream consumer of $parentAction (counts, the apply plan,
    # the run summary's own display) reads it AFTER this point.
    $parentContentDroppedVal = Get-JiraPlanPropSafe $lresult 'parent_content_dropped'
    if ($null -ne $parentContentDroppedVal -and [bool]$parentContentDroppedVal) {
        $parentAction = $null
    }

    # Every blocked story produces exactly one warning from the diagnostics
    # catalogue (FR-011, FR-016, FR-021) — folded into the same channel the
    # lifecycle rules use.
    $warnsList = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($warnsJson | ConvertFrom-Json -Depth 100)) { $warnsList.Add([string]$w) }
    foreach ($b in @($recog.blocked)) { $warnsList.Add([string]$b.detail) }
    # Phase 3, US1: the task tier's own warnings — a withheld tier, a
    # recognition block, or a plan failure — join the same channel.
    foreach ($tw in $taskWarns) { $warnsList.Add($tw) }
    # Stray-marker warning (FR-007, contracts/target-guard.md §4): one entry
    # naming every match, computed earlier, before the plan or Jira were
    # even reached — never blocks, never changes the exit code.
    if (-not [string]::IsNullOrEmpty($strayFiles)) {
        $warnsList.Add("spec-kit-jira markers were found in files this mirror never writes: $strayFiles — they are inert, were left untouched, and can be removed by hand")
    }
    foreach ($lw in $planLabelWarnings) { $warnsList.Add([string]$lw) }
    # Duplicate-probe "unavailable" warning (User Story 4, contract §4):
    # computed above, on the planning pass — never blocks, never changes the
    # exit code.
    if (-not [string]::IsNullOrEmpty($dupProbeWarning)) { $warnsList.Add($dupProbeWarning) }
    $warnsJson = ConvertTo-JiraJsonValue $warnsList

# T073 (FR-021, FR-022): orphan and re-attribution reports join the notes
# channel — reported once, never acted on.
$notesListTaskNotes = [System.Collections.Generic.List[string]]::new()
foreach ($n in @($notesJson | ConvertFrom-Json -Depth 100)) { $notesListTaskNotes.Add([string]$n) }
foreach ($tn in $taskNotes) { $notesListTaskNotes.Add($tn) }
$notesJson = ConvertTo-JiraJsonValue $notesListTaskNotes

    # A List keeps a single-element action set an ARRAY (a bare @() unwraps to an
    # object under ConvertTo-JiraJsonValue, diverging from the Bash port).
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($actionsJson | ConvertFrom-Json -Depth 100)) { $actions.Add($x) }

    # created/updated count only their own endpoints; a transition is also a
    # POST but is not a ticket creation, so it is excluded from the created
    # tally. skipped (FR-023) is what Get-JiraLifecyclePlan silently dropped
    # as no-op: every recognised ticket whose write would have been a no-op.
    $created = @($actions | Where-Object { $_.method -eq 'POST' -and ([string]$_.url).EndsWith('/issue') }).Count
    $updated = @($actions | Where-Object { $_.method -eq 'PUT' }).Count
    # The parent's own creation/update counts toward the same tallies (T079).
    if ($null -ne $parentAction) {
        if ($parentAction.method -eq 'POST') { $created++ }
        elseif ($parentAction.method -eq 'PUT') { $updated++ }
    }
    # 023, data-model.md §5, FR-011: counts.transitioned is present ONLY when
    # this run carries an event AND at least one role declares a step for it
    # — absence, not a zeroed count, is the off switch that keeps a run with
    # no event byte-identical to before this feature. Never folded into
    # created/updated: a move is a position change, not a content one.
    # Computed from `actions` (the parent's transition, if any, already
    # rides in this same array — Get-JiraLifecyclePlan appends it there,
    # never to a second slot).
    $countsTransitioned = $null
    if (-not [string]::IsNullOrEmpty($hookEvent)) {
        $phaseMapForCount = $phaseStatusMap | ConvertFrom-Json -Depth 100
        $anyRoleDeclaresStep = $false
        foreach ($prop in $phaseMapForCount.PSObject.Properties) {
            $stepVal = [string](Get-JiraPlanPropSafe $prop.Value $hookEvent)
            if (-not [string]::IsNullOrEmpty($stepVal)) { $anyRoleDeclaresStep = $true; break }
        }
        if ($anyRoleDeclaresStep) {
            $countsTransitioned = @($actions | Where-Object { $_.method -eq 'POST' -and ([string]$_.url).EndsWith('/transitions') }).Count
        }
    }
    $warnCount = @($warnsJson | ConvertFrom-Json -Depth 100).Count
    $noteCount = @($notesJson | ConvertFrom-Json -Depth 100).Count
    $recognisedCount = @($recog.bound.PSObject.Properties).Count
    $skippedCount = $recognisedCount - $updated
    if ($skippedCount -lt 0) { $skippedCount = 0 }
    $hasLifecycle = $hasOverrideLifecycle
    if ($warnCount -gt 0 -or $noteCount -gt 0) { $hasLifecycle = $true }

    # The consolidated question (Phase 4, US2, T066/T068; contract §3.3/
    # §3.4; data-model.md §4): fired only now that recognition and planning
    # show whether a creation is actually pending (FR-013) — $fdAskPending
    # above was merely a STRUCTURAL candidate, computed before recognition
    # ran. Scoped to the types that actually have a creation pending THIS
    # run (never a type the project merely offers — FR-028). Zero writes on
    # this path: neither the marker file (deferred above) nor any Jira call
    # has happened yet.
    # T066a (FR-040): the task tier's own pending creations join the SAME
    # gate and the SAME set of pending types — a run creating all three
    # tiers still asks exactly one question, naming every tier's field.
    $fdTaskCreatesPending = @(@($tasksActionsJson | ConvertFrom-Json -Depth 100) | Where-Object { $_.method -eq 'POST' -and ([string]$_.url).EndsWith('/issue') }).Count
    if ($fdAskPending -and ($created -gt 0 -or $fdTaskCreatesPending -gt 0)) {
        $fdPendingTypes = [System.Collections.Generic.List[string]]::new()
        foreach ($x in $actions) {
            if ($x.method -eq 'POST' -and ([string]$x.url).EndsWith('/issue')) {
                $fdPendingTypes.Add([string]$x.body.fields.issuetype.id)
            }
        }
        if ($null -ne $parentAction -and $parentAction.method -eq 'POST') {
            $fdPendingTypes.Add([string]$parentAction.body.fields.issuetype.id)
        }
        foreach ($x in @($tasksActionsJson | ConvertFrom-Json -Depth 100)) {
            if ($x.method -eq 'POST' -and ([string]$x.url).EndsWith('/issue')) {
                $fdPendingTypes.Add([string]$x.body.fields.issuetype.id)
            }
        }
        # 015 (regression, NFR-1): jq's `unique` (bash's twin, reconcile.sh)
        # sorts its result ordinally — Select-Object -Unique only dedupes,
        # preserving first-seen order, which diverges whenever more than one
        # type is pending in the same run (first exposed by an option-typed
        # default required on both the specification and story roles at
        # once). Sort with the same comparer ConvertTo-JiraJsonValue already
        # uses for key order, so both ports agree byte for byte.
        $fdPendingUnique = [System.Collections.Generic.List[string]]::new()
        foreach ($t in @($fdPendingTypes | Select-Object -Unique)) { $fdPendingUnique.Add($t) }
        $fdPendingUnique.Sort([System.StringComparer]::Ordinal)
        $fdPendingTypesJson = ConvertTo-JiraJsonValue (@($fdPendingUnique))
        $fdFieldsJson = Get-JiraPlanConfirmationField -IssueTypesJson $fdItypesJson -DefaultableFieldsByTypeJson $fdDfJson `
            -FieldDefaultsByTypeJson $fdDefaultsByTypeJson -PendingTypeIdsJson $fdPendingTypesJson
        $fdFields = @($fdFieldsJson | ConvertFrom-Json -Depth 100)
        if ($fdFields.Count -gt 0) {
            $fdCreationsPending = $created + $fdTaskCreatesPending
            $fdConfirmation = [ordered]@{
                status            = 'confirmation-pending'
                project           = $projectKey
                fields            = $fdFields
                creations_pending = $fdCreationsPending
                resume_with       = "/speckit.jira-mirror.reconcile $specFile --accept-defaults"
            }
            $fdConfirmationJson = ConvertTo-JiraJsonValue $fdConfirmation
            # Write + an explicit "`n", never WriteLine: WriteLine's terminator
            # is [Environment]::NewLine, which is CRLF on Windows, while the
            # Bash twin's `printf '…\n'` is LF on every host (reconcile.sh
            # 1785-1789). These were the only three WriteLine calls on stdout in
            # the port and all three diverged; the two conformance scenarios
            # that caught it (us2-field-defaults-question and
            # -option-question) exercise the --json branch only — the prose
            # branch below is uncovered and was the same defect (#46 D3).
            if ($json) {
                [Console]::Out.Write($fdConfirmationJson + "`n")
            }
            else {
                $fdLabels = ($fdFields | ForEach-Object { [string]$_.label }) -join ', '
                [Console]::Out.Write("Jira mirror paused: confirm $fdLabels before $fdCreationsPending creation(s) are written.`n")
                [Console]::Out.Write("Resume with: $($fdConfirmation.resume_with)`n")
            }
            return 0
        }
        elseif ($null -ne $gateResult -and $gateResult.status -eq 'unsatisfiable') {
            # The gate found a pending creation's type structurally
            # unsatisfiable, but no field-level detail could be built for
            # it — the binding predates defaultable-field discovery for
            # that type. Refuse via the gate's own message rather than
            # silently writing a payload missing a required field.
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message $gateResult.message)
        }
    }

    # The marker write deferred above, now that we know the question did
    # not fire (either $fdAskPending was never true, or it was but neither
    # §3.3 trigger held once the plan was known).
    if ($fdAskPending -and $needWrite) {
        try { Write-JiraMarkerSpliceFile -Path $specFile -NewContent $assignedSpec | Out-Null }
        catch {
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: $specFile could not be written — no ticket may be created before its identifier is recorded (zero writes)")
        }
    }

    Stop-JiraTimingPhase -Phase 'plan' -RequestCount (Get-JiraRequestCount)
    Start-JiraTimingPhase -Phase 'apply' -RequestCount (Get-JiraRequestCount)

    $rc = 0
    if (-not $dryRun) {
        # R5 steps 4/6, contract steps 8-11: Invoke-JiraApplyWriteSetWithRecognition
        # performs the parent first, marks every planned creation `creating`
        # before the first create, and stamps + records each created
        # ticket's key IMMEDIATELY, per ticket.
        $applyPlanJson = ConvertTo-JiraJsonValue ([ordered]@{ parent = $parentAction; stories = @($actionsJson | ConvertFrom-Json -Depth 100) })
        $knownParentKey = if ($parentState -eq 'bound') { [string]$recogParent.key } else { '' }
        # Phase 3, US1: the task tier's own writes join the SAME apply call —
        # the pre-write privacy sweep must cover every payload of the run
        # before any of them is written (FR-025) — never a second call.
        # $knownStoryKeys seeds the parent-key resolution with every story
        # ALREADY recognised; a story created in this same run is added to
        # the map as the apply pass reaches it.
        $knownStoryKeysJson = '{}'
        if ($taskRoleActive) {
            $ksk = [ordered]@{}
            $boundForKsk = Get-JiraPlanPropSafe $recog 'bound'
            if ($boundForKsk) {
                foreach ($p in $boundForKsk.PSObject.Properties) { $ksk[$p.Name] = [string](Get-JiraPlanPropSafe $p.Value 'key') }
            }
            $knownStoryKeysJson = ConvertTo-JiraJsonValue $ksk
        }
        $applyOutcome = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $applyPlanJson -SpecRefJson $specRefJson -SpecFile $specFile -KnownParentKey $knownParentKey -DefaultableFieldsByTypeJson $fdDfJson `
            -TasksActionsJson $tasksActionsJson -TasksFile $tasksFile -KnownStoryKeysJson $knownStoryKeysJson
        $rc = [int]$applyOutcome.ExitCode
        # 015, research R4, contract §4.3/§5: `created` now reports what Jira
        # actually confirmed, not what was merely planned. The parent/story
        # filter keeps 012's sub-tasks out of this tier's tally: they are
        # counted separately in counts.tasks.created (012 FR-011).
        $created = @(@($applyOutcome.Created) | Where-Object { $_.role -eq 'parent' -or $_.role -eq 'story' }).Count
    }

    # Edge Cases (contract §6, final line; T084): a task checked before its
    # sub-task ever existed is created and transitioned in this SAME run. The
    # completion pass above deferred it — no key existed yet to read
    # transitions for. Resolved now that the create above (if it completed)
    # stamped a key into tasksFile; pendingCreateCompleteIds stays empty
    # whenever nothing qualifies, so this block is a no-op otherwise.
    if (-not $dryRun -and $pendingCreateCompleteIds.Count -gt 0) {
        $pccDoc = ConvertTo-JiraTasksParseDocument -Text (Get-Content -Raw -LiteralPath $tasksFile) | ConvertFrom-Json -Depth 100
        $pccCtxTasks = [ordered]@{}
        foreach ($pccId in $pendingCreateCompleteIds) {
            $pccTaskEntry = @($pccDoc.tasks) | Where-Object { [string]$_.local_id -eq $pccId } | Select-Object -First 1
            $pccKey = if ($pccTaskEntry) { [string](Get-JiraPlanPropSafe $pccTaskEntry.marker 'ticket') } else { '' }
            if ([string]::IsNullOrEmpty($pccKey)) { continue }
            $pccFwdResult = Get-JiraDiscoveryTaskTransitionResult -IssueKey $pccKey -Direction 'forward'
            if ($pccFwdResult.ExitCode -ne 0) {
                if ([int]$pccFwdResult.ExitCode -gt $rc) { $rc = [int]$pccFwdResult.ExitCode }
                continue
            }
            $pccCtxTasks[$pccId] = [ordered]@{ key = $pccKey; blockers = @(); forward = ($pccFwdResult.Transition | ConvertFrom-Json -Depth 100) }
        }

        if ($pccCtxTasks.Count -gt 0) {
            $pccCtxJson = ConvertTo-JiraJsonValue ([ordered]@{ base_url = $base; tasks = $pccCtxTasks })
            $pccResultJson = Get-JiraTaskLifecyclePlan -ContentActionsJson '[]' -CompletionContextJson $pccCtxJson
            $pccResult = $pccResultJson | ConvertFrom-Json -Depth 100
            $pccActions = @(Get-JiraPlanPropSafe $pccResult 'actions')
            if ($pccActions.Count -gt 0) {
                $pccActionsJson = ConvertTo-JiraJsonValue $pccActions
                # 015 contract §4.2: the apply returns @{ExitCode; Created}, not
                # a bare code. This pass only transitions already-created
                # sub-tasks, so Created carries nothing this tier counts — but
                # the exit code must be read off the object, not the object
                # itself, or every outcome would compare as non-zero.
                $pccOutcome = Invoke-JiraApplyWriteSetWithRecognition -PlanJson '{"parent":null,"stories":[]}' -SpecRefJson $specRefJson -SpecFile $specFile -KnownParentKey '' -DefaultableFieldsByTypeJson $fdDfJson `
                    -TasksActionsJson $pccActionsJson -TasksFile $tasksFile -KnownStoryKeysJson '{}'
                $pccRc = [int]$pccOutcome.ExitCode
                if ($pccRc -eq 0) {
                    $tasksActionsListPcc = [System.Collections.Generic.List[object]]::new()
                    foreach ($x in @($tasksActionsJson | ConvertFrom-Json -Depth 100)) { $tasksActionsListPcc.Add($x) }
                    foreach ($x in $pccActions) { $tasksActionsListPcc.Add($x) }
                    $tasksActionsJson = ConvertTo-JiraJsonValue $tasksActionsListPcc
                }
                elseif ([int]$pccRc -gt $rc) { $rc = [int]$pccRc }
            }

            $warnsListPcc = [System.Collections.Generic.List[string]]::new()
            foreach ($w in @($warnsJson | ConvertFrom-Json -Depth 100)) { $warnsListPcc.Add([string]$w) }
            foreach ($w in @(Get-JiraPlanPropSafe $pccResult 'warnings')) { $warnsListPcc.Add([string]$w) }
            $warnsJson = ConvertTo-JiraJsonValue $warnsListPcc

            $notesListPcc = [System.Collections.Generic.List[string]]::new()
            foreach ($n in @($notesJson | ConvertFrom-Json -Depth 100)) { $notesListPcc.Add([string]$n) }
            foreach ($n in @(Get-JiraPlanPropSafe $pccResult 'notes')) { $notesListPcc.Add([string]$n) }
            $notesJson = ConvertTo-JiraJsonValue $notesListPcc

            $warnCount = @($warnsJson | ConvertFrom-Json -Depth 100).Count
            $noteCount = @($notesJson | ConvertFrom-Json -Depth 100).Count
            if ($warnCount -gt 0 -or $noteCount -gt 0) { $hasLifecycle = $true }
        }
    }

    # T079/parent-marker.md `parent-recreated`: a summary note, not a
    # refusal — the recorded parent no longer existed, so a new one was
    # created and the record was updated. The new key is only known after
    # the create response, so re-read the just-written spec file for it.
    if (-not $dryRun -and $parentState -eq 'new' -and $recogParent.PSObject.Properties.Name -contains 'recreated_from') {
        $formerParentKey = [string]$recogParent.recreated_from.key
        $postEpicRaw = Get-Content -Raw -LiteralPath $specFile
        if ($null -eq $postEpicRaw) { $postEpicRaw = '' }
        $postEpicInfo = Get-JiraSpecMarkerDocumentInfo -Content $postEpicRaw | ConvertFrom-Json -Depth 100
        $newParentKey = [string](Get-JiraPlanPropSafe $postEpicInfo 'ticket')
        if (-not [string]::IsNullOrEmpty($newParentKey)) {
            $notesList2 = [System.Collections.Generic.List[string]]::new()
            foreach ($n in @($notesJson | ConvertFrom-Json -Depth 100)) { $notesList2.Add([string]$n) }
            $notesList2.Add("$formerParentKey, recorded as the parent of $specFile, no longer exists in Jira; a new parent was created and the record updated (now $newParentKey).")
            $notesJson = ConvertTo-JiraJsonValue $notesList2
            $hasLifecycle = $true
        }
    }

    # T071: the catalogued `re-routed` notice, once the new key is recorded.
    # Recognition tags a re-routed story with its former key and project
    # ($recog.rerouted); the new key is only known after the create response,
    # so the command layer re-reads the just-written spec file for it.
    # Skipped under --dry-run (no key is ever recorded there) and skipped for
    # a story whose creation did not complete this run — a future run
    # reports it then.
    $reroutedProp = Get-JiraPlanPropSafe $recog 'rerouted'
    if (-not $dryRun -and $reroutedProp -and @($reroutedProp.PSObject.Properties).Count -gt 0) {
        $postRaw = Get-Content -Raw -LiteralPath $specFile
        if ($null -eq $postRaw) { $postRaw = '' }
        try {
            $postParseObj = (Get-JiraParsedSpec -Text $postRaw -FolderSlug $slug) | ConvertFrom-Json -Depth 100
            $notesList = [System.Collections.Generic.List[string]]::new()
            foreach ($n in @($notesJson | ConvertFrom-Json -Depth 100)) { $notesList.Add([string]$n) }
            foreach ($rp in $reroutedProp.PSObject.Properties) {
                $rid = $rp.Name
                $story = $postParseObj.stories | Where-Object { [string]$_.local_id -eq $rid } | Select-Object -First 1
                $marker = if ($story) { Get-JiraPlanPropSafe $story 'marker' } else { $null }
                $state = if ($marker) { [string](Get-JiraPlanPropSafe $marker 'state') } else { '' }
                if ($state -eq 'bound') {
                    $newKey = [string](Get-JiraPlanPropSafe $marker 'ticket')
                    if (-not [string]::IsNullOrEmpty($newKey)) {
                        $formerKey = [string]$rp.Value.former_key
                        $formerProject = [string]$rp.Value.former_project
                        $notesList.Add("Story $rid in $specFile was previously mirrored as $formerKey in project $formerProject, which is no longer the project this specification routes to; $formerKey was left untouched and the story was mirrored into $projectKey as $newKey. Nothing was moved or deleted.")
                        $hasLifecycle = $true
                    }
                }
            }
            $notesJson = ConvertTo-JiraJsonValue $notesList
        }
        catch {
            # Best-effort re-read of the just-written spec file; a parse
            # failure here only skips the re-routed notice this run, it does
            # not undo the writes already applied above.
            $null = $_
        }
    }

    # Hook health is READ and reported on every run (FR-047). Nothing here writes
    # the registry, in any state — reading it is the extension's whole
    # relationship with that file (003 FR-022). The path is relative to the
    # repository root (cwd), overridable for tests.
    $extPath = if ($env:SPEC_KIT_JIRA_EXTENSIONS_YML) { $env:SPEC_KIT_JIRA_EXTENSIONS_YML } else { '.specify/extensions.yml' }
    $hooksHealth = Get-JiraHookHealth -Path $extPath -DisabledJson (Get-JiraHooksDisabled) | ConvertFrom-Json -Depth 100

    # Save-JiraRunState (021, T031) below must see whether this run actually
    # applied every planned action — the hook-context downgrade just below
    # resets $rc to 0 even on a real failure, so the pre-downgrade value is
    # captured here rather than trusting $rc at the point of recording.
    $rcBeforeHookDowngrade = $rc

    # FR-046 / 003 FR-015: in hook context a bridge failure NEVER fails the host
    # command — after surfacing a single actionable WARNING the exit is downgraded
    # to 0, so the mirror can fail without ever affecting the spec-kit command
    # that triggered it. The warning names the true cause and only commands that
    # can be run as spelled (FR-017, FR-018): `reconcile --repair-hooks` used to
    # be named here and no longer exists, because repairing the registry is a
    # write FR-022 forbids.
    if ($env:SPEC_KIT_JIRA_HOOK_CONTEXT -and $rc -ne 0) {
        $cause = switch ($rc) {
            2 { 'Jira could not be reached, or a read failed closed' }
            3 { 'Jira rejected the credentials' }
            4 { 'the configuration was refused' }
            5 { 'a prerequisite is missing' }
            9 { 'the privacy guard blocked the write' }
            default { 'the mirror did not complete' }
        }
        [Console]::Error.WriteLine("WARNING: Jira mirror not completed — $cause (exit $rc). This spec-kit command completed normally. Run /speckit.jira-mirror.config to re-check the binding.")
        $rc = 0
    }

    # FR-026: an unattributed or dangling task is never a fault ($rc stays
    # 0), so it is invisible to the block above — but a lifecycle hook still
    # gets only ONE warning, not one per task. The run summary's own notes
    # (above) keep naming each one individually; only the stderr side
    # collapses.
    if ($env:SPEC_KIT_JIRA_HOOK_CONTEXT -and $rc -eq 0 -and $taskSkipNotes.Count -gt 0) {
        [Console]::Error.WriteLine("WARNING: $($taskSkipNotes.Count) task(s) could not be mirrored (no story attribution, or attributed to a story the specification does not contain); see the run summary for detail. This spec-kit command completed normally.")
    }

    # Field-default provenance (011, T074, contract §4.1/§4.2): every field
    # this run actually sent that came from a recorded default or a this-run
    # answer, attributed to its source, plus the promotion command for an
    # override and the skipped-confirmation reason. Reads the SAME resolved
    # map the gate already computed ($gateResolved) — never a second
    # resolution pass, so the preview and the real run cannot disagree
    # (§4.3). Empty when nothing was defaulted this run (FR-028 — the off
    # switch).
    $gateResolvedJsonForNotes = if ($null -ne $gateResolved) { ConvertTo-JiraJsonValue $gateResolved } else { '{}' }
    # Phase 3, US1 (FR-042): a sub-task creation's field values are attributed
    # to their source through this SAME reporting surface — never a
    # sub-task-specific one — so the action list handed to it must include
    # the task tier's own actions.
    $fdNotesActions = [System.Collections.Generic.List[object]]::new()
    foreach ($x in $actions) { $fdNotesActions.Add($x) }
    if ($taskRoleActive) {
        foreach ($x in @($tasksActionsJson | ConvertFrom-Json -Depth 100)) { $fdNotesActions.Add($x) }
    }
    $fdNoteLines = @(Get-JiraReconcileFieldDefaultNote -ProjectKey $projectKey -IssueTypesJson $fdItypesJson `
            -DefaultableFieldsByTypeJson $fdDfJson -ResolvedJson $gateResolvedJsonForNotes `
            -ActionsJson (ConvertTo-JiraJsonValue $fdNotesActions) -ParentActionJson (ConvertTo-JiraJsonValue $parentAction) `
            -Ask $gateAsk -AcceptDefaults $acceptDefaults -DryRun $dryRun)
    if ($fdNoteLines.Count -gt 0) {
        $notesList3 = [System.Collections.Generic.List[string]]::new()
        foreach ($n in @($notesJson | ConvertFrom-Json -Depth 100)) { $notesList3.Add([string]$n) }
        foreach ($n in $fdNoteLines) { $notesList3.Add($n) }
        $notesJson = ConvertTo-JiraJsonValue $notesList3
        $hasLifecycle = $true
    }

    # Report the action set with the base URL stripped to a host-relative path:
    # the site host is a coordinate that must never appear in output
    # (Constitution IV), and it keeps the summary stable across the mock port.
    # `local_id` is internal bookkeeping (which story a creation stamps) and
    # is never part of the published action shape — UNLESS a task role is
    # active, when a story's own local_id is the only way a --dry-run
    # preview names WHICH story a sub-task belongs to (FR-024), since
    # `fields.parent.key` stays the "<resolved at apply time>" placeholder
    # for a same-run story creation. Never kept for a no-task-role run, so
    # FR-011's byte-identical guarantee is unaffected.
    # The reported action list stays FLAT (T080a): the parent — when
    # present — is reported first, exactly like any other action,
    # host-relative and stripped of its internal local_id bookkeeping.
    # identity_stamp (018, T049) is an apply-time-only instruction — never
    # part of the displayed/dry-run summary, regardless of whether local_id
    # itself is kept for task matching.
    $disp = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $parentAction) {
        $u = [string]$parentAction.url
        if ($u.StartsWith($base)) { $parentAction.url = $u.Substring($base.Length) }
        $copy = [ordered]@{}
        foreach ($p in $parentAction.PSObject.Properties) { if ($p.Name -ne 'local_id' -and $p.Name -ne 'identity_stamp') { $copy[$p.Name] = $p.Value } }
        $disp.Add($copy)
    }
    foreach ($x in $actions) {
        $u = [string]$x.url
        if ($u.StartsWith($base)) { $x.url = $u.Substring($base.Length) }
        $copy = [ordered]@{}
        foreach ($p in $x.PSObject.Properties) { if (($p.Name -ne 'local_id' -or ($taskRoleActive -and $taskTierMode -eq 'subtask')) -and $p.Name -ne 'identity_stamp') { $copy[$p.Name] = $p.Value } }
        $disp.Add($copy)
    }
    # Phase 3, US1 (Constitution XI): task actions join the SAME displayed
    # list, last — a --dry-run preview that reports counts.tasks but never
    # shows what it counted would not be an honest preview. `parent_local_id`
    # is kept (only the task's own local_id is stripped) so it can be
    # matched against the story action's local_id kept above.
    if ($taskRoleActive -and $taskTierMode -eq 'subtask') {
        foreach ($x in @($tasksActionsJson | ConvertFrom-Json -Depth 100)) {
            $u = [string]$x.url
            if ($u.StartsWith($base)) { $x.url = $u.Substring($base.Length) }
            $copy = [ordered]@{}
            foreach ($p in $x.PSObject.Properties) { if ($p.Name -ne 'local_id' -and $p.Name -ne 'identity_stamp') { $copy[$p.Name] = $p.Value } }
            $disp.Add($copy)
        }
    }

    # Phase 3, US1 (data-model.md 6, SC-006): the task tier's own nested
    # counts, emitted ONLY when a `task` role is declared (research R8) —
    # absence, not a zeroed-out object, is the off switch that keeps a run
    # with no `task` role byte-for-byte identical to before this feature
    # (FR-011). created/updated read straight off the plan actions actually
    # applied; unchanged is every other attributed task.
    $taskCounts = $null
    if ($taskRoleActive -and $taskTierMode -eq 'subtask') {
        $tasksActionsForCount = @($tasksActionsJson | ConvertFrom-Json -Depth 100)
        $taskCreated = @($tasksActionsForCount | Where-Object { $_.method -eq 'POST' -and ([string]$_.url).EndsWith('/issue') }).Count
        $taskUpdated = @($tasksActionsForCount | Where-Object { $_.method -eq 'PUT' }).Count
        # Phase 8, US5: a transition is also a POST, so it is named separately from
        # `/issue` creations here exactly as it is excluded from `created` above.
        $taskTransitioned = @($tasksActionsForCount | Where-Object { $_.method -eq 'POST' -and ([string]$_.url).EndsWith('/transitions') }).Count
        $taskTotal = 0
        foreach ($s in @($docForWriteObj.stories)) {
            $sTasksForCount = Get-JiraPlanPropSafe $s 'tasks'
            if ($null -ne $sTasksForCount) { $taskTotal += @($sTasksForCount).Count }
        }
        $taskUnchanged = $taskTotal - $taskCreated - $taskUpdated
        if ($taskUnchanged -lt 0) { $taskUnchanged = 0 }
        $taskCounts = [ordered]@{ created = $taskCreated; updated = $taskUpdated; transitioned = $taskTransitioned; unchanged = $taskUnchanged; skipped = $taskSkipNotes.Count; withheld = $taskWithheldCount }
    }

    # The warnings/notes keys appear when the lifecycle facts were supplied OR
    # a story was blocked, so the content-only reconcile (US3) summary with
    # neither is byte-for-byte unchanged.
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'reconcile'
        dry_run        = [bool]$dryRun
        counts         = [ordered]@{ created = $created; updated = $updated; skipped = $skippedCount; warnings = $warnCount; errors = 0; recognised = $recognisedCount; assigned = $assignedCount }
        actions        = $disp
    }
    if ($null -ne $countsTransitioned) { $summaryObj.counts['transitioned'] = $countsTransitioned }
    if ($null -ne $taskCounts) { $summaryObj.counts['tasks'] = $taskCounts }
    if ($null -ne $checklistCounts) {
        $summaryObj.counts['checklists'] = [ordered]@{ created = $checklistCounts.created; updated = $checklistCounts.updated; unchanged = $checklistCounts.unchanged }
        $summaryObj.counts['entries'] = [ordered]@{ completed = $checklistCounts.entries_completed }
    }
    if ($hasLifecycle) {
        $summaryObj['warnings'] = @($warnsJson | ConvertFrom-Json -Depth 100)
        $summaryObj['notes'] = @($notesJson | ConvertFrom-Json -Depth 100)
    }
    $summaryObj['hook_health'] = $hooksHealth
    $summaryObj['exit_code'] = $rc
    $summary = ConvertTo-JiraJsonValue $summaryObj

    Stop-JiraTimingPhase -Phase 'apply' -RequestCount (Get-JiraRequestCount)

    # Save-JiraRunState (021, T031, contracts/run-state.md §4): only a real
    # run (never -DryRun) that applied every planned action (the
    # pre-downgrade rc is 0 — a hook-context failure masked to exit 0 must
    # not be recorded as a success), emitted no warning, and has no pending
    # confirmation outstanding (a pending-confirmation run already returned
    # above, long before this point, so reaching here already proves that
    # condition).
    if (-not $dryRun -and $rcBeforeHookDowngrade -eq 0 -and $warnCount -eq 0) {
        Save-JiraRunState -SpecPath $specFile -BaseUrl $base -Email $email -OnDrift $onDrift -HookEvent $hookEvent -FieldValues $fieldValues
    }

    if ($json) {
        [Console]::Out.Write($summary + "`n")
    }
    else {
        [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $summary))
    }
    return $rc
}

Export-ModuleMember -Function Invoke-JiraReconcile, Resolve-JiraReconcileRouting, `
    Get-JiraReconcileLocalBindingFor, Get-JiraReconcilePlanContextFromBinding
