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

function ConvertTo-JiraAdfDocument {
    <#
    .SYNOPSIS
      Render a story's neutral content into a single canonical ADF document.
      Mirror of adf_render_description.
    #>
    [CmdletBinding()]
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

    $doc = [ordered]@{ type = 'doc'; version = 1; content = $docContent }
    return (ConvertTo-JiraJsonValue $doc)
}

Export-ModuleMember -Function ConvertTo-JiraAdfDocument
