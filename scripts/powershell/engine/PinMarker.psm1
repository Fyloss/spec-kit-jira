# engine/PinMarker.psm1 — The pinning marker: grammar, placement, the
# four-property validation, and consume-at-binding replacement (027,
# research R3, contracts/pin-marker.md). Mirror of engine/pin_marker.sh.
#
# ENGINE module: handles an OPAQUE ticket string, exactly as StoryMarker.psm1
# does with `ticket=`. Reuses MarkerSplice.psm1's byte-preserving splice and
# StoryMarker.psm1's Get-JiraStoryMarkerAnchors heading scan.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MarkerSplice.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StoryMarker.psm1') -Force

function Format-JiraPinMarkerLine {
    <#
    .SYNOPSIS
      §2, the written form. Mirror of pin_marker_format.
    #>
    param([Parameter(Mandatory)] [string] $Key)
    return "<!-- speckit-jira pin=$Key -->"
}

function ConvertTo-JiraPinMarkerInfo {
    <#
    .SYNOPSIS
      §3 grammar. Mirror of pin_marker_parse_line. A `story=`, `spec=`, or
      `task=` body falls through to 'none' by construction.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Line)
    $line = $Line.TrimEnd("`r")
    $t = $line.Trim()

    if ($t -notmatch '^<!--\s+speckit-jira\s+(.*)-->\s*$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }
    $body = $Matches[1].Trim()

    if ($body -notmatch '^pin=(.*)$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }
    $val = $Matches[1]
    if ([string]::IsNullOrEmpty($val) -or $val -match '\s') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'malformed' }))
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'valid'; key = $val }))
}

function Get-JiraPinMarkerAnchors {
    <#
    .SYNOPSIS
      §4 placement. Mirror of pin_marker_anchors — verbatim
      Get-JiraStoryMarkerAnchors.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    return (Get-JiraStoryMarkerAnchors -Content $Content)
}

function Test-JiraPinMarkerValidate {
    <#
    .SYNOPSIS
      §5, FR-058. Mirror of pin_marker_validate. Prints a canonical JSON
      array of violations, empty when all four properties hold.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath, [Parameter(Mandatory)] [string] $DesignatorsJson)

    $content = [System.IO.File]::ReadAllText($SpecPath)
    $anchors = @(Get-JiraPinMarkerAnchors -Content $content | ForEach-Object { [int]$_ })
    $n = $anchors.Count
    $totalLines = (Get-JiraMarkerSpliceLineCount -Content $content)

    $lines = $content -split "`n"
    $markerLines = [System.Collections.Generic.List[int]]::new()
    $markerKeys = [System.Collections.Generic.List[string]]::new()
    $markerMalformed = [System.Collections.Generic.List[bool]]::new()
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $lineno = $li + 1
        $info = ConvertTo-JiraPinMarkerInfo -Line $lines[$li] | ConvertFrom-Json -Depth 20
        if ($info.kind -eq 'none') { continue }
        $markerLines.Add($lineno)
        if ($info.kind -eq 'valid') {
            $markerKeys.Add([string]$info.key)
            $markerMalformed.Add($false)
        }
        else {
            $markerKeys.Add('')
            $markerMalformed.Add($true)
        }
    }

    $markerSection = [System.Collections.Generic.List[int]]::new()
    foreach ($m in $markerLines) {
        $sec = -1
        for ($i = 0; $i -lt $n; $i++) {
            $a = $anchors[$i]
            $spanStart = if ($a -eq 0) { 1 } else { $a + 1 }
            $spanEnd = if ($i + 1 -lt $n) { $anchors[$i + 1] - 1 } else { $totalLines }
            if ($m -ge $spanStart -and $m -le $spanEnd) { $sec = $i; break }
        }
        $markerSection.Add($sec)
    }

    $violations = [System.Collections.Generic.List[object]]::new()

    for ($mi = 0; $mi -lt $markerLines.Count; $mi++) {
        if ($markerMalformed[$mi]) {
            $violations.Add([ordered]@{ kind = 'malformed'; line = $markerLines[$mi] })
        }
    }

    $designators = @($DesignatorsJson | ConvertFrom-Json -Depth 20)
    foreach ($dk in $designators) {
        $found = 0
        for ($mj = 0; $mj -lt $markerKeys.Count; $mj++) {
            if (-not $markerMalformed[$mj] -and $markerKeys[$mj] -eq $dk) { $found++ }
        }
        if ($found -eq 0) { $violations.Add([ordered]@{ kind = 'missing'; key = $dk }) }
    }

    $seen = @{}
    for ($mi = 0; $mi -lt $markerKeys.Count; $mi++) {
        if ($markerMalformed[$mi]) { continue }
        $k = $markerKeys[$mi]
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $isDesignated = $designators -contains $k
        $matchLines = [System.Collections.Generic.List[int]]::new()
        for ($mj = 0; $mj -lt $markerKeys.Count; $mj++) {
            if (-not $markerMalformed[$mj] -and $markerKeys[$mj] -eq $k) { $matchLines.Add($markerLines[$mj]) }
        }
        if (-not $isDesignated) {
            $violations.Add([ordered]@{ kind = 'orphan'; key = $k; lines = $matchLines })
        }
        elseif ($matchLines.Count -gt 1) {
            $violations.Add([ordered]@{ kind = 'split'; key = $k; lines = $matchLines })
        }
    }

    $sectionCount = @{}
    for ($mi = 0; $mi -lt $markerSection.Count; $mi++) {
        $sec = $markerSection[$mi]
        if ($sec -lt 0) { continue }
        if (-not $sectionCount.ContainsKey($sec)) { $sectionCount[$sec] = 0 }
        $sectionCount[$sec]++
    }
    foreach ($sec in $sectionCount.Keys) {
        if ($sectionCount[$sec] -gt 1) {
            $secLines = [System.Collections.Generic.List[int]]::new()
            for ($mj = 0; $mj -lt $markerSection.Count; $mj++) {
                if ($markerSection[$mj] -eq $sec) { $secLines.Add($markerLines[$mj]) }
            }
            $violations.Add([ordered]@{ kind = 'merge'; lines = $secLines })
        }
    }

    $fileOrder = [System.Collections.Generic.List[string]]::new()
    for ($mi = 0; $mi -lt $markerKeys.Count; $mi++) {
        if (-not $markerMalformed[$mi]) { $fileOrder.Add($markerKeys[$mi]) }
    }
    $gotFiltered = [System.Collections.Generic.List[string]]::new()
    $addedSet = @{}
    foreach ($k in $fileOrder) {
        if (($designators -contains $k) -and (-not $addedSet.ContainsKey($k))) {
            $gotFiltered.Add($k)
            $addedSet[$k] = $true
        }
    }
    $sameOrder = ($gotFiltered.Count -eq $designators.Count)
    if ($sameOrder) {
        for ($i = 0; $i -lt $designators.Count; $i++) {
            if ($gotFiltered[$i] -ne $designators[$i]) { $sameOrder = $false; break }
        }
    }
    if (-not $sameOrder) { $violations.Add([ordered]@{ kind = 'reorder' }) }

    return (ConvertTo-JiraJsonValue $violations)
}

function Get-JiraPinMarkerProvenance {
    <#
    .SYNOPSIS
      FR-032: one entry per drafted user-story section, in document order,
      naming its heading text and its source — the designated key whose
      valid marker falls within its span, or 'new' when none does. Mirror
      of pin_marker_provenance.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [string] $DesignatorsJson)

    $anchors = @(Get-JiraPinMarkerAnchors -Content $Content | ForEach-Object { [int]$_ })
    $n = $anchors.Count
    $totalLines = (Get-JiraMarkerSpliceLineCount -Content $Content)
    $lines = $Content -split "`n"
    $designators = @($DesignatorsJson | ConvertFrom-Json -Depth 20)

    $markerLines = [System.Collections.Generic.List[int]]::new()
    $markerKeys = [System.Collections.Generic.List[string]]::new()
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $info = ConvertTo-JiraPinMarkerInfo -Line $lines[$li] | ConvertFrom-Json -Depth 20
        if ($info.kind -ne 'valid') { continue }
        $markerLines.Add($li + 1)
        $markerKeys.Add([string]$info.key)
    }

    $result = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        $a = $anchors[$i]
        $source = 'new'
        if ($a -eq 0) {
            $spanStart = 1
            $heading = 'Overview'
        }
        else {
            $spanStart = $a + 1
            $raw = $lines[$a - 1].TrimEnd("`r")
            if ($raw -match '^#+\s+(.*)$') { $heading = $Matches[1] } else { $heading = $raw }
        }
        $spanEnd = if ($i + 1 -lt $n) { $anchors[$i + 1] - 1 } else { $totalLines }
        for ($mj = 0; $mj -lt $markerLines.Count; $mj++) {
            $m = $markerLines[$mj]
            if ($m -ge $spanStart -and $m -le $spanEnd) {
                $mk = $markerKeys[$mj]
                if ($designators -contains $mk) { $source = $mk }
                break
            }
        }
        $result.Add([ordered]@{ heading = $heading; source = $source })
    }
    return (ConvertTo-JiraJsonValue $result)
}

function ConvertTo-JiraPinMarkerConsumed {
    <#
    .SYNOPSIS
      §6: replace the pin=<Key> marker line IN PLACE with
      <ReplacementLine>, preserving every other byte and the line ending
      (P-7). Mirror of pin_marker_consume. A no-op when <Key> has no pin
      marker line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content,
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $ReplacementLine,
        [Parameter(Mandatory)] [string] $Nl
    )
    $lines = $Content -split "`n"
    $found = 0
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $info = ConvertTo-JiraPinMarkerInfo -Line $lines[$li] | ConvertFrom-Json -Depth 20
        if ($info.kind -eq 'none') { continue }
        if ($info.kind -eq 'valid' -and [string]$info.key -eq $Key) { $found = $li + 1; break }
    }
    if ($found -eq 0) { return $Content }
    return (Set-JiraMarkerSpliceReplaceLine -Content $Content -N $found -Text $ReplacementLine -Nl $Nl)
}

Export-ModuleMember -Function Format-JiraPinMarkerLine, ConvertTo-JiraPinMarkerInfo, Get-JiraPinMarkerAnchors, `
    Test-JiraPinMarkerValidate, Get-JiraPinMarkerProvenance, ConvertTo-JiraPinMarkerConsumed
