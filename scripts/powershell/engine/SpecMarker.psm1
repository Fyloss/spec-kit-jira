# engine/SpecMarker.psm1 — The durable parent identifier: generation,
# grammar, and the byte-preserving splice that writes it into a
# specification. Mirror of engine/spec_marker.sh (Phase 5, US2;
# contracts/parent-marker.md).
#
# NEUTRAL layer: zero Jira vocabulary. Exactly one parent marker exists per
# specification file, so this module works over the WHOLE document rather
# than per-section, unlike StoryMarker.psm1.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MarkerSplice.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StoryMarker.psm1') -Force -Global # New-JiraStoryMarkerId — same identifier alphabet, same seam

function Format-JiraSpecMarkerLine {
    <#
    .SYNOPSIS
      The marker line's TEXT (no trailing newline). Mirror of
      spec_marker_format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $State = '',
        [string] $Ticket = ''
    )
    switch ($State) {
        'creating' { return "<!-- speckit-jira spec=$Id creating -->" }
        'bound' { return "<!-- speckit-jira spec=$Id ticket=$Ticket -->" }
        default { return "<!-- speckit-jira spec=$Id -->" }
    }
}

function ConvertTo-JiraSpecMarkerInfo {
    <#
    .SYNOPSIS
      Classify one line against the grammar. Canonical JSON, mirror of
      spec_marker_parse_line. A "story=" body MUST fall through to 'none'
      here, by construction (contracts/parent-marker.md "Non-collision").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Line)
    $line = $Line.TrimEnd("`r")
    $t = $line.Trim()

    if ($t -notmatch '^<!--\s+speckit-jira\s+(.*)-->\s*$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }
    $body = $Matches[1].Trim()

    if ($body -notmatch '^spec=(\S+)(\s+(.*))?$') {
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

function Get-JiraSpecMarkerH1OrZero {
    # The 1-based line number of the document's first H1 (`^#\s`), or 0 when
    # there is none. Mirror of _smkp_h1_or_zero.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $lines = $Content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lc = $lines[$i].TrimEnd("`r")
        if ($lc -match '^#\s') { return $i + 1 }
    }
    return 0
}

function Get-JiraSpecMarkerDocumentInfo {
    <#
    .SYNOPSIS
      Full marker detail over the WHOLE document. Canonical JSON, mirror of
      spec_marker_document_info.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $lines = $Content -split "`n"
    $foundLines = [System.Collections.Generic.List[int]]::new()
    $foundIds = [System.Collections.Generic.List[string]]::new()
    $foundStates = [System.Collections.Generic.List[string]]::new()
    $foundTickets = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $info = ConvertTo-JiraSpecMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
        if ($info.kind -eq 'none') { continue }
        $foundLines.Add($i + 1)
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

function Set-JiraSpecMarkerAssign {
    <#
    .SYNOPSIS
      When the document carries no spec= marker attempt at all, insert one
      bare `spec=<id>` line immediately after the H1, or as line 1 when
      there is no H1. IDEMPOTENT: a document that already carries a marker
      attempt (valid or malformed) is returned unchanged. Mirror of
      spec_marker_assign.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $content = $Text
    $info = Get-JiraSpecMarkerDocumentInfo -Content $content | ConvertFrom-Json -Depth 20
    if ($info.state -ne 'absent') { return $content }

    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    $anchor = Get-JiraSpecMarkerH1OrZero -Content $content
    $id = New-JiraStoryMarkerId
    $lineText = Format-JiraSpecMarkerLine -Id $id
    return (Add-JiraMarkerSpliceAfterLine -Content $content -N $anchor -Text $lineText -Nl $nl)
}

function Set-JiraSpecMarkerMarkCreating {
    <#
    .SYNOPSIS
      Replace the bare `spec=<id>` line with `spec=<id> creating`. A no-op
      when <Id> has no matching bare line. Mirror of
      spec_marker_mark_creating.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $Id)
    $content = $Text
    $info = Get-JiraSpecMarkerDocumentInfo -Content $content | ConvertFrom-Json -Depth 20
    if ([string]$info.id -ne $Id) { return $content }
    $lineno = [int]$info.lines[0]
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    return (Set-JiraMarkerSpliceReplaceLine -Content $content -N $lineno -Text (Format-JiraSpecMarkerLine -Id $Id -State 'creating') -Nl $nl)
}

function Set-JiraSpecMarkerRecordTicket {
    <#
    .SYNOPSIS
      Replace the marker line for <Id> (whatever its state) with
      `spec=<id> ticket=<key>`. A no-op when <Id> has no marker line at all.
      Mirror of spec_marker_record_ticket.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Key)
    $content = $Text
    $info = Get-JiraSpecMarkerDocumentInfo -Content $content | ConvertFrom-Json -Depth 20
    if ([string]$info.id -ne $Id) { return $content }
    $lineno = [int]$info.lines[0]
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    return (Set-JiraMarkerSpliceReplaceLine -Content $content -N $lineno -Text (Format-JiraSpecMarkerLine -Id $Id -State 'bound' -Ticket $Key) -Nl $nl)
}

Export-ModuleMember -Function Format-JiraSpecMarkerLine, ConvertTo-JiraSpecMarkerInfo, `
    Get-JiraSpecMarkerDocumentInfo, Set-JiraSpecMarkerAssign, Set-JiraSpecMarkerMarkCreating, `
    Set-JiraSpecMarkerRecordTicket
