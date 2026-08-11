# sink/jira/Prefetch.psm1 — the recognition prefetch (021 US4;
# contracts/recognition-prefetch.md). Mirror of sink/jira/prefetch.sh. One
# POST .../issue/bulkfetch per 100 recorded keys, issued once from the
# command layer, in place of one GET per key. The governing rule: the
# prefetch may only ever remove requests — it may never change an outcome.
# Get-JiraRecognitionRead/-ReadParent consult Get-JiraPrefetch first and
# fall through to their existing unchanged GET on any miss (contract §3), so
# every classification this module cannot express (a deleted vs. a
# forbidden key) resolves exactly as it does today.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1')    # No -Force — see project memory: powershell-import-force-clobbers-caller-scope

function Get-JiraPrefetchSafe {
    # A StrictMode-safe property read: `.PSObject.Properties.Name -contains`
    # throws on an EMPTY PSCustomObject (member enumeration over zero
    # elements) — a routine shape here (an issue with no marker, a
    # projection with no fields). Mirror of Recognition.psm1's own
    # Get-JiraRecognitionSafe.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $m = $Object.PSObject.Properties[$Name]
    if ($null -eq $m) { return $null }
    return $m.Value
}

function Get-JiraPrefetchIdentityKey {
    if ($env:SPEC_KIT_JIRA_IDENTITY_KEY) { return $env:SPEC_KIT_JIRA_IDENTITY_KEY }
    return 'spec-kit-jira'
}

# The union of every reader's field list (contract §5) — requested once,
# regardless of which reader later calls Get-JiraPrefetch for a given hit.
$script:JiraPrefetchFields = 'summary,description,priority,status,issuelinks,parent,labels,subtasks,Flagged'

# JiraPrefetchMap: lower-cased key -> canonical {"gone":false,"marker":...,
# "fields":{...}} JSON, matching what Get-JiraRecognitionRead itself
# returns. Module-scoped only (Constitution XIII); Reset-JiraPrefetch exists
# so tests never leak state across cases.
$script:JiraPrefetchMap = @{}

function Reset-JiraPrefetch {
    <#
    .SYNOPSIS
      Empties the map. Test support (contract §2).
    #>
    $script:JiraPrefetchMap = @{}
}

function Invoke-JiraPrefetchLoad {
    <#
    .SYNOPSIS
      Chunks the keys at 100, issues one POST /issue/bulkfetch per chunk,
      populates the map. Always succeeds (P2/P6): neither a zero-key call
      nor a bulkfetch failure is ever fail-closed — the authoritative
      per-key read has not happened yet, and a miss here is resolved by the
      reader's own unchanged GET (contract §3).
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)] [string[]] $Keys = @())

    Reset-JiraPrefetch
    if ($Keys.Count -eq 0) { return }

    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    $url = "$base/rest/api/3/issue/bulkfetch"
    $idKey = Get-JiraPrefetchIdentityKey
    $fieldsArr = @($script:JiraPrefetchFields -split ',')

    $offset = 0
    while ($offset -lt $Keys.Count) {
        $end = [Math]::Min($offset + 99, $Keys.Count - 1)
        $chunk = @($Keys[$offset..$end])
        $offset += 100

        $bodyObj = @{ issueIdsOrKeys = @($chunk); fields = $fieldsArr; properties = @($idKey) }
        $body = $bodyObj | ConvertTo-Json -Depth 20 -Compress

        $r = Invoke-JiraRequest -Method POST -Url $url -Body $body

        # P2: a non-2xx empties the map — no partial optimisation survives a
        # chunk failure, so every key this load call named falls through to
        # today's per-key read at today's cost.
        if ([int]$r.ExitCode -ne 0) {
            Reset-JiraPrefetch
            return
        }

        $resp = $null
        try { $resp = $r.Body | ConvertFrom-Json -Depth 100 } catch { $resp = $null }
        $respIssues = Get-JiraPrefetchSafe $resp 'issues'
        $issues = if ($respIssues) { @($respIssues) } else { @() }
        foreach ($issue in $issues) {
            $key = Get-JiraPrefetchSafe $issue 'key'
            if ([string]::IsNullOrEmpty($key)) { continue }

            $props = Get-JiraPrefetchSafe $issue 'properties'
            $marker = Get-JiraPrefetchSafe $props $idKey
            $fields = Get-JiraPrefetchSafe $issue 'fields'
            if ($null -eq $fields) { $fields = [pscustomobject]@{} }

            $entryObj = @{ gone = $false; marker = $marker; fields = $fields }
            $entryJson = ConvertTo-JiraCanonicalJson ($entryObj | ConvertTo-Json -Depth 100 -Compress)
            $script:JiraPrefetchMap[$key.ToLowerInvariant()] = $entryJson
        }
    }
}

function Get-JiraPrefetch {
    <#
    .SYNOPSIS
      The cached entry (P4: matched by key, case-insensitively — never by
      position) projected to <FieldsCsv> (P3), matching
      Get-JiraRecognitionRead's own shape. Returns $null on a miss.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] [string] $FieldsCsv)

    $lower = $Key.ToLowerInvariant()
    if (-not $script:JiraPrefetchMap.ContainsKey($lower)) { return $null }
    $entry = $script:JiraPrefetchMap[$lower] | ConvertFrom-Json -Depth 100

    $want = @($FieldsCsv -split ',' | Where-Object { $_ -ne '' })
    $fields = [ordered]@{}
    $entryFields = Get-JiraPrefetchSafe $entry 'fields'
    if ($entryFields) {
        foreach ($p in $entryFields.PSObject.Properties) {
            if ($want -contains $p.Name) { $fields[$p.Name] = $p.Value }
        }
    }
    $out = @{ gone = $false; marker = (Get-JiraPrefetchSafe $entry 'marker'); fields = $fields }
    return ConvertTo-JiraCanonicalJson ($out | ConvertTo-Json -Depth 100 -Compress)
}

Export-ModuleMember -Function Invoke-JiraPrefetchLoad, Get-JiraPrefetch, Reset-JiraPrefetch
