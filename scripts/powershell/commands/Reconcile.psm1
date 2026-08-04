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
Import-Module (Join-Path $PSScriptRoot '../engine/StoryMarker.psm1') -Force -Global # R5 step 1 — assign identifiers
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Recognition.psm1') -Force # R5 step 2 — recognise recorded tickets
Import-Module (Join-Path $PSScriptRoot '../sink/jira/PlanApply.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../hooks/RegisterHooks.psm1') -Force # hook health — READ ONLY (003 FR-022)
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force          # the operator disable record
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Hierarchy.psm1') -Force -Global # the mandatory-field gate — a nested import inside lib/Config.psm1 is not enough
Import-Module (Join-Path $PSScriptRoot '../lib/Prereq.psm1') -Force          # the bridge-unavailable cause

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
      The resolved project's declared phase->status map (Phase 6, US4,
      research R9), or {} when the project declares none. Mirror of
      _reconcile_phase_status_map.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey, [Parameter(Mandatory)] [string] $ConfigJson)
    $cfg = $ConfigJson | ConvertFrom-Json -Depth 100
    $projectsVal = Get-JiraPlanPropSafe $cfg 'projects'
    $projects = if ($null -ne $projectsVal) { @($projectsVal) } else { @() }
    foreach ($p in $projects) {
        if ([string](Get-JiraPlanPropSafe $p 'key') -eq $ProjectKey) {
            $v = Get-JiraPlanPropSafe $p 'phase_status_map'
            if ($null -ne $v) { return (ConvertTo-JiraJsonValue $v) }
        }
    }
    return '{}'
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
      The DISTINCT statuses a phase->status map resolves to, IN THE FIXED
      CANONICAL LIFECYCLE-EVENT ORDER (extension.yml's own hook list) —
      deliberately NOT Get-JiraPhaseStatusTargetSet, whose own tested
      contract accepts arbitrary phase names and therefore returns them
      SORTED, not chronologically (Import-JiraConfig's merge also sorts the
      map's own keys, so declaration order can never be recovered from the
      map alone). Reconcile's phase names ARE the fixed lifecycle events, so
      this local helper can use that closed vocabulary to restore the true
      chronological order drift's ahead/behind comparison depends on
      (Phase 6, US4, research R9). Mirror of _reconcile_phase_order.
    #>
    [CmdletBinding()]
    param([string] $PhaseStatusMapJson = '{}')
    $pm = $PhaseStatusMapJson | ConvertFrom-Json -Depth 100
    $canonicalOrder = @('before_specify', 'after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')
    $distinct = [System.Collections.Generic.List[string]]::new()
    foreach ($phaseEvent in $canonicalOrder) {
        if ($pm -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $member = $pm.PSObject.Properties[$phaseEvent]
        if ($null -eq $member) { continue }
        $v = [string]$member.Value
        if ([string]::IsNullOrEmpty($v)) { continue }
        if (-not $distinct.Contains($v)) { $distinct.Add($v) }
    }
    return (ConvertTo-JiraJsonValue $distinct)
}

function Get-JiraReconcileFieldDefaultNote {
    <#
    .SYNOPSIS
      011, contract §4.1/§4.2: mirror of _reconcile_field_default_notes. For
      every field this run actually sent that came from a recorded default or
      a this-run answer (never a bridge-supplied field), one provenance line
      naming the field, the value, and its source; for an `operator-answer`
      source, one further line with the `/speckit.jira.config --field-default
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
        $lines.Add("config: project ${ProjectKey}: make this override permanent — /speckit.jira.config $ProjectKey --field-default '$ProjectKey=$typeName=$label=$($e.value)'")
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
        [string] $FieldValues = ''
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
    $fieldDefaultsJson = (Get-JiraPlanResolveFieldDefault -IssueTypesJson $fdItypesJson -DefaultableFieldsByTypeJson $fdDfJson `
            -RecordedJson $fdRecordedJson -AnswersJson $fdAnswersJson | ConvertFrom-Json -Depth 100).field_defaults

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
    if ($boundVal) {
        foreach ($p in $boundVal.PSObject.Properties) {
            $tickets[$p.Name] = [string](Get-JiraPlanPropSafe $p.Value 'key')
            # Populated ONLY for a non-bridge origin (FR-038): a "bridge"
            # origin means plan_writes owns the whole description (the US3
            # behaviour, unchanged) — the same meaning an absent map entry
            # has always had.
            $originVal = [string](Get-JiraPlanPropSafe $p.Value 'origin')
            if ($originVal -ne 'bridge') { $ticketOrigins[$p.Name] = $originVal }
            $current = Get-JiraPlanPropSafe $p.Value 'current'
            $ticketDescriptions[$p.Name] = Get-JiraPlanPropSafe $current 'description'
            $currentParent = Get-JiraPlanPropSafe $current 'parent'
            if ($null -ne $currentParent) { $ticketParents[$p.Name] = [string]$currentParent }
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
    if (@($fieldDefaultsJson.PSObject.Properties).Count -gt 0) { $result['field_defaults'] = $fieldDefaultsJson }
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
    $onDrift = if ($state.ContainsKey('on_drift') -and $state['on_drift']) { $state['on_drift'] } else { 'abort' }
    $fieldValues = if ($state.ContainsKey('field_values')) { $state['field_values'] } else { '' }
    $acceptDefaults = $state['accept_defaults'] -eq 'true'

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
    if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path -LiteralPath $specFile)) {
        return (Get-JiraReconcileFaultCode -Code ([int](Get-JiraExitCode 'usage')) -Message 'reconcile: a readable spec file argument is required')
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
            'To bind it, run /speckit.jira.config.')
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
            "Jira mirror skipped: the bridge entry point $bridgeMissing was not found; the extension install is incomplete. This spec-kit command completed normally and nothing was mirrored to Jira. Restore it with: specify extension add --dev <path-to-spec-kit-jira> --force")
        return 0
    }

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
                'To bind it, run /speckit.jira.config.')
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
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: the project is still set to the shipped placeholder `"$projectKey`" — run /speckit.jira.config to bind a real project (zero writes)")
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

    # Phase 6, US4: the phase->status map and halted-status list this run's
    # lifecycle-safety rules resolve against — declared per project, exactly
    # like priority_map (FR-006). Absent a declaration both default to empty.
    $phaseStatusMap = Get-JiraReconcilePhaseStatusMap -ProjectKey $projectKey -ConfigJson $cfg
    $haltedStatuses = Get-JiraReconcileHaltedStatuses -ProjectKey $projectKey -ConfigJson $cfg

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
    $gateBindingResult = Get-JiraReconcileLocalBindingFor -ProjectKey $projectKey -ConfigDir $cfgDir
    if ($gateBindingResult.ExitCode -eq 0) {
        $gateBinding = $gateBindingResult.Json | ConvertFrom-Json -Depth 100
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

    # SINK: the plan context (US2, FR-007–FR-011; Phase 3, US1: tickets/
    # ticket_origins/ticket_descriptions now come from recognition's `bound`
    # map). An explicit SPEC_KIT_JIRA_PLAN_CONTEXT overrides the derived
    # object wholesale; otherwise it is built from the resolved project's
    # persisted binding.
    $planCtxResult = Get-JiraReconcilePlanContextFromBinding -BaseUrl $base -ProjectKey $projectKey -ConfigDir $cfgDir -ConfigJson $cfg -RecognitionJson $recogJson -FieldValues $fieldValues
    if ($planCtxResult.ExitCode -eq 2) {
        Write-JiraReconcileNotice -Lines @(
            'Jira mirror skipped: this repository is not bound to a Jira project yet.',
            'Nothing was mirrored, and this spec-kit command completed normally.',
            'To bind it, run /speckit.jira.config.')
        return 0
    }
    elseif ($planCtxResult.ExitCode -eq 3) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: the project `"$projectKey`" has not been bound yet — run /speckit.jira.config to discover its issue types and priorities (zero writes)")
    }
    elseif ($planCtxResult.ExitCode -eq 6) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: the local binding for $projectKey predates parent support and does not record issue-type hierarchy. The project is bound — its binding is simply a version behind. Run /speckit.jira.config to refresh it (zero writes)")
    }
    elseif ($planCtxResult.ExitCode -eq 7) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message "reconcile: project $projectKey has no recorded issue type for user stories. Run /speckit.jira.config to record it (zero writes)")
    }
    elseif ($planCtxResult.ExitCode -eq $script:ReconcileExitConfig) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the local Jira binding could not be read (zero writes)')
    }
    $planCtx = $planCtxResult.Json

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
        $planCtx = ConvertTo-JiraJsonValue $planCtxMap
    }

    try { $planJson = Get-JiraPlanWriteSet -NeutralDocJson $docForWriteJson -PlanContextJson $planCtx }
    catch {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the write plan could not be assembled (zero writes)')
    }
    $planObj = $planJson | ConvertFrom-Json -Depth 100
    $parentAction = Get-JiraPlanPropSafe $planObj 'parent'
    $actionsJson = ConvertTo-JiraJsonValue @(Get-JiraPlanPropSafe $planObj 'stories')

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
        # origin is omitted when "bridge": Get-JiraLifecyclePlan's own churn
        # check branches on origin exactly as Get-JiraPlanWriteSet does, and
        # a "bridge" value would wrongly route a bridge-created ticket
        # through the human-origin managed-panel comparison, which always
        # reads "unchanged" for a description that never carried the panel
        # marker in the first place.
        # target/category (Phase 6, US4, research R9): target is the status
        # the CURRENT lifecycle event maps to, via the routed project's
        # phase_status_map — empty when this run has no hook event or the
        # event has no declared mapping (R9's inert fallback). category
        # classifies each recognised ticket's OWN status the same way
        # config_classify_statuses seeds it: mapped (a declared phase
        # target) overrides an operator-designated halted state, which
        # overrides Jira's own "done" statusCategory (post-scope), else
        # unknown.
        $phaseMapObj = $phaseStatusMap | ConvertFrom-Json -Depth 100
        $mappedTargets = @()
        if ($phaseMapObj -is [System.Management.Automation.PSCustomObject]) {
            $mappedTargets = @($phaseMapObj.PSObject.Properties | ForEach-Object { [string]$_.Value })
        }
        $order = @(Get-JiraReconcilePhaseOrder -PhaseStatusMapJson $phaseStatusMap | ConvertFrom-Json -Depth 100)
        $target = ''
        if ($phaseMapObj -is [System.Management.Automation.PSCustomObject] -and -not [string]::IsNullOrEmpty($hookEvent)) {
            $target = [string](Get-JiraPlanPropSafe $phaseMapObj $hookEvent)
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
                    flagged  = Get-JiraPlanPropSafe $p.Value 'flagged'
                    blockers = Get-JiraPlanPropSafe $p.Value 'blockers'
                }
                $originVal2 = [string](Get-JiraPlanPropSafe $p.Value 'origin')
                if ($originVal2 -ne 'bridge') { $entry['origin'] = $originVal2 }
                $lcTickets[$p.Name] = $entry
            }
        }
        $lcJson = ConvertTo-JiraJsonValue ([ordered]@{ base_url = $base; on_drift = $onDrift; order = $order; tickets = $lcTickets })
    }
    try { $lresult = Get-JiraLifecyclePlan -ContentActionsJson $actionsJson -NeutralDocJson $docForWriteJson -LifecycleContextJson $lcJson | ConvertFrom-Json -Depth 100 }
    catch {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the lifecycle plan could not be assembled (zero writes)')
    }
    $actionsJson = ConvertTo-JiraJsonValue $lresult.actions
    $warnsJson = ConvertTo-JiraJsonValue $lresult.warnings
    $notesJson = ConvertTo-JiraJsonValue $lresult.notes

    # Every blocked story produces exactly one warning from the diagnostics
    # catalogue (FR-011, FR-016, FR-021) — folded into the same channel the
    # lifecycle rules use.
    $warnsList = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($warnsJson | ConvertFrom-Json -Depth 100)) { $warnsList.Add([string]$w) }
    foreach ($b in @($recog.blocked)) { $warnsList.Add([string]$b.detail) }
    $warnsJson = ConvertTo-JiraJsonValue $warnsList

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
    $warnCount = @($warnsJson | ConvertFrom-Json -Depth 100).Count
    $recognisedCount = @($recog.bound.PSObject.Properties).Count
    $skippedCount = $recognisedCount - $updated
    if ($skippedCount -lt 0) { $skippedCount = 0 }
    $hasLifecycle = $hasOverrideLifecycle
    if ($warnCount -gt 0) { $hasLifecycle = $true }

    # The consolidated question (Phase 4, US2, T066/T068; contract §3.3/
    # §3.4; data-model.md §4): fired only now that recognition and planning
    # show whether a creation is actually pending (FR-013) — $fdAskPending
    # above was merely a STRUCTURAL candidate, computed before recognition
    # ran. Scoped to the types that actually have a creation pending THIS
    # run (never a type the project merely offers — FR-028). Zero writes on
    # this path: neither the marker file (deferred above) nor any Jira call
    # has happened yet.
    if ($fdAskPending -and $created -gt 0) {
        $fdPendingTypes = [System.Collections.Generic.List[string]]::new()
        foreach ($x in $actions) {
            if ($x.method -eq 'POST' -and ([string]$x.url).EndsWith('/issue')) {
                $fdPendingTypes.Add([string]$x.body.fields.issuetype.id)
            }
        }
        if ($null -ne $parentAction -and $parentAction.method -eq 'POST') {
            $fdPendingTypes.Add([string]$parentAction.body.fields.issuetype.id)
        }
        $fdPendingTypesJson = ConvertTo-JiraJsonValue (@($fdPendingTypes | Select-Object -Unique))
        $fdFieldsJson = Get-JiraPlanConfirmationField -IssueTypesJson $fdItypesJson -DefaultableFieldsByTypeJson $fdDfJson `
            -FieldDefaultsByTypeJson $fdDefaultsByTypeJson -PendingTypeIdsJson $fdPendingTypesJson
        $fdFields = @($fdFieldsJson | ConvertFrom-Json -Depth 100)
        if ($fdFields.Count -gt 0) {
            $fdConfirmation = [ordered]@{
                status            = 'confirmation-pending'
                project           = $projectKey
                fields            = $fdFields
                creations_pending = $created
                resume_with       = "/speckit.jira.reconcile $specFile --accept-defaults"
            }
            $fdConfirmationJson = ConvertTo-JiraJsonValue $fdConfirmation
            # `Out.Write` with an explicit "`n", never `Out.WriteLine`: the
            # latter terminates with Environment.NewLine, which is CRLF on
            # Windows, while the Bash twin writes a bare LF on every host —
            # a divergence in the terminator alone, invisible on macOS and
            # Linux (docs/10-windows-portability.md quirk 8). This is the
            # convention the summary writer below already follows.
            if ($json) {
                [Console]::Out.Write($fdConfirmationJson + "`n")
            }
            else {
                $fdLabels = ($fdFields | ForEach-Object { [string]$_.label }) -join ', '
                [Console]::Out.Write("Jira mirror paused: confirm $fdLabels before $created creation(s) are written.`n")
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

    $rc = 0
    if (-not $dryRun) {
        # R5 steps 4/6, contract steps 8-11: Invoke-JiraApplyWriteSetWithRecognition
        # performs the parent first, marks every planned creation `creating`
        # before the first create, and stamps + records each created
        # ticket's key IMMEDIATELY, per ticket.
        $applyPlanJson = ConvertTo-JiraJsonValue ([ordered]@{ parent = $parentAction; stories = @($actionsJson | ConvertFrom-Json -Depth 100) })
        $knownParentKey = if ($parentState -eq 'bound') { [string]$recogParent.key } else { '' }
        $rc = Invoke-JiraApplyWriteSetWithRecognition -PlanJson $applyPlanJson -SpecRefJson $specRefJson -SpecFile $specFile -KnownParentKey $knownParentKey -DefaultableFieldsByTypeJson $fdDfJson
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
        [Console]::Error.WriteLine("WARNING: Jira mirror not completed — $cause (exit $rc). This spec-kit command completed normally. Run /speckit.jira.config to re-check the binding.")
        $rc = 0
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
    $fdNoteLines = @(Get-JiraReconcileFieldDefaultNote -ProjectKey $projectKey -IssueTypesJson $fdItypesJson `
            -DefaultableFieldsByTypeJson $fdDfJson -ResolvedJson $gateResolvedJsonForNotes `
            -ActionsJson (ConvertTo-JiraJsonValue $actions) -ParentActionJson (ConvertTo-JiraJsonValue $parentAction) `
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
    # is never part of the published action shape.
    # The reported action list stays FLAT (T080a): the parent — when
    # present — is reported first, exactly like any other action,
    # host-relative and stripped of its internal local_id bookkeeping.
    $disp = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $parentAction) {
        $u = [string]$parentAction.url
        if ($u.StartsWith($base)) { $parentAction.url = $u.Substring($base.Length) }
        $copy = [ordered]@{}
        foreach ($p in $parentAction.PSObject.Properties) { if ($p.Name -ne 'local_id') { $copy[$p.Name] = $p.Value } }
        $disp.Add($copy)
    }
    foreach ($x in $actions) {
        $u = [string]$x.url
        if ($u.StartsWith($base)) { $x.url = $u.Substring($base.Length) }
        $copy = [ordered]@{}
        foreach ($p in $x.PSObject.Properties) { if ($p.Name -ne 'local_id') { $copy[$p.Name] = $p.Value } }
        $disp.Add($copy)
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
    if ($hasLifecycle) {
        $summaryObj['warnings'] = @($warnsJson | ConvertFrom-Json -Depth 100)
        $summaryObj['notes'] = @($notesJson | ConvertFrom-Json -Depth 100)
    }
    $summaryObj['hook_health'] = $hooksHealth
    $summaryObj['exit_code'] = $rc
    $summary = ConvertTo-JiraJsonValue $summaryObj

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
