# engine/TasksParse.psm1 — Neutral tasks.md reader. Mirror of
# engine/tasks_parse.sh (Phase 2; contracts/task-tier.md §2; data-model.md §2).
#
# NEUTRAL layer: no Jira identifier, issue type, or project key ever crosses
# this layer (FR-005).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MarkerSplice.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StoryMarker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TaskMarker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Markdown.psm1') -Force # a task's own text is author prose (016, FR-017)

$script:JiraTaskLineCaptureRegex = '^-\s+\[([ xX])\]\s+(T[0-9]+[A-Za-z]?)\s*(.*)$'
$script:JiraPhaseHeadingRegex = '^##\s+(Phase.*)$'
$script:JiraHeadingRegex = '^#{1,6}\s'
$script:JiraUserStoryOrdinalRegex = 'User\sStory\s+([0-9]+)'
$script:JiraMarkerLineRegex = '^\s*<!--\s+speckit-jira\s+.*-->\s*$'

function ConvertTo-JiraTasksParseLocalId {
    param([Parameter(Mandatory)] [string] $InfoJson)
    $info = $InfoJson | ConvertFrom-Json -Depth 20
    switch ($info.state) {
        'absent' { return '' }
        'duplicate' { return (New-JiraStoryMarkerId) }
        default { return [string]$info.id }
    }
}

function Get-JiraTaskParseFile {
    # Backtick-quoted spans that look like a file path: no whitespace,
    # contains a "/". Mirror of _tp_extract_files.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $acc = [System.Collections.Generic.List[string]]::new()
    $spans = [regex]::Matches($Text, '`([^`]+)`')
    foreach ($m in $spans) {
        $span = $m.Groups[1].Value
        if (($span -notmatch '\s') -and ($span -match '/')) {
            $acc.Add($span)
        }
    }
    return $acc.ToArray()
}

function Get-JiraTasksParseDependsOn {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $acc = [System.Collections.Generic.List[string]]::new()
    if ($Text -match '\(depends\son\s([^\)]+)\)') {
        $list = $Matches[1]
        foreach ($tok in ($list -split ',')) {
            $t = $tok.Trim()
            if ($t -match '^T[0-9]+[A-Za-z]?$') { $acc.Add($t) }
        }
    }
    return $acc.ToArray()
}

function Remove-JiraTaskParseTag {
    # Remove a leading [P] and/or [US<N>] token from the front of a task's
    # own line text, then trim. Mirror of _tp_strip_tags.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $s = $Text
    $changed = $true
    while ($changed) {
        $changed = $false
        $t = $s.Trim()
        if ($t -match '^\[P\]\s*(.*)$') { $s = $Matches[1]; $changed = $true }
        elseif ($t -match '^\[US[0-9]+\]\s*(.*)$') { $s = $Matches[1]; $changed = $true }
        else { $s = $t }
    }
    return $s.Trim()
}

function Remove-JiraTasksParseDependsOn {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ($Text -match '^(.*)\(depends\son\s[^\)]+\)\s*$') {
        return $Matches[1].Trim()
    }
    return $Text
}

function ConvertTo-JiraTasksParseDocument {
    <#
    .SYNOPSIS
      Read tasks.md text; emit {"tasks":[...], "skipped":[...]}. Mirror of
      tasks_parse_document.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ skipped = @(); tasks = @() }))
    }

    $lines = $Text -split "`n"
    $totalLines = $lines.Count

    $anchorLines = [System.Collections.Generic.List[int]]::new()
    $anchorDone = [System.Collections.Generic.List[string]]::new()
    $anchorRef = [System.Collections.Generic.List[string]]::new()
    $anchorRest = [System.Collections.Generic.List[string]]::new()
    $anchorPhase = [System.Collections.Generic.List[string]]::new()
    $anchorPhaseOrdinal = [System.Collections.Generic.List[string]]::new()

    $phaseText = ''
    $phaseOrdinal = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineno = $i + 1
        $lc = $lines[$i].TrimEnd("`r")
        if ($lc -match $script:JiraPhaseHeadingRegex) {
            $phaseText = $Matches[1].Trim()
            if ($phaseText -match $script:JiraUserStoryOrdinalRegex) {
                $phaseOrdinal = $Matches[1]
            }
            else {
                $phaseOrdinal = ''
            }
            continue
        }
        if ($lc -match $script:JiraTaskLineCaptureRegex) {
            $anchorLines.Add($lineno)
            $anchorDone.Add($Matches[1])
            $anchorRef.Add($Matches[2])
            $anchorRest.Add($Matches[3])
            $anchorPhase.Add($phaseText)
            $anchorPhaseOrdinal.Add($phaseOrdinal)
        }
    }

    $n = $anchorLines.Count
    if ($n -eq 0) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ skipped = @(); tasks = @() }))
    }

    $tasks = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $n; $i++) {
        $a = $anchorLines[$i]
        $spanEnd = if ($i + 1 -lt $n) { $anchorLines[$i + 1] - 1 } else { $totalLines }

        $minfoJson = Get-JiraTaskMarkerSectionInfo -Content $Text -Start ($a + 1) -End $spanEnd
        $localId = ConvertTo-JiraTasksParseLocalId -InfoJson $minfoJson

        $cont = [System.Collections.Generic.List[string]]::new()
        $started = $false
        for ($j = $a + 1; $j -le $spanEnd; $j++) {
            $cl = $lines[$j - 1].TrimEnd("`r")
            if ($cl -match $script:JiraMarkerLineRegex) { continue }
            $ct = $cl.Trim()
            if ([string]::IsNullOrEmpty($ct)) {
                if ($started) { break } else { continue }
            }
            if ($cl -match $script:JiraHeadingRegex) { break }
            $cont.Add($ct)
            $started = $true
        }

        $rest = $anchorRest[$i]
        $fullText = $rest
        foreach ($c in $cont) { if ($c) { $fullText = "$fullText $c" } }

        $parallel = ($rest -match '\[P\]')

        $tagOrdinal = ''
        $attributionSource = 'none'
        if ($rest -match '\[US([0-9]+)\]') {
            $tagOrdinal = $Matches[1]
            $attributionSource = 'tag'
        }
        elseif ($anchorPhaseOrdinal[$i]) {
            $tagOrdinal = $anchorPhaseOrdinal[$i]
            $attributionSource = 'heading'
        }

        $files = @(Get-JiraTaskParseFile -Text $fullText)
        $dependsOn = @(Get-JiraTasksParseDependsOn -Text $fullText)

        $title = Remove-JiraTaskParseTag -Text $rest
        $title = Remove-JiraTasksParseDependsOn -Text $title
        foreach ($c in $cont) {
            if (-not $c) { continue }
            $cc = Remove-JiraTasksParseDependsOn -Text $c
            if ($cc) { $title = "$title $cc" }
        }
        $title = $title.Trim()

        $taskRef = $anchorRef[$i]
        if ([string]::IsNullOrEmpty($title)) {
            $skipped.Add([ordered]@{ task_ref = $taskRef; reason = 'empty title' })
            continue
        }

        $doneBool = ($anchorDone[$i] -eq 'x' -or $anchorDone[$i] -eq 'X')

        # 016, FR-017: the task's own text is author prose and carries the same
        # markup spec prose does (backtick-quoted paths above all), so it is
        # tokenized into marked spans here rather than shipped as a raw string.
        # $title itself stays verbatim — it becomes the Jira summary, a
        # plain-text field where no rich text is possible (data-model.md §3).
        $descSpans = @(ConvertTo-JiraMarkdownInlineSpanList -Text $title | ConvertFrom-Json -Depth 100)
        $descBlocks = @([ordered]@{ type = 'paragraph'; spans = $descSpans })

        $ordinalValue = if ($tagOrdinal) { [int]$tagOrdinal } else { $null }

        $markerObj = $minfoJson | ConvertFrom-Json -Depth 20

        $task = [ordered]@{
            local_id      = $localId
            task_ref      = $taskRef
            title         = $title
            description   = [ordered]@{ blocks = $descBlocks }
            attribution   = [ordered]@{ story_ordinal = $ordinalValue; source = $attributionSource }
            phase         = $anchorPhase[$i]
            parallel      = $parallel
            files         = $files
            depends_on    = $dependsOn
            done          = $doneBool
            marker        = $markerObj
        }
        $tasks.Add($task)
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{ skipped = $skipped.ToArray(); tasks = $tasks.ToArray() }))
}

Export-ModuleMember -Function ConvertTo-JiraTasksParseDocument, Get-JiraTaskParseFile, `
    Get-JiraTasksParseDependsOn, Remove-JiraTaskParseTag, Remove-JiraTasksParseDependsOn
