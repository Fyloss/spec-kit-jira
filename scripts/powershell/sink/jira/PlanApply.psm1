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
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')    # No -Force — see project memory: powershell-import-force-clobbers-caller-scope
Import-Module (Join-Path $PSScriptRoot 'Transitions.psm1') -Force # 023: Import-JiraTransitions/Get-JiraTransitionRecord/Resolve-JiraTransition
Import-Module (Join-Path $PSScriptRoot 'Ticket.psm1') -Force # Get-JiraCreateFieldsBase — the shared creation-fields builder (research R3)
Import-Module (Join-Path $PSScriptRoot '../../engine/MarkerSplice.psm1') -Force # Write-JiraMarkerSpliceFile — a nested import inside StoryMarker.psm1 is not enough
Import-Module (Join-Path $PSScriptRoot '../../engine/StoryMarker.psm1') -Force -Global # R5 steps 4/6 — mark `creating`, stamp + record per ticket
Import-Module (Join-Path $PSScriptRoot '../../engine/SpecMarker.psm1') -Force # the parent marker's same splice (Phase 5, US2)
Import-Module (Join-Path $PSScriptRoot '../../engine/TaskMarker.psm1') -Force -Global # Phase 3, US1 — the task tier's own marker grammar, same seam (bare -Force here strips a caller's -Global load — see StoryMarker.psm1's import above)
Import-Module (Join-Path $PSScriptRoot 'Identity.psm1') -Force # stamp the identity marker on each created ticket (R5 step 6)

# 017, contracts/provenance-label.md §4: Jira Cloud's documented label-length
# cap. One named constant so a tracker that differs is a one-line correction.
$script:JiraLabelMaxLength = 255

function Get-JiraPlanApplyLabelDecision {
    <#
    .SYNOPSIS
      017, contract §4's two degradation triggers. Mirror of
      _plan_apply_label_decision. Returns [ordered]@{ Label; Warning } —
      Warning is '' when the label is sent unchanged. Neither trigger ever
      refuses or drops a write — the label is simply omitted, with one
      named warning.
    #>
    param(
        $DefaultableByType,
        [string] $TypeId,
        [string] $TypeName,
        [string] $ProjectKey,
        [string] $Provenance,
        [string] $Slug
    )
    if ([string]::IsNullOrEmpty($Provenance)) { return [ordered]@{ Label = ''; Warning = '' } }

    # (b) The label is too long — checked first: an over-long label is never
    # sent regardless of the type's own capability, and its warning names
    # the SLUG (the operator's remedy), never the type.
    if ($Provenance.Length -gt $script:JiraLabelMaxLength) {
        $warning = "the provenance label for `"$Slug`" is $($Provenance.Length) characters, past the tracker's $($script:JiraLabelMaxLength)-character limit; every ticket was mirrored without it"
        return [ordered]@{ Label = ''; Warning = $warning }
    }

    # (a) The type cannot hold labels — "present" means the key EXISTS in
    # the type's defaultable_fields entry (recorded `defaultable: false`
    # included), never whether it is itself defaultable (research
    # R6/contract §4): that entry is exactly discovery's evidence that the
    # type's create screen OFFERS labels at all. A type with no
    # defaultable_fields entry recorded predates the metadata and must not
    # gain a second refusal — it sends.
    $entryProp = if ($null -ne $DefaultableByType) { $DefaultableByType.PSObject.Properties[$TypeId] } else { $null }
    if ($null -ne $entryProp) {
        $hasLabels = $false
        foreach ($f in @($entryProp.Value)) { if ([string]$f.field_id -eq 'labels') { $hasLabels = $true; break } }
        if (-not $hasLabels) {
            $warning = "the provenance label `"$Provenance`" could not be applied to $TypeName in $ProjectKey; every ticket was mirrored without it"
            return [ordered]@{ Label = ''; Warning = $warning }
        }
    }
    return [ordered]@{ Label = $Provenance; Warning = '' }
}

# 022, FR-041, contract §7: the sink's practical ceiling for a rendered
# description, in bytes of the canonical ADF JSON — Jira Cloud's documented
# text-field limit. Mirror of _PLAN_APPLY_DESCRIPTION_SIZE_CEILING.
$script:PlanApplyDescriptionSizeCeiling = 32767

function Get-JiraApplyManagedField {
    <#
    .SYNOPSIS
      018, T027, contract §3 rows 1/4 (FR-012/FR-020a/FR-020b). Mirror of
      _plan_apply_managed_field. Given ConvertTo-JiraManagedAdfDocument's or
      ConvertTo-JiraManagedTaskAdfDocument's {status, doc} and a label
      identifying the ticket for a warning (the ticket's key on an UPDATE;
      empty on a CREATE, which never warns since a creation has no existing
      content to be ambiguous about), decide the description FIELD to send
      and any warning to surface. Returns canonical {doc, warning}: doc is
      $null when the boundary is malformed — the caller MUST omit the
      description key entirely rather than send null, so every other field
      of that ticket still reconciles (FR-012); warning is '' when none
      applies.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RenderJson,
        [Parameter()] [string] $Label = ''
    )
    $render = $RenderJson | ConvertFrom-Json -Depth 100
    $status = [string]$render.status
    $doc = $null
    $warning = ''
    switch ($status) {
        'malformed' {
            $warning = "$Label carries more than one boundary marker in its description; nothing was written to it. A human must remove the duplicate."
        }
        'migrated-warned' {
            $doc = $render.doc
            $warning = "$Label's previous mirrored content could not be identified and is preserved above the boundary; it may now appear twice."
        }
        default {
            $doc = $render.doc
        }
    }
    # 022, FR-041, contract §7: a rendered description (the checklist
    # included) that exceeds the sink's ceiling withholds THAT ONE field —
    # every other field of the story, and every other story, still
    # reconciles. Reuses the SAME whole-field drop as the malformed row
    # above, rather than a second way to fail a field.
    if ($null -ne $doc) {
        $docJson = ConvertTo-JiraJsonValue $doc
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($docJson)
        if ($byteCount -gt $script:PlanApplyDescriptionSizeCeiling) {
            $doc = $null
            $warning = "$Label's rendered description exceeds what Jira accepts and was not written — nothing changed in Jira. Reduce the number of tasks in this story, or switch this project to subtask mode."
        }
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ doc = $doc; warning = $warning }))
}

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

      015, research R1/R2/R3, contract §1.3, data-model.md §2: alongside the
      recorded map, emits field_defaults_encoded — the same map with each
      value shaped for the field's declared schema_type (an `option` field
      as {"value": v}, a named-entity field as {"name": v}, everything
      else, including `user` and a non-string value, unchanged). Only the
      plan context's assignment reads the encoded map; every other consumer
      keeps reading field_defaults untouched (research R2).

      Returns one canonical object: {field_defaults; field_defaults_encoded;
      field_default_sources; unresolved}.
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
    function Resolve-FieldMeta([string] $TypeId, [string] $Label) {
        $listProp = $df.PSObject.Properties[$TypeId]
        if ($null -eq $listProp) { return $null }
        foreach ($f in @($listProp.Value)) { if ([string]$f.logical_name -eq $Label) { return $f } }
        return $null
    }
    $namedEntityTypes = @('priority', 'resolution', 'version', 'component', 'group')
    function Get-JiraEncodedFieldDefault($Meta, $Value) {
        if ($Value -isnot [string]) { return $Value }
        $schemaType = [string](Get-JiraPlanProp $Meta 'schema_type')
        if ($schemaType -eq 'option') { return [ordered]@{ value = $Value } }
        if ($namedEntityTypes -contains $schemaType) { return [ordered]@{ name = $Value } }
        return $Value
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
    $fieldDefaultsEncoded = [ordered]@{}
    $sources = [ordered]@{}
    $unresolved = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        $tid = Resolve-TypeId $e.type
        if ($null -eq $tid) {
            $unresolved.Add([ordered]@{ type = $e.type; label = $e.label; reason = 'unknown issue type' })
            continue
        }
        $meta = Resolve-FieldMeta $tid $e.label
        if ($null -eq $meta) {
            $unresolved.Add([ordered]@{ type = $e.type; label = $e.label; reason = 'unknown field label' })
            continue
        }
        $fid = [string]$meta.field_id
        if (-not $fieldDefaults.Contains($tid)) { $fieldDefaults[$tid] = [ordered]@{} }
        $fieldDefaults[$tid][$fid] = $e.value
        if (-not $fieldDefaultsEncoded.Contains($tid)) { $fieldDefaultsEncoded[$tid] = [ordered]@{} }
        $fieldDefaultsEncoded[$tid][$fid] = Get-JiraEncodedFieldDefault $meta $e.value
        if (-not $sources.Contains($tid)) { $sources[$tid] = [ordered]@{} }
        $sources[$tid][$fid] = $e.source
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{
        field_defaults = $fieldDefaults
        field_defaults_encoded = $fieldDefaultsEncoded
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
    # 022, contract §1/§7: the resolved task_mirror mode, threaded into the
    # renderer as 'checklist' or 'off' — constant for the whole run.
    $checklistMode = 'off'
    if ([string](Get-JiraPlanProp $ctx 'task_mirror') -eq 'checklist') { $checklistMode = 'checklist' }
    # 022, data-model.md §4: the checklist tallies, accumulated per story
    # below and returned distinct from the specification/story/sub-task
    # counts.
    $clCreated = 0; $clUpdated = 0; $clUnchanged = 0; $clEntriesCompleted = 0

    # Provenance label (017, contracts/provenance-label.md §1/§4): derived
    # once per run, from the document's own validated spec_ref — the
    # "speckit-" prefix is a sink literal, the engine never learns the word
    # "label". The degradation decision (§4's two triggers) is resolved
    # ONCE for the story type here and reused by every story this run
    # creates or updates, so at most one warning is ever emitted for it.
    $slug = [string](Get-JiraPlanProp (Get-JiraPlanProp $doc 'spec_ref') 'spec_slug')
    $provenanceLabel = if ($slug -ne '') { "speckit-$slug" } else { '' }
    $defaultableByType = Get-JiraPlanProp $ctx 'defaultable_fields_by_type'
    # @() around a $null property wraps it into a ONE-element array holding
    # $null, not an empty array — filter it explicitly, or an absent
    # issue_types key (a binding that predates it) throws under StrictMode
    # instead of leaving the label decision to fall through to the type id.
    $issueTypesRaw = Get-JiraPlanProp $ctx 'issue_types'
    $issueTypesList = if ($null -eq $issueTypesRaw) { @() } else { @($issueTypesRaw) }
    function Resolve-JiraPlanTypeName([string] $TypeId) {
        foreach ($t in $issueTypesList) { if ([string]$t.id -eq $TypeId) { return [string]$t.logical_name } }
        return $TypeId
    }
    $storyLabel = ''
    $planWarnings = [System.Collections.Generic.List[string]]::new()
    if ($provenanceLabel -ne '') {
        $storyDecision = Get-JiraPlanApplyLabelDecision -DefaultableByType $defaultableByType -TypeId $storyType `
            -TypeName (Resolve-JiraPlanTypeName $storyType) -ProjectKey $project -Provenance $provenanceLabel -Slug $slug
        $storyLabel = $storyDecision.Label
        if ($storyDecision.Warning -ne '') { $planWarnings.Add($storyDecision.Warning) }
    }

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

        if ($ticket -eq '') {
            # FR-024 assembly guard: refuse an incomplete creation BEFORE it is
            # ever emitted, rather than sending it for the destination service
            # to reject.
            if ($project -eq '' -or $storyType -eq '') {
                throw "plan_writes: refusing to assemble a creation for `"$sid`" with no project or issue type (zero writes)"
            }
            # CREATE: the shared mandatory base (research R3, FR-025) + the
            # optional attributes + the parent-key placeholder (T072/T073),
            # resolved once the parent's create response is read. Every
            # ticket the mirror creates now carries the boundary from its
            # first byte (018, T027, FR-006/FR-010) — a creation never warns.
            $createRenderJson = ConvertTo-JiraManagedAdfDocument -ContentJson $storyJson -Mode $checklistMode
            $createFieldResult = Get-JiraApplyManagedField -RenderJson $createRenderJson -Label $title | ConvertFrom-Json -Depth 100
            $adf = $createFieldResult.doc
            if ([string]$createFieldResult.warning -ne '') { $planWarnings.Add([string]$createFieldResult.warning) }
            $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $title -IssueTypeId $storyType -FieldDefaultsByTypeJson $fieldDefaultsJson -Provenance $storyLabel | ConvertFrom-Json
            $fields = [ordered]@{}
            foreach ($p in $baseFields.PSObject.Properties) { $fields[$p.Name] = $p.Value }
            if ($null -ne $adf) { $fields['description'] = $adf }
            $fields['parent'] = [ordered]@{ key = '<resolved at apply time>' }
            if ($priorityId -ne '') { $fields['priority'] = [ordered]@{ id = $priorityId } }
            $estValue = Get-JiraPlanProp $story 'estimation'
            if ($estId -ne '' -and $null -ne $estValue) { $fields[$estId] = $estValue }
            # 018, T049, contracts/summary-record.md §2: a creation's payload
            # always carries a summary, so it always establishes the record.
            $createChecklistDigest = ''
            if ($checklistMode -eq 'checklist') {
                $createChecklistDigest = Get-JiraAdfChecklistDigest -ContentJson $storyJson
                if ($createChecklistDigest -ne '') { $clCreated++ }
            }
            $identityStamp = [ordered]@{ origin = 'bridge'; story = $sid; role = 'story'; summary = $title }
            if ($createChecklistDigest -ne '') { $identityStamp['checklist'] = $createChecklistDigest }
            $actions.Add([ordered]@{ method = 'POST'; url = "$base/rest/api/3/issue"; body = [ordered]@{ fields = $fields }; local_id = $sid; role = 'story'; identity_stamp = $identityStamp })
        }
        else {
            # UPDATE: content + priority; no project or issuetype is required
            # (an update targets an existing item by key). The managed-panel
            # path is now UNCONDITIONAL (018, T027): every recognised story's
            # description is spliced through the origin-independent
            # resolution, so human prose above the boundary survives (FR-007)
            # regardless of origin.
            $descs = Get-JiraPlanProp $ctx 'ticket_descriptions'
            $existing = Get-JiraPlanProp $descs $sid
            $existingJson = if ($null -eq $existing) { '{}' } else { ConvertTo-JiraJsonValue $existing }
            # 019: the origin lookup MUST be hoisted above the render call —
            # this port reads $ticketOrigins only later, at the summary-drift
            # branch (research R6, the ordering hazard that exists only here).
            $ticketOriginsForRender = Get-JiraPlanProp $ctx 'ticket_origins'
            $storyOriginForRender = [string](Get-JiraPlanProp $ticketOriginsForRender $sid)
            $renderJson = ConvertTo-JiraManagedAdfDocument -ContentJson $storyJson -ExistingJson $existingJson -Origin $storyOriginForRender -Mode $checklistMode
            $fieldResult = Get-JiraApplyManagedField -RenderJson $renderJson -Label $ticket | ConvertFrom-Json -Depth 100
            if ([string]$fieldResult.warning -ne '') { $planWarnings.Add([string]$fieldResult.warning) }

            # 022, contract §6: the four-row checklist drift decision — did a
            # PERSON edit the checklist on the ticket since the mirror last wrote
            # it? A three-way digest comparison, mirroring
            # Get-JiraPlanSummaryDriftStatus's shape but the OPPOSITE outcome: warn
            # then WRITE regardless (FR-026).
            if ($checklistMode -eq 'checklist') {
                $clMarker = Get-JiraManagedMarker
                $clExisting = $existingJson | ConvertFrom-Json -Depth 100
                $clExistingContent = if ($clExisting.PSObject.Properties.Name -contains 'content') { ConvertTo-JiraJsonValue @($clExisting.content) } else { '[]' }
                $clExistingManaged = (Split-JiraManagedSectionPanel -Marker $clMarker -ContentJson $clExistingContent | ConvertFrom-Json -Depth 100).managed
                $clCurrentNodes = Get-JiraAdfChecklistSlice -ManagedJson (ConvertTo-JiraJsonValue @($clExistingManaged))
                $clCurrentDigest = Get-JiraAdfChecklistNodesDigest -NodesJson $clCurrentNodes
                $ticketLastChecklists = Get-JiraPlanProp $ctx 'ticket_last_checklists'
                $clRecordedDigest = [string](Get-JiraPlanProp $ticketLastChecklists $sid)
                $clDesiredDigest = Get-JiraAdfChecklistDigest -ContentJson $storyJson

                # 022, data-model.md §4: created/updated/unchanged classified
                # from CURRENT vs DESIRED (zero churn is current==desired) —
                # independent of the drift record above.
                $clDesiredNodesJson = ConvertTo-JiraJsonValue (Get-JiraAdfChecklistNode -ContentJson $storyJson)
                if ($clCurrentNodes -eq '[]') {
                    if ($clDesiredNodesJson -ne '[]') { $clCreated++ }
                } elseif ($clCurrentDigest -eq $clDesiredDigest) {
                    $clUnchanged++
                } else {
                    $clUpdated++
                }
                # entries.completed: positional zip of the two flattened
                # glyph sequences (entries carry no identity, contract §3).
                $clCurrentGlyphs = [System.Collections.Generic.List[bool]]::new()
                foreach ($n in @($clCurrentNodes | ConvertFrom-Json -Depth 100)) {
                    if ($n.type -eq 'bulletList') {
                        foreach ($li in @($n.content)) { $clCurrentGlyphs.Add(([string]$li.content[0].content[0].text).StartsWith('☑')) }
                    }
                }
                $clDesiredGlyphs = [System.Collections.Generic.List[bool]]::new()
                foreach ($n in @($clDesiredNodesJson | ConvertFrom-Json -Depth 100)) {
                    if ($n.type -eq 'bulletList') {
                        foreach ($li in @($n.content)) { $clDesiredGlyphs.Add(([string]$li.content[0].content[0].text).StartsWith('☑')) }
                    }
                }
                $clZipCount = [Math]::Min($clCurrentGlyphs.Count, $clDesiredGlyphs.Count)
                for ($ci = 0; $ci -lt $clZipCount; $ci++) {
                    if (-not $clCurrentGlyphs[$ci] -and $clDesiredGlyphs[$ci]) { $clEntriesCompleted++ }
                }

                if ($clRecordedDigest -ne '' -and $clCurrentDigest -ne $clRecordedDigest -and $clDesiredDigest -ne $clCurrentDigest) {
                    $planWarnings.Add("reconcile: ticket $ticket's checklist differs from the one the mirror last wrote — a human appears to have edited it since. tasks.md is the source of truth and the checklist has been rewritten from it; no box in tasks.md was changed.")
                }
            }

            # Summary drift (018, T049, contracts/summary-record.md §4):
            # decided before `$fields` is built, so an omission never
            # reaches the payload.
            $ticketSummaries = Get-JiraPlanProp $ctx 'ticket_summaries'
            $currentSummary = [string](Get-JiraPlanProp $ticketSummaries $sid)
            $ticketLastSummaries = Get-JiraPlanProp $ctx 'ticket_last_summaries'
            $recordedSummary = [string](Get-JiraPlanProp $ticketLastSummaries $sid)
            $onDriftMode = [string](Get-JiraPlanProp $ctx 'on_drift')
            if ($onDriftMode -eq '') { $onDriftMode = 'abort' }
            $summaryDecision = Get-JiraPlanSummaryDriftStatus -CurrentSummary $currentSummary -RecordedSummary $recordedSummary -DesiredSummary $title -OnDrift $onDriftMode
            $finalSummary = $summaryDecision.summary
            $identityStamp = $null
            if ([string]::IsNullOrEmpty($finalSummary)) {
                $planWarnings.Add("reconcile: ticket $ticket diverges from the specification on `"summary`" — a human appears to have renamed it since the last write; nothing was sent. Pass --on-drift=proceed to restore the specification's title.")
            }

            $fields = [ordered]@{}
            if ($null -ne $fieldResult.doc) { $fields['description'] = $fieldResult.doc }
            if (-not [string]::IsNullOrEmpty($finalSummary)) {
                $fields['summary'] = $finalSummary
                $ticketOrigins = Get-JiraPlanProp $ctx 'ticket_origins'
                $storyOrigin = [string](Get-JiraPlanProp $ticketOrigins $sid)
                if ([string]::IsNullOrEmpty($storyOrigin)) { $storyOrigin = 'bridge' }
                $identityStamp = [ordered]@{ origin = $storyOrigin; story = $sid; role = 'story'; summary = $finalSummary }
                if ($checklistMode -eq 'checklist') {
                    $updateChecklistDigest = Get-JiraAdfChecklistDigest -ContentJson $storyJson
                    if ($updateChecklistDigest -ne '') { $identityStamp['checklist'] = $updateChecklistDigest }
                }
            }
            if ($priorityId -ne '') { $fields['priority'] = [ordered]@{ id = $priorityId } }

            # Provenance label union (017, contract §2/§3): the desired list
            # is the ticket's CURRENT labels plus the provenance token —
            # Jira's PUT replaces the whole array, so the union is
            # simultaneously the merge rule (FR-012) and the zero-churn
            # rule (FR-013). Omitted entirely when the label is degraded
            # (empty $storyLabel) — an existing label set is never touched
            # on a project that cannot hold the token.
            if ($storyLabel -ne '') {
                $ticketLabels = Get-JiraPlanProp $ctx 'ticket_labels'
                # @() around a $null property wraps it into a ONE-element
                # array holding $null, not an empty array — a ticket with no
                # current labels (exactly the back-fill case T3 covers) would
                # otherwise union in a spurious "" label.
                $existingLabelsRaw = Get-JiraPlanProp $ticketLabels $sid
                $existingLabels = if ($null -eq $existingLabelsRaw) { @() } else { @($existingLabelsRaw) }
                $labels = [string[]]@(@($existingLabels) + @($storyLabel) | ForEach-Object { [string]$_ } | Select-Object -Unique)
                [System.Array]::Sort($labels, [System.StringComparer]::Ordinal)
                $fields['labels'] = $labels
            }

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

            $storyAction = [ordered]@{ method = 'PUT'; url = "$base/rest/api/3/issue/$ticket"; body = [ordered]@{ fields = $fields }; role = 'story' }
            if ($null -ne $identityStamp) { $storyAction['identity_stamp'] = $identityStamp }
            $actions.Add($storyAction)
        }
    }

    # The parent type's own label decision (017, contract §4) — resolved
    # here, independently of the story type's, and reused whether the
    # parent is created or updated this run. At most one further warning.
    $parentTypeForLabel = [string](Get-JiraPlanProp $ctx 'parent_type_id')
    $parentLabel = ''
    if ($provenanceLabel -ne '' -and $parentTypeForLabel -ne '') {
        $parentDecision = Get-JiraPlanApplyLabelDecision -DefaultableByType $defaultableByType -TypeId $parentTypeForLabel `
            -TypeName (Resolve-JiraPlanTypeName $parentTypeForLabel) -ProjectKey $project -Provenance $provenanceLabel -Slug $slug
        $parentLabel = $parentDecision.Label
        if ($parentDecision.Warning -ne '') { $planWarnings.Add($parentDecision.Warning) }
    }

    # The task type's own label decision (017 FR-009, extended to 012's task
    # tier) — resolved here beside the story's and the parent's, so this ONE
    # warning travels through this function's `warnings` channel. The
    # resolved token travels back as `task_label`; Get-JiraPlanTaskWriteSet's
    # OWN warnings (018, T027 — the boundary's malformed/migrated-warned
    # cases) travel through its own `warnings` key instead, since they are
    # per-ticket rather than per-run. Absent when no `task` role resolved.
    $taskTypeForLabel = [string](Get-JiraPlanProp $ctx 'task_type_id')
    $taskLabel = ''
    if ($provenanceLabel -ne '' -and $taskTypeForLabel -ne '') {
        $taskDecision = Get-JiraPlanApplyLabelDecision -DefaultableByType $defaultableByType -TypeId $taskTypeForLabel `
            -TypeName (Resolve-JiraPlanTypeName $taskTypeForLabel) -ProjectKey $project -Provenance $provenanceLabel -Slug $slug
        $taskLabel = $taskDecision.Label
        if ($taskDecision.Warning -ne '') { $planWarnings.Add($taskDecision.Warning) }
    }

    $parentResult = Get-JiraPlanWriteSetParent -DocObject $doc -CtxObject $ctx -Base $base -ParentLabel $parentLabel | ConvertFrom-Json -Depth 100
    $parent = $parentResult.action
    foreach ($w in @($parentResult.warnings)) { $planWarnings.Add([string]$w) }
    $result = [ordered]@{ parent = $parent; stories = $actions }
    if ($taskLabel -ne '') { $result['task_label'] = $taskLabel }
    if ($planWarnings.Count -gt 0) { $result['warnings'] = $planWarnings }
    # 022, data-model.md §4: present only when checklist mode was active
    # this run, so a subtask-mode or unrecorded run stays byte-for-byte
    # unchanged (FR-002).
    if ($checklistMode -eq 'checklist') {
        $result['checklist_counts'] = [ordered]@{ created = $clCreated; updated = $clUpdated; unchanged = $clUnchanged; entries_completed = $clEntriesCompleted }
    }
    return (ConvertTo-JiraJsonValue $result)
}

function Get-JiraPlanWriteSetParent {
    <#
    .SYNOPSIS
      The parent half of Get-JiraPlanWriteSet's return shape (Phase 5, US2,
      T072/T076). Mirror of _plan_writes_parent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $DocObject, [Parameter(Mandatory)] $CtxObject, [Parameter(Mandatory)] [string] $Base, [string] $ParentLabel = '')
    $doc = $DocObject
    $ctx = $CtxObject
    $parentType = [string](Get-JiraPlanProp $ctx 'parent_type_id')
    $project = [string](Get-JiraPlanProp (Get-JiraPlanProp $doc 'routing') 'project_key')
    $epic = Get-JiraPlanProp $doc 'epic'
    $epicTitle = [string](Get-JiraPlanProp $epic 'title')
    $epicLocalId = [string](Get-JiraPlanProp $epic 'local_id')
    $epicJson = ConvertTo-JiraJsonValue $epic

    $parentKey = [string](Get-JiraPlanProp $ctx 'parent_key')
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($parentKey -eq '') {
        # CREATE: no parent recognised yet. 011, research R2: same
        # field_defaults map the story branch reads, scoped to the parent
        # type by the shared builder itself. Every ticket the mirror creates
        # now carries the boundary from its first byte (018, T027,
        # FR-006/FR-010) — a creation never warns.
        $epicAdf = (ConvertTo-JiraManagedAdfDocument -ContentJson $epicJson | ConvertFrom-Json -Depth 100).doc
        $fieldDefaultsProp = Get-JiraPlanProp $ctx 'field_defaults'
        $fieldDefaultsJson = if ($null -eq $fieldDefaultsProp) { '' } else { ConvertTo-JiraJsonValue $fieldDefaultsProp }
        $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $epicTitle -IssueTypeId $parentType -FieldDefaultsByTypeJson $fieldDefaultsJson -Provenance $ParentLabel | ConvertFrom-Json
        $fields = [ordered]@{}
        foreach ($p in $baseFields.PSObject.Properties) { $fields[$p.Name] = $p.Value }
        $fields['description'] = $epicAdf
        # 018, T049, contracts/summary-record.md §2: a creation's payload
        # always carries a summary, so it always establishes the record.
        $identityStamp = [ordered]@{ origin = 'bridge'; role = 'parent'; summary = $epicTitle }
        $action = [ordered]@{ method = 'POST'; url = "$Base/rest/api/3/issue"; body = [ordered]@{ fields = $fields }; local_id = $epicLocalId; role = 'parent'; identity_stamp = $identityStamp }
        return (ConvertTo-JiraJsonValue ([ordered]@{ action = $action; warnings = $warnings }))
    }

    # A recognised parent: the managed-panel path is now UNCONDITIONAL (018,
    # T027) — every recognised parent's description is spliced through the
    # origin-independent resolution (contract §3), so human prose above the
    # boundary survives (FR-007) on the parent exactly as on a story.
    $current = Get-JiraPlanProp $ctx 'parent_current'

    $existing = Get-JiraPlanProp $current 'description'
    $existingJson = if ($null -eq $existing) { '{}' } else { ConvertTo-JiraJsonValue $existing }
    # 019: hoisted above the render call — this port reads $parentOrigin only
    # later, at the summary-drift branch (research R6, the ordering hazard
    # that exists only here).
    $parentOriginForRender = [string](Get-JiraPlanProp $ctx 'parent_origin')
    $renderJson = ConvertTo-JiraManagedAdfDocument -ContentJson $epicJson -ExistingJson $existingJson -Origin $parentOriginForRender
    $fieldResult = Get-JiraApplyManagedField -RenderJson $renderJson -Label $parentKey | ConvertFrom-Json -Depth 100
    if ([string]$fieldResult.warning -ne '') { $warnings.Add([string]$fieldResult.warning) }
    $epicAdf = $fieldResult.doc

    # Summary drift (018, T049, contracts/summary-record.md §4): decided
    # before $desiredFields is built, so an omission never reaches the
    # payload (mirror of the story branch).
    $currentSummary = [string](Get-JiraPlanProp $current 'summary')
    $recordedSummary = [string](Get-JiraPlanProp $ctx 'parent_last_summary')
    $onDriftMode = [string](Get-JiraPlanProp $ctx 'on_drift')
    if ($onDriftMode -eq '') { $onDriftMode = 'abort' }
    $summaryDecision = Get-JiraPlanSummaryDriftStatus -CurrentSummary $currentSummary -RecordedSummary $recordedSummary -DesiredSummary $epicTitle -OnDrift $onDriftMode
    $finalSummary = $summaryDecision.summary
    $identityStamp = $null
    if ([string]::IsNullOrEmpty($finalSummary)) {
        $warnings.Add("reconcile: ticket $parentKey diverges from the specification on `"summary`" — a human appears to have renamed it since the last write; nothing was sent. Pass --on-drift=proceed to restore the specification's title.")
    }

    $desiredFields = [ordered]@{}
    if ($null -ne $epicAdf) { $desiredFields['description'] = $epicAdf }
    if (-not [string]::IsNullOrEmpty($finalSummary)) {
        $desiredFields['summary'] = $finalSummary
        $parentOrigin = [string](Get-JiraPlanProp $ctx 'parent_origin')
        if ([string]::IsNullOrEmpty($parentOrigin)) { $parentOrigin = 'bridge' }
        $identityStamp = [ordered]@{ origin = $parentOrigin; role = 'parent'; summary = $finalSummary }
    }

    # Provenance label union (017, contract §2/§3), on the recognised-parent
    # branch — same union rule as the story branch, folded into
    # $desiredFields BEFORE the zero-churn comparison below so a settled
    # parent's label participates in it exactly like every other field.
    if ($ParentLabel -ne '') {
        # @() around a $null property wraps it into a ONE-element array
        # holding $null, not an empty array — a parent with no current
        # labels would otherwise union in a spurious "" label.
        $existingParentLabels = @()
        if ($null -ne $current) {
            $existingParentLabelsRaw = Get-JiraPlanProp $current 'labels'
            $existingParentLabels = if ($null -eq $existingParentLabelsRaw) { @() } else { @($existingParentLabelsRaw) }
        }
        $labels = [string[]]@(@($existingParentLabels) + @($ParentLabel) | ForEach-Object { [string]$_ } | Select-Object -Unique)
        [System.Array]::Sort($labels, [System.StringComparer]::Ordinal)
        $desiredFields['labels'] = $labels
    }

    $curRest = [ordered]@{}
    if ($null -ne $current) { foreach ($p in $current.PSObject.Properties) { if ($p.Name -ne 'description') { $curRest[$p.Name] = $p.Value } } }
    $desRest = [ordered]@{}; foreach ($k in $desiredFields.Keys) { if ($k -ne 'description') { $desRest[$k] = $desiredFields[$k] } }

    if ($null -eq $current) {
        $status = 'changed'
    }
    else {
        $descSt = 'unchanged'
        if ($desiredFields.Contains('description')) {
            $curDesc = Get-JiraPlanProp $current 'description'; if ($null -eq $curDesc) { $curDesc = [ordered]@{} }
            $newDesc = $desiredFields['description']
            $descSt = Get-JiraManagedDescriptionStatus -CurrentDescJson (ConvertTo-JiraJsonValue $curDesc) -NewDescJson (ConvertTo-JiraJsonValue $newDesc)
        }
        $otherSt = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $curRest) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desRest)
        $status = if ($descSt -eq 'unchanged' -and $otherSt -eq 'unchanged') { 'unchanged' } else { 'changed' }
    }

    if ($status -eq 'unchanged') { return (ConvertTo-JiraJsonValue ([ordered]@{ action = $null; warnings = $warnings })) }
    $action = [ordered]@{ method = 'PUT'; url = "$Base/rest/api/3/issue/$parentKey"; body = [ordered]@{ fields = $desiredFields }; role = 'parent' }
    if ($null -ne $identityStamp) { $action['identity_stamp'] = $identityStamp }
    return (ConvertTo-JiraJsonValue ([ordered]@{ action = $action; warnings = $warnings }))
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
    param(
        [Parameter(Mandatory)] [string] $DocJson,
        [Parameter(Mandatory)] [string] $ContextJson,
        [string] $TaskLabel = ''
    )
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
    $warnings = [System.Collections.Generic.List[string]]::new()
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

            if ($ticket -eq '') {
                if ($project -eq '' -or $taskType -eq '') {
                    throw "plan_writes_tasks: refusing to assemble a creation for `"$tid`" with no project or issue type (zero writes)"
                }
                # Every ticket the mirror creates now carries the boundary
                # from its first byte (018, T027, FR-006/FR-010) — a
                # creation never warns.
                $adf = (ConvertTo-JiraManagedTaskAdfDocument -TaskJson $taskJson | ConvertFrom-Json -Depth 100).doc
                $baseFields = Get-JiraCreateFieldsBase -ProjectKey $project -Summary $summary -IssueTypeId $taskType -FieldDefaultsByTypeJson $fieldDefaultsJson -Provenance $TaskLabel | ConvertFrom-Json
                $fields = [ordered]@{}
                foreach ($p in $baseFields.PSObject.Properties) { $fields[$p.Name] = $p.Value }
                $fields['description'] = $adf
                $fields['parent'] = [ordered]@{ key = '<resolved at apply time>' }
                # 018, T049, contracts/summary-record.md §2: a creation's
                # payload always carries a summary, so it always
                # establishes the record.
                $identityStamp = [ordered]@{ origin = 'bridge'; story = $tid; role = 'task'; summary = $summary }
                $actions.Add([ordered]@{ method = 'POST'; url = "$base/rest/api/3/issue"; body = [ordered]@{ fields = $fields }; local_id = $tid; parent_local_id = $storyLocalId; role = 'task'; identity_stamp = $identityStamp })
            }
            else {
                $current = Get-JiraPlanProp $ticketCurrent $tid

                # The managed-panel path is now UNCONDITIONAL (018, T027):
                # every recognised sub-task's description is spliced through
                # the origin-independent resolution (contract §3), so human
                # prose above the boundary survives (FR-007) on the task
                # tier exactly as on a story or the parent.
                $existing = Get-JiraPlanProp $current 'description'
                $existingJson = if ($null -eq $existing) { '{}' } else { ConvertTo-JiraJsonValue $existing }
                # 019: hoisted above the render call — this port reads
                # $taskOrigins only later, at the identity-stamp branch
                # (research R6, the ordering hazard that exists only here).
                $taskOriginsForRender = Get-JiraPlanProp $ctx 'ticket_origins'
                $taskOriginForRender = [string](Get-JiraPlanProp $taskOriginsForRender $tid)
                $renderJson = ConvertTo-JiraManagedTaskAdfDocument -TaskJson $taskJson -ExistingJson $existingJson -Origin $taskOriginForRender
                $fieldResult = Get-JiraApplyManagedField -RenderJson $renderJson -Label $ticket | ConvertFrom-Json -Depth 100
                if ([string]$fieldResult.warning -ne '') { $warnings.Add([string]$fieldResult.warning) }
                $adf = $fieldResult.doc

                # Summary drift (018, T049, contracts/summary-record.md
                # §4/§5): decided before $desired is built. The desired
                # value is the task tier's own (possibly shortened) summary
                # — the exact string a payload carries is what the record
                # keeps (contract §2).
                $currentSummary = [string](Get-JiraPlanProp $current 'summary')
                $ticketLastSummaries = Get-JiraPlanProp $ctx 'ticket_last_summaries'
                $recordedSummary = [string](Get-JiraPlanProp $ticketLastSummaries $tid)
                $onDriftMode = [string](Get-JiraPlanProp $ctx 'on_drift')
                if ($onDriftMode -eq '') { $onDriftMode = 'abort' }
                $summaryDecision = Get-JiraPlanSummaryDriftStatus -CurrentSummary $currentSummary -RecordedSummary $recordedSummary -DesiredSummary $summary -OnDrift $onDriftMode
                $finalSummary = $summaryDecision.summary
                $summaryChanged = $false
                if ([string]::IsNullOrEmpty($finalSummary)) {
                    $warnings.Add("reconcile: ticket $ticket diverges from the specification on `"summary`" — a human appears to have renamed it since the last write; nothing was sent. Pass --on-drift=proceed to restore the specification's title.")
                }
                elseif ($finalSummary -ne $currentSummary) {
                    $summaryChanged = $true
                }

                $desired = [ordered]@{}
                if ($null -ne $adf) { $desired['description'] = $adf }
                if (-not [string]::IsNullOrEmpty($finalSummary)) { $desired['summary'] = $finalSummary }
                # Provenance label union (017 FR-009/FR-011/FR-012/FR-013 on
                # the task tier): the desired list is the sub-task's CURRENT
                # labels plus the provenance token, both unique-normalised —
                # at once the merge rule, the one-time back-fill trigger, and
                # the zero-churn rule, because the comparison below is over
                # the desired keys.
                if ($TaskLabel -ne '') {
                    # @() around a $null property wraps it into a ONE-element
                    # array holding $null, not an empty array — a sub-task
                    # with no current labels (the back-fill case) would
                    # otherwise union in a spurious "" label.
                    $curLabelsProp = if ($null -ne $current) { Get-JiraPlanProp $current 'labels' } else { $null }
                    $curLabels = if ($null -eq $curLabelsProp) { @() } else { @($curLabelsProp) }
                    $taskLabels = [string[]]@(@($curLabels) + @($TaskLabel) | ForEach-Object { [string]$_ } | Select-Object -Unique)
                    # Ordinal, like the story branch: jq's `unique` sorts by
                    # byte, and Sort-Object's culture-aware order would
                    # diverge from it (FR-027).
                    [System.Array]::Sort($taskLabels, [System.StringComparer]::Ordinal)
                    $desired['labels'] = $taskLabels
                }

                # Churn (FR-009): the description key, when present, is
                # decided on its managed section alone — an edit confined to
                # the human prefix is not churn. Every other field compares
                # as before this feature.
                # `summary` is excluded from the generic field-diff below
                # and merged back in separately (summaryChanged), exactly
                # like description — its own divergence is reported
                # through the summary record's warning above, not the
                # generic per-field one.
                $curRest = [ordered]@{}
                if ($null -ne $current) { foreach ($p in $current.PSObject.Properties) { if ($p.Name -ne 'description' -and $p.Name -ne 'summary') { $curRest[$p.Name] = $p.Value } } }
                $desRest = [ordered]@{}; foreach ($k in $desired.Keys) { if ($k -ne 'description' -and $k -ne 'summary') { $desRest[$k] = $desired[$k] } }
                $descSt = 'unchanged'
                if ($desired.Contains('description') -and $null -ne $current) {
                    $curDesc = Get-JiraPlanProp $current 'description'; if ($null -eq $curDesc) { $curDesc = [ordered]@{} }
                    $descSt = Get-JiraManagedDescriptionStatus -CurrentDescJson (ConvertTo-JiraJsonValue $curDesc) -NewDescJson (ConvertTo-JiraJsonValue $desired['description'])
                }
                if ($null -eq $current) {
                    $st = 'changed'
                }
                else {
                    $otherSt = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $curRest) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desRest)
                    $st = if ($descSt -eq 'unchanged' -and $otherSt -eq 'unchanged' -and -not $summaryChanged) { 'unchanged' } else { 'changed' }
                }
                if ($st -eq 'unchanged') { continue }

                # FR-019: only the fields that differ are written. FR-020: the same
                # comparison names the divergent field(s) in a warning before the
                # overwrite — $current -eq $null means no prior state was read at
                # all, so nothing narrower than the full desired set can be sent,
                # and there is no known field to name. The description field's
                # own divergence is reported through the boundary's warnings
                # above, not this per-field one, so it is excluded here and
                # merged back in separately when it churned.
                $filtered = $desired
                $warning = ''
                if ($null -ne $current) {
                    $filtered = [ordered]@{}
                    $diverged = [System.Collections.Generic.List[string]]::new()
                    foreach ($key in $desRest.Keys) {
                        $curMember = if ($current -is [System.Management.Automation.PSCustomObject]) { $current.PSObject.Properties[$key] } else { $null }
                        $curVal = if ($null -eq $curMember) { $null } else { $curMember.Value }
                        $desCanon = ConvertTo-JiraJsonValue $desRest[$key]
                        $curCanon = if ($null -eq $curVal) { 'null' } else { ConvertTo-JiraJsonValue $curVal }
                        if (-not [System.String]::Equals($desCanon, $curCanon, [System.StringComparison]::Ordinal)) {
                            $filtered[$key] = $desRest[$key]
                            # `labels` is excluded from the divergence naming
                            # (017 FR-011): a sub-task that merely lacks its
                            # provenance label has not diverged from the
                            # specification, and back-filling it must stay as
                            # silent on the task tier as on the story tier.
                            if ($key -ne 'labels') { $diverged.Add($key) }
                        }
                    }
                    if ($descSt -eq 'changed') { $filtered['description'] = $desired['description'] }
                    if ($summaryChanged) { $filtered['summary'] = $finalSummary }
                    if ($diverged.Count -gt 0) {
                        $warning = "$ticket diverges from the specification on `"$($diverged -join ', ')`"; only the differing field(s) will be written"
                    }
                }

                # identity_stamp (018, T049, contracts/summary-record.md
                # §2): the record is written only after a payload that
                # ACTUALLY carries `summary` — decided from $filtered, the
                # payload this action will really send.
                $identityStamp = $null
                if ($filtered.Contains('summary')) {
                    $taskOrigins = Get-JiraPlanProp $ctx 'ticket_origins'
                    $taskOrigin = [string](Get-JiraPlanProp $taskOrigins $tid)
                    if ([string]::IsNullOrEmpty($taskOrigin)) { $taskOrigin = 'bridge' }
                    $identityStamp = [ordered]@{ origin = $taskOrigin; story = $tid; role = 'task'; summary = $finalSummary }
                }

                $action = [ordered]@{ method = 'PUT'; url = "$base/rest/api/3/issue/$ticket"; body = [ordered]@{ fields = $filtered }; role = 'task' }
                if ($warning -ne '') { $action['warning'] = $warning }
                if ($null -ne $identityStamp) { $action['identity_stamp'] = $identityStamp }
                $actions.Add($action)
            }
        }
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{ actions = $actions; warnings = $warnings }))
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

function Get-JiraSummaryNormalized {
    <#
    .SYNOPSIS
      Contract summary-record.md §3: strip leading/trailing whitespace, then
      collapse every internal run of whitespace to a single space. For
      COMPARISON only — never applied to a value recorded or sent. Mirror
      of _summary_normalise.
    #>
    param([string] $Value)
    return ([regex]::Replace($Value, '\s+', ' ')).Trim()
}

function Get-JiraPlanSummaryDriftStatus {
    <#
    .SYNOPSIS
      018, T049, contracts/summary-record.md §4: the whole decision table,
      collapsed into one function every tier calls identically. Mirror of
      plan_summary_drift_status. Returns {summary: <string>|$null}: the
      value to send (present), or $null when the field must be OMITTED —
      the caller's own signal to skip this field and emit exactly one
      warning naming the ticket.
    #>
    [CmdletBinding()]
    param(
        [string] $CurrentSummary,
        [string] $RecordedSummary = '',
        [Parameter(Mandatory)] [string] $DesiredSummary,
        [string] $OnDrift = 'abort'
    )
    if ([string]::IsNullOrEmpty($RecordedSummary)) {
        return [pscustomobject]@{ summary = $DesiredSummary }
    }
    $nc = Get-JiraSummaryNormalized $CurrentSummary
    $nr = Get-JiraSummaryNormalized $RecordedSummary
    if ($nc -eq $nr) {
        return [pscustomobject]@{ summary = $DesiredSummary }
    }
    $nd = Get-JiraSummaryNormalized $DesiredSummary
    if ($nc -eq $nd) {
        return [pscustomobject]@{ summary = $DesiredSummary }
    }
    if ($OnDrift -eq 'proceed') {
        return [pscustomobject]@{ summary = $DesiredSummary }
    }
    return [pscustomobject]@{ summary = $null }
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

function Get-JiraLifecycleRoleOrder {
    # 023, data-model.md §1: `order` is now PER ROLE — a specification and a
    # story on different workflows are never compared against each other's
    # step order (contract role-lifecycle-config.md §5 I1). `return ,$list`,
    # never a bare `return $list`: an empty (or single-element) IEnumerable
    # returned bare auto-unrolls in the pipeline and the caller captures
    # $null instead of an empty collection (the same hazard Recognition.psm1's
    # Get-JiraRecognitionNormalizedLabel guards against).
    param($OrderObj, [string] $Role)
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $OrderObj) { return , $list }
    $roleVal = Get-JiraPlanProp $OrderObj $Role
    if ($null -ne $roleVal) { foreach ($o in @($roleVal)) { $list.Add([string]$o) } }
    return , $list
}

function Get-JiraLifecycleBlockers {
    # @(Get-JiraPlanProp ...) on a missing property yields @($null) (Count 1,
    # not 0) — PowerShell's array-cast of $null is a one-element array, never
    # an empty one. This normalises that to a genuinely empty array. `return
    # ,@(...)`, never bare: an empty (or single-element) array returned bare
    # auto-unrolls in the pipeline and the caller captures $null (or the
    # scalar) instead of an array.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of blocking links it derives; a singular name would misdescribe the value.')]
    param($Tk)
    $val = Get-JiraPlanProp $Tk 'blockers'
    if ($null -eq $val) { return , @() }
    return , @($val)
}

function Get-JiraTransitionWarning {
    <#
    .SYNOPSIS
      Contract transition-resolution.md §4's verbatim wording for the three
      non-move outcomes (never called for "move"). Mirror of
      _plan_transition_warning.
    #>
    param($Outcome, [string] $Role, [string] $Key, [string] $Declared, [string] $Current)
    $roleLabel = if ($Role.Length -gt 0) { $Role.Substring(0, 1).ToUpperInvariant() + $Role.Substring(1) } else { $Role }
    $kind = [string](Get-JiraPlanProp $Outcome 'outcome')
    switch ($kind) {
        'ambiguous' {
            $cands = @(Get-JiraPlanProp $Outcome 'candidates')
            $names = ($cands | ForEach-Object { "$($_.name) ($($_.id))" }) -join ', '
            return "$roleLabel ticket $Key was not moved to `"$Declared`": $($cands.Count) transitions land on it ($names). The bridge invents no preference — perform the one you want by hand, or narrow the workflow."
        }
        'gated' {
            $field = [string](Get-JiraPlanProp (Get-JiraPlanProp $Outcome 'gated_field') 'logical_name')
            return "$roleLabel ticket $Key was not moved to `"$Declared`": completing that transition requires `"$field`", which the bridge does not hold and never guesses. Set it by hand, then reconcile."
        }
        'unreachable' {
            $reachable = @(Get-JiraPlanProp $Outcome 'reachable')
            if ($reachable.Count -gt 0) {
                $rl = ($reachable -join ', ')
                return "$roleLabel ticket $Key was not moved to `"$Declared`": no transition from `"$Current`" lands on it. Reachable from here: $rl. Move it by hand, or map this event to one of those."
            }
            return "$roleLabel ticket $Key was not moved to `"$Declared`": no transition from `"$Current`" is available at all. Move it by hand, or map this event to a reachable step."
        }
    }
    return ''
}

function Get-JiraLifecyclePlan {
    <#
    .SYNOPSIS
      Fold the US6 lifecycle-safety rules over the planned content actions and emit
      the final action set plus warnings/notes. Mirror of plan_lifecycle. PURE apart
      from the transitions read: content-actions[i] corresponds to doc.stories[i].
      023, contract transition-resolution.md: the due set (a `transition` decision
      with no already-supplied transition_id) is resolved by ONE call to
      Import-JiraTransitions for the whole set, never per ticket. See plan_apply.sh
      for the full contract (zero-churn FR-030, drift FR-031/034/035, Flagged
      FR-036, human links FR-037).

      ParentActionJson (023, research R6): the parent's OWN content action, as a
      JSON string — 'null' or omitted when there is none. When present alongside a
      `parent_local_id` in LifecycleContextJson, the parent gets ONE more entry in
      the SAME per-ticket body below (zero-churn drop, Flagged check, drift
      decision, transition) — never a duplicated code path (contract §5 U8). The
      parent's own content action is never re-emitted from here: the caller already
      holds it and decides separately whether to keep it.

      A transitions-read failure (contract §2 F2) throws — fail-closed for the
      WHOLE specification: the content actions already gathered are discarded,
      never returned. The exception's message names the failing key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ContentActionsJson,
        [Parameter(Mandatory)] [string] $NeutralDocJson,
        [Parameter(Mandatory)] [string] $LifecycleContextJson,
        [string] $ParentActionJson = 'null'
    )
    # Lists never unwrap to a scalar (a 1-element @() flowing through an if/else
    # expression collapses under StrictMode, and its .Count then throws).
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($ContentActionsJson | ConvertFrom-Json -Depth 100)) { $actions.Add($x) }
    $doc = $NeutralDocJson | ConvertFrom-Json -Depth 100
    $lc = $LifecycleContextJson | ConvertFrom-Json -Depth 100
    $parentAction = $ParentActionJson | ConvertFrom-Json -Depth 100

    $onDrift = [string](Get-JiraPlanProp $lc 'on_drift'); if ($onDrift -eq '') { $onDrift = 'abort' }
    $base = [string](Get-JiraPlanProp $lc 'base_url')
    $orderVal = Get-JiraPlanProp $lc 'order'
    $tickets = Get-JiraPlanProp $lc 'tickets'
    $storyProp = Get-JiraPlanProp $doc 'stories'

    # Each entry: Sid, Action, Method, Tk, IsParent.
    $entries = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $storyProp) {
        $stories = @($storyProp)
        for ($i = 0; $i -lt $stories.Count; $i++) {
            if ($i -ge $actions.Count) { continue }
            $sid = [string]$stories[$i].local_id
            $action = $actions[$i]
            $tk = Get-JiraPlanProp $tickets $sid
            if ($null -eq $tk) { $tk = [pscustomobject]@{} }
            $entries.Add([pscustomobject]@{ Sid = $sid; Action = $action; Method = [string]$action.method; Tk = $tk; IsParent = $false })
        }
    }

    # 023, research R6: the parent gets one more entry in the SAME list, so the
    # per-ticket body below runs over it unchanged (contract §5 U8). Fix: the
    # parent has no pending CONTENT write on a run where its content is
    # unchanged ($parentAction is $null then) — that must never suppress its
    # own lifecycle-safety evaluation, exactly as a story with no content
    # change still reaches Get-JiraDriftDecision. A placeholder stands in
    # only when there is no real action, never treated as a content write
    # (IsParent below already excludes the parent from $kept
    # unconditionally).
    $parentLid = [string](Get-JiraPlanProp $lc 'parent_local_id')
    if ($parentLid -ne '') {
        $ptk = Get-JiraPlanProp $tickets $parentLid
        if ($null -eq $ptk) { $ptk = [pscustomobject]@{} }
        $parentEntryAction = if ($null -ne $parentAction) { $parentAction } else { [pscustomobject]@{} }
        # Get-JiraPlanProp, never a direct .method: an empty PSCustomObject
        # placeholder has no `method` property, and StrictMode throws on a
        # direct access to a property that does not exist.
        $entries.Add([pscustomobject]@{ Sid = $parentLid; Action = $parentEntryAction; Method = [string](Get-JiraPlanProp $parentEntryAction 'method'); Tk = $ptk; IsParent = $true })
    }

    $kept = [System.Collections.Generic.List[object]]::new()
    $warns = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $due = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $entries) {
        $sid = $entry.Sid
        $action = $entry.Action
        if ($null -eq $action) { continue }
        $method = $entry.Method
        $tk = $entry.Tk

        $dropContent = $false

        # --- Zero churn: drop an unchanged UPDATE -----------------------------
        # The managed-panel path is now UNCONDITIONAL (018, T027): every
        # recognised ticket's description churn is decided on its managed
        # section alone (FR-009), regardless of origin.
        if ($method -eq 'PUT') {
            $current = Get-JiraPlanProp $tk 'current'
            if ($null -ne $current) {
                $desObj = $action.body.fields
                $descSt = 'unchanged'
                $desiredHasDescription = ($desObj -is [System.Management.Automation.PSCustomObject]) -and ($null -ne $desObj.PSObject.Properties['description'])
                if ($desiredHasDescription) {
                    $curDesc = Get-JiraPlanProp $current 'description'; if ($null -eq $curDesc) { $curDesc = [pscustomobject]@{} }
                    $newDesc = Get-JiraPlanProp $desObj 'description'; if ($null -eq $newDesc) { $newDesc = [pscustomobject]@{} }
                    $descSt = Get-JiraManagedDescriptionStatus -CurrentDescJson (ConvertTo-JiraJsonValue $curDesc) -NewDescJson (ConvertTo-JiraJsonValue $newDesc)
                }
                $curRest = [ordered]@{}; foreach ($p in $current.PSObject.Properties) { if ($p.Name -ne 'description') { $curRest[$p.Name] = $p.Value } }
                $desRest = [ordered]@{}; foreach ($p in $desObj.PSObject.Properties) { if ($p.Name -ne 'description') { $desRest[$p.Name] = $p.Value } }
                $otherSt = Get-JiraIdempotentFieldStatus -CurrentFieldsJson (ConvertTo-JiraJsonValue $curRest) -DesiredFieldsJson (ConvertTo-JiraJsonValue $desRest)
                if ($descSt -eq 'unchanged' -and $otherSt -eq 'unchanged') { $dropContent = $true }
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
        $role = [string](Get-JiraPlanProp $tk 'role')
        if ($role -eq '') { $role = if ($entry.IsParent) { 'specification' } else { 'story' } }
        $roleOrder = Get-JiraLifecycleRoleOrder -OrderObj $orderVal -Role $role

        if ($status -ne '' -and $target -ne '' -and $status -ne $target) {
            if ($flagged) {
                $warns.Add("ticket `"$sid`" carries the Flagged (impediment) marker; its transition is withheld and the flag is left untouched")
            }
            else {
                $di = [ordered]@{ current_status = $status; current_category = $category; target_status = $target; order = $roleOrder.ToArray(); on_drift = $onDrift } | ConvertTo-Json -Compress -Depth 10
                $dec = Get-JiraDriftDecision -InputJson $di | ConvertFrom-Json -Depth 100
                foreach ($w in @($dec.warnings)) { $warns.Add([string]$w) }
                if ($dec.content_writes -eq $false) { $dropContent = $true }
                if ([string]$dec.decision -eq 'transition' -and $key -ne '') {
                    if ($transitionId -ne '') {
                        # The SPEC_KIT_JIRA_LIFECYCLE test seam already supplies an
                        # id directly — unchanged from before this feature;
                        # resolution is never consulted for a ticket that already
                        # has one.
                        $tres = Get-JiraTransitionAction -BaseUrl $base -Key $key -TransitionId $transitionId -Blockers (Get-JiraLifecycleBlockers $tk) -Label $sid
                        $kept.Add($tres.Action)
                        if ($tres.Note) { $notes.Add($tres.Note) }
                    }
                    else {
                        $due.Add([pscustomobject]@{ Sid = $sid; Key = $key; Target = $target; Status = $status; Role = $role; Blockers = (Get-JiraLifecycleBlockers $tk) })
                    }
                }
            }
        }

        if (-not $dropContent -and -not $entry.IsParent) { $kept.Add($action) }
    }

    # Resolution (023, contract transition-resolution.md §1/§2): the read is
    # issued only for the due set assembled above and ONCE for the whole set,
    # never per ticket. A failure fails closed for the WHOLE specification: the
    # content actions already gathered above are discarded (never returned),
    # not only the moves (contract §2 F2).
    if ($due.Count -gt 0) {
        $dueKeys = @($due | ForEach-Object { $_.Key })
        $rc = Import-JiraTransitions -Key $dueKeys
        if ($rc -ne 0) {
            throw "$($dueKeys[0])'s available moves could not be read (zero writes)"
        }
        foreach ($d in $due) {
            $record = Get-JiraTransitionRecord -Key $d.Key
            if ($null -eq $record) { continue }
            $outcome = Resolve-JiraTransition -RecordJson $record -DeclaredStep $d.Target | ConvertFrom-Json -Depth 100
            if ([string]$outcome.outcome -eq 'move') {
                $tres = Get-JiraTransitionAction -BaseUrl $base -Key $d.Key -TransitionId ([string]$outcome.transition_id) -Blockers $d.Blockers -Label $d.Sid
                $kept.Add($tres.Action)
                if ($tres.Note) { $notes.Add($tres.Note) }
            }
            else {
                $warns.Add((Get-JiraTransitionWarning -Outcome $outcome -Role $d.Role -Key $d.Key -Declared $d.Target -Current $d.Status))
            }
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

function Get-JiraApplyPrivacyProjection {
    <#
    .SYNOPSIS
      018, T019, contract §5, FR-024a. Mirror of _plan_apply_privacy_projection.
      The projection of a payload handed to the pre-write privacy scan,
      excluding the description's preserved human prefix. The guard's own
      rules (PrivacyGuard.psm1) are untouched; only what reaches them changes.
      The preserved prefix is a verbatim round-trip — read from this ticket
      and written back to it — so it cannot carry anything into the tracker
      the tracker does not already hold. Splits the description's content at
      the managed-panel marker (structural, not configurable) and scans only
      the managed portion (the marker node onward) plus every other field,
      exactly as before this feature. A payload with no description field, or
      a description with no content array, is returned unchanged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BodyJson)
    $body = $BodyJson | ConvertFrom-Json -Depth 100
    $fields = Get-JiraPlanProp $body 'fields'
    $desc = Get-JiraPlanProp $fields 'description'
    $content = Get-JiraPlanProp $desc 'content'
    if ($null -eq $content) { return $BodyJson }
    $contentJson = ConvertTo-Json -InputObject @($content) -Depth 100 -Compress
    $split = Split-JiraManagedSectionPanel -Marker (Get-JiraManagedMarker) -ContentJson $contentJson | ConvertFrom-Json -Depth 100
    $managed = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($split.managed)) { $managed.Add($n) }
    $body.fields.description.content = $managed
    return (ConvertTo-Json -InputObject $body -Depth 100 -Compress)
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
        $code = Test-JiraPrivacyBlock -Payload (Get-JiraApplyPrivacyProjection -BodyJson $bodyText) -KnownCoordinatesJson $coords -AllowlistJson $allow
        if ($code -ne 0) { return [int]$code }
    }

    # (2) Write pass — all payloads cleared; perform each write in order. A
    # fail-closed transport result (exit >= 2) ABORTS the remaining writes for this
    # spec and is returned verbatim — no further mutation once a read/write is
    # unreliable (FR-032, monotonic escalation).
    $worst = 0
    foreach ($a in $actions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -ne $bodyObj) { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 } else { $null }
        $r = Invoke-JiraApplyWrite -Method $a.method -Url $a.url -BodyJson $bodyText
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

function Invoke-JiraApplyWrite {
    <#
    .SYNOPSIS
      The single write primitive every write loop in this module goes
      through. 018, T069, contract managed-description §2, FR-011: on a PUT
      whose body carries a `description` field and Jira rejects it (400,
      `errors.description` present), the write is retried ONCE with
      `description` stripped from the payload and one warning is printed to
      stderr naming the ticket key — EVERY OTHER field of that ticket still
      reconciles, and the caller sees the retried result (success or
      otherwise), never the original rejection: the host's exit code is
      unaffected by a description-only rejection. A rejection that does not
      name `description`, or a non-PUT method, is left to the existing
      generic failure path untouched. Mirror of _plan_apply_write.
    #>
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Url,
        [string] $BodyJson
    )
    $r = if ($BodyJson) { Invoke-JiraRequest -Method $Method -Url $Url -Body $BodyJson } else { Invoke-JiraRequest -Method $Method -Url $Url }
    if ([int]$r.ExitCode -lt 2 -or $Method -ne 'PUT' -or [int]$r.Status -ne 400 -or -not $BodyJson) {
        return $r
    }
    $bodyObj = $null
    try { $bodyObj = $BodyJson | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
    if ($null -eq $bodyObj) { return $r }
    $fieldsMember = $bodyObj.PSObject.Properties['fields']
    if ($null -eq $fieldsMember -or $null -eq $fieldsMember.Value.PSObject.Properties['description']) {
        return $r
    }
    $errObj = $null
    try { $errObj = $r.ErrorBody | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
    $descReason = $null
    if ($null -ne $errObj) {
        $errorsMember = $errObj.PSObject.Properties['errors']
        if ($null -ne $errorsMember) {
            $descMember = $errorsMember.Value.PSObject.Properties['description']
            if ($null -ne $descMember) { $descReason = [string]$descMember.Value }
        }
    }
    if (-not $descReason) { return $r }
    $key = $Url -replace '^.*/issue/', ''
    [Console]::Error.WriteLine("reconcile: Jira rejected the description for $key — $descReason. No description was written for $key; every other field still reconciled.")
    $fieldsMember.Value.PSObject.Properties.Remove('description')
    $strippedJson = ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100
    return Invoke-JiraRequest -Method $Method -Url $Url -Body $strippedJson
}

function Invoke-JiraApplyStampIdentity {
    <#
    .SYNOPSIS
      018, T049, contracts/summary-record.md §2: stamp the identity marker
      with $Action's identity_stamp when it carries one — a no-op when it
      does not. Called after EVERY successful write (create or update), on
      every tier's every role. Mirror of _plan_apply_stamp_identity.
    #>
    param([string] $IssueKey, [string] $SpecRefJson, $Action)
    if ([string]::IsNullOrEmpty($IssueKey)) { return }
    $stampMember = $Action.PSObject.Properties['identity_stamp']
    if ($null -eq $stampMember -or $null -eq $stampMember.Value) { return }
    $stamp = $stampMember.Value
    $origin = [string](Get-JiraPlanProp $stamp 'origin'); if ($origin -eq '') { $origin = 'bridge' }
    $story = [string](Get-JiraPlanProp $stamp 'story')
    $role = [string](Get-JiraPlanProp $stamp 'role')
    $summary = [string](Get-JiraPlanProp $stamp 'summary')
    Set-JiraIdentity -IssueKey $IssueKey -SpecRefJson $SpecRefJson -Origin $origin -Story $story -Role $role -Summary $summary | Out-Null
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

      015, research R4, contract §4.2, data-model.md §5: returns
      [ordered]@{ ExitCode; Created } rather than a bare exit code — the
      structured mirror of the bash port's stdout outcome
      {"created":[{key, role, local_id}, ...]}. Created holds an entry only
      after Jira returned a key for that creation, in apply order (the parent
      first when present, then stories, then 012's tasks). On the three
      pre-write privacy-guard returns Created is empty (rule O4) — the
      object-shaped equivalent of the bash port's "empty stdout reads as zero
      created". `role` is "parent", "story", or "task"; the caller filters,
      because the task tier carries its OWN tally (counts.tasks, 012 FR-011)
      and must not inflate counts.created.
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
    $createdOut = [System.Collections.Generic.List[object]]::new()

    # (1) Pre-write gate — scan every payload, parent then stories then
    # tasks, before writing anything.
    if ($null -ne $parent) {
        $bodyObj = Get-JiraPlanProp $parent 'body'
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload (Get-JiraApplyPrivacyProjection -BodyJson $bodyText) -KnownCoordinatesJson $coords -AllowlistJson $allow
        if ($code -ne 0) { return [ordered]@{ ExitCode = [int]$code; Created = @() } }
    }
    foreach ($a in $stories) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload (Get-JiraApplyPrivacyProjection -BodyJson $bodyText) -KnownCoordinatesJson $coords -AllowlistJson $allow
        if ($code -ne 0) { return [ordered]@{ ExitCode = [int]$code; Created = @() } }
    }
    foreach ($a in $taskActions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload (Get-JiraApplyPrivacyProjection -BodyJson $bodyText) -KnownCoordinatesJson $coords -AllowlistJson $allow
        # 015 contract §4.2 (rule O4): the task sweep is the THIRD pre-write
        # guard and returns the same outcome shape as the parent's and the
        # stories' — a bare exit code here reads as $null through the caller's
        # `.ExitCode`, turning a refused write into a reported clean run.
        if ($code -ne 0) { return [ordered]@{ ExitCode = [int]$code; Created = @() } }
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
        $bodyText = if ($null -ne $bodyObj) { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 } else { $null }
        $r = Invoke-JiraApplyWrite -Method $parent.method -Url $parent.url -BodyJson $bodyText
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) {
            Write-JiraApplyRejectionReport -Method $parent.method -Url $parent.url -Action $parent -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -Result $r
            return [ordered]@{ ExitCode = $worst; Created = @($createdOut) }
        }
        if ($parent.method -eq 'POST') {
            $respObj = $null
            # A body that fails to parse is not fatal: $respObj stays $null
            # and the caller below treats a missing key as "not recorded".
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
            $parentKey = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            if ($parentKey -ne '' -and $parentLocalId -ne '') {
                $cur = if (Test-Path -LiteralPath $SpecFile) { Get-Content -Raw -LiteralPath $SpecFile } else { '' }
                if ($null -eq $cur) { $cur = '' }
                $new = Set-JiraSpecMarkerRecordTicket -Text $cur -Id $parentLocalId -Key $parentKey
                Write-JiraMarkerSpliceFile -Path $SpecFile -NewContent $new | Out-Null
                $createdOut.Add([ordered]@{ key = $parentKey; role = 'parent'; local_id = $parentLocalId })
            }
        }
        Invoke-JiraApplyStampIdentity -IssueKey $parentKey -SpecRefJson $SpecRefJson -Action $parent
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
        $bodyText = if ($null -ne $bodyObj) { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 } else { $null }
        $r = Invoke-JiraApplyWrite -Method $action.method -Url $action.url -BodyJson $bodyText
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) {
            Write-JiraApplyRejectionReport -Method $action.method -Url $action.url -Action $action -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -Result $r
            return [ordered]@{ ExitCode = $worst; Created = @($createdOut) }
        }

        if ($action.method -eq 'POST' -and ([string]$action.url).EndsWith('/issue')) {
            $respObj = $null
            # A body that fails to parse is not fatal: $respObj stays $null
            # and the caller below treats a missing key as "not recorded".
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
            $key = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            $localId = [string](Get-JiraPlanProp $action 'local_id')
            if ($key -ne '' -and $localId -ne '') {
                $cur = if (Test-Path -LiteralPath $SpecFile) { Get-Content -Raw -LiteralPath $SpecFile } else { '' }
                if ($null -eq $cur) { $cur = '' }
                $new = Set-JiraStoryMarkerRecordTicket -Text $cur -Id $localId -Key $key
                Write-JiraMarkerSpliceFile -Path $SpecFile -NewContent $new | Out-Null
                $storyKeyMap[$localId] = $key
                $createdOut.Add([ordered]@{ key = $key; role = 'story'; local_id = $localId })
            }
            Invoke-JiraApplyStampIdentity -IssueKey $key -SpecRefJson $SpecRefJson -Action $action
        }
        elseif ($action.method -eq 'PUT') {
            Invoke-JiraApplyStampIdentity -IssueKey ([string]$action.url -replace '^.*/issue/', '') -SpecRefJson $SpecRefJson -Action $action
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
        $bodyText = if ($null -ne $bodyObj) { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 } else { $null }
        $r = Invoke-JiraApplyWrite -Method $taction.method -Url $taction.url -BodyJson $bodyText
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
        if ([int]$r.ExitCode -ge 2) {
            Write-JiraApplyRejectionReport -Method $taction.method -Url $taction.url -Action $taction -DefaultableFieldsByTypeJson $DefaultableFieldsByTypeJson -Result $r
            return [ordered]@{ ExitCode = $worst; Created = @($createdOut) }
        }

        if ($taction.method -eq 'POST' -and ([string]$taction.url).EndsWith('/issue')) {
            $respObj = $null
            try { $respObj = $r.Body | ConvertFrom-Json -Depth 100 } catch { $null = $_ }
            $tKey = if ($respObj) { [string](Get-JiraPlanProp $respObj 'key') } else { '' }
            $tLocalId = [string](Get-JiraPlanProp $taction 'local_id')
            if ($tKey -ne '' -and $tLocalId -ne '' -and $TasksFile -ne '') {
                $tCur = if (Test-Path -LiteralPath $TasksFile) { Get-Content -Raw -LiteralPath $TasksFile } else { '' }
                if ($null -eq $tCur) { $tCur = '' }
                $tNew = Set-JiraTaskMarkerRecordTicket -Text $tCur -Id $tLocalId -Key $tKey
                Write-JiraMarkerSpliceFile -Path $TasksFile -NewContent $tNew | Out-Null
                $createdOut.Add([ordered]@{ key = $tKey; role = 'task'; local_id = $tLocalId })
            }
            Invoke-JiraApplyStampIdentity -IssueKey $tKey -SpecRefJson $SpecRefJson -Action $taction
        }
        elseif ($taction.method -eq 'PUT') {
            Invoke-JiraApplyStampIdentity -IssueKey ([string]$taction.url -replace '^.*/issue/', '') -SpecRefJson $SpecRefJson -Action $taction
        }
    }
    return [ordered]@{ ExitCode = $worst; Created = @($createdOut) }
}

Export-ModuleMember -Function Get-JiraApplyKnownCoordinate, Invoke-JiraApplyWriteSet, Get-JiraPlanWriteSet, Get-JiraLifecyclePlan, `
    Get-JiraManagedDescriptionStatus, Invoke-JiraApplyWriteSetWithRecognition, Get-JiraPlanResolveFieldDefault, `
    Get-JiraPlanConfirmationField, Get-JiraPlanTaskWriteSet, Get-JiraTaskLifecyclePlan, Get-JiraPlanSummaryDriftStatus, `
    Get-JiraTransitionAction, Get-JiraTransitionWarning
