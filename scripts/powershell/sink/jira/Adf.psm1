# sink/jira/Adf.psm1 — Neutral content -> Atlassian Document Format. Mirror of
# sink/jira/adf.sh (US3, T056).
#
# The ONLY place ADF node names live: the engine emits neutral content blocks and
# the sink renders them to ADF here (Constitution VIII). It maps description
# blocks to ADF nodes, acceptance_criteria to a dedicated info panel (FR-015), and
# design to a distinct Design section (FR-016). Output is byte-identical to the
# Bash port via the shared canonical serialiser (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
# The sink may consume the neutral engine (the boundary only forbids engine->sink).
Import-Module (Join-Path $PSScriptRoot '../../engine/ManagedSection.psm1') -Force

function New-JiraAdfText {
    param([string] $Text)
    return [ordered]@{ type = 'text'; text = $Text }
}

function New-JiraAdfParagraph {
    param([string] $Text)
    $content = [System.Collections.Generic.List[object]]::new()
    if ($Text -ne '') { $content.Add((New-JiraAdfText $Text)) }
    return [ordered]@{ type = 'paragraph'; content = $content }
}

function New-JiraAdfListItem {
    param([string] $Text)
    return [ordered]@{ type = 'listItem'; content = @((New-JiraAdfParagraph $Text)) }
}

function ConvertTo-JiraAdfBlockNode {
    # Render neutral content blocks to ADF nodes. Mirror of _adf_blocks_to_nodes.
    param([object[]] $Blocks)
    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $Blocks) {
        $type = $b.type
        if ($type -eq 'heading') {
            $level = if ($b.PSObject.Properties.Name -contains 'level' -and $null -ne $b.level) { [int]$b.level } else { 3 }
            $text = if ($b.PSObject.Properties.Name -contains 'text') { [string]$b.text } else { '' }
            $nodes.Add([ordered]@{ type = 'heading'; attrs = [ordered]@{ level = $level }; content = @((New-JiraAdfText $text)) })
        }
        elseif ($type -eq 'paragraph') {
            $text = if ($b.PSObject.Properties.Name -contains 'text') { [string]$b.text } else { '' }
            $nodes.Add((New-JiraAdfParagraph $text))
        }
        elseif ($type -eq 'bullet_list') {
            $items = if ($b.PSObject.Properties.Name -contains 'items' -and $null -ne $b.items) { @($b.items) } else { @() }
            $li = [System.Collections.Generic.List[object]]::new()
            foreach ($it in $items) { $li.Add((New-JiraAdfListItem ([string]$it))) }
            $nodes.Add([ordered]@{ type = 'bulletList'; content = $li })
        }
        elseif ($type -eq 'code') {
            $text = if ($b.PSObject.Properties.Name -contains 'text') { [string]$b.text } else { '' }
            $content = [System.Collections.Generic.List[object]]::new()
            if ($text -ne '') { $content.Add((New-JiraAdfText $text)) }
            $nodes.Add([ordered]@{ type = 'codeBlock'; content = $content })
        }
    }
    return $nodes
}

function New-JiraAdfGherkinPanel {
    # A dedicated info panel carrying Given/When/Then clauses. Mirror of
    # _adf_gherkin_panel. Returns $null when there is no acceptance criteria.
    param([object[]] $Acceptance)
    if (@($Acceptance).Count -eq 0) { return $null }
    $paras = [System.Collections.Generic.List[object]]::new()
    foreach ($sc in $Acceptance) {
        foreach ($g in @($sc.given)) { if ($null -ne $g) { $paras.Add((New-JiraAdfParagraph "Given $g")) } }
        foreach ($w in @($sc.when)) { if ($null -ne $w) { $paras.Add((New-JiraAdfParagraph "When $w")) } }
        foreach ($t in @($sc.then)) { if ($null -ne $t) { $paras.Add((New-JiraAdfParagraph "Then $t")) } }
    }
    return [ordered]@{ type = 'panel'; attrs = [ordered]@{ panelType = 'info' }; content = $paras }
}

function New-JiraAdfDesignNode {
    # A distinct Design section: a level-3 heading + a bullet list of guidance and
    # Figma links. Mirror of _adf_design_nodes. Returns an empty list when absent.
    param([object[]] $Design)
    $nodes = [System.Collections.Generic.List[object]]::new()
    if (@($Design).Count -eq 0) { return $nodes }
    $nodes.Add([ordered]@{ type = 'heading'; attrs = [ordered]@{ level = 3 }; content = @((New-JiraAdfText 'Design')) })
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Design) {
        if ($d.kind -eq 'figma_link') {
            $label = if ($d.PSObject.Properties.Name -contains 'label' -and $null -ne $d.label) { [string]$d.label } else { 'Figma' }
            $line = "$($label): $($d.value)"
        }
        else {
            $line = [string]$d.value
        }
        $items.Add((New-JiraAdfListItem $line))
    }
    $nodes.Add([ordered]@{ type = 'bulletList'; content = $items })
    return $nodes
}

function Get-JiraAdfContentNode {
    # The managed content-node list for a story (description body, acceptance
    # panel, Design section) — the bridge-owned managed section. Mirror of
    # _adf_content_nodes. Returns a List[object].
    param([Parameter(Mandatory)] [string] $ContentJson)
    $content = $ContentJson | ConvertFrom-Json -Depth 100

    $blocks = @()
    if ($content.PSObject.Properties.Name -contains 'description' -and $null -ne $content.description) {
        if ($content.description.PSObject.Properties.Name -contains 'blocks' -and $null -ne $content.description.blocks) {
            $blocks = @($content.description.blocks)
        }
    }
    $ac = @()
    if ($content.PSObject.Properties.Name -contains 'acceptance_criteria' -and $null -ne $content.acceptance_criteria) { $ac = @($content.acceptance_criteria) }
    $design = @()
    if ($content.PSObject.Properties.Name -contains 'design' -and $null -ne $content.design) { $design = @($content.design) }

    $docContent = [System.Collections.Generic.List[object]]::new()
    foreach ($n in (ConvertTo-JiraAdfBlockNode $blocks)) { $docContent.Add($n) }

    if ($ac.Count -gt 0) {
        $panel = New-JiraAdfGherkinPanel $ac
        $docContent.Add([ordered]@{ type = 'heading'; attrs = [ordered]@{ level = 3 }; content = @((New-JiraAdfText 'Acceptance Criteria')) })
        $docContent.Add($panel)
    }

    if ($design.Count -gt 0) {
        foreach ($n in (New-JiraAdfDesignNode $design)) { $docContent.Add($n) }
    }

    return $docContent
}

function ConvertTo-JiraAdfDocument {
    <#
    .SYNOPSIS
      Render a story's neutral content into a single canonical ADF document.
      Mirror of adf_render_description.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ContentJson)
    # @(...): PowerShell unwraps a single-item pipeline output to a bare
    # scalar, which would serialise `content` as a JSON object instead of a
    # one-element array (a real, reproduced defect — see test_adf.bats
    # "a single content node still renders...").
    $docContent = @(Get-JiraAdfContentNode -ContentJson $ContentJson)
    return (ConvertTo-JiraJsonValue ([ordered]@{ type = 'doc'; version = 1; content = $docContent }))
}

function Get-JiraManagedMarker {
    # The human-facing text delimiting the bridge-owned managed panel on a
    # human-origin ticket (FR-038). Mirror of adf_managed_marker.
    return 'Synced from spec-kit — do not edit below this line'
}

function New-JiraAdfMarkerNode {
    # The delimiter the managed section begins with: a single strong paragraph
    # carrying the marker text (must be the FIRST managed node). Mirror of
    # _adf_marker_nodes.
    $text = New-JiraAdfText (Get-JiraManagedMarker)
    $text.Add('marks', @([ordered]@{ type = 'strong' }))
    return [ordered]@{ type = 'paragraph'; content = @($text) }
}

function Resolve-JiraManagedAdfContent {
    <#
    .SYNOPSIS
      The shared contract §3 resolution engine (018, T014/T027,
      data-model.md §3), independent of what produced the managed-node
      array — the same decision serves the story/parent shape
      (Get-JiraAdfContentNode) and the task tier's own shape
      (ConvertTo-JiraAdfTaskDescription) identically. Mirror of
      _adf_resolve_managed.
    .DESCRIPTION
      - ExistingJson omitted entirely: a CREATION. No prior content to preserve;
        the result is marker ++ freshly-rendered managed nodes, with no human
        prefix and no warning (contract §3 row 5).
      - marker_count > 1 (Split-JiraManagedSectionPanel): malformed — nothing is
        written for this description (row 1). Status 'malformed', no `doc` key.
      - marker_count == 1: well-formed. The existing prefix is preserved
        verbatim above a freshly-rendered managed panel (row 2).
      - marker_count == 0: Split-JiraManagedSectionSuffix (the migration split)
        decides whether the existing content ends with the freshly rendered
        managed nodes: a match is a clean migration with nothing duplicated
        (row 3); no match preserves the WHOLE existing content as human text
        above a fresh panel and reports 'migrated-warned' (row 4) — nothing is
        ever discarded (FR-020a/FR-020b).
      Returns canonical {status:'ok'|'malformed'|'migrated-warned', doc:<adf-doc>}
      — `doc` is present on every status except 'malformed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Managed,
        [Parameter()] [AllowEmptyString()] [string] $ExistingJson = ''
    )
    $managedJson = ConvertTo-JiraJsonValue $Managed
    $marker = Get-JiraManagedMarker
    $markerNode = New-JiraAdfMarkerNode

    if ([string]::IsNullOrEmpty($ExistingJson)) {
        $docContent = [System.Collections.Generic.List[object]]::new()
        $docContent.Add($markerNode)
        foreach ($n in $Managed) { $docContent.Add($n) }
        $docObj = [ordered]@{ type = 'doc'; version = 1; content = $docContent }
        return (ConvertTo-JiraJsonValue ([ordered]@{ status = 'ok'; doc = $docObj }))
    }

    $existingContentJson = '[]'
    $existing = $ExistingJson | ConvertFrom-Json -Depth 100
    # An EMPTY PSCustomObject's .PSObject.Properties.Name throws under
    # StrictMode (the same gotcha Get-JiraPlanProp guards against) — index
    # the member collection instead.
    $contentMember = $existing.PSObject.Properties['content']
    if ($null -ne $contentMember -and $null -ne $contentMember.Value) {
        $existingContentJson = ConvertTo-JiraJsonValue @($contentMember.Value)
    }
    $split = Split-JiraManagedSectionPanel -Marker $marker -ContentJson $existingContentJson | ConvertFrom-Json -Depth 100
    $markerCount = [int]$split.marker_count

    if ($markerCount -gt 1) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ status = 'malformed' }))
    }

    $prefix = [System.Collections.Generic.List[object]]::new()
    $status = 'ok'
    if ($markerCount -eq 1) {
        foreach ($n in @($split.prefix)) { $prefix.Add($n) }
    }
    else {
        $suffix = Split-JiraManagedSectionSuffix -ManagedJson $managedJson -ContentJson $existingContentJson | ConvertFrom-Json -Depth 100
        foreach ($n in @($suffix.prefix)) { $prefix.Add($n) }
        if (-not $suffix.matched) { $status = 'migrated-warned' }
    }

    $docContent = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $prefix) { $docContent.Add($n) }
    $docContent.Add($markerNode)
    foreach ($n in $Managed) { $docContent.Add($n) }
    $docObj = [ordered]@{ type = 'doc'; version = 1; content = $docContent }
    return (ConvertTo-JiraJsonValue ([ordered]@{ status = $status; doc = $docObj }))
}

function ConvertTo-JiraManagedAdfDocument {
    <#
    .SYNOPSIS
      Origin-INDEPENDENT description resolution for the story/parent shape
      (018, T015). See Resolve-JiraManagedAdfContent for the contract §3
      decision. Mirror of adf_render_managed_description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ContentJson,
        [Parameter()] [AllowEmptyString()] [string] $ExistingJson = ''
    )
    $managed = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @(Get-JiraAdfContentNode -ContentJson $ContentJson)) { $managed.Add($n) }
    return (Resolve-JiraManagedAdfContent -Managed $managed -ExistingJson $ExistingJson)
}

function ConvertTo-JiraManagedTaskAdfDocument {
    <#
    .SYNOPSIS
      Origin-INDEPENDENT description resolution for the task tier's own
      shape (018, T027, FR-006): the sub-task's description
      (ConvertTo-JiraAdfTaskDescription — its own text, identifier, phase,
      attribution, etc., never the story or the specification, FR-009) is
      what the boundary now wraps, resolved through the SAME §3 decision as
      every other tier. Mirror of adf_render_managed_task_description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TaskJson,
        [Parameter()] [AllowEmptyString()] [string] $ExistingJson = ''
    )
    $taskDoc = ConvertTo-JiraAdfTaskDescription -TaskJson $TaskJson | ConvertFrom-Json -Depth 100
    $managed = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($taskDoc.content)) { $managed.Add($n) }
    return (Resolve-JiraManagedAdfContent -Managed $managed -ExistingJson $ExistingJson)
}

# --- The task tier (Phase 3, US1, T037; contracts/task-tier.md §4) ----------

$script:JiraAdfTaskSummaryMax = 255

function Get-JiraAdfTaskSummary {
    <#
    .SYNOPSIS
      The sub-task's summary: the task's own text, shortened
      DETERMINISTICALLY when it exceeds what the sink accepts. Mirror of
      adf_task_summary.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Title)
    $max = $script:JiraAdfTaskSummaryMax
    if ($Title.Length -le $max) { return $Title }
    return $Title.Substring(0, $max - 1) + '…'
}

function ConvertTo-JiraAdfTaskDescription {
    <#
    .SYNOPSIS
      The sub-task's description: the task's own full (untruncated) text,
      then its identifier, phase, attribution, parallel-safety, files and
      dependencies as a bullet list. Mirror of adf_render_task_description.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TaskJson)
    $task = $TaskJson | ConvertFrom-Json -Depth 100

    $title = [string]$task.title
    $taskRef = [string]$task.task_ref
    $phase = if ($task.PSObject.Properties.Name -contains 'phase' -and $null -ne $task.phase) { [string]$task.phase } else { '' }
    $parallel = [bool]$task.parallel
    # @(if(){}else{}) wraps the WHOLE conditional's result, not just one
    # branch: PowerShell unwraps a single-element array the same way through
    # an if-expression's output as it does through a function's return, so
    # wrapping only inside the true branch is not enough (a real, reproduced
    # defect — see test_adf_task.bats "the PowerShell port renders
    # byte-identical task description ADF").
    $files = @(if ($task.PSObject.Properties.Name -contains 'files' -and $null -ne $task.files) { $task.files } else { @() })
    $deps = @(if ($task.PSObject.Properties.Name -contains 'depends_on' -and $null -ne $task.depends_on) { $task.depends_on } else { @() })
    $ordinal = $null
    if ($task.PSObject.Properties.Name -contains 'attribution' -and $null -ne $task.attribution -and
        $task.attribution.PSObject.Properties.Name -contains 'story_ordinal' -and $null -ne $task.attribution.story_ordinal) {
        $ordinal = $task.attribution.story_ordinal
    }

    $meta = [System.Collections.Generic.List[string]]::new()
    $meta.Add("Identifier: $taskRef")
    if ($phase) { $meta.Add("Phase: $phase") }
    if ($null -ne $ordinal) { $meta.Add("Attribution: User Story $ordinal") } else { $meta.Add('Attribution: none') }
    if ($parallel) { $meta.Add('Parallel-safe: yes') } else { $meta.Add('Parallel-safe: no') }
    if ($files.Count -gt 0) { $meta.Add("Files: $($files -join ', ')") }
    if ($deps.Count -gt 0) { $meta.Add("Depends on: $($deps -join ', ')") }

    $docContent = [System.Collections.Generic.List[object]]::new()
    $docContent.Add((New-JiraAdfParagraph $title))
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $meta) { $items.Add((New-JiraAdfListItem $m)) }
    $docContent.Add([ordered]@{ type = 'bulletList'; content = $items })

    return (ConvertTo-JiraJsonValue ([ordered]@{ type = 'doc'; version = 1; content = $docContent }))
}

Export-ModuleMember -Function ConvertTo-JiraAdfDocument, ConvertTo-JiraManagedAdfDocument, ConvertTo-JiraManagedTaskAdfDocument, `
    Get-JiraManagedMarker, Get-JiraAdfTaskSummary, ConvertTo-JiraAdfTaskDescription
