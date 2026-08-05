# engine/TaskMarker.psm1 — The durable task identifier: generation, grammar,
# and the byte-preserving splice that writes it into tasks.md. Mirror of
# engine/task_marker.sh (Phase 2; contracts/task-tier.md §1).
#
# NEUTRAL layer: zero Jira vocabulary. This module defines NO generator of
# its own: New-JiraStoryMarkerId is reused unchanged so all three grammars
# share one SPEC_KIT_JIRA_ID_SOURCE seam cursor and stay byte-identical
# across ports.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MarkerSplice.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StoryMarker.psm1') -Force -Global # New-JiraStoryMarkerId — same convention as SpecMarker.psm1

# A task line: a checkbox followed by a task reference (T014). Deliberately
# minimal — full task recognition lives in TasksParse.psm1.
$script:JiraTaskLineRegex = '^-\s+\[[ xX]\]\s+T[0-9]+[A-Za-z]?(\s|$)'

function Format-JiraTaskMarkerLine {
    <#
    .SYNOPSIS
      The marker line's TEXT (no trailing newline). Mirror of
      task_marker_format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $State = '',
        [string] $Ticket = ''
    )
    switch ($State) {
        'creating' { return "<!-- speckit-jira task=$Id creating -->" }
        'bound' { return "<!-- speckit-jira task=$Id ticket=$Ticket -->" }
        default { return "<!-- speckit-jira task=$Id -->" }
    }
}

function ConvertTo-JiraTaskMarkerInfo {
    <#
    .SYNOPSIS
      Classify one line against the grammar. Mirror of
      task_marker_parse_line. A "story=" or "spec=" body parses as 'none'
      here, by construction: the body is matched against '^task='.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Line)
    $line = $Line.TrimEnd("`r")
    $t = $line.Trim()

    if ($t -notmatch '^<!--\s+speckit-jira\s+(.*)-->\s*$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }
    $body = $Matches[1].Trim()

    if ($body -notmatch '^task=(\S+)(\s+(.*))?$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }
    $idval = $Matches[1]
    $tail = if ($Matches[3]) { $Matches[3] } else { '' }

    if ($idval -notmatch '^[0-9a-f]{16}$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }

    $tail = $tail.Trim()
    if ([string]::IsNullOrEmpty($tail)) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'valid'; id = $idval; state = 'assigned' }))
    }
    if ($tail -eq 'creating') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'valid'; id = $idval; state = 'creating' }))
    }
    if ($tail -match '^ticket=(\S+)$') {
        $key = $Matches[1]
        if ($key -cmatch '^[A-Z][A-Z0-9_]*-[1-9][0-9]*$') {
            return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'valid'; id = $idval; state = 'bound'; ticket = $key }))
        }
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'malformed'; id = $idval }))
}

function Get-JiraTaskMarkerAnchor {
    <#
    .SYNOPSIS
      The anchor line numbers (1-based), one per task line, IN DOCUMENT
      ORDER. Unlike the story marker's scan there is NO fallback anchor: a
      file with no recognisable task line yields an empty array. Mirror of
      _tmk_scan_anchors.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $lines = $Content -split "`n"
    $anchors = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineno = $i + 1
        $lc = $lines[$i].TrimEnd("`r")
        if ($lc -match $script:JiraTaskLineRegex) {
            $anchors.Add($lineno)
        }
    }
    return $anchors.ToArray()
}

function Test-JiraTaskMarkerSectionHasMarker {
    # Mirror of _tmk_section_has_marker.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [int] $Start, [Parameter(Mandatory)] [int] $End)
    $lines = $Content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineno = $i + 1
        if ($lineno -lt $Start) { continue }
        if ($lineno -gt $End) { break }
        $info = ConvertTo-JiraTaskMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
        if ($info.kind -ne 'none') { return $true }
    }
    return $false
}

function Get-JiraTaskMarkerSectionInfo {
    <#
    .SYNOPSIS
      Full marker detail for the 1-based inclusive line range, on the WHOLE
      document. Mirror of task_marker_section_info.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [int] $Start, [Parameter(Mandatory)] [int] $End)
    $lines = $Content -split "`n"
    $foundLines = [System.Collections.Generic.List[int]]::new()
    $foundIds = [System.Collections.Generic.List[string]]::new()
    $foundStates = [System.Collections.Generic.List[string]]::new()
    $foundTickets = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineno = $i + 1
        if ($lineno -lt $Start) { continue }
        if ($lineno -gt $End) { break }
        $info = ConvertTo-JiraTaskMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
        if ($info.kind -eq 'none') { continue }
        $foundLines.Add($lineno)
        if ($info.kind -eq 'valid') {
            $foundIds.Add([string]$info.id)
            $foundStates.Add([string]$info.state)
            $foundTickets.Add($(if ($info.PSObject.Properties.Name -contains 'ticket') { [string]$info.ticket } else { '' }))
        }
        else {
            $foundIds.Add([string]$info.id)
            $foundStates.Add('malformed')
            $foundTickets.Add('')
        }
    }
    $count = $foundLines.Count
    if ($count -eq 0) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ state = 'absent'; id = ''; lines = @() }))
    }
    if ($count -eq 1) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ state = $foundStates[0]; id = $foundIds[0]; ticket = $foundTickets[0]; lines = @($foundLines[0]) }))
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ state = 'duplicate'; id = ''; lines = @($foundLines) }))
}

function Find-JiraTaskMarkerLineForId {
    # Mirror of _tmk_find_line_for_id.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [string] $Id)
    $lines = $Content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $info = ConvertTo-JiraTaskMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
        if ($info.kind -eq 'none') { continue }
        if ([string]$info.id -eq $Id) { return $i + 1 }
    }
    return 0
}

function Set-JiraTaskMarkerAssign {
    <#
    .SYNOPSIS
      Assign a fresh identifier to every task line that carries no marker
      attempt, inserting one bare `task=<id>` line right after it.
      IDEMPOTENT. Mirror of task_marker_assign.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $content = $Text
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content

    $anchors = @(Get-JiraTaskMarkerAnchor -Content $content)
    $n = $anchors.Count
    if ($n -eq 0) { return $content }

    $need = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        $a = $anchors[$i]
        $spanStart = $a + 1
        $spanEnd = if ($i + 1 -lt $n) { $anchors[$i + 1] - 1 } else { Get-JiraMarkerSpliceLineCount -Content $content }
        if (-not (Test-JiraTaskMarkerSectionHasMarker -Content $content -Start $spanStart -End $spanEnd)) {
            $need.Add($a)
        }
    }

    if ($need.Count -eq 0) { return $content }

    # Identifiers are generated in ASCENDING document order, but insertions
    # happen in DESCENDING line order — pairing before the sort, exactly as
    # Set-JiraStoryMarkerAssign does.
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $need) {
        $pairs.Add([pscustomobject]@{ Anchor = $a; Id = (New-JiraStoryMarkerId) })
    }
    $sorted = $pairs | Sort-Object -Property Anchor -Descending

    foreach ($pair in $sorted) {
        $lineText = Format-JiraTaskMarkerLine -Id $pair.Id
        $content = Add-JiraMarkerSpliceAfterLine -Content $content -N $pair.Anchor -Text $lineText -Nl $nl
    }
    return $content
}

function Set-JiraTaskMarkerMarkCreating {
    <#
    .SYNOPSIS
      Replace the bare `task=<id>` line for each id in <IdsJson> with
      `task=<id> creating`. Mirror of task_marker_mark_creating.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $IdsJson)
    $content = $Text
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    $ids = @($IdsJson | ConvertFrom-Json -Depth 20)
    foreach ($id in $ids) {
        $idStr = [string]$id
        if ([string]::IsNullOrEmpty($idStr)) { continue }
        $lineno = Find-JiraTaskMarkerLineForId -Content $content -Id $idStr
        if ($lineno -eq 0) { continue }
        $content = Set-JiraMarkerSpliceReplaceLine -Content $content -N $lineno -Text (Format-JiraTaskMarkerLine -Id $idStr -State 'creating') -Nl $nl
    }
    return $content
}

function Set-JiraTaskMarkerRecordTicket {
    <#
    .SYNOPSIS
      Replace the marker line for <Id> with `task=<id> ticket=<key>`.
      Mirror of task_marker_record_ticket.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Key)
    $content = $Text
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    $lineno = Find-JiraTaskMarkerLineForId -Content $content -Id $Id
    if ($lineno -eq 0) { return $content }
    return (Set-JiraMarkerSpliceReplaceLine -Content $content -N $lineno -Text (Format-JiraTaskMarkerLine -Id $Id -State 'bound' -Ticket $Key) -Nl $nl)
}

Export-ModuleMember -Function Format-JiraTaskMarkerLine, ConvertTo-JiraTaskMarkerInfo, `
    Get-JiraTaskMarkerAnchor, Set-JiraTaskMarkerAssign, Set-JiraTaskMarkerMarkCreating, `
    Set-JiraTaskMarkerRecordTicket, Find-JiraTaskMarkerLineForId, Get-JiraTaskMarkerSectionInfo
