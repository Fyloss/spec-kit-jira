# sink/jira/Designator.psm1 — Designator grammar, URL reduction, host
# comparison, order and de-duplication (027, research R2,
# contracts/designator-grammar.md). Mirror of sink/jira/designator.sh.
#
# SINK module: owns the issue-key regex and the Atlassian host comparison.
# Every function here is a pure function of its arguments — no network call
# is issued anywhere in this file.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1')
# 032 — the one origin grammar (C1); this module owned a second one until then.
# No -Force: forcing a lib dependency from a sink module reimports it into the
# caller's scope and clobbers state the caller already holds.
Import-Module (Join-Path $PSScriptRoot '../../lib/UrlOrigin.psm1') -Force

function Get-JiraDesignatorKey {
    <#
    .SYNOPSIS
      §2: the key grammar, applied after upper-casing. Mirror of
      designator_reduce_key. Returns the upper-cased key, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Raw)
    $raw = $Raw.TrimEnd("`r")
    $up = $raw.ToUpperInvariant()
    if ($up -cmatch '^[A-Z][A-Z0-9_]+-[0-9]+$') { return $up }
    return $null
}

function Get-JiraDesignatorUrlCandidate {
    <#
    .SYNOPSIS
      §3, rules 1-4. Mirror of designator_reduce_url_candidate. Returns the
      raw (not yet upper-cased or grammar-validated) candidate, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Raw)
    $raw = $Raw.TrimEnd("`r")
    $nofrag = $raw.Split('#')[0]
    $query = ''
    $noquery = $nofrag
    $qIdx = $nofrag.IndexOf('?')
    if ($qIdx -ge 0) {
        $query = $nofrag.Substring($qIdx + 1)
        $noquery = $nofrag.Substring(0, $qIdx)
    }

    if ($query) {
        $sel = ''
        foreach ($pair in ($query -split '&')) {
            if ($pair.StartsWith('selectedIssue=')) { $sel = $pair.Substring('selectedIssue='.Length) }
        }
        if ($sel) {
            return [System.Uri]::UnescapeDataString($sel)
        }
    }

    if ($noquery.Contains('/browse/')) {
        $after = $noquery.Substring($noquery.IndexOf('/browse/') + '/browse/'.Length)
        $seg = $after.Split('/')[0]
        if ($seg) { return $seg }
    }

    $last = $noquery.Split('/')[-1]
    if ($last -and (Get-JiraDesignatorKey -Raw $last)) { return $last }

    return $null
}

function Test-JiraDesignatorHostMatch {
    <#
    .SYNOPSIS
      §4: compare scheme, host (case-insensitively, minus one trailing
      dot), and port (after the scheme's default). Mirror of
      designator_host_match.
    .NOTES
      032: the parsing and comparison this function owned now live in
      lib/UrlOrigin.psm1, which is where the connection chokepoint can also
      reach them (Constitution VIII forbids lib/ depending on sink/).
      Delegating rather than keeping a second copy closed two measured
      cross-port divergences that lived here — TrimEnd('.') stripped every
      trailing dot where bash stripped one, and ToLowerInvariant() folded
      U+0130 differently — plus a Split(':', 2) that broke a bracketed IPv6
      authority. That last one was equally wrong in bash, which is why the
      corpus never noticed it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Url, [Parameter(Mandatory)] [string] $BaseUrl)
    return (Test-JiraUrlOriginEqual -First $Url -Second $BaseUrl)
}

function Resolve-JiraDesignator {
    <#
    .SYNOPSIS
      The single-designator resolver (§2-§5). Mirror of
      designator_classify. Prints canonical JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Role,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Raw,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $BaseUrl
    )

    $key = Get-JiraDesignatorKey -Raw $Raw
    if ($key) {
        return (ConvertTo-JiraJsonValue ([ordered]@{ role = $Role; raw = $Raw; form = 'key'; key = $key }))
    }

    if ($Raw.Contains('://')) {
        $candidate = Get-JiraDesignatorUrlCandidate -Raw $Raw
        $up = if ($candidate) { Get-JiraDesignatorKey -Raw $candidate } else { $null }
        if ($up) {
            if (-not (Test-JiraDesignatorHostMatch -Url $Raw -BaseUrl $BaseUrl)) {
                return (ConvertTo-JiraJsonValue ([ordered]@{ role = $Role; raw = $Raw; refuse = 'REF-HOST' }))
            }
            return (ConvertTo-JiraJsonValue ([ordered]@{ role = $Role; raw = $Raw; form = 'url'; key = $up }))
        }
        return (ConvertTo-JiraJsonValue ([ordered]@{ role = $Role; raw = $Raw; refuse = 'REF-DESIGNATOR' }))
    }

    if ($Role -eq 'specification') {
        $trimmed = $Raw.TrimEnd("`r").Trim()
        if ($trimmed) {
            # `text` is the TRIMMED value, `raw` the operator's exact bytes —
            # the two fields answer different questions and must not be
            # conflated. `text` becomes the created parent's Jira summary, so
            # a pasted trailing CR or padding would otherwise be written into
            # the board; `raw` is what a refusal quotes back, and trimming it
            # would misreport what was typed. Emitting the SAME expression the
            # non-blank guard above already computes is what keeps the two
            # coherent: a value is accepted and titled by one rule, never
            # accepted by one and titled by another (contract §7, "a
            # designator arriving with a trailing CR is trimmed").
            return (ConvertTo-JiraJsonValue ([ordered]@{ role = $Role; raw = $Raw; form = 'free_text'; text = $trimmed }))
        }
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{ role = $Role; raw = $Raw; refuse = 'REF-DESIGNATOR' }))
}

function Resolve-JiraDesignatorSet {
    <#
    .SYNOPSIS
      §6/FR-008/FR-054: assigns `position` (0-based, argv order, among
      same-role designators) and detects a reduced key occurring more than
      once, within one role or across both. Mirror of designator_dedupe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Items)

    $arr = @($Items | ConvertFrom-Json -Depth 100)
    # A free_text-form entry (the specification role only) carries no `key`
    # at all — mirror of jq's forgiving `.key` (undefined -> null) rather
    # than a PropertyNotFoundException under Set-StrictMode.
    $keys = @($arr | Where-Object { -not ($_.PSObject.Properties.Name -contains 'refuse') } | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'key') { $_.key } else { $null }
        })
    $dupSet = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($k in $keys) {
        if ($null -eq $k) { continue } # a free_text entry carries no key to de-duplicate on
        if ($seen.ContainsKey($k)) {
            if (-not $dupSet.Contains($k)) { $dupSet.Add($k) }
        }
        else { $seen[$k] = $true }
    }
    if ($dupSet.Count -gt 0) {
        $sorted = @($dupSet | Sort-Object)
        return (ConvertTo-JiraJsonValue ([ordered]@{ ok = $false; duplicates = $sorted }))
    }

    $storyPos = 0
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $arr) {
        $obj = [ordered]@{}
        foreach ($p in $item.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        if ($obj.Contains('refuse')) {
            $out.Add($obj)
            continue
        }
        if ($obj['role'] -eq 'story') {
            $obj['position'] = $storyPos
            $storyPos++
        }
        else {
            $obj['position'] = 0
        }
        $out.Add($obj)
    }
    return (ConvertTo-JiraJsonValue ([ordered]@{ ok = $true; designators = $out }))
}

Export-ModuleMember -Function Get-JiraDesignatorKey, Get-JiraDesignatorUrlCandidate, Test-JiraDesignatorHostMatch, `
    Resolve-JiraDesignator, Resolve-JiraDesignatorSet
