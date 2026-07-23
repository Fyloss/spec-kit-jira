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
            $m = [regex]::Match($t, '[Gg]iven\s+(.*?)\s+[Ww]hen\s+(.*?)\s+[Tt]hen\s+(.+)')
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
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $FolderSlug, [Parameter(Mandatory)] [string] $LocalId)

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

function Get-JiraParsedSpec {
    <#
    .SYNOPSIS
      Parse a whole specification into neutral content: one epic plus one story
      per User Story section (or a single story). Mirror of parse_spec.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $FolderSlug)
    $lines = Split-JiraParseLine $Text

    $etitle = Get-JiraParsedTitle -Text $Text -FolderSlug $FolderSlug
    $edesc = Get-JiraParsedDescription -Text $Text | ConvertFrom-Json -Depth 100

    $sections = [System.Collections.Generic.List[string]]::new()
    $cur = ''
    $inStory = $false
    foreach ($line in $lines) {
        if ($line -match '^#{2,4}\s+User Story') {
            if ($inStory) { $sections.Add($cur) }
            $cur = "$line`n"; $inStory = $true
        }
        elseif ($inStory) {
            $cur += "$line`n"
        }
    }
    if ($inStory) { $sections.Add($cur) }

    $stories = [System.Collections.Generic.List[object]]::new()
    if ($sections.Count -eq 0) {
        $stories.Add((Get-JiraParsedStory -Text $Text -FolderSlug $FolderSlug -LocalId 's1' | ConvertFrom-Json -Depth 100))
    }
    else {
        $i = 0
        foreach ($s in $sections) {
            $i++
            $stories.Add((Get-JiraParsedStory -Text $s -FolderSlug $FolderSlug -LocalId "s$i" | ConvertFrom-Json -Depth 100))
        }
    }

    $doc = [ordered]@{
        epic    = [ordered]@{ title = $etitle; description = $edesc }
        stories = $stories
    }
    return (ConvertTo-JiraJsonValue $doc)
}

Export-ModuleMember -Function Get-JiraParsedTitle, Get-JiraParsedDescription,
Get-JiraParsedAcceptance, Get-JiraParsedDesign, Get-JiraParsedPriority,
Get-JiraParsedEstimation, Get-JiraParsedStory, Get-JiraParsedSpec
