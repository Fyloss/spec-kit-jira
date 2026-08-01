# engine/StoryMarker.psm1 — The durable story identifier: generation, grammar,
# and the byte-preserving splice that writes it into a specification. Mirror of
# engine/story_marker.sh (Phase 2; contracts/story-marker.md).
#
# NEUTRAL layer: zero Jira vocabulary. The identifier is an opaque random hex
# string and the ticket key it is ever paired with is opaque text handed in by
# the caller — exactly as ManagedSection.psm1 takes its markers as parameters
# without knowing about READMEs (Constitution VIII).
#
# The byte-offset, line-ending, atomic-write and line-replacement primitives
# live in MarkerSplice.psm1 (T064) — SpecMarker.psm1 reuses the same routines
# rather than duplicating a splice.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MarkerSplice.psm1') -Force

$script:JiraStoryMarkerIdIndex = 0

function New-JiraStoryMarkerId {
    <#
    .SYNOPSIS
      A new 16-lowercase-hex-character identifier: 8 bytes of cryptographic
      randomness, or the next value from the SPEC_KIT_JIRA_ID_SOURCE seam (a
      space/newline separated list, consumed in order and cycling) when set —
      the ONLY thing that keeps the two ports byte-identical under the
      conformance gate over an otherwise non-deterministic value. Mirror of
      story_marker_generate_id.
    #>
    [CmdletBinding()]
    param()
    $seq = $env:SPEC_KIT_JIRA_ID_SOURCE
    if (-not [string]::IsNullOrEmpty($seq)) {
        $ids = @($seq -split '\s+' | Where-Object { $_ -ne '' })
        $idx = $script:JiraStoryMarkerIdIndex % $ids.Count
        $script:JiraStoryMarkerIdIndex++
        return $ids[$idx]
    }
    $bytes = [byte[]]::new(8)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Format-JiraStoryMarkerLine {
    <#
    .SYNOPSIS
      The marker line's TEXT (no trailing newline). State: '' (bare, assigned)
      | 'creating' | 'bound' (requires -Ticket). Mirror of story_marker_format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $State = '',
        [string] $Ticket = ''
    )
    switch ($State) {
        'creating' { return "<!-- speckit-jira story=$Id creating -->" }
        'bound' { return "<!-- speckit-jira story=$Id ticket=$Ticket -->" }
        default { return "<!-- speckit-jira story=$Id -->" }
    }
}

function ConvertTo-JiraStoryMarkerInfo {
    <#
    .SYNOPSIS
      Classify one line against the grammar. Canonical JSON, mirror of
      story_marker_parse_line:
        {"kind":"none"}
        {"kind":"valid","id":"..","state":"assigned"}
        {"kind":"valid","id":"..","state":"creating"}
        {"kind":"valid","id":"..","state":"bound","ticket":".."}
        {"kind":"malformed","id":".."}

      A "spec=" body is a DIFFERENT marker (contracts/parent-marker.md
      "Non-collision with the story marker") and MUST fall through to
      'none' here, by construction: the body is matched against '^story='.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Line)
    $line = $Line.TrimEnd("`r")
    $t = $line.Trim()

    if ($t -notmatch '^<!--\s+speckit-jira\s+(.*)-->\s*$') {
        return (ConvertTo-JiraJsonValue ([ordered]@{ kind = 'none' }))
    }
    $body = $Matches[1].Trim()

    if ($body -notmatch '^story=(\S+)(\s+(.*))?$') {
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

function Get-JiraStoryMarkerAnchors {
    <#
    .SYNOPSIS
      The anchor line numbers (1-based), one per story section, IN DOCUMENT
      ORDER: every `^#{2,4}\s+User Story` heading; else the document's first
      H1; else 0 (the sole element), meaning "before line 1". Mirror of
      _smk_scan_anchors.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Names the set of anchor line numbers it derives; a singular name would misdescribe the value.')]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $lines = $Content -split "`n"
    $story = [System.Collections.Generic.List[int]]::new()
    $h1 = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineno = $i + 1
        $lc = $lines[$i].TrimEnd("`r")
        if ($lc -match '^#{2,4}\s+User\sStory') {
            $story.Add($lineno)
        }
        elseif ($h1 -eq 0 -and $lc -match '^#\s') {
            $h1 = $lineno
        }
    }
    if ($story.Count -gt 0) { return $story.ToArray() }
    if ($h1 -gt 0) { return @($h1) }
    return @(0)
}

function Test-JiraStoryMarkerSectionHasMarker {
    # $true when any line in the 1-based inclusive range carries a marker
    # attempt (kind != 'none'). Mirror of _smk_section_has_marker.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [int] $Start, [Parameter(Mandatory)] [int] $End)
    $lines = $Content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineno = $i + 1
        if ($lineno -lt $Start) { continue }
        if ($lineno -gt $End) { break }
        $info = ConvertTo-JiraStoryMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
        if ($info.kind -ne 'none') { return $true }
    }
    return $false
}

function Get-JiraStoryMarkerSectionInfo {
    <#
    .SYNOPSIS
      Full marker detail for the 1-based inclusive line range, on the WHOLE
      document (so line numbers in the result are absolute). Canonical JSON,
      mirror of story_marker_section_info:
        {"state":"absent","id":"","lines":[]}
        {"state":"assigned"|"creating"|"bound","id":"..","ticket":"..","lines":[N]}
        {"state":"malformed","id":"..","lines":[N]}
        {"state":"duplicate","id":"","lines":[N1,N2,...]}
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
        $info = ConvertTo-JiraStoryMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
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

function Find-JiraStoryMarkerLineForId {
    # The 1-based line number of the marker line naming <Id> (any state), or
    # 0 when absent. Mirror of _smk_find_line_for_id.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content, [Parameter(Mandatory)] [string] $Id)
    $lines = $Content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $info = ConvertTo-JiraStoryMarkerInfo -Line $lines[$i] | ConvertFrom-Json -Depth 20
        if ($info.kind -eq 'none') { continue }
        if ([string]$info.id -eq $Id) { return $i + 1 }
    }
    return 0
}

function Set-JiraStoryMarkerAssign {
    <#
    .SYNOPSIS
      Assign a fresh identifier to every story section that carries no marker
      at all, inserting one bare `story=<id>` line right after its anchor.
      IDEMPOTENT: when every section already has a marker attempt, the output
      is identical to the input. Mirror of story_marker_assign.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $content = $Text
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content

    $anchors = @(Get-JiraStoryMarkerAnchors -Content $content)
    $n = $anchors.Count
    $need = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        $a = $anchors[$i]
        $spanStart = if ($a -eq 0) { 1 } else { $a + 1 }
        $spanEnd = if ($i + 1 -lt $n) { $anchors[$i + 1] - 1 } else { Get-JiraMarkerSpliceLineCount -Content $content }
        if (-not (Test-JiraStoryMarkerSectionHasMarker -Content $content -Start $spanStart -End $spanEnd)) {
            $need.Add($a)
        }
    }

    if ($need.Count -eq 0) { return $content }

    # Identifiers are generated in ASCENDING document order (`need` already
    # is), but insertions happen in DESCENDING line order: an insertion
    # strictly after a lower anchor's line never shifts that lower anchor's
    # own line number — so pairing must happen BEFORE the sort.
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $need) {
        $pairs.Add([pscustomobject]@{ Anchor = $a; Id = (New-JiraStoryMarkerId) })
    }
    $sorted = $pairs | Sort-Object -Property Anchor -Descending

    foreach ($pair in $sorted) {
        $lineText = Format-JiraStoryMarkerLine -Id $pair.Id
        $content = Add-JiraMarkerSpliceAfterLine -Content $content -N $pair.Anchor -Text $lineText -Nl $nl
    }
    return $content
}

function Set-JiraStoryMarkerMarkCreating {
    <#
    .SYNOPSIS
      Replace the bare `story=<id>` line for each id in <IdsJson> (a JSON
      array) with `story=<id> creating`. IDs with no matching bare line are
      left untouched. Mirror of story_marker_mark_creating.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $IdsJson)
    $content = $Text
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    $ids = @($IdsJson | ConvertFrom-Json -Depth 20)
    foreach ($id in $ids) {
        $idStr = [string]$id
        if ([string]::IsNullOrEmpty($idStr)) { continue }
        $lineno = Find-JiraStoryMarkerLineForId -Content $content -Id $idStr
        if ($lineno -eq 0) { continue }
        $content = Set-JiraMarkerSpliceReplaceLine -Content $content -N $lineno -Text (Format-JiraStoryMarkerLine -Id $idStr -State 'creating') -Nl $nl
    }
    return $content
}

function Set-JiraStoryMarkerRecordTicket {
    <#
    .SYNOPSIS
      Replace the marker line for <Id> (whatever its state) with
      `story=<id> ticket=<key>`. A no-op when <Id> has no marker line at all.
      Mirror of story_marker_record_ticket.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Key)
    $content = $Text
    $nl = Get-JiraMarkerSpliceDominantNl -Content $content
    $lineno = Find-JiraStoryMarkerLineForId -Content $content -Id $Id
    if ($lineno -eq 0) { return $content }
    return (Set-JiraMarkerSpliceReplaceLine -Content $content -N $lineno -Text (Format-JiraStoryMarkerLine -Id $Id -State 'bound' -Ticket $Key) -Nl $nl)
}

Export-ModuleMember -Function New-JiraStoryMarkerId, Format-JiraStoryMarkerLine, ConvertTo-JiraStoryMarkerInfo, `
    Get-JiraStoryMarkerAnchors, Set-JiraStoryMarkerAssign, Set-JiraStoryMarkerMarkCreating, `
    Set-JiraStoryMarkerRecordTicket, Find-JiraStoryMarkerLineForId, `
    Get-JiraStoryMarkerSectionInfo
