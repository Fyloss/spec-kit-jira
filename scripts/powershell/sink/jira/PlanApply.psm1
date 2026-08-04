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
Import-Module (Join-Path $PSScriptRoot '../../engine/TaskMarker.psm1') -Force -Global # Phase 3, US1 — the task tier's own marker grammar, same seam (bare -Force here strips a caller's -Global load — see StoryMarker.psm1's import above)
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

function Get-JiraPlanResolveFieldDefault {
    <#
    .SYNOPSIS
      011, research R2/R3, contract §3.1/§3.2, data-model.md §3: join the
      labels one project's field_defaults holds (and this run's
      --field-value answers) to the field ids the binding's
      defaultable_fields holds, for that project. Mirror of
      plan_resolve_field_defaults.

      IssueTypesJson: [{logical_name, id}, ...] — resolves a Type NAME to an
        issue-type id.
      DefaultableFieldsByTypeJson: {type_id: [{logical_name, field_id, ...}]}
        — resolves a Label to a field id, WITHIN the type its default was
        recorded for (FR-018).
      RecordedJson: the project's field_defaults entry — {ask, <Type>:
        {<Label>: <Value>}, ...}. The literal key `ask` is never mistaken
        for an issue-type name.
      AnswersJson: [{type, label, value}, ...] — this run's --field-value
        answers, already scoped to this project by the caller.

      Precedence (contract §3.1): an answer wins over the recorded default
      for the same (type, label). An unresolvable type name or field label
      is reported in Unresolved, never silently dropped.

      Returns one canonical object: {field_defaults; field_default_sources;
      unresolved}.
    #>
    [CmdletBinding()]
    param(
        [string] $IssueTypesJson = '[]',
        [string] $DefaultableFieldsByTypeJson = '{}',
        [string] $RecordedJson = '{}',
        [string] $AnswersJson = '[]'
    )
    if ([string]::IsNullOrEmpty($IssueTypesJson)) { $IssueTypesJson = '[]' }
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($RecordedJson)) { $RecordedJson = '{}' }
    if ([string]::IsNullOrEmpty($AnswersJson)) { $AnswersJson = '[]' }

    $itypes = @($IssueTypesJson | ConvertFrom-Json -Depth 100)
    $df = $DefaultableFieldsByTypeJson | ConvertFrom-Json -Depth 100
    $rec = $RecordedJson | ConvertFrom-Json -Depth 100
    $ans = @($AnswersJson | ConvertFrom-Json -Depth 100)

    function Resolve-TypeId([string] $Name) {
        foreach ($t in $itypes) { if ([string]$t.logical_name -eq $Name) { return [string]$t.id } }
        return $null
    }
    function Resolve-FieldId([string] $TypeId, [string] $Label) {
        $listProp = $df.PSObject.Properties[$TypeId]
        if ($null -eq $listProp) { return $null }
        foreach ($f in @($listProp.Value)) { if ([string]$f.logical_name -eq $Label) { return [string]$f.field_id } }
        return $null
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $rec.PSObject.Properties) {
        if ($p.Name -eq 'ask') { continue }
        foreach ($fp in $p.Value.PSObject.Properties) {
            $entries.Add([pscustomobject]@{ type = $p.Name; label = $fp.Name; value = $fp.Value; source = 'team-config' })
        }
    }
    foreach ($a in $ans) {
        $entries.Add([pscustomobject]@{ type = [string]$a.type; label = [string]$a.label; value = $a.value; source = 'operator-answer' })
    }

    $fieldDefaults = [ordered]@{}
    $sources = [ordered]@{}
    $unresolved = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        $tid = Resolve-TypeId $e.type
        if ($null -eq $tid) {
            $unresolved.Add([ordered]@{ type = $e.type; label = $e.label; reason = 'unknown issue type' })
            continue
        }
        $fid = Resolve-FieldId $tid $e.label
        if ($null -eq $fid) {
            $unresolved.Add([ordered]@{ type = $e.type; label = $e.label; reason = 'unknown field label' })
            continue
        }
        if (-not $fieldDefaults.Contains($tid)) { $fieldDefaults[$tid] = [ordered]@{} }
        $fieldDefaults[$tid][$fid] = $e.value
        if (-not $sources.Contains($tid)) { $sources[$tid] = [ordered]@{} }
        $sources[$tid][$fid] = $e.source
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{
        field_defaults = $fieldDefaults
        field_default_sources = $sources
        unresolved = $unresolved
    }))
}

function Get-JiraPlanConfirmationField {
    <#
    .SYNOPSIS
      011, contract §3.3, data-model.md §4: the `fields` array of the
      consolidated question, scoped to the issue types that actually have a
      creation pending THIS run. Mirror of plan_confirmation_fields.

      A field is included exactly when it is about to be SENT (its field_id
      is a key of FieldDefaultsByTypeJson[type], value taken from there) OR
      it is required and NOT about to be sent (included with recorded_value
      $null). A merely-defaultable, optional, unresolved field is never
      included — it is not a trigger.

      An empty result means neither §3.3 trigger fires: the caller asks
      nothing.
    #>
    [CmdletBinding()]
    param(
        [string] $IssueTypesJson = '[]',
        [string] $DefaultableFieldsByTypeJson = '{}',
        [string] $FieldDefaultsByTypeJson = '{}',
        [string] $PendingTypeIdsJson = '[]'
    )
    if ([string]::IsNullOrEmpty($IssueTypesJson)) { $IssueTypesJson = '[]' }
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($FieldDefaultsByTypeJson)) { $FieldDefaultsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($PendingTypeIdsJson)) { $PendingTypeIdsJson = '[]' }

    $itypes = @($IssueTypesJson | ConvertFrom-Json -Depth 100)
    $df = $DefaultableFieldsByTypeJson | ConvertFrom-Json -Depth 100
    $fd = $FieldDefaultsByTypeJson | ConvertFrom-Json -Depth 100
    $pending = @($PendingTypeIdsJson | ConvertFrom-Json -Depth 100)

    function Resolve-PcfTypeName([string] $TypeId) {
        foreach ($t in $itypes) { if ([string]$t.id -eq $TypeId) { return [string]$t.logical_name } }
        return $TypeId
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($tid in $pending) {
        $tid = [string]$tid
        $listProp = $df.PSObject.Properties[$tid]
        if ($null -eq $listProp) { continue }
        $fdForType = Get-JiraPlanProp $fd $tid
        foreach ($f in @($listProp.Value)) {
            $sent = $null
            if ($null -ne $fdForType) { $sent = Get-JiraPlanProp $fdForType ([string]$f.field_id) }
            $required = [bool]$f.required
            if ($null -eq $sent -and -not $required) { continue }
            $allowed = @()
            if ($null -ne (Get-JiraPlanProp $f 'allowed_values')) { $allowed = @($f.allowed_values) }
            $result.Add([ordered]@{
                issue_type = (Resolve-PcfTypeName $tid)
                label = [string]$f.logical_name
                recorded_value = $sent
                required = $required
                allowed_values = $allowed
            })
        }
    }
    return (ConvertTo-JiraJsonValue $result)
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
    # 011, research R2: {type_id: {field_id: value}}. $null ⇒ the merge in
    # Get-JiraCreateFieldsBase is a no-op (FR-028) — that builder itself
    # scopes the merge to the type being created, so a default recorded for
    # the OTHER written type never reaches this payload (FR-018).
    $fieldDefaultsProp = Get-JiraPlanProp $ctx 'field_defaults'
    $fieldDefaultsJson = if ($null -eq $fieldDefaultsProp) { '' } else { ConvertTo-JiraJsonValue $fieldDefaultsProp }
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
            $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $title -IssueTypeId $storyType -FieldDefaultsByTypeJson $fieldDefaultsJson | ConvertFrom-Json
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
            # (an update targets an existing item by key). On a human-origin
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

            # Parent-link correction (T109): a child ALREADY linked to a
            # parent (never a flat mirror carrying none — that is Out of
            # Scope, "no migration") whose current parent disagrees with the
            # resolved one is re-linked. The resolved key is either already
            # known (a recognised parent) or, when the parent is being
            # created this same run, filled in later by the same
            # "<resolved at apply time>" placeholder every story creation
            # already uses (Invoke-JiraApplyWritesWithRecognition step 11).
            $ticketParents = Get-JiraPlanProp $ctx 'ticket_parents'
            $curParent = [string](Get-JiraPlanProp $ticketParents $sid)
            if ($curParent -ne '') {
                $targetParent = [string](Get-JiraPlanProp $ctx 'parent_key')
                if ($targetParent -ne '') {
                    if ($curParent -ne $targetParent) { $fields['parent'] = [ordered]@{ key = $targetParent } }
                }
                else {
                    $fields['parent'] = [ordered]@{ key = '<resolved at apply time>' }
                }
            }

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
        # CREATE: no parent recognised yet. 011, research R2: same
        # field_defaults map the story branch reads, scoped to the parent
        # type by the shared builder itself.
        $fieldDefaultsProp = Get-JiraPlanProp $ctx 'field_defaults'
        $fieldDefaultsJson = if ($null -eq $fieldDefaultsProp) { '' } else { ConvertTo-JiraJsonValue $fieldDefaultsProp }
        $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $epicTitle -IssueTypeId $parentType -FieldDefaultsByTypeJson $fieldDefaultsJson | ConvertFrom-Json
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

function Get-JiraPlanTaskWriteSet {
    <#
    .SYNOPSIS
      Resolve the task tier of the validated neutral document into an
      ordered array of write actions. Mirror of plan_writes_tasks (Phase 3,
      US1, T039; contract §4). Iterates stories[].tasks[]: a task is never
      planned under anything but its own story (FR-007) because that is the
      only place it is nested. A PUT carries only the fields that differ
      (FR-019), with a `warning` naming the ticket and the divergent
      field(s) attached to that same action (FR-020).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $DocJson, [Parameter(Mandatory)] [string] $ContextJson)
    $doc = $DocJson | ConvertFrom-Json -Depth 100
    $ctx = $ContextJson | ConvertFrom-Json -Depth 100

    $base = [string](Get-JiraPlanProp $ctx 'base_url')
    $taskType = [string](Get-JiraPlanProp $ctx 'task_type_id')
    $fieldDefaultsProp = Get-JiraPlanProp $ctx 'field_defaults'
    $fieldDefaultsJson = if ($null -eq $fieldDefaultsProp) { '' } else { ConvertTo-JiraJsonValue $fieldDefaultsProp }
    $project = [string](Get-JiraPlanProp (Get-JiraPlanProp $doc 'routing') 'project_key')
    $tickets = Get-JiraPlanProp $ctx 'tickets'
    $ticketCurrent = Get-JiraPlanProp $ctx 'ticket_current'

    $stories = @()
    $storyProp = Get-JiraPlanProp $doc 'stories'
    if ($null -ne $storyProp) { $stories = @($storyProp) }

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($story in $stories) {
        $storyLocalId = [string]$story.local_id
        $tasksProp = Get-JiraPlanProp $story 'tasks'
        if ($null -eq $tasksProp) { continue }
        foreach ($task in @($tasksProp)) {
            $tid = [string]$task.local_id
            $title = [string]$task.title
            $ticket = [string](Get-JiraPlanProp $tickets $tid)
            $taskJson = ConvertTo-JiraJsonValue $task
            $summary = Get-JiraAdfTaskSummary -Title $title
            $adf = ConvertTo-JiraAdfTaskDescription -TaskJson $taskJson | ConvertFrom-Json -Depth 100

            if ($ticket -eq '') {
                if ($project -eq '' -or $taskType -eq '') {
                    throw "plan_writes_tasks: refusing to assemble a creation for `"$tid`" with no project or issue type (zero writes)"
                }
                $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $summary -IssueTypeId $taskType -FieldDefaultsByTypeJson $fieldDefaultsJson | ConvertFrom-Json
                $fields = [ordered]@{}
                foreach ($p in $baseFields.PSObject.Properties) { $fields[$p.Name] = $p.Value }
                $fields['description'] = $adf
                $fields['parent'] = [ordered]@{ key = '<resolved at apply time>' }
                $actions.Add([ordered]@{ method = 'POST'; url = "$base/rest/api/3/issue"; body = [ordered]@{ fields = $fields }; local_id = $tid; parent_local_id = $storyLocalId; role = 'task' })
            }
            else {
                $current = Get-JiraPlanProp $ticketCurrent $tid
                $desired = [ordered]@{ summary = $summary; description = $adf }
                if ($null -eq $current) {
                    $st = 'changed'
                }
                else {
                    $st = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $current) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desired)
                }
                if ($st -eq 'unchanged') { continue }

                # FR-019: only the fields that differ are written. FR-020: the same
                # comparison names the divergent field(s) in a warning before the
                # overwrite — $current -eq $null means no prior state was read at
                # all, so nothing narrower than the full desired set can be sent,
                # and there is no known field to name.
                $filtered = $desired
                $warning = ''
                if ($null -ne $current) {
                    $filtered = [ordered]@{}
                    $diverged = [System.Collections.Generic.List[string]]::new()
                    foreach ($key in $desired.Keys) {
                        $curMember = if ($current -is [System.Management.Automation.PSCustomObject]) { $current.PSObject.Properties[$key] } else { $null }
                        $curVal = if ($null -eq $curMember) { $null } else { $curMember.Value }
                        $desCanon = ConvertTo-JiraJsonValue $desired[$key]
                        $curCanon = if ($null -eq $curVal) { 'null' } else { ConvertTo-JiraJsonValue $curVal }
                        if (-not [System.String]::Equals($desCanon, $curCanon, [System.StringComparison]::Ordinal)) {
                            $filtered[$key] = $desired[$key]
                            $diverged.Add($key)
                        }
                    }
                    $warning = "$ticket diverges from the specification on `"$($diverged -join ', ')`"; only the differing field(s) will be written"
                }

                $action = [ordered]@{ method = 'PUT'; url = "$base/rest/api/3/issue/$ticket"; body = [ordered]@{ fields = $filtered }; role = 'task' }
                if ($warning -ne '') { $action['warning'] = $warning }
                $actions.Add($action)
            }
        }
    }

    return (ConvertTo-JiraJsonValue $actions)
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

function Get-JiraTransitionAction {
    <#
    .SYNOPSIS
      The single transition-POST emission site (012, T092), shared by
      Get-JiraLifecyclePlan (story tier) and Get-JiraTaskLifecyclePlan (task
      tier) rather than each building its own. Mirror of
      _plan_transition_action. Returns [ordered]@{ Action; Note } — Note is
      $null when the ticket carries no open blocking link.
    #>
    param(
        [string] $BaseUrl, [string] $Key, [string] $TransitionId,
        [object[]] $Blockers, [string] $Label
    )
    $action = [ordered]@{
        method = 'POST'; url = "$BaseUrl/rest/api/3/issue/$Key/transitions"
        body   = [ordered]@{ transition = [ordered]@{ id = $TransitionId } }
    }
    $note = $null
    if ($Blockers -and $Blockers.Count -gt 0) {
        $blist = ($Blockers -join ', ')
        $note = "transition of `"$Label`" proceeds with open blocking links ($blist); human-created links are left unchanged"
    }
    return [ordered]@{ Action = $action; Note = $note }
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
            $blockersVal = Get-JiraPlanProp $tk 'blockers'
            $blockers = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $blockersVal) { foreach ($b in @($blockersVal)) { $blockers.Add([string]$b) } }
            $tres = Get-JiraTransitionAction -BaseUrl $base -Key $key -TransitionId $transitionId -Blockers $blockers.ToArray() -Label $sid
            $kept.Add($tres.Action)
            if ($tres.Note) { $notes.Add($tres.Note) }
        }
    }

    $out = [ordered]@{ actions = $kept; warnings = $warns; notes = $notes }
    return (ConvertTo-JiraJsonValue $out)
}

function Get-JiraTaskLifecyclePlan {
    <#
    .SYNOPSIS
      The task tier's own completion pass (012, US5, contract §6). Mirror of
      plan_lifecycle_tasks — a sibling of Get-JiraLifecyclePlan, never routed
      through it: task completion is a binary done/not-done model, not a
      named multi-status order, and every divergence is reported by ticket
      key, never by a status name (FR-030/FR-032). PURE: the candidates, the
      chosen transition (if any) and the withheld field arrive already
      resolved by the caller's discovery read (research R5). Only ever ADDS
      transition actions to content-actions; content zero-churn is
      Get-JiraTaskWriteSet's own concern (FR-015).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ContentActionsJson,
        [Parameter(Mandatory)] [string] $CompletionContextJson
    )
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($ContentActionsJson | ConvertFrom-Json -Depth 100)) { $kept.Add($x) }
    $cc = $CompletionContextJson | ConvertFrom-Json -Depth 100
    $base = [string](Get-JiraPlanProp $cc 'base_url')
    $tasks = Get-JiraPlanProp $cc 'tasks'

    $warns = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    $taskEntries = @()
    if ($null -ne $tasks) { $taskEntries = @($tasks.PSObject.Properties) }
    foreach ($entry in $taskEntries) {
        $t = $entry.Value
        $key = [string](Get-JiraPlanProp $t 'key')
        if ($key -eq '') { continue }
        $blockersVal = Get-JiraPlanProp $t 'blockers'
        $blockers = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $blockersVal) { foreach ($b in @($blockersVal)) { $blockers.Add([string]$b) } }

        $divergedVal = Get-JiraPlanProp $t 'already_done_diverged'
        if ($divergedVal -eq $true) {
            $warns.Add("sub-task $key is already at a done status while its task is unchecked in tasks.md; it is left as is unless this run is authorised to pull it backward")
        }

        $fwd = Get-JiraPlanProp $t 'forward'
        if ($null -ne $fwd) {
            $tidF = [string](Get-JiraPlanProp $fwd 'transition_id')
            $cands = @(Get-JiraPlanProp $fwd 'candidates')
            $withheld = Get-JiraPlanProp $fwd 'withheld_field'
            if ($tidF -ne '') {
                $tres = Get-JiraTransitionAction -BaseUrl $base -Key $key -TransitionId $tidF -Blockers $blockers.ToArray() -Label $key
                $kept.Add($tres.Action)
                if ($tres.Note) { $notes.Add($tres.Note) }
            }
            elseif ($null -ne $withheld) {
                $fname = [string](Get-JiraPlanProp $withheld 'logical_name')
                $warns.Add("sub-task $key reaches a done status only through a transition that requires `"$fname`"; the transition is withheld — set it directly in Jira, or record a default for that field")
            }
            elseif ($cands.Count -eq 0) {
                $warns.Add("sub-task $key has no transition to a status this project classifies as done; nothing was transitioned")
            }
            else {
                $names = ($cands | ForEach-Object { [string](Get-JiraPlanProp $_ 'name') }) -join ', '
                $warns.Add("sub-task $key offers more than one transition to a status this project classifies as done ($names); the bridge does not choose one")
            }
        }

        $bwd = Get-JiraPlanProp $t 'backward'
        if ($null -ne $bwd) {
            $tidB = [string](Get-JiraPlanProp $bwd 'transition_id')
            if ($tidB -ne '') {
                $tres = Get-JiraTransitionAction -BaseUrl $base -Key $key -TransitionId $tidB -Blockers $blockers.ToArray() -Label $key
                $kept.Add($tres.Action)
                if ($tres.Note) { $notes.Add($tres.Note) }
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

function Write-JiraApplyRejectionReport {
    <#
    .SYNOPSIS
      011, contract §3.7, FR-019: when a CREATE (POST .../issue) fails with a
      400 whose Jira error body names a field this run defaulted, print the
      human translation to stderr (mirrors Test-JiraPrivacyBlock's own
      self-printing pattern) before the caller returns fail-closed. Mirror of
      _plan_apply_report_rejection.
    #>
    param(
        [string] $Method,
        [string] $Url,
        $Action,
        [string] $DefaultableFieldsByTypeJson,
        $Result
    )
    if ($Method -ne 'POST' -or -not $Url.EndsWith('/issue') -or [int]$Result.Status -ne 400) { return }
    $actionJson = ConvertTo-JiraJsonValue $Action
    $errBody = if ($Result.ErrorBody) { $Result.ErrorBody } else { '{}' }
    $msg = Get-JiraTicketFieldRejectionMessage -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -ActionJson $actionJson -ErrorBodyJson $errBody
    if ($msg) { [Console]::Error.WriteLine($msg) }
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

      DefaultableFieldsByTypeJson (011, contract §3.7, FR-019): the binding's
      defaultable_fields map, {type_id: [{logical_name, field_id, ...}]}.
      Omitted or empty ⇒ a rejected creation falls through to the existing
      generic failure path unchanged (FR-028).

      TasksActionsJson (Phase 3, US1, T041; contract §5): Get-JiraPlanTaskWriteSet'
      output. Every task body joins the SAME pre-write guard sweep as the
      parent and every story, before the first write of the run (FR-025).
      Tasks are applied LAST, after every story. Each task creation's
      parent-key placeholder is resolved from KnownStoryKeysJson merged with
      the keys created earlier in THIS run. TasksFile is where the task
      marker is spliced (tasks.md); empty means no task action is applied
      and no file is touched (FR-011).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PlanJson,
        [Parameter(Mandatory)] [string] $SpecRefJson,
        [Parameter(Mandatory)] [string] $SpecFile,
        [string] $KnownParentKey = '',
        [string] $ExtraKnownCoordinatesJson = '[]',
        [string] $DefaultableFieldsByTypeJson = '{}',
        [string] $TasksActionsJson = '[]',
        [string] $TasksFile = '',
        [string] $KnownStoryKeysJson = '{}'
    )
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($TasksActionsJson)) { $TasksActionsJson = '[]' }
    if ([string]::IsNullOrEmpty($KnownStoryKeysJson)) { $KnownStoryKeysJson = '{}' }
    $coords = Get-JiraApplyKnownCoordinate -ExtraJson $ExtraKnownCoordinatesJson
    $allow = if ($env:SPEC_KIT_JIRA_ALLOWLIST) { $env:SPEC_KIT_JIRA_ALLOWLIST } else { '[]' }
    $plan = $PlanJson | ConvertFrom-Json -Depth 100
    $parent = Get-JiraPlanProp $plan 'parent'
    $stories = @()
    $storiesProp = Get-JiraPlanProp $plan 'stories'
    if ($null -ne $storiesProp) { $stories = @($storiesProp) }
    $taskActions = @($TasksActionsJson | ConvertFrom-Json -Depth 100)

    # (1) Pre-write gate — scan every payload, parent then stories then
    # tasks, before writing anything.
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
    foreach ($a in $taskActions) {
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

    # (2b) Same step, for the task tier's OWN file: mark every planned task
    # creation `creating` in TasksFile. A no-op when TasksFile is empty.
    if ($TasksFile -ne '') {
        $tCurrent = if (Test-Path -LiteralPath $TasksFile) { Get-Content -Raw -LiteralPath $TasksFile } else { '' }
        if ($null -eq $tCurrent) { $tCurrent = '' }
        $tNewContent = $tCurrent
        $taskCreatingIds = [System.Collections.Generic.List[string]]::new()
        foreach ($a in $taskActions) {
            $lid = [string](Get-JiraPlanProp $a 'local_id')
            if ($a.method -eq 'POST' -and ([string]$a.url).EndsWith('/issue') -and $lid -ne '') { $taskCreatingIds.Add($lid) }
        }
        if ($taskCreatingIds.Count -gt 0) {
            $tNewContent = Set-JiraTaskMarkerMarkCreating -Text $tNewContent -IdsJson (ConvertTo-JiraJsonValue $taskCreatingIds)
        }
        if ($tNewContent -ne $tCurrent) {
            Write-JiraMarkerSpliceFile -Path $TasksFile -NewContent $tNewContent | Out-Null
        }
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
        if ([int]$r.ExitCode -ge 2) {
            Write-JiraApplyRejectionReport -Method $parent.method -Url $parent.url -Action $parent -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -Result $r
            return $worst
        }
        if ($parent.method -eq 'POST') {
            $respObj = $null
            # A body that fails to parse is not fatal: $respObj stays $null
            # and the caller below treats a missing key as "not recorded".
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
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
    # $storyKeyMap is seeded from KnownStoryKeysJson (the caller's
    # already-recognised story keys) so a task's own parent resolution
    # (step 5) can find a story that was recognised rather than created
    # this run.
    $storyKeyMap = [ordered]@{}
    $knownStoryKeysObj = $KnownStoryKeysJson | ConvertFrom-Json -Depth 100
    if ($knownStoryKeysObj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $knownStoryKeysObj.PSObject.Properties) { $storyKeyMap[$p.Name] = [string]$p.Value }
    }
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
        if ([int]$r.ExitCode -ge 2) {
            Write-JiraApplyRejectionReport -Method $action.method -Url $action.url -Action $action -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -Result $r
            return $worst
        }

        if ($action.method -eq 'POST' -and ([string]$action.url).EndsWith('/issue')) {
            $respObj = $null
            # A body that fails to parse is not fatal: $respObj stays $null
            # and the caller below treats a missing key as "not recorded".
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
            $key = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            $localId = [string](Get-JiraPlanProp $action 'local_id')
            if ($key -ne '' -and $localId -ne '') {
                Set-JiraIdentity -IssueKey $key -SpecRefJson $SpecRefJson -Origin 'bridge' -Story $localId -Role 'story' | Out-Null
                $cur = if (Test-Path -LiteralPath $SpecFile) { Get-Content -Raw -LiteralPath $SpecFile } else { '' }
                if ($null -eq $cur) { $cur = '' }
                $new = Set-JiraStoryMarkerRecordTicket -Text $cur -Id $localId -Key $key
                Write-JiraMarkerSpliceFile -Path $SpecFile -NewContent $new | Out-Null
                $storyKeyMap[$localId] = $key
            }
        }
    }

    # (5) Task writes (Phase 3, US1, T041; contract §5) — LAST, after every
    # story. A task attributed to a story with no entry in $storyKeyMap
    # (not created and not recognised this run) is left unresolved and its
    # write is skipped — it reconciles on the next run once the story
    # exists (contract §4 rule 5).
    foreach ($a in $taskActions) {
        $taction = $a
        $tParentLocalId = [string](Get-JiraPlanProp $taction 'parent_local_id')
        if ($tParentLocalId -ne '') {
            if (-not $storyKeyMap.Contains($tParentLocalId)) { continue }
            $tParentKey = [string]$storyKeyMap[$tParentLocalId]
            $fields = Get-JiraPlanProp (Get-JiraPlanProp $taction 'body') 'fields'
            $parentField = Get-JiraPlanProp $fields 'parent'
            if ($null -ne $parentField -and [string](Get-JiraPlanProp $parentField 'key') -eq '<resolved at apply time>') {
                $parentField.key = $tParentKey
            }
        }
        $bodyObj = if ($taction.PSObject.Properties.Name -contains 'body') { $taction.body } else { $null }
        if ($null -ne $bodyObj) {
            $bodyText = ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100
            $r = Invoke-JiraRequest -Method $taction.method -Url $taction.url -Body $bodyText
        }
        else {
            $r = Invoke-JiraRequest -Method $taction.method -Url $taction.url
        }
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) {
            Write-JiraApplyRejectionReport -Method $taction.method -Url $taction.url -Action $taction -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -Result $r
            return $worst
        }

        if ($taction.method -eq 'POST' -and ([string]$taction.url).EndsWith('/issue') -and $TasksFile -ne '') {
            $respObj = $null
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
            $tKey = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            $tLocalId = [string](Get-JiraPlanProp $taction 'local_id')
            if ($tKey -ne '' -and $tLocalId -ne '') {
                Set-JiraIdentity -IssueKey $tKey -SpecRefJson $SpecRefJson -Origin 'bridge' -Story $tLocalId -Role 'task' | Out-Null
                $tCur = if (Test-Path -LiteralPath $TasksFile) { Get-Content -Raw -LiteralPath $TasksFile } else { '' }
                if ($null -eq $tCur) { $tCur = '' }
                $tNew = Set-JiraTaskMarkerRecordTicket -Text $tCur -Id $tLocalId -Key $tKey
                Write-JiraMarkerSpliceFile -Path $TasksFile -NewContent $tNew | Out-Null
            }
        }
    }
    return $worst
}

Export-ModuleMember -Function Get-JiraApplyKnownCoordinate, Invoke-JiraApplyWriteSet, Get-JiraPlanWriteSet, Get-JiraLifecyclePlan, `
    Get-JiraManagedDescriptionStatus, Invoke-JiraApplyWriteSetWithRecognition, Get-JiraPlanResolveFieldDefault, `
    Get-JiraPlanConfirmationField, Get-JiraPlanTaskWriteSet, Get-JiraTaskLifecyclePlan
