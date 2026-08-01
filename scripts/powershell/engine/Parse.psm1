# engine/Parse.psm1 — Neutral spec parser. Mirror of engine/parse.sh (US3, T054).
#
# Turns a specification document into the neutral content the interchange
# assembly wraps into a schema-validated neutral document. Every decision here is
# the ENGINE's (Constitution VIII): the deterministic title ladder (FR 013), the
# never-empty structured description (FR 014), Given/When/Then extraction
# (FR 015), the Design section (FR 016), the P1/P2/P3 priority (FR 017), and the
# declared estimation (FR 018). It carries ZERO Jira identifiers and never imports
# sink/: it emits logical, Jira-agnostic content. Output is byte-identical to the
# Bash port (NFR 1) via the shared canonical serialiser.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force # canonical serialiser only — lib/, never sink/
Import-Module (Join-Path $PSScriptRoot 'MarkerSplice.psm1') -Force # Get-JiraMarkerSpliceLineCount — a nested import inside StoryMarker.psm1 is not enough
Import-Module (Join-Path $PSScriptRoot 'SpecMarker.psm1') -Force # Get-JiraSpecMarkerDocumentInfo, ConvertTo-JiraSpecMarkerInfo (Phase 5, US2)
Import-Module (Join-Path $PSScriptRoot 'StoryMarker.psm1') -Force -Global # the durable identifier's grammar (Phase 2)

function Remove-JiraParseMarkerLines {
    <#
    .SYNOPSIS
      Remove every speckit-jira marker attempt line (story= or spec=, valid
      or malformed — contract "Reading rules" #2) from $Text, so it never
      lands in a title, description, acceptance criterion, or design item.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraParseLine $Text
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $storyInfo = ConvertTo-JiraStoryMarkerInfo -Line $line | ConvertFrom-Json -Depth 20
        $specInfo = ConvertTo-JiraSpecMarkerInfo -Line $line | ConvertFrom-Json -Depth 20
        if ($storyInfo.kind -ne 'none' -or $specInfo.kind -ne 'none') { continue }
        $out.Add($line)
    }
    return ($out -join "`n")
}

function Get-JiraParseLocalIdForMarker {
    <#
    .SYNOPSIS
      The story's local_id derived from its marker (research R7): the
      marker's own identifier when one resolves it; empty for a truly
      unassigned section; a freshly generated identifier for a "duplicate"
      section, so the story still has a legitimate, unique local_id and is
      excluded from the write plan by itself rather than failing the whole
      document's schema validation.
    #>
    param([Parameter(Mandatory)] [string] $InfoJson)
    $info = $InfoJson | ConvertFrom-Json -Depth 20
    switch ([string]$info.state) {
        'absent' { return '' }
        'duplicate' { return (New-JiraStoryMarkerId) }
        default { return [string]$info.id }
    }
}

function Split-JiraParseLine {
    param([string] $Text)
    if ($null -eq $Text) { $Text = '' }
    return ($Text -replace "`r`n", "`n") -replace "`r", "`n" -split "`n"
}

function Remove-JiraParseMarker {
    param([string] $S)
    $m = [regex]::Match($S, '^([-*]|[0-9]+\.)\s+(.*)$')
    if ($m.Success) { return $m.Groups[2].Value }
    return $S
}

function Get-JiraParsedTitle {
    <#
    .SYNOPSIS
      The deterministic title ladder (FR 013): explicit `Title:` line -> first H1
      -> user-story section title -> first non-empty paragraph -> humanised folder
      slug. NEVER a `## Summary`.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [string] $FolderSlug = '')
    $lines = Split-JiraParseLine $Text

    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^\s*Title:\s*(.+)$')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }

    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^#\s+(.+)$')
        if ($m.Success) {
            $h = $m.Groups[1].Value
            $fm = [regex]::Match($h, '^Feature Specification:\s*(.+)$')
            if ($fm.Success) { $h = $fm.Groups[1].Value }
            return $h.Trim()
        }
    }

    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^#{2,4}\s+User Story[^-]*-\s*(.+)$')
        if ($m.Success) {
            $t = $m.Groups[1].Value
            $idx = $t.IndexOf('(Priority:')
            if ($idx -ge 0) { $t = $t.Substring(0, $idx) }
            return $t.Trim()
        }
    }

    foreach ($line in $lines) {
        $p = $line.Trim()
        if ([string]::IsNullOrEmpty($p)) { continue }
        if ($p.StartsWith('#')) { continue }
        if ($p -match '^Title:') { continue }
        return (Remove-JiraParseMarker $p).Trim()
    }

    $s = $FolderSlug
    $s = [regex]::Replace($s, '^[0-9]{3}-', '')
    $s = $s -replace '-', ' ' -replace '_', ' '
    return $s
}

function Get-JiraParsedDescription {
    <#
    .SYNOPSIS
      Synthesise a never-empty structured description (FR 014). Mirror of
      parse_description_blocks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraParseLine $Text

    $paras = [System.Collections.Generic.List[string]]::new()
    $para = ''
    $h1 = ''
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ([string]::IsNullOrEmpty($t)) {
            if ($para -ne '') { $paras.Add($para); $para = '' }
            continue
        }
        $hm = [regex]::Match($t, '^#{1,6}\s+(.*)$')
        if ($hm.Success) {
            $ht = $hm.Groups[1].Value
            if ([string]::IsNullOrEmpty($h1) -and ($line -match '^#\s')) {
                $h1 = ($ht -replace '^Feature Specification: ', '').Trim()
            }
            if ($ht -match '^(Acceptance|Design|Task|Scenario|Requirement|Success|Edge)') { break }
            if ($para -ne '') { $paras.Add($para); $para = '' }
            continue
        }
        if ($t -match '^Title:') { continue }
        $t = (Remove-JiraParseMarker $t).Trim()
        if ($para -ne '') { $para = "$para $t" } else { $para = $t }
    }
    if ($para -ne '') { $paras.Add($para) }

    if ($paras.Count -eq 0) {
        if ($h1 -ne '') { $paras.Add($h1) } else { $paras.Add('This ticket tracks the linked specification.') }
    }

    $blocks = [System.Collections.Generic.List[object]]::new()
    $idx = 0
    foreach ($p in $paras) {
        if ($idx -ge 2) { break }
        $blocks.Add([ordered]@{ type = 'paragraph'; text = $p })
        $idx++
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ blocks = $blocks }))
}

function Get-JiraParsedAcceptance {
    <#
    .SYNOPSIS
      Extract Given/When/Then scenarios (FR 015). Mirror of
      parse_acceptance_criteria.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraParseLine $Text

    $blocks = [System.Collections.Generic.List[object]]::new()
    $given = [System.Collections.Generic.List[string]]::new()
    $when = [System.Collections.Generic.List[string]]::new()
    $then = [System.Collections.Generic.List[string]]::new()

    $flush = {
        if ($then.Count -gt 0) {
            $blocks.Add([ordered]@{
                    given = [System.Collections.Generic.List[string]]::new($given)
                    when  = [System.Collections.Generic.List[string]]::new($when)
                    then  = [System.Collections.Generic.List[string]]::new($then)
                })
        }
        $given.Clear(); $when.Clear(); $then.Clear(); $script:acLast = ''
    }
    $script:acLast = ''

    foreach ($line in $lines) {
        $t = $line.Trim()
        $t = $t -replace '\*\*', ''
        $t = (Remove-JiraParseMarker $t).Trim()
        if ([string]::IsNullOrEmpty($t)) { continue }

        if (($t -cmatch '[Gg]iven\s') -and ($t -cmatch '[Ww]hen\s') -and ($t -cmatch '[Tt]hen\s')) {
            & $flush
            # Prefer explicit clause boundaries (", When" / ", Then") so a Given
            # clause that itself contains the word "when" survives intact; only a
            # delimiter-free line falls back to the first-keyword split.
            $m = [regex]::Match($t, '[Gg]iven\s+(.+)[,;]\s*[Ww]hen\s+(.+)[,;]\s*[Tt]hen\s+(.+)$')
            if (-not $m.Success) { $m = [regex]::Match($t, '[Gg]iven\s+(.*?)\s+[Ww]hen\s+(.*?)\s+[Tt]hen\s+(.+)') }
            if ($m.Success) {
                $given.Add($m.Groups[1].Value.Trim())
                $when.Add($m.Groups[2].Value.Trim())
                $then.Add($m.Groups[3].Value.Trim())
            }
            & $flush
            continue
        }

        $gm = [regex]::Match($t, '^[Gg]iven\s+(.+)$')
        $wm = [regex]::Match($t, '^[Ww]hen\s+(.+)$')
        $tm = [regex]::Match($t, '^[Tt]hen\s+(.+)$')
        $am = [regex]::Match($t, '^([Aa]nd|[Bb]ut)\s+(.+)$')
        if ($gm.Success) {
            if ($then.Count -gt 0) { & $flush }
            $given.Add($gm.Groups[1].Value.Trim()); $script:acLast = 'g'
        }
        elseif ($wm.Success) {
            $when.Add($wm.Groups[1].Value.Trim()); $script:acLast = 'w'
        }
        elseif ($tm.Success) {
            $then.Add($tm.Groups[1].Value.Trim()); $script:acLast = 't'
        }
        elseif ($am.Success) {
            $v = $am.Groups[2].Value.Trim()
            switch ($script:acLast) {
                'g' { $given.Add($v) }
                'w' { $when.Add($v) }
                't' { $then.Add($v) }
            }
        }
    }
    & $flush

    return (ConvertTo-JiraJsonValue $blocks)
}

function Get-JiraParsedDesign {
    <#
    .SYNOPSIS
      Surface Figma links and Design-section UX guidance (FR 016). Mirror of
      parse_design.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraParseLine $Text

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        $md = [regex]::Match($line, '\[([^]]+)\]\(([^)]+)\)')
        if ($md.Success -and $md.Groups[2].Value -like '*figma.com*') {
            $items.Add([ordered]@{ kind = 'figma_link'; label = $md.Groups[1].Value; value = $md.Groups[2].Value })
        }
        else {
            $bm = [regex]::Match($line, '(https?://[^\s)]*figma\.com[^\s)]*)')
            if ($bm.Success) {
                $items.Add([ordered]@{ kind = 'figma_link'; value = $bm.Groups[1].Value })
            }
        }
    }

    $dlevel = 0
    foreach ($line in $lines) {
        $t = $line.Trim()
        $hm = [regex]::Match($t, '^(#{1,6})\s+(.*)$')
        if ($hm.Success) {
            $hl = $hm.Groups[1].Value.Length
            $htext = $hm.Groups[2].Value
            if ($htext -match '[Dd]esign') { $dlevel = $hl }
            elseif ($dlevel -gt 0 -and $hl -le $dlevel) { $dlevel = 0 }
            continue
        }
        if ($dlevel -gt 0) {
            if ([string]::IsNullOrEmpty($t)) { continue }
            if ($t -match 'figma\.com') { continue }
            $t = (Remove-JiraParseMarker $t).Trim()
            if ([string]::IsNullOrEmpty($t)) { continue }
            $items.Add([ordered]@{ kind = 'guidance'; value = $t })
        }
    }

    return (ConvertTo-JiraJsonValue $items)
}

function Get-JiraParsedPriority {
    <#
    .SYNOPSIS
      The spec's P1/P2/P3 priority (FR 017); defaults to P2. Mirror of parse_priority.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $m = [regex]::Match($Text, '[Pp]riority:?\s*P([123])')
    if ($m.Success) { return "P$($m.Groups[1].Value)" }
    return 'P2'
}

function Get-JiraParsedEstimation {
    <#
    .SYNOPSIS
      The declared estimation as a JSON number, or null (FR 018). Mirror of
      parse_estimation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $m = [regex]::Match($Text, '([Ee]stimation|[Ee]stimate|[Ee]ffort|[Pp]oints)\s*:\s*([0-9]+(\.[0-9]+)?)')
    if ($m.Success) { return $m.Groups[2].Value }
    return 'null'
}

function Get-JiraParsedStory {
    <#
    .SYNOPSIS
      Assemble one neutral story from a section of the spec. Mirror of parse_story.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $FolderSlug, [Parameter(Mandatory)] [AllowEmptyString()] [string] $LocalId)

    $Text = Remove-JiraParseMarkerLines -Text $Text
    $title = Get-JiraParsedTitle -Text $Text -FolderSlug $FolderSlug
    $desc = Get-JiraParsedDescription -Text $Text | ConvertFrom-Json -Depth 100
    $ac = @(Get-JiraParsedAcceptance -Text $Text | ConvertFrom-Json -Depth 100)
    $design = @(Get-JiraParsedDesign -Text $Text | ConvertFrom-Json -Depth 100)
    $priority = Get-JiraParsedPriority -Text $Text
    $est = Get-JiraParsedEstimation -Text $Text

    $story = [ordered]@{
        local_id         = $LocalId
        title            = $title
        description      = $desc
        priority_logical = $priority
    }
    if ($ac.Count -gt 0) { $story['acceptance_criteria'] = $ac }
    if ($design.Count -gt 0) { $story['design'] = $design }
    if ($est -ne 'null') {
        if ($est -match '\.') { $story['estimation'] = [double]$est } else { $story['estimation'] = [long]$est }
    }
    return (ConvertTo-JiraJsonValue $story)
}

function Remove-JiraParseSCLabel {
    <#
    .SYNOPSIS
      Strip a leading "SC-NNN:" label (optionally wrapped in markdown bold)
      from a Success Criteria bullet item. Mirror of _parse_strip_sc_label.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $bare = $Text -replace '\*\*', ''
    if ($bare -match '^SC-\d+:\s*(.*)$') { return $Matches[1] }
    return $bare
}

function Get-JiraParsedEpicExtraBlocks {
    <#
    .SYNOPSIS
      The Success Criteria and Out of Scope sections as neutral content
      blocks (data-model.md §7, Phase 5 US2): a named heading plus a bullet
      list for each section present. Empty when the document carries
      neither. Mirror of _parse_epic_extra_blocks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraParseLine $Text
    $scItems = [System.Collections.Generic.List[string]]::new()
    $oosItems = [System.Collections.Generic.List[string]]::new()
    $mode = ''
    $cur = ''
    $section = ''

    foreach ($line in $lines) {
        $t = $line.Trim()
        $hm = [regex]::Match($t, '^(#{1,6})\s+(.*)$')
        if ($hm.Success) {
            if (-not [string]::IsNullOrEmpty($cur)) {
                $trimmed = $cur.Trim()
                if ($mode -eq 'sc') { $scItems.Add((Remove-JiraParseSCLabel -Text $trimmed)) }
                elseif ($mode -eq 'oos') { $oosItems.Add($trimmed) }
            }
            $cur = ''
            $mode = ''
            $hl = $hm.Groups[1].Value.Length
            $htext = $hm.Groups[2].Value
            if ($hl -eq 2 -and $htext -match '^Success\sCriteria') {
                $section = 'sc-outer'
            }
            elseif ($hl -eq 3 -and $section -eq 'sc-outer' -and $htext -match '^Measurable\sOutcomes') {
                $section = 'sc-outcomes'
            }
            elseif ($hl -eq 2 -and $htext -match '^Out\sof\sScope') {
                $section = 'oos'
            }
            else {
                $section = ''
            }
            continue
        }
        if ($section -eq 'sc-outcomes' -or $section -eq 'oos') {
            $bm = [regex]::Match($t, '^([-*]|\d+\.)\s+(.*)$')
            if ($bm.Success) {
                if (-not [string]::IsNullOrEmpty($cur)) {
                    $trimmed = $cur.Trim()
                    if ($mode -eq 'sc') { $scItems.Add((Remove-JiraParseSCLabel -Text $trimmed)) }
                    elseif ($mode -eq 'oos') { $oosItems.Add($trimmed) }
                }
                $mode = if ($section -eq 'sc-outcomes') { 'sc' } else { 'oos' }
                $cur = $bm.Groups[2].Value
            }
            elseif (-not [string]::IsNullOrEmpty($t) -and -not [string]::IsNullOrEmpty($cur)) {
                $cur = "$cur $t"
            }
        }
    }
    if (-not [string]::IsNullOrEmpty($cur)) {
        $trimmed = $cur.Trim()
        if ($mode -eq 'sc') { $scItems.Add((Remove-JiraParseSCLabel -Text $trimmed)) }
        elseif ($mode -eq 'oos') { $oosItems.Add($trimmed) }
    }

    $blocks = [System.Collections.Generic.List[object]]::new()
    if ($scItems.Count -gt 0) {
        $blocks.Add([ordered]@{ type = 'heading'; level = 3; text = 'Success Criteria' })
        $blocks.Add([ordered]@{ type = 'bullet_list'; items = @($scItems) })
    }
    if ($oosItems.Count -gt 0) {
        $blocks.Add([ordered]@{ type = 'heading'; level = 3; text = 'Out of Scope' })
        $blocks.Add([ordered]@{ type = 'bullet_list'; items = @($oosItems) })
    }
    return $blocks
}

function Get-JiraParsedPlanSummary {
    <#
    .SYNOPSIS
      The feature folder's plan.md, as neutral content blocks (data-model.md
      §7, US5, spec FR-026/FR-027/FR-028): a named "Implementation Plan"
      heading plus one paragraph block per paragraph under `## Summary`,
      stopping at the next heading. Empty when the input is empty or carries
      no `## Summary` section. Mirror of parse_plan_summary. Returns the
      canonical JSON array as a string.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = Split-JiraParseLine $Text
    $paras = [System.Collections.Generic.List[string]]::new()
    $para = ''
    $inSummary = $false

    foreach ($line in $lines) {
        $t = $line.Trim()
        $hm = [regex]::Match($t, '^(#{1,6})\s+(.*)$')
        if ($hm.Success) {
            if ($para -ne '') { $paras.Add($para); $para = '' }
            $hl = $hm.Groups[1].Value.Length
            $htext = $hm.Groups[2].Value
            $inSummary = ($hl -eq 2 -and $htext -match '^Summary')
            continue
        }
        if (-not $inSummary) { continue }
        if ([string]::IsNullOrEmpty($t)) {
            if ($para -ne '') { $paras.Add($para); $para = '' }
            continue
        }
        $t = (Remove-JiraParseMarker $t).Trim()
        if ($para -ne '') { $para = "$para $t" } else { $para = $t }
    }
    if ($para -ne '') { $paras.Add($para) }

    if ($paras.Count -eq 0) {
        return (ConvertTo-JiraJsonValue @())
    }

    $blocks = [System.Collections.Generic.List[object]]::new()
    $blocks.Add([ordered]@{ type = 'heading'; level = 3; text = 'Implementation Plan' })
    foreach ($p in $paras) {
        $blocks.Add([ordered]@{ type = 'paragraph'; text = $p })
    }
    return (ConvertTo-JiraJsonValue $blocks)
}

function Get-JiraParsedSpec {
    <#
    .SYNOPSIS
      Parse a whole specification into neutral content: one epic plus one story
      per User Story section (or a single story). Mirror of parse_spec.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $FolderSlug)
    $lines = Split-JiraParseLine $Text

    $cleanText = Remove-JiraParseMarkerLines -Text $Text
    $etitle = Get-JiraParsedTitle -Text $cleanText -FolderSlug $FolderSlug
    $edesc = Get-JiraParsedDescription -Text $cleanText | ConvertFrom-Json -Depth 100

    # Phase 5, US2, T059/T067: the parent's description also carries a named
    # Success Criteria section and a named Out of Scope section, as prose
    # (data-model.md §7) — never a list of user stories (FR-011).
    $epicExtra = @(Get-JiraParsedEpicExtraBlocks -Text $cleanText)
    if ($epicExtra.Count -gt 0) {
        $edesc.blocks = @($edesc.blocks) + $epicExtra
    }

    # Split into user-story sections, tracking each heading's ABSOLUTE
    # 1-based line number (the "anchor", exactly as StoryMarker.psm1's
    # assignment scan defines it) so the marker section-info lookup below
    # reports line numbers a human can find in the real file.
    $sections = [System.Collections.Generic.List[string]]::new()
    $anchors = [System.Collections.Generic.List[int]]::new()
    $cur = ''
    $inStory = $false
    $lineno = 0
    foreach ($line in $lines) {
        $lineno++
        if ($line -match '^#{2,4}\s+User Story') {
            if ($inStory) { $sections.Add($cur) }
            $cur = "$line`n"; $inStory = $true
            $anchors.Add($lineno)
        }
        elseif ($inStory) {
            $cur += "$line`n"
        }
    }
    if ($inStory) { $sections.Add($cur) }

    $totalLines = Get-JiraMarkerSpliceLineCount -Content $Text
    $stories = [System.Collections.Generic.List[object]]::new()

    if ($sections.Count -eq 0) {
        # The implicit single story: the marker sits after the document's
        # H1, or the file's first line when there is no H1 either — anchor 0
        # means "before line 1", matching StoryMarker.psm1's own convention.
        $docAnchors = @(Get-JiraStoryMarkerAnchors -Content $Text)
        $anchor = $docAnchors[0]
        $spanStart = if ($anchor -eq 0) { 1 } else { $anchor + 1 }
        $minfo = Get-JiraStoryMarkerSectionInfo -Content $Text -Start $spanStart -End $totalLines
        $localId = Get-JiraParseLocalIdForMarker -InfoJson $minfo
        $story = Get-JiraParsedStory -Text $Text -FolderSlug $FolderSlug -LocalId $localId | ConvertFrom-Json -Depth 100
        $story | Add-Member -MemberType NoteProperty -Name 'marker' -Value ($minfo | ConvertFrom-Json -Depth 20)
        $stories.Add($story)
    }
    else {
        $n = $sections.Count
        for ($i = 0; $i -lt $n; $i++) {
            $spanStart = $anchors[$i] + 1
            $spanEnd = if ($i + 1 -lt $n) { $anchors[$i + 1] - 1 } else { $totalLines }
            $minfo = Get-JiraStoryMarkerSectionInfo -Content $Text -Start $spanStart -End $spanEnd
            $localId = Get-JiraParseLocalIdForMarker -InfoJson $minfo
            $story = Get-JiraParsedStory -Text $sections[$i] -FolderSlug $FolderSlug -LocalId $localId | ConvertFrom-Json -Depth 100
            $story | Add-Member -MemberType NoteProperty -Name 'marker' -Value ($minfo | ConvertFrom-Json -Depth 20)
            $stories.Add($story)
        }
    }

    # epic.local_id / epic.marker (data-model.md §2, Phase 5 US2, T066): the
    # SAME slim marker view a story carries, read from the whole document —
    # the parent marker has no section of its own to scope a search to.
    $epicMinfo = Get-JiraSpecMarkerDocumentInfo -Content $Text
    $epicLocalId = Get-JiraParseLocalIdForMarker -InfoJson $epicMinfo

    $doc = [ordered]@{
        epic    = [ordered]@{ title = $etitle; description = $edesc; local_id = $epicLocalId; marker = ($epicMinfo | ConvertFrom-Json -Depth 20) }
        stories = $stories
    }
    return (ConvertTo-JiraJsonValue $doc)
}

Export-ModuleMember -Function Get-JiraParsedTitle, Get-JiraParsedDescription,
Get-JiraParsedAcceptance, Get-JiraParsedDesign, Get-JiraParsedPriority,
Get-JiraParsedEstimation, Get-JiraParsedStory, Get-JiraParsedSpec, Get-JiraParsedPlanSummary
