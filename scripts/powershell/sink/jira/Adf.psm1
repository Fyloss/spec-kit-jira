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
# No -Force: a -Force reimport here tears Markdown.psm1 out of a caller's
# session scope when the caller already imported it (see AGENTS.md memory
# powershell-import-force-clobbers-caller-scope).
Import-Module (Join-Path $PSScriptRoot '../../engine/Markdown.psm1')

function New-JiraAdfText {
    param([string] $Text)
    return [ordered]@{ type = 'text'; text = $Text }
}

function ConvertTo-JiraAdfMark {
    <#
    .SYNOPSIS
      The neutral mark -> ADF mark map (research §1, feature 016). THE ONLY
      place ADF mark names may appear (Constitution VIII). Mirror of
      adf.sh's marks_to_adf.
    #>
    param($Mark)
    switch ($Mark.kind) {
        'bold' { return [ordered]@{ type = 'strong' } }
        'italic' { return [ordered]@{ type = 'em' } }
        'monospace' { return [ordered]@{ type = 'code' } }
        'strikethrough' { return [ordered]@{ type = 'strike' } }
        'link' { return [ordered]@{ type = 'link'; attrs = [ordered]@{ href = $Mark.href } } }
        default { return $null }
    }
}

function ConvertTo-JiraAdfTextNode {
    <#
    .SYNOPSIS
      Render one neutral span ({text, marks}) as an ADF text node, with an
      ADF `marks` array present only when the span carries any. Mirror of
      adf.sh's spans_to_adf (per element).
    #>
    param($Span)
    $node = [ordered]@{ type = 'text'; text = [string]$Span.text }
    $marks = @(@($Span.marks) | Where-Object { $null -ne $_ })
    if ($marks.Count -gt 0) {
        $adfMarks = @($marks | ForEach-Object { ConvertTo-JiraAdfMark $_ })
        $node['marks'] = $adfMarks
    }
    return $node
}

function ConvertTo-JiraAdfTextNodeList {
    <# Render a neutral inline sequence (array of spans) to ADF text nodes. #>
    param([object[]] $Spans)
    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($Spans)) {
        if ($null -eq $s) { continue }
        $nodes.Add((ConvertTo-JiraAdfTextNode $s))
    }
    return $nodes
}

function New-JiraAdfParagraph {
    param([string] $Text)
    $content = [System.Collections.Generic.List[object]]::new()
    if ($Text -ne '') { $content.Add((New-JiraAdfText $Text)) }
    return [ordered]@{ type = 'paragraph'; content = $content }
}

function New-JiraAdfParagraphFromSpanList {
    <# A paragraph node whose content is a rendered neutral inline sequence. #>
    param([object[]] $Spans)
    return [ordered]@{ type = 'paragraph'; content = @(ConvertTo-JiraAdfTextNodeList -Spans $Spans) }
}

function New-JiraAdfListItem {
    param([string] $Text)
    return [ordered]@{ type = 'listItem'; content = @((New-JiraAdfParagraph $Text)) }
}

function New-JiraAdfListItemFromSpanList {
    <# A listItem node whose paragraph content is a rendered inline sequence. #>
    param([object[]] $Spans)
    return [ordered]@{ type = 'listItem'; content = @((New-JiraAdfParagraphFromSpanList -Spans $Spans)) }
}

function ConvertTo-JiraAdfBlockNode {
    <#
    .SYNOPSIS
      Render neutral content blocks to ADF nodes. code stays a plain-string
      body (FR-007: no markup interpretation inside code). Mirror of
      _adf_blocks_to_nodes.
    #>
    param([object[]] $Blocks)
    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $Blocks) {
        $type = $b.type
        if ($type -eq 'heading') {
            $level = if ($b.PSObject.Properties.Name -contains 'level' -and $null -ne $b.level) { [int]$b.level } else { 3 }
            $spans = if ($b.PSObject.Properties.Name -contains 'spans' -and $null -ne $b.spans) { @($b.spans) } else { @() }
            $nodes.Add([ordered]@{ type = 'heading'; attrs = [ordered]@{ level = $level }; content = @(ConvertTo-JiraAdfTextNodeList -Spans $spans) })
        }
        elseif ($type -eq 'paragraph') {
            $spans = if ($b.PSObject.Properties.Name -contains 'spans' -and $null -ne $b.spans) { @($b.spans) } else { @() }
            $nodes.Add((New-JiraAdfParagraphFromSpanList -Spans $spans))
        }
        elseif ($type -eq 'bullet_list' -or $type -eq 'ordered_list') {
            $items = if ($b.PSObject.Properties.Name -contains 'items' -and $null -ne $b.items) { @($b.items) } else { @() }
            $li = [System.Collections.Generic.List[object]]::new()
            foreach ($it in $items) { $li.Add((New-JiraAdfListItemFromSpanList -Spans @($it))) }
            $adfType = if ($type -eq 'bullet_list') { 'bulletList' } else { 'orderedList' }
            $nodes.Add([ordered]@{ type = $adfType; content = $li })
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
    <#
    .SYNOPSIS
      A dedicated info panel carrying Given/When/Then clauses. Each clause is
      an inline sequence (feature 016): the "Given "/"When "/"Then " prefix is
      a plain unmarked text node ahead of the clause's own rendered spans.
      Mirror of _adf_gherkin_panel. Returns $null when there is no AC.
    #>
    param([object[]] $Acceptance)
    if (@($Acceptance).Count -eq 0) { return $null }
    $paras = [System.Collections.Generic.List[object]]::new()
    foreach ($sc in $Acceptance) {
        foreach ($g in @($sc.given)) {
            if ($null -ne $g) {
                $content = [System.Collections.Generic.List[object]]::new()
                $content.Add((New-JiraAdfText 'Given '))
                foreach ($n in (ConvertTo-JiraAdfTextNodeList -Spans @($g))) { $content.Add($n) }
                $paras.Add([ordered]@{ type = 'paragraph'; content = $content })
            }
        }
        foreach ($w in @($sc.when)) {
            if ($null -ne $w) {
                $content = [System.Collections.Generic.List[object]]::new()
                $content.Add((New-JiraAdfText 'When '))
                foreach ($n in (ConvertTo-JiraAdfTextNodeList -Spans @($w))) { $content.Add($n) }
                $paras.Add([ordered]@{ type = 'paragraph'; content = $content })
            }
        }
        foreach ($t in @($sc.then)) {
            if ($null -ne $t) {
                $content = [System.Collections.Generic.List[object]]::new()
                $content.Add((New-JiraAdfText 'Then '))
                foreach ($n in (ConvertTo-JiraAdfTextNodeList -Spans @($t))) { $content.Add($n) }
                $paras.Add([ordered]@{ type = 'paragraph'; content = $content })
            }
        }
    }
    return [ordered]@{ type = 'panel'; attrs = [ordered]@{ panelType = 'info' }; content = $paras }
}

function New-JiraAdfDesignNode {
    <#
    .SYNOPSIS
      A distinct Design section: a level-3 heading + a bullet list of guidance
      and Figma links. guidance values are inline sequences (feature 016);
      figma_link stays a plain string URL with its label prefixed as plain
      text. Mirror of _adf_design_nodes. Returns an empty list when absent.
    #>
    param([object[]] $Design)
    $nodes = [System.Collections.Generic.List[object]]::new()
    if (@($Design).Count -eq 0) { return $nodes }
    $nodes.Add([ordered]@{ type = 'heading'; attrs = [ordered]@{ level = 3 }; content = @((New-JiraAdfText 'Design')) })
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Design) {
        if ($d.kind -eq 'figma_link') {
            $label = if ($d.PSObject.Properties.Name -contains 'label' -and $null -ne $d.label) { [string]$d.label } else { 'Figma' }
            $line = "$($label): $($d.value)"
            $items.Add((New-JiraAdfListItem $line))
        }
        else {
            $items.Add((New-JiraAdfListItemFromSpanList -Spans @($d.value)))
        }
    }
    $nodes.Add([ordered]@{ type = 'bulletList'; content = $items })
    return $nodes
}

function Get-JiraAdfContentNode {
    # The managed content-node list for a story (description body, acceptance
    # panel, Design section) — the bridge-owned managed section. Mirror of
    # _adf_content_nodes. Returns a List[object].
    param([Parameter(Mandatory)] [string] $ContentJson, [Parameter()] [string] $Mode = 'off')
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


    # 022, contract §1: appended LAST, and only in checklist mode — every
    # existing call site (mode defaulting to 'off') stays byte-identical.
    if ($Mode -eq 'checklist') {
        foreach ($n in (Get-JiraAdfChecklistNode -ContentJson $ContentJson)) { $docContent.Add($n) }
    }

    return $docContent
}


function Get-JiraAdfChecklistNode {
    <#
    .SYNOPSIS
      A story's tasks rendered as one checklist section (022,
      contracts/checklist-rendering.md §2-4): one 'Tasks' heading, one group
      per phase in first-appearance order, entries in document order, a
      leading no-phase group carrying no phase paragraph. Candidate B
      (research §1): the existing bulletList/listItem pair, each entry's
      first span a state glyph — no node carries an identity attribute.
      Empty when there is no attributed task at all (FR-021). Mirror of
      _adf_checklist_nodes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ContentJson)
    $content = $ContentJson | ConvertFrom-Json -Depth 100
    $nodes = [System.Collections.Generic.List[object]]::new()
    $tasksProp = $content.PSObject.Properties['tasks']
    $tasks = @()
    if ($null -ne $tasksProp -and $null -ne $tasksProp.Value) { $tasks = @($tasksProp.Value) }
    if ($tasks.Count -eq 0) { return $nodes }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $tasks) {
        $title = [string]$t.title
        $done = [bool]$t.done
        $phase = if ($t.PSObject.Properties.Name -contains 'phase' -and $null -ne $t.phase) { [string]$t.phase } else { '' }
        $spansJson = ConvertTo-JiraMarkdownInlineSpanList -Text $title
        $spans = @($spansJson | ConvertFrom-Json -Depth 100)
        $entries.Add([pscustomobject]@{ Spans = $spans; Done = $done; Phase = $phase })
    }

    $nophase = @($entries | Where-Object { $_.Phase -eq '' })
    $phased = @($entries | Where-Object { $_.Phase -ne '' })
    $phaseOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $phased) { if (-not $phaseOrder.Contains($e.Phase)) { $phaseOrder.Add($e.Phase) } }

    $groups = [System.Collections.Generic.List[object]]::new()
    if ($nophase.Count -gt 0) { $groups.Add([pscustomobject]@{ Phase = $null; Entries = $nophase }) }
    foreach ($ph in $phaseOrder) {
        $groups.Add([pscustomobject]@{ Phase = $ph; Entries = @($phased | Where-Object { $_.Phase -eq $ph }) })
    }

    $nodes.Add([ordered]@{ type = 'heading'; attrs = [ordered]@{ level = 3 }; content = @((New-JiraAdfText 'Tasks')) })
    foreach ($g in $groups) {
        if ($null -ne $g.Phase) {
            $phaseText = [ordered]@{ type = 'text'; text = $g.Phase; marks = @([ordered]@{ type = 'strong' }) }
            $nodes.Add([ordered]@{ type = 'paragraph'; content = @($phaseText) })
        }
        $li = [System.Collections.Generic.List[object]]::new()
        foreach ($e in $g.Entries) {
            $glyph = if ($e.Done) { [char]0x2611 + ' ' } else { [char]0x2610 + ' ' }
            $paraContent = [System.Collections.Generic.List[object]]::new()
            $paraContent.Add((New-JiraAdfText $glyph))
            foreach ($n in (ConvertTo-JiraAdfTextNodeList -Spans $e.Spans)) { $paraContent.Add($n) }
            $li.Add([ordered]@{ type = 'listItem'; content = @([ordered]@{ type = 'paragraph'; content = $paraContent }) })
        }
        $nodes.Add([ordered]@{ type = 'bulletList'; content = $li })
    }
    return $nodes
}


function ConvertTo-JiraAdfChecklistNormalized {
    <#
    .SYNOPSIS
      Comparison-only normalisation (022, contract §5): strip attrs.localId
      from every checklist node and entry node. A defensive no-op under the
      shipped candidate B (bulletList/listItem carry no identity attribute).
      Mirror of _adf_checklist_normalise.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $NodesJson)
    $nodes = @($NodesJson | ConvertFrom-Json -Depth 100)
    foreach ($n in $nodes) {
        if ($n.PSObject.Properties.Name -contains 'attrs') { $n.PSObject.Properties.Remove('attrs') }
        if ($n.PSObject.Properties.Name -contains 'content') {
            foreach ($c in @($n.content)) {
                if ($c.PSObject.Properties.Name -contains 'attrs') { $c.PSObject.Properties.Remove('attrs') }
            }
        }
    }
    return (ConvertTo-JiraJsonValue $nodes)
}

function Get-JiraAdfChecklistNodesDigest {
    <#
    .SYNOPSIS
      git hash-object --no-filters over the canonical JSON of NORMALISED
      nodes. Empty input yields an empty digest. Mirror of
      _adf_checklist_nodes_digest.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $NodesJson)
    if ($NodesJson -eq '[]') { return '' }
    $normalized = ConvertTo-JiraAdfChecklistNormalized -NodesJson $NodesJson
    $canonical = ConvertTo-JiraCanonicalJson -Json $normalized
    $hash = ($canonical | & git hash-object --no-filters --stdin 2>$null | Select-Object -First 1)
    if ($null -eq $hash) { return '' }
    return $hash.Trim()
}

function Get-JiraAdfChecklistDigest {
    <#
    .SYNOPSIS
      The identity-stamp digest (022, data-model.md §3): the digest of the
      story's DESIRED checklist nodes. Empty when the story has no
      attributed task at all. Mirror of adf_checklist_digest.
    #>
    param([Parameter(Mandatory)] [string] $ContentJson)
    $nodes = ConvertTo-JiraJsonValue (Get-JiraAdfChecklistNode -ContentJson $ContentJson)
    return (Get-JiraAdfChecklistNodesDigest -NodesJson $nodes)
}

function Get-JiraAdfChecklistSlice {
    <#
    .SYNOPSIS
      The checklist portion of an already-managed node array (022, contract
      §1/§5): everything from the 'Tasks' heading onward, or [] when there
      is none. Mirror of _adf_checklist_slice.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $ManagedJson)
    $managed = @($ManagedJson | ConvertFrom-Json -Depth 100)
    $idx = -1
    for ($i = 0; $i -lt $managed.Count; $i++) {
        $n = $managed[$i]
        if ($n.type -eq 'heading' -and $n.content -and $n.content[0].text -eq 'Tasks') { $idx = $i; break }
    }
    if ($idx -lt 0) { return (ConvertTo-JiraJsonValue @()) }
    return (ConvertTo-JiraJsonValue @($managed[$idx..($managed.Count - 1)]))
}

function Test-JiraAdfContentHasChecklist {
    <#
    .SYNOPSIS
      True when a story's CURRENT description (the full {type, version,
      content} doc, as read by recognition) already carries a checklist
      section in its managed region (022, FR-034's reverse-switch report).
      No new Jira read: the caller already has this from recognition's own
      current-content fetch. Mirror of _adf_content_has_checklist.
    #>
    param([string] $ExistingJson = '{}')
    if ([string]::IsNullOrEmpty($ExistingJson) -or $ExistingJson -eq 'null') { $ExistingJson = '{}' }
    $existing = $ExistingJson | ConvertFrom-Json -Depth 100
    $contentProp = $existing.PSObject.Properties['content']
    $contentJson = if ($null -ne $contentProp) { ConvertTo-JiraJsonValue @($contentProp.Value) } else { '[]' }
    $managed = (Split-JiraManagedSectionPanel -Marker (Get-JiraManagedMarker) -ContentJson $contentJson | ConvertFrom-Json -Depth 100).managed
    $managedJson = ConvertTo-JiraJsonValue @($managed)
    $cl = Get-JiraAdfChecklistSlice -ManagedJson $managedJson | ConvertFrom-Json -Depth 100
    return (@($cl).Count -gt 0)
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

function ConvertTo-JiraOwnership {
    <#
    .SYNOPSIS
      019, contracts/ownership-decision.md §2: the sink-side, total
      translation from the ticket's recorded origin to the engine's neutral
      ownership vocabulary. Mirror of _adf_translate_origin.
    .DESCRIPTION
      'bridge' (the mirror created it) -> self; 'human' (adopted via mention)
      -> other; anything else, including empty and absent, -> unknown (FR-004).
    #>
    param([Parameter()] [AllowEmptyString()] [string] $Origin = '')
    switch ($Origin) {
        'bridge' { return 'self' }
        'human' { return 'other' }
        default { return 'unknown' }
    }
}

function Resolve-JiraManagedAdfContent {
    <#
    .SYNOPSIS
      The shared contract §3 resolution engine (018, T014/T027; 019, T013,
      data-model.md §3), independent of what produced the managed-node
      array — the same decision serves the story/parent shape
      (Get-JiraAdfContentNode) and the task tier's own shape
      (ConvertTo-JiraAdfTaskDescription) identically. Mirror of
      _adf_resolve_managed.
    .DESCRIPTION
      - ExistingJson omitted entirely: a CREATION. No prior content to preserve;
        the result is marker ++ freshly-rendered managed nodes, with no human
        prefix and no warning (contract §3 row 5).
      - Otherwise Origin is translated (ConvertTo-JiraOwnership) and the whole
        marker-count-then-ownership decision is delegated to
        Split-JiraManagedSectionOwnership (019, T007): marker_count > 1 is
        malformed (row 1); marker_count == 1 keeps the existing prefix
        verbatim (row 2); marker_count == 0 and ownership self replaces the
        whole existing description (row 3, the fix, FR-002); ownership other
        reuses today's suffix-split behaviour unmodified (row 4); ownership
        unknown preserves the whole existing content and reports
        'migrated-warned' (row 5, FR-004) — nothing is ever discarded
        (FR-020a/FR-020b).
      Returns canonical {status:'ok'|'malformed'|'migrated-warned', doc:<adf-doc>}
      — `doc` is present on every status except 'malformed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Managed,
        [Parameter()] [AllowEmptyString()] [string] $ExistingJson = '',
        [Parameter()] [AllowEmptyString()] [string] $Origin = ''
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
    $ownership = ConvertTo-JiraOwnership -Origin $Origin
    $split = Split-JiraManagedSectionOwnership -Marker $marker -ManagedJson $managedJson -Ownership $ownership -ExistingJson $existingContentJson | ConvertFrom-Json -Depth 100
    $status = [string]$split.status

    if ($status -eq 'malformed') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ status = 'malformed' }))
    }

    $prefix = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($split.prefix)) { $prefix.Add($n) }

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
      Description resolution for the story/parent shape (018, T015; 019,
      T013). See Resolve-JiraManagedAdfContent for the contract §3 decision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ContentJson,
        [Parameter()] [AllowEmptyString()] [string] $ExistingJson = '',
        [Parameter()] [AllowEmptyString()] [string] $Origin = '',
        [Parameter()] [string] $Mode = 'off'
    )
    $managed = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @(Get-JiraAdfContentNode -ContentJson $ContentJson -Mode $Mode)) { $managed.Add($n) }
    return (Resolve-JiraManagedAdfContent -Managed $managed -ExistingJson $ExistingJson -Origin $Origin)
}

function ConvertTo-JiraManagedTaskAdfDocument {
    <#
    .SYNOPSIS
      Description resolution for the task tier's own shape (018, T027,
      FR-006; 019, T031): the sub-task's description
      (ConvertTo-JiraAdfTaskDescription — its own text, identifier, phase,
      attribution, etc., never the story or the specification, FR-009) is
      what the boundary now wraps, resolved through the SAME §3 decision as
      every other tier. Mirror of adf_render_managed_task_description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TaskJson,
        [Parameter()] [AllowEmptyString()] [string] $ExistingJson = '',
        [Parameter()] [AllowEmptyString()] [string] $Origin = ''
    )
    $taskDoc = ConvertTo-JiraAdfTaskDescription -TaskJson $TaskJson | ConvertFrom-Json -Depth 100
    $managed = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($taskDoc.content)) { $managed.Add($n) }
    return (Resolve-JiraManagedAdfContent -Managed $managed -ExistingJson $ExistingJson -Origin $Origin)
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

      The body comes from .description.blocks through the SAME neutral-block
      renderer the story tier uses, so a task's markup renders as marks
      rather than surviving as punctuation (016, FR-017). The metadata
      bullets are composed by the bridge and stay plain text (FR-018).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TaskJson)
    $task = $TaskJson | ConvertFrom-Json -Depth 100

    $blocks = @(if ($task.PSObject.Properties.Name -contains 'description' -and $null -ne $task.description -and
            $task.description.PSObject.Properties.Name -contains 'blocks' -and $null -ne $task.description.blocks) {
            $task.description.blocks
        }
        else { @() })
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
    foreach ($n in (ConvertTo-JiraAdfBlockNode -Blocks $blocks)) { $docContent.Add($n) }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $meta) { $items.Add((New-JiraAdfListItem $m)) }
    $docContent.Add([ordered]@{ type = 'bulletList'; content = $items })

    return (ConvertTo-JiraJsonValue ([ordered]@{ type = 'doc'; version = 1; content = $docContent }))
}

Export-ModuleMember -Function ConvertTo-JiraAdfDocument, ConvertTo-JiraManagedAdfDocument, ConvertTo-JiraManagedTaskAdfDocument, `
    Get-JiraManagedMarker, Get-JiraAdfTaskSummary, ConvertTo-JiraAdfTaskDescription, Get-JiraAdfChecklistNode, `
    ConvertTo-JiraAdfChecklistNormalized, Get-JiraAdfChecklistNodesDigest, Get-JiraAdfChecklistDigest, Get-JiraAdfChecklistSlice, `
    Test-JiraAdfContentHasChecklist
