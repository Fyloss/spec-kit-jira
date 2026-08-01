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
Import-Module (Join-Path $PSScriptRoot '../../engine/ManagedSection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivacyGuard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Ticket.psm1') -Force # Get-JiraCreateFieldsBase — the shared creation-fields builder (research R3)
Import-Module (Join-Path $PSScriptRoot '../../engine/MarkerSplice.psm1') -Force # Write-JiraMarkerSpliceFile — a nested import inside StoryMarker.psm1 is not enough
Import-Module (Join-Path $PSScriptRoot '../../engine/StoryMarker.psm1') -Force -Global # R5 steps 4/6 — mark `creating`, stamp + record per ticket
Import-Module (Join-Path $PSScriptRoot '../../engine/SpecMarker.psm1') -Force # the parent marker's same splice (Phase 5, US2)
Import-Module (Join-Path $PSScriptRoot 'Identity.psm1') -Force # stamp the identity marker on each created ticket (R5 step 6)

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
      Resolve the validated neutral document into an ordered write plan. Mirror of
      plan_writes (US3, T058; Phase 5, US2, T072, R7). Each story becomes a create
      OR an update, priority resolved by logical name (FR-017), estimation written
      on CREATE ONLY (FR-018). No Jira mutation happens here.

      Returns {parent, stories} (data-model.md §6): `parent` is $null when a
      recognised parent's bridge-owned content already matches (zero churn); a PUT
      when it differs; a POST — carrying local_id and role:"parent" — when no
      parent is yet recognised. Every STORY creation carries the literal
      placeholder fields.parent.key = "<resolved at apply time>", resolved by
      Invoke-JiraApplyWriteSetWithRecognition once the parent's real key is known.
      An update never re-touches the parent link.
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
    # The payload's project comes from the neutral document's validated
    # routing.project_key — never from the plan context — so it cannot
    # disagree with the run summary's resolved project (research R2, FR-023).
    $project = [string](Get-JiraPlanProp (Get-JiraPlanProp $doc 'routing') 'project_key')

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

        if ($ticket -eq '') {
            # FR-024 assembly guard: refuse an incomplete creation BEFORE it is
            # ever emitted, rather than sending it for the destination service
            # to reject.
            if ($project -eq '' -or $storyType -eq '') {
                throw "plan_writes: refusing to assemble a creation for `"$sid`" with no project or issue type (zero writes)"
            }
            # CREATE: the shared mandatory base (research R3, FR-025) + the
            # optional attributes + the parent-key placeholder (T072/T073),
            # resolved once the parent's create response is read. A
            # bridge-created ticket owns its whole description (no delimiter,
            # FR-040).
            $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $title -IssueTypeId $storyType | ConvertFrom-Json
            $fields = [ordered]@{}
            foreach ($p in $baseFields.PSObject.Properties) { $fields[$p.Name] = $p.Value }
            $fields['description'] = $adf
            $fields['parent'] = [ordered]@{ key = '<resolved at apply time>' }
            if ($priorityId -ne '') { $fields['priority'] = [ordered]@{ id = $priorityId } }
            $estValue = Get-JiraPlanProp $story 'estimation'
            if ($estId -ne '' -and $null -ne $estValue) { $fields[$estId] = $estValue }
            $actions.Add([ordered]@{ method = 'POST'; url = "$base/rest/api/3/issue"; body = [ordered]@{ fields = $fields }; local_id = $sid; role = 'story' })
        }
        else {
            # UPDATE: content + priority; no project or issuetype is required
            # (an update targets an existing item by key), and the parent link
            # is never re-touched (it was set at creation). On a human-origin
            # ticket the description is spliced into the managed panel so the
            # human prose above survives (FR-038).
            $fields = [ordered]@{ summary = $title; description = $adf }
            $origins = Get-JiraPlanProp $ctx 'ticket_origins'
            $origin = [string](Get-JiraPlanProp $origins $sid)
            if ($origin -ne '' -and $origin -ne 'bridge-created') {
                $descs = Get-JiraPlanProp $ctx 'ticket_descriptions'
                $existing = Get-JiraPlanProp $descs $sid
                $existingJson = if ($null -eq $existing) { '{}' } else { ConvertTo-JiraJsonValue $existing }
                $adf = ConvertTo-JiraManagedAdfDocument -ContentJson $storyJson -Origin $origin -ExistingJson $existingJson | ConvertFrom-Json -Depth 100
                $fields['description'] = $adf
            }
            if ($priorityId -ne '') { $fields['priority'] = [ordered]@{ id = $priorityId } }
            $actions.Add([ordered]@{ method = 'PUT'; url = "$base/rest/api/3/issue/$ticket"; body = [ordered]@{ fields = $fields }; role = 'story' })
        }
    }

    $parent = Get-JiraPlanWriteSetParent -DocObject $doc -CtxObject $ctx -Base $base
    return (ConvertTo-JiraJsonValue ([ordered]@{ parent = $parent; stories = $actions }))
}

function Get-JiraPlanWriteSetParent {
    <#
    .SYNOPSIS
      The parent half of Get-JiraPlanWriteSet's return shape (Phase 5, US2,
      T072/T076). Mirror of _plan_writes_parent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $DocObject, [Parameter(Mandatory)] $CtxObject, [Parameter(Mandatory)] [string] $Base)
    $doc = $DocObject
    $ctx = $CtxObject
    $parentType = [string](Get-JiraPlanProp $ctx 'parent_type_id')
    $project = [string](Get-JiraPlanProp (Get-JiraPlanProp $doc 'routing') 'project_key')
    $epic = Get-JiraPlanProp $doc 'epic'
    $epicTitle = [string](Get-JiraPlanProp $epic 'title')
    $epicLocalId = [string](Get-JiraPlanProp $epic 'local_id')
    $epicJson = ConvertTo-JiraJsonValue $epic

    $epicAdf = ConvertTo-JiraAdfDocument -ContentJson $epicJson | ConvertFrom-Json -Depth 100

    $parentKey = [string](Get-JiraPlanProp $ctx 'parent_key')

    if ($parentKey -eq '') {
        # CREATE: no parent recognised yet.
        $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $epicTitle -IssueTypeId $parentType | ConvertFrom-Json
        $fields = [ordered]@{}
        foreach ($p in $baseFields.PSObject.Properties) { $fields[$p.Name] = $p.Value }
        $fields['description'] = $epicAdf
        return [ordered]@{ method = 'POST'; url = "$Base/rest/api/3/issue"; body = [ordered]@{ fields = $fields }; local_id = $epicLocalId; role = 'parent' }
    }

    # A recognised parent: compare its bridge-owned content before planning a
    # write (T076) — a human-origin parent's description is rendered through
    # the SAME managed-panel splice a human-origin story uses (FR-039's
    # rule, extended to the parent), so its prose above the panel survives,
    # and is then compared on its managed section alone.
    $current = Get-JiraPlanProp $ctx 'parent_current'
    $origin = [string](Get-JiraPlanProp $ctx 'parent_origin')

    if ($origin -ne '' -and $origin -ne 'bridge') {
        $existing = Get-JiraPlanProp $current 'description'
        $existingJson = if ($null -eq $existing) { '{}' } else { ConvertTo-JiraJsonValue $existing }
        $epicAdf = ConvertTo-JiraManagedAdfDocument -ContentJson $epicJson -Origin $origin -ExistingJson $existingJson | ConvertFrom-Json -Depth 100
    }
    $desiredFields = [ordered]@{ summary = $epicTitle; description = $epicAdf }

    if ($null -eq $current) {
        $status = 'changed'
    }
    elseif ($origin -ne '' -and $origin -ne 'bridge') {
        $curDesc = Get-JiraPlanProp $current 'description'; if ($null -eq $curDesc) { $curDesc = [ordered]@{} }
        $newDesc = $desiredFields['description']
        $descSt = Get-JiraManagedDescriptionStatus -CurrentDescJson (ConvertTo-JiraJsonValue $curDesc) -NewDescJson (ConvertTo-JiraJsonValue $newDesc)
        $curRest = [ordered]@{}; foreach ($p in $current.PSObject.Properties) { if ($p.Name -ne 'description') { $curRest[$p.Name] = $p.Value } }
        $desRest = [ordered]@{}; foreach ($k in $desiredFields.Keys) { if ($k -ne 'description') { $desRest[$k] = $desiredFields[$k] } }
        $otherSt = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $curRest) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desRest)
        $status = if ($descSt -eq 'unchanged' -and $otherSt -eq 'unchanged') { 'unchanged' } else { 'changed' }
    }
    else {
        $status = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $current) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desiredFields)
    }

    if ($status -eq 'unchanged') { return $null }
    return [ordered]@{ method = 'PUT'; url = "$Base/rest/api/3/issue/$parentKey"; body = [ordered]@{ fields = $desiredFields }; role = 'parent' }
}

function Get-JiraManagedDescriptionStatus {
    <#
    .SYNOPSIS
      FR-039: decide description churn on the managed section alone. Both
      descriptions are split at the panel marker and only their managed portions are
      compared. Mirror of plan_managed_description_status. Returns 'unchanged' |
      'changed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CurrentDescJson,
        [Parameter(Mandatory)] [string] $NewDescJson
    )
    $marker = Get-JiraManagedMarker
    $cur = $CurrentDescJson | ConvertFrom-Json -Depth 100
    $new = $NewDescJson | ConvertFrom-Json -Depth 100
    $curContent = Get-JiraPlanProp $cur 'content'; if ($null -eq $curContent) { $curContent = @() }
    $newContent = Get-JiraPlanProp $new 'content'; if ($null -eq $newContent) { $newContent = @() }
    $cm = (Split-JiraManagedSectionPanel -Marker $marker -ContentJson (ConvertTo-JiraJsonValue @($curContent)) | ConvertFrom-Json).managed
    $nm = (Split-JiraManagedSectionPanel -Marker $marker -ContentJson (ConvertTo-JiraJsonValue @($newContent)) | ConvertFrom-Json).managed
    $cmJson = ConvertTo-JiraJsonValue @($cm)
    $nmJson = ConvertTo-JiraJsonValue @($nm)
    if ([System.String]::Equals($cmJson, $nmJson, [System.StringComparison]::Ordinal)) { return 'unchanged' }
    return 'changed'
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
                $origin = [string](Get-JiraPlanProp $tk 'origin')
                if ($origin -ne '' -and $origin -ne 'bridge-created') {
                    # FR-039: description diff on the managed section alone; the
                    # other fields compare normally.
                    $curDesc = Get-JiraPlanProp $current 'description'; if ($null -eq $curDesc) { $curDesc = [pscustomobject]@{} }
                    $desObj = $action.body.fields
                    $newDesc = Get-JiraPlanProp $desObj 'description'; if ($null -eq $newDesc) { $newDesc = [pscustomobject]@{} }
                    $descSt = Get-JiraManagedDescriptionStatus -CurrentDescJson (ConvertTo-JiraJsonValue $curDesc) -NewDescJson (ConvertTo-JiraJsonValue $newDesc)
                    $curRest = [ordered]@{}; foreach ($p in $current.PSObject.Properties) { if ($p.Name -ne 'description') { $curRest[$p.Name] = $p.Value } }
                    $desRest = [ordered]@{}; foreach ($p in $desObj.PSObject.Properties) { if ($p.Name -ne 'description') { $desRest[$p.Name] = $p.Value } }
                    $otherSt = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $curRest) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desRest)
                    if ($descSt -eq 'unchanged' -and $otherSt -eq 'unchanged') { $dropContent = $true }
                }
                elseif ((Get-JiraIdempotentFieldStatus -CurrentFieldsJson $currentJson -DesiredFieldsJson $desired) -eq 'unchanged') {
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
    # De-duplicate + sort ORDINALLY and case-sensitively, matching jq `unique`
    # (Sort-Object -Unique would COLLAPSE case-variant coordinates, dropping them
    # from the BLOCK set), and serialise through the canonical serialiser.
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in @($ExtraJson | ConvertFrom-Json -Depth 100)) { [void]$set.Add([string]$e) }
    if (-not [string]::IsNullOrEmpty($host0)) { [void]$set.Add($host0) }
    return (ConvertTo-JiraJsonValue @($set))
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
    # The allowlist (US12, FR-053) neutralises allowlisted Confluence links/domains so
    # they never false-block; empty unless the caller supplies one out of band.
    $allow = if ($env:SPEC_KIT_JIRA_ALLOWLIST) { $env:SPEC_KIT_JIRA_ALLOWLIST } else { '[]' }
    $actions = @($ActionsJson | ConvertFrom-Json -Depth 100)

    # (1) Pre-write gate — scan every content payload before writing anything.
    foreach ($a in $actions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload $bodyText -KnownCoordinatesJson $coords -AllowlistJson $allow
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

function Invoke-JiraApplyWriteSetWithRecognition {
    <#
    .SYNOPSIS
      Mirror of apply_writes_with_recognition. Guards every payload (US11,
      unchanged), then adds R5 steps 4 and 6, and Phase 5/US2's parent-first
      ordering (contracts/parent-marker.md "Ordering within one run", steps
      8-11). $PlanJson is Get-JiraPlanWriteSet's {parent, stories} shape.

      The parent (when present) is performed FIRST; its response key is
      read before any story is written, and every story creation's
      fields.parent.key placeholder ("<resolved at apply time>") is
      resolved to that key — the just-created key, or $KnownParentKey (the
      plan context's already-known parent_key) when the parent was
      unchanged or updated rather than created. Every story whose action is
      a creation is marked `creating` in $SpecFile, in the SAME splice that
      marks the parent `creating` (step 9); then, for each ticket actually
      created (parent or story), its identity marker is stamped and its
      `creating` mark is replaced with the recorded key IN $SpecFile — per
      ticket, IMMEDIATELY, never batched (step 6/11).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PlanJson,
        [Parameter(Mandatory)] [string] $SpecRefJson,
        [Parameter(Mandatory)] [string] $SpecFile,
        [string] $KnownParentKey = '',
        [string] $ExtraKnownCoordinatesJson = '[]'
    )
    $coords = Get-JiraApplyKnownCoordinate -ExtraJson $ExtraKnownCoordinatesJson
    $allow = if ($env:SPEC_KIT_JIRA_ALLOWLIST) { $env:SPEC_KIT_JIRA_ALLOWLIST } else { '[]' }
    $plan = $PlanJson | ConvertFrom-Json -Depth 100
    $parent = Get-JiraPlanProp $plan 'parent'
    $stories = @()
    $storiesProp = Get-JiraPlanProp $plan 'stories'
    if ($null -ne $storiesProp) { $stories = @($storiesProp) }

    # (1) Pre-write gate — scan every payload, parent then stories, before
    # writing anything.
    if ($null -ne $parent) {
        $bodyObj = Get-JiraPlanProp $parent 'body'
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload $bodyText -KnownCoordinatesJson $coords -AllowlistJson $allow
        if ($code -ne 0) { return [int]$code }
    }
    foreach ($a in $stories) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload $bodyText -KnownCoordinatesJson $coords -AllowlistJson $allow
        if ($code -ne 0) { return [int]$code }
    }

    # (2) R5 step 4 / contract step 9 — mark the parent (when it is a
    # creation) and every planned story creation `creating`, in ONE splice.
    $current = if (Test-Path -LiteralPath $SpecFile) { Get-Content -Raw -LiteralPath $SpecFile } else { '' }
    if ($null -eq $current) { $current = '' }
    $newContent = $current
    $parentLocalId = ''
    if ($null -ne $parent -and $parent.method -eq 'POST') {
        $parentLocalId = [string](Get-JiraPlanProp $parent 'local_id')
        if ($parentLocalId -ne '') {
            $newContent = Set-JiraSpecMarkerMarkCreating -Text $newContent -Id $parentLocalId
        }
    }
    $creatingIds = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $stories) {
        $lid = [string](Get-JiraPlanProp $a 'local_id')
        if ($a.method -eq 'POST' -and ([string]$a.url).EndsWith('/issue') -and $lid -ne '') { $creatingIds.Add($lid) }
    }
    if ($creatingIds.Count -gt 0) {
        $newContent = Set-JiraStoryMarkerMarkCreating -Text $newContent -IdsJson (ConvertTo-JiraJsonValue $creatingIds)
    }
    if ($newContent -ne $current) {
        Write-JiraMarkerSpliceFile -Path $SpecFile -NewContent $newContent | Out-Null
    }

    # (3) Write pass — the parent FIRST (step 10): its response key is read
    # before the first story action is scanned for writing.
    $worst = 0
    $parentKey = $KnownParentKey
    if ($null -ne $parent) {
        $bodyObj = Get-JiraPlanProp $parent 'body'
        if ($null -ne $bodyObj) {
            $bodyText = ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100
            $r = Invoke-JiraRequest -Method $parent.method -Url $parent.url -Body $bodyText
        }
        else {
            $r = Invoke-JiraRequest -Method $parent.method -Url $parent.url
        }
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) { return $worst }
        if ($parent.method -eq 'POST') {
            $respObj = $null
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { }
            $parentKey = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            if ($parentKey -ne '' -and $parentLocalId -ne '') {
                Set-JiraIdentity -IssueKey $parentKey -SpecRefJson $SpecRefJson -Origin 'bridge' -Role 'parent' | Out-Null
                $cur = if (Test-Path -LiteralPath $SpecFile) { Get-Content -Raw -LiteralPath $SpecFile } else { '' }
                if ($null -eq $cur) { $cur = '' }
                $new = Set-JiraSpecMarkerRecordTicket -Text $cur -Id $parentLocalId -Key $parentKey
                Write-JiraMarkerSpliceFile -Path $SpecFile -NewContent $new | Out-Null
            }
        }
    }

    # (4) Story writes (step 11) — the parent-key placeholder resolved to
    # the key just created, or the already-known parent_key when the
    # parent was recognised (unchanged or updated) rather than created.
    foreach ($a in $stories) {
        $action = $a
        if ($parentKey -ne '') {
            $fields = Get-JiraPlanProp (Get-JiraPlanProp $action 'body') 'fields'
            $parentField = Get-JiraPlanProp $fields 'parent'
            if ($null -ne $parentField -and [string](Get-JiraPlanProp $parentField 'key') -eq '<resolved at apply time>') {
                $parentField.key = $parentKey
            }
        }
        $bodyObj = if ($action.PSObject.Properties.Name -contains 'body') { $action.body } else { $null }
        if ($null -ne $bodyObj) {
            $bodyText = ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100
            $r = Invoke-JiraRequest -Method $action.method -Url $action.url -Body $bodyText
        }
        else {
            $r = Invoke-JiraRequest -Method $action.method -Url $action.url
        }
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) { return $worst }

        if ($action.method -eq 'POST' -and ([string]$action.url).EndsWith('/issue')) {
            $respObj = $null
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { }
            $key = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            $localId = [string](Get-JiraPlanProp $action 'local_id')
            if ($key -ne '' -and $localId -ne '') {
                Set-JiraIdentity -IssueKey $key -SpecRefJson $SpecRefJson -Origin 'bridge' -Story $localId -Role 'story' | Out-Null
                $cur = if (Test-Path -LiteralPath $SpecFile) { Get-Content -Raw -LiteralPath $SpecFile } else { '' }
                if ($null -eq $cur) { $cur = '' }
                $new = Set-JiraStoryMarkerRecordTicket -Text $cur -Id $localId -Key $key
                Write-JiraMarkerSpliceFile -Path $SpecFile -NewContent $new | Out-Null
            }
        }
    }
    return $worst
}

Export-ModuleMember -Function Get-JiraApplyKnownCoordinate, Invoke-JiraApplyWriteSet, Get-JiraPlanWriteSet, Get-JiraLifecyclePlan, `
    Get-JiraManagedDescriptionStatus, Invoke-JiraApplyWriteSetWithRecognition
