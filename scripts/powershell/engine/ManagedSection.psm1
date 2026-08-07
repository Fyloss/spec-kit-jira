# engine/ManagedSection.psm1 — Generic managed-section byte-splice. Mirror of
# engine/managed_section.sh (US5, T063).
#
# Replaces only the region between (and including) the begin/end markers,
# preserves every byte outside it, renders the region with the host's dominant
# line ending, appends the region once when absent, and refuses malformed marker
# configurations with a located error and no content.
#
# NEUTRAL layer: zero Jira identifiers, never imports sink/. The marker tokens are
# PARAMETERS — the module knows nothing about README files or the extension.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force

function Get-JiraManagedSectionLineEnding {
    <#
    .SYNOPSIS
      Return the dominant line-ending token, 'CRLF' or 'LF'. A file with more
      CRLF than bare-LF terminators is CRLF; everything else (including an empty
      file) is LF, so a new file always uses LF. Byte-identical to the Bash port.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $lfTotal = ([regex]::Matches($Text, "`n")).Count
    $lfOnly = $lfTotal - $crlf
    if ($crlf -gt $lfOnly) { return 'CRLF' }
    return 'LF'
}

function Get-JiraManagedSectionLineNumber {
    # 1-based line numbers of every occurrence of $Token in $Text. Located-error
    # reporting only.
    param([string] $Text, [string] $Token)
    $nums = @()
    $idx = 0
    while (($p = $Text.IndexOf($Token, $idx)) -ge 0) {
        $nums += ($Text.Substring(0, $p) -split "`n").Count
        $idx = $p + $Token.Length
    }
    return ($nums -join ' ')
}

function Invoke-JiraManagedSectionSplice {
    <#
    .SYNOPSIS
      Splice a managed section into $Text. Returns { ExitCode; Content } — the
      same asymmetric-shape-but-identical-behaviour convention as the REST client.
      ExitCode 0 with the new bytes in Content on success; ExitCode 4 with empty
      Content (and a located error on stderr) when the markers are malformed.
    .DESCRIPTION
      $NewBlock is the full replacement region including its markers, LF-joined and
      without a trailing newline; the splice re-renders it with the host's dominant
      line ending. Every byte outside the region is preserved verbatim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $BeginToken,
        [Parameter(Mandatory)] [string] $EndToken,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $NewBlock
    )

    $eol = Get-JiraManagedSectionLineEnding -Text $Text
    $nl = if ($eol -eq 'CRLF') { "`r`n" } else { "`n" }
    $rblock = $NewBlock.Replace("`n", $nl)

    $bcount = ([regex]::Matches($Text, [regex]::Escape($BeginToken))).Count
    $ecount = ([regex]::Matches($Text, [regex]::Escape($EndToken))).Count

    # --- Absent: append the region once at the end of the file ----------------
    if ($bcount -eq 0 -and $ecount -eq 0) {
        if ($Text.Length -eq 0) {
            return [pscustomobject]@{ ExitCode = 0; Content = ($rblock + $nl) }
        }
        $sep = ''
        if (-not $Text.EndsWith("`n")) { $sep = $nl }
        $sep = $sep + $nl
        return [pscustomobject]@{ ExitCode = 0; Content = ($Text + $sep + $rblock + $nl) }
    }

    # --- Malformed: anything other than exactly one well-ordered pair ---------
    $beginIdx = $Text.IndexOf($BeginToken)
    $endIdx = $Text.IndexOf($EndToken)
    if ($bcount -ne 1 -or $ecount -ne 1 -or $beginIdx -ge $endIdx) {
        $bl = Get-JiraManagedSectionLineNumber -Text $Text -Token $BeginToken
        $el = Get-JiraManagedSectionLineNumber -Text $Text -Token $EndToken
        if ($bcount -ge 1 -and $ecount -eq 0) {
            [Console]::Error.WriteLine("managed section: begin marker at line(s) $bl with no matching end marker")
        }
        elseif ($ecount -ge 1 -and $bcount -eq 0) {
            [Console]::Error.WriteLine("managed section: end marker at line(s) $el with no matching begin marker")
        }
        elseif ($bcount -eq 1 -and $ecount -eq 1) {
            [Console]::Error.WriteLine("managed section: end marker at line $el precedes begin marker at line $bl")
        }
        else {
            [Console]::Error.WriteLine("managed section: malformed markers — begin at line(s) $bl, end at line(s) $el (expected exactly one of each)")
        }
        return [pscustomobject]@{ ExitCode = 4; Content = '' }
    }

    # --- Present: replace the region, preserving every byte outside it --------
    $prefix = $Text.Substring(0, $beginIdx)
    $lastNl = $prefix.LastIndexOf("`n")
    $before = if ($lastNl -ge 0) { $prefix.Substring(0, $lastNl + 1) } else { '' }

    $afterStart = $endIdx + $EndToken.Length
    $rest = $Text.Substring($afterStart)
    $firstNl = $rest.IndexOf("`n")
    $after = if ($firstNl -ge 0) { $rest.Substring($firstNl + 1) } else { '' }

    return [pscustomobject]@{ ExitCode = 0; Content = ($before + $rblock + $nl + $after) }
}

function Get-JiraNodeStringValue {
    # Recursively collect every string value inside an opaque JSON node. Mirror of
    # the Bash `[ node | .. | strings ]` descent — no host-format knowledge.
    param([object] $Node)
    $out = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Node) { return $out }
    if ($Node -is [string]) { $out.Add($Node); return $out }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { foreach ($s in (Get-JiraNodeStringValue $item)) { $out.Add($s) } }
        return $out
    }
    # Anything left (an object, or a boxed scalar such as an ADF `attrs.level`)
    # falls through to property enumeration. Guarding this with `-is
    # [psobject] -or ...` looks redundant but is NOT equivalent to omitting
    # it: under Set-StrictMode, some property-bearing values throw on
    # `.PSObject.Properties.Count` even though `-is [psobject]` is true for
    # them, defeating the intended short-circuit. `foreach` over Properties
    # is always safe — zero properties just means zero iterations.
    foreach ($p in $Node.PSObject.Properties) { foreach ($s in (Get-JiraNodeStringValue $p.Value)) { $out.Add($s) } }
    return $out
}

function Split-JiraManagedSectionPanel {
    <#
    .SYNOPSIS
      Split an existing description's content-node array at the managed panel
      marker. Mirror of managed_section_panel_split (US7, T075; 018, T007). The
      marker is a parameter; nodes are treated as opaque JSON. Returns canonical
      { prefix, managed, had_marker, marker_count } — everything before the first
      node carrying the marker is the human-authored prefix; everything from it
      onward is the previously-written managed section. marker_count is the
      number of nodes carrying the marker (0 = no boundary, 1 = well-formed,
      >1 = malformed, contract §1); had_marker is unchanged (marker_count > 0).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Marker,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ContentJson
    )
    $nodes = @()
    if (-not [string]::IsNullOrEmpty($ContentJson)) { $nodes = @($ContentJson | ConvertFrom-Json -Depth 100) }

    $idxs = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $strings = Get-JiraNodeStringValue $nodes[$i]
        if (($strings -join "`n").Contains($Marker)) { $idxs.Add($i) }
    }
    $count = $idxs.Count
    $k = if ($count -gt 0) { $idxs[0] } else { -1 }

    $prefix = [System.Collections.Generic.List[object]]::new()
    $managed = [System.Collections.Generic.List[object]]::new()
    if ($k -lt 0) {
        foreach ($n in $nodes) { $prefix.Add($n) }
        return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; managed = $managed; had_marker = $false; marker_count = $count }))
    }
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        if ($i -lt $k) { $prefix.Add($nodes[$i]) } else { $managed.Add($nodes[$i]) }
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; managed = $managed; had_marker = $true; marker_count = $count }))
}

function Split-JiraManagedSectionSuffix {
    <#
    .SYNOPSIS
      The migration split (018, T011, research R3, contract §3, data-model.md
      §2). Mirror of managed_section_suffix_split. PURE structural array
      comparison — no marker, no tracker vocabulary — used only on the
      migration path (marker_count == 0).
    .DESCRIPTION
      Returns canonical { prefix, matched }: matched is true when the existing
      content array (ContentJson) ends with ManagedJson, in which case prefix is
      everything before that matched suffix; false means the mirror's previous
      output could not be identified, and prefix is the WHOLE existing array —
      nothing is ever discarded (FR-020a/FR-020b). Built with List[object] and
      explicit .Add() throughout — never a bare array slice assignment — because
      PowerShell flattens a single-element array result of an if/else expression
      into its lone element on assignment (the same trap Split-JiraManagedSectionPanel
      already avoids the same way).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManagedJson,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ContentJson
    )
    $existing = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrEmpty($ContentJson)) {
        foreach ($n in @($ContentJson | ConvertFrom-Json -Depth 100)) { $existing.Add($n) }
    }
    $managed = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrEmpty($ManagedJson)) {
        foreach ($n in @($ManagedJson | ConvertFrom-Json -Depth 100)) { $managed.Add($n) }
    }

    $mlen = $managed.Count
    $elen = $existing.Count
    $prefix = [System.Collections.Generic.List[object]]::new()

    if ($mlen -eq 0) {
        foreach ($n in $existing) { $prefix.Add($n) }
        return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; matched = $true }))
    }
    if ($elen -lt $mlen) {
        foreach ($n in $existing) { $prefix.Add($n) }
        return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; matched = $false }))
    }

    $matched = $true
    for ($i = 0; $i -lt $mlen; $i++) {
        $ea = ConvertTo-JiraJsonValue $existing[$elen - $mlen + $i]
        $eb = ConvertTo-JiraJsonValue $managed[$i]
        if ($ea -ne $eb) { $matched = $false; break }
    }
    if (-not $matched) {
        foreach ($n in $existing) { $prefix.Add($n) }
        return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; matched = $false }))
    }
    for ($i = 0; $i -lt ($elen - $mlen); $i++) { $prefix.Add($existing[$i]) }
    return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; matched = $true }))
}

function Split-JiraManagedSectionOwnership {
    <#
    .SYNOPSIS
      The ownership decision (019, T007, contracts/ownership-decision.md §1).
      Mirror of managed_section_ownership_split.
    .DESCRIPTION
      Given the existing content-node array and an ownership of self|other|
      unknown (anything else MUST be treated as unknown), returns canonical
      { prefix, status }: status is 'ok' | 'malformed' | 'migrated-warned'.
      The marker count is decided BEFORE ownership (ordering is normative) —
      a description that already carries its boundary is never subject to
      the self branch.
        1. marker occurs more than once -> malformed, no `prefix` key
        2. marker occurs exactly once   -> prefix is the nodes above it, ok
        3. marker absent, ownership self   -> prefix [] (the fix, FR-002)
        4. marker absent, ownership other  -> Split-JiraManagedSectionSuffix
           (today's behaviour, unmodified) -> ok | migrated-warned
        5. marker absent, ownership unknown (or anything else) -> whole
           content preserved as prefix, migrated-warned (FR-004)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Marker,
        [Parameter(Mandatory)] [string] $ManagedJson,
        [Parameter(Mandatory)] [string] $Ownership,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ExistingJson
    )
    $existingContentJson = if ([string]::IsNullOrEmpty($ExistingJson)) { '[]' } else { $ExistingJson }

    $split = Split-JiraManagedSectionPanel -Marker $Marker -ContentJson $existingContentJson | ConvertFrom-Json -Depth 100
    $markerCount = [int]$split.marker_count

    if ($markerCount -gt 1) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ status = 'malformed' }))
    }
    if ($markerCount -eq 1) {
        $prefix = [System.Collections.Generic.List[object]]::new()
        foreach ($n in @($split.prefix)) { $prefix.Add($n) }
        return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; status = 'ok' }))
    }

    switch ($Ownership) {
        'self' {
            return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = [System.Collections.Generic.List[object]]::new(); status = 'ok' }))
        }
        'other' {
            $suffix = Split-JiraManagedSectionSuffix -ManagedJson $ManagedJson -ContentJson $existingContentJson | ConvertFrom-Json -Depth 100
            $prefix = [System.Collections.Generic.List[object]]::new()
            foreach ($n in @($suffix.prefix)) { $prefix.Add($n) }
            $status = if ($suffix.matched) { 'ok' } else { 'migrated-warned' }
            return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; status = $status }))
        }
        default {
            $prefix = [System.Collections.Generic.List[object]]::new()
            if (-not [string]::IsNullOrEmpty($existingContentJson)) {
                foreach ($n in @($existingContentJson | ConvertFrom-Json -Depth 100)) { $prefix.Add($n) }
            }
            return (ConvertTo-JiraJsonValue ([ordered]@{ prefix = $prefix; status = 'migrated-warned' }))
        }
    }
}

Export-ModuleMember -Function Get-JiraManagedSectionLineEnding, Invoke-JiraManagedSectionSplice, Split-JiraManagedSectionPanel, Split-JiraManagedSectionSuffix, Split-JiraManagedSectionOwnership
