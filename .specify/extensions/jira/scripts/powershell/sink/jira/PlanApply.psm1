# sink/jira/PlanApply.psm1 — The Jira write path. Mirror of plan_apply.sh.
#
# Invoke-JiraApplyWriteSet executes an ordered action set against Jira. Its FIRST
# responsibility (US11, T049) is the mandatory pre-write privacy gate: every
# action's content payload is scanned through the BLOCK guard BEFORE any write is
# performed. A single blocked payload aborts the whole apply with exit 9 and ZERO
# writes — no gap through which a leak could reach Jira (Constitution IV, FR-052).
#
# US3 (T058) fleshes out the richer action set; this module owns the invariant
# guard-then-write ordering. Only the content `body` is scanned (the URL targets
# the real host and is not content).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Adf.psm1') -Force
# The sink may consume the neutral engine (the boundary only forbids engine->sink).
Import-Module (Join-Path $PSScriptRoot '../../engine/Drift.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../engine/Idempotency.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivacyGuard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force

function Get-JiraPlanProp {
    # Safe property read: an EMPTY PSCustomObject's `.PSObject.Properties.Name`
    # throws under StrictMode, so index the member collection instead.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    return $member.Value
}

function Get-JiraPlanWriteSet {
    <#
    .SYNOPSIS
      Resolve the validated neutral document into an ordered action set. Mirror of
      plan_writes (US3, T058). Each story becomes a create OR an update, priority
      resolved by logical name (FR-017), estimation written on CREATE ONLY
      (FR-018). No Jira mutation happens here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $NeutralDocJson, [Parameter(Mandatory)] [string] $PlanContextJson)
    $doc = $NeutralDocJson | ConvertFrom-Json -Depth 100
    $ctx = $PlanContextJson | ConvertFrom-Json -Depth 100

    $base = [string](Get-JiraPlanProp $ctx 'base_url')
    $storyType = [string](Get-JiraPlanProp $ctx 'story_type_id')
    $estId = [string](Get-JiraPlanProp $ctx 'estimation_field_id')
    $tickets = Get-JiraPlanProp $ctx 'tickets'
    $priorityIds = Get-JiraPlanProp $ctx 'priority_ids'

    $stories = @()
    $storyProp = Get-JiraPlanProp $doc 'stories'
    if ($null -ne $storyProp) { $stories = @($storyProp) }

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($story in $stories) {
        $sid = [string]$story.local_id
        $title = [string]$story.title
        $prio = [string]$story.priority_logical

        $ticket = [string](Get-JiraPlanProp $tickets $sid)
        $priorityId = [string](Get-JiraPlanProp $priorityIds $prio)

        # The story object already carries description / acceptance_criteria / design.
        $storyJson = ConvertTo-JiraJsonValue $story
        $adf = ConvertTo-JiraAdfDocument -ContentJson $storyJson | ConvertFrom-Json -Depth 100

        $fields = [ordered]@{ summary = $title; description = $adf }
        if ($ticket -eq '') {
            if ($storyType -ne '') { $fields['issuetype'] = [ordered]@{ id = $storyType } }
            if ($priorityId -ne '') { $fields['priority'] = [ordered]@{ id = $priorityId } }
            $estValue = Get-JiraPlanProp $story 'estimation'
            if ($estId -ne '' -and $null -ne $estValue) { $fields[$estId] = $estValue }
            $actions.Add([ordered]@{ method = 'POST'; url = "$base/rest/api/3/issue"; body = [ordered]@{ fields = $fields } })
        }
        else {
            if ($priorityId -ne '') { $fields['priority'] = [ordered]@{ id = $priorityId } }
            $actions.Add([ordered]@{ method = 'PUT'; url = "$base/rest/api/3/issue/$ticket"; body = [ordered]@{ fields = $fields } })
        }
    }
    return (ConvertTo-JiraJsonValue $actions)
}

function Get-JiraLifecyclePlan {
    <#
    .SYNOPSIS
      Fold the US6 lifecycle-safety rules over the planned content actions and emit
      the final action set plus warnings/notes. Mirror of plan_lifecycle. PURE: no
      Jira reads or writes. content-actions[i] corresponds to doc.stories[i]. See
      plan_apply.sh for the full contract (zero-churn FR-030, drift FR-031/034/035,
      Flagged FR-036, human links FR-037).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ContentActionsJson,
        [Parameter(Mandatory)] [string] $NeutralDocJson,
        [Parameter(Mandatory)] [string] $LifecycleContextJson
    )
    # Lists never unwrap to a scalar (a 1-element @() flowing through an if/else
    # expression collapses under StrictMode, and its .Count then throws).
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($ContentActionsJson | ConvertFrom-Json -Depth 100)) { $actions.Add($x) }
    $doc = $NeutralDocJson | ConvertFrom-Json -Depth 100
    $lc = $LifecycleContextJson | ConvertFrom-Json -Depth 100

    $onDrift = [string](Get-JiraPlanProp $lc 'on_drift'); if ($onDrift -eq '') { $onDrift = 'abort' }
    $base = [string](Get-JiraPlanProp $lc 'base_url')
    $order = [System.Collections.Generic.List[object]]::new()
    $orderVal = Get-JiraPlanProp $lc 'order'
    if ($null -ne $orderVal) { foreach ($o in @($orderVal)) { $order.Add([string]$o) } }
    $tickets = Get-JiraPlanProp $lc 'tickets'
    $stories = [System.Collections.Generic.List[object]]::new()
    $storyProp = Get-JiraPlanProp $doc 'stories'
    if ($null -ne $storyProp) { foreach ($s in @($storyProp)) { $stories.Add($s) } }

    $kept = [System.Collections.Generic.List[object]]::new()
    $warns = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $stories.Count; $i++) {
        if ($i -ge $actions.Count) { continue }
        $sid = [string]$stories[$i].local_id
        $action = $actions[$i]
        if ($null -eq $action) { continue }
        $method = [string]$action.method
        $tk = Get-JiraPlanProp $tickets $sid
        if ($null -eq $tk) { $tk = [pscustomobject]@{} }

        $dropContent = $false
        $doTransition = $false

        # --- Zero churn: drop an unchanged UPDATE -----------------------------
        if ($method -eq 'PUT') {
            $current = Get-JiraPlanProp $tk 'current'
            if ($null -ne $current) {
                $desired = ConvertTo-JiraJsonValue $action.body.fields
                $currentJson = ConvertTo-JiraJsonValue $current
                if ((Get-JiraIdempotentFieldStatus -CurrentFieldsJson $currentJson -DesiredFieldsJson $desired) -eq 'unchanged') {
                    $dropContent = $true
                }
            }
        }

        # --- Drift / Flagged: decide the transition ---------------------------
        $status = [string](Get-JiraPlanProp $tk 'status')
        $target = [string](Get-JiraPlanProp $tk 'target')
        $category = [string](Get-JiraPlanProp $tk 'category'); if ($category -eq '') { $category = 'unknown' }
        $flaggedVal = Get-JiraPlanProp $tk 'flagged'
        $flagged = ($flaggedVal -eq $true)
        $transitionId = [string](Get-JiraPlanProp $tk 'transition_id')
        $key = [string](Get-JiraPlanProp $tk 'key')

        if ($status -ne '' -and $target -ne '' -and $status -ne $target) {
            if ($flagged) {
                $warns.Add("ticket `"$sid`" carries the Flagged (impediment) marker; its transition is withheld and the flag is left untouched")
            }
            else {
                $di = [ordered]@{ current_status = $status; current_category = $category; target_status = $target; order = $order.ToArray(); on_drift = $onDrift } | ConvertTo-Json -Compress -Depth 10
                $dec = Get-JiraDriftDecision -InputJson $di | ConvertFrom-Json -Depth 100
                foreach ($w in @($dec.warnings)) { $warns.Add([string]$w) }
                if ($dec.content_writes -eq $false) { $dropContent = $true }
                if ([string]$dec.decision -eq 'transition') { $doTransition = $true }
            }
        }

        if (-not $dropContent) { $kept.Add($action) }

        if ($doTransition -and $transitionId -ne '' -and $key -ne '') {
            $kept.Add([ordered]@{ method = 'POST'; url = "$base/rest/api/3/issue/$key/transitions"; body = [ordered]@{ transition = [ordered]@{ id = $transitionId } } })
            $blockersVal = Get-JiraPlanProp $tk 'blockers'
            $blockers = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $blockersVal) { foreach ($b in @($blockersVal)) { $blockers.Add([string]$b) } }
            if ($blockers.Count -gt 0) {
                $blist = ($blockers -join ', ')
                $notes.Add("transition of `"$sid`" proceeds with open blocking links ($blist); human-created links are left unchanged")
            }
        }
    }

    $out = [ordered]@{ actions = $kept; warnings = $warns; notes = $notes }
    return (ConvertTo-JiraJsonValue $out)
}

function Get-JiraApplyKnownCoordinate {
    # The known-coordinate set: the real site host from SPEC_KIT_JIRA_BASE_URL plus
    # any caller extras. Mirror of _apply_known_coords.
    param([string] $ExtraJson = '[]')
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    $host0 = $base -replace '^[a-zA-Z]+://', '' -replace '/.*$', '' -replace ':[0-9]+$', ''
    $coords = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($ExtraJson | ConvertFrom-Json -Depth 100)) { $coords.Add([string]$e) }
    if (-not [string]::IsNullOrEmpty($host0)) { $coords.Add($host0) }
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($c in ($coords | Sort-Object -Unique)) { $unique.Add($c) }
    return (ConvertTo-Json -InputObject $unique.ToArray() -Compress -Depth 5)
}

function Invoke-JiraApplyWriteSet {
    <#
    .SYNOPSIS
      Guard every payload, then perform the writes in order. Returns exit 9 with
      zero writes if any payload is blocked; otherwise the worst (highest)
      transport exit code. Mirror of apply_writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ActionsJson,
        [string] $ExtraKnownCoordinatesJson = '[]'
    )
    $coords = Get-JiraApplyKnownCoordinate -ExtraJson $ExtraKnownCoordinatesJson
    $actions = @($ActionsJson | ConvertFrom-Json -Depth 100)

    # (1) Pre-write gate — scan every content payload before writing anything.
    foreach ($a in $actions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload $bodyText -KnownCoordinatesJson $coords
        if ($code -ne 0) { return [int]$code }
    }

    # (2) Write pass — all payloads cleared; perform each write in order. A
    # fail-closed transport result (exit >= 2) ABORTS the remaining writes for this
    # spec and is returned verbatim — no further mutation once a read/write is
    # unreliable (FR-032, monotonic escalation).
    $worst = 0
    foreach ($a in $actions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        if ($null -ne $bodyObj) {
            $bodyText = ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100
            $r = Invoke-JiraRequest -Method $a.method -Url $a.url -Body $bodyText
        }
        else {
            $r = Invoke-JiraRequest -Method $a.method -Url $a.url
        }
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) { return $worst }
    }
    return $worst
}

Export-ModuleMember -Function Get-JiraApplyKnownCoordinate, Invoke-JiraApplyWriteSet, Get-JiraPlanWriteSet, Get-JiraLifecyclePlan
