# lib/SeedState.psm1 — The seeded-not-bound record's document layer (027,
# research R8, contracts/seed-record.md). Mirror of lib/seed_state.sh.
#
# A sibling of RunState.psm1's <feature-dir>.json, but a SEPARATE document
# (research R8). Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')   # Get-JiraExtensionVersion
Import-Module (Join-Path $PSScriptRoot 'Output.psm1')   # ConvertTo-JiraCanonicalJson, Write-JiraWarning

$script:SeedStateSchema = 1

function Get-JiraSeedStateConfigDir {
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-JiraSeedStatePath {
    <#
    .SYNOPSIS
      The recorded document's path for the feature directory holding this
      spec. A sibling of Get-JiraRunStatePath's <feature-dir>.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath)
    $featureDir = Split-Path -Leaf (Split-Path -Parent $SpecPath)
    $stateDir = Join-Path (Get-JiraSeedStateConfigDir) 'state'
    return (Join-Path $stateDir "$featureDir.seed.json")
}

function Get-JiraSeedStateRecordKey {
    <#
    .SYNOPSIS
      The key the record for this feature was actually written under, which
      is NOT always the directory the host went on to create. Mirror of
      seed_state_resolve_key.
    .DESCRIPTION
      `feature` records under the resolved short name, while spec-kit's own
      create-new-feature.sh builds `<FEATURE_NUM>-<short-name>` and truncates
      the suffix past its branch-length cap. Exact match wins outright;
      otherwise the host's numbering is stripped — at three digits or more,
      since every non-timestamp path in create-new-feature.sh ends at
      `printf "%03d"` — and the remainder is matched as a PREFIX of the
      recorded keys, since truncation can only shorten a name. Exactly one candidate resolves; zero or several resolve to the
      directory itself, so the caller fails exactly as it does today.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath)
    $dir = Split-Path -Leaf (Split-Path -Parent $SpecPath)
    $stateDir = Join-Path (Get-JiraSeedStateConfigDir) 'state'
    if (Test-Path -LiteralPath (Join-Path $stateDir "$dir.seed.json") -PathType Leaf) { return $dir }

    $stripped = $dir
    if ($dir -match '^[0-9]{8}-[0-9]{6}-(.+)$') { $stripped = $Matches[1] }
    elseif ($dir -match '^[0-9]{3,}-(.+)$') { $stripped = $Matches[1] }

    $hit = ''
    $n = 0
    if (Test-Path -LiteralPath $stateDir -PathType Container) {
        foreach ($f in [System.IO.Directory]::GetFiles($stateDir, '*.seed.json')) {
            $cand = [System.IO.Path]::GetFileName($f)
            $cand = $cand.Substring(0, $cand.Length - '.seed.json'.Length)
            if (-not $cand.StartsWith($stripped, [System.StringComparison]::Ordinal)) { continue }
            $hit = $cand
            $n++
        }
    }
    if ($n -eq 1) { return $hit }
    return $dir
}

function Get-JiraSeedStateResolvedPath {
    <#
    .SYNOPSIS
      Get-JiraSeedStatePath's read-side twin, built from the resolved key.
      Reads and the post-success delete go through this; the WRITE stays on
      Get-JiraSeedStatePath. Mirror of seed_state_resolved_path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath)
    $stateDir = Join-Path (Get-JiraSeedStateConfigDir) 'state'
    return (Join-Path $stateDir ((Get-JiraSeedStateRecordKey -SpecPath $SpecPath) + '.seed.json'))
}

function New-JiraSeedStateDocument {
    <#
    .SYNOPSIS
      The canonical JSON document (§2). `bindings` is always an explicit
      empty array; `plan_digest` is null when <PlanDigest> is empty.
      `RoutingJson` (default '{}') carries the routed project key and the
      declared types/terminal statuses moment 1 already resolved from
      config.yml — additive, so a resume (FR-062) can re-evaluate every
      refusal class from Jira alone. `PlanSnapshotJson` (default '[]') is
      the last-rendered plan entries, kept so a resume can compute FR-064's
      added/vanished delta structurally.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Slug,
        [Parameter(Mandatory)] [string] $DesignatorsJson,
        [AllowEmptyString()] [string] $PlanDigest = '',
        [string] $RoutingJson = '{}',
        [string] $PlanSnapshotJson = '[]'
    )
    $extVersion = Get-JiraExtensionVersion
    if ($extVersion -isnot [string]) { $extVersion = '' }
    # @(...) guards a single-element JSON array: ConvertFrom-Json collapses
    # `[{...}]` to a bare PSCustomObject rather than a one-element array,
    # which then serialises back out as an object, not `[...]` — bash's jq
    # has no such collapse (a real, observed cross-port divergence, first
    # hit by this feature's own one-designator scenarios).
    $designators = @($DesignatorsJson | ConvertFrom-Json -Depth 100)
    $doc = [ordered]@{
        schema_version    = $script:SeedStateSchema
        extension_version = $extVersion
        slug              = $Slug
        designators       = $designators
        bindings          = @()
        plan_digest       = if ($PlanDigest) { $PlanDigest } else { $null }
        routing           = ($RoutingJson | ConvertFrom-Json -Depth 100)
        plan_snapshot     = @($PlanSnapshotJson | ConvertFrom-Json -Depth 100)
    }
    return (ConvertTo-JiraJsonValue $doc)
}

function Test-JiraSeedStateDesignatorsEqual {
    <#
    .SYNOPSIS
      §3, FR-041: "the same" when, for each role, the ordered list of
      reduced keys is equal, and the free-text parent value is byte-equal
      when present. Mirror of seed_state_designators_equal.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RecordedJson, [Parameter(Mandatory)] [string] $CurrentJson)
    $a = @($RecordedJson | ConvertFrom-Json -Depth 100)
    $b = @($CurrentJson | ConvertFrom-Json -Depth 100)

    $normSpec = {
        param($x)
        $p = @($x | Where-Object { $_.role -eq 'specification' }) | Select-Object -First 1
        if (-not $p) { return $null }
        if ($p.form -eq 'free_text') { return @{ t = [string]$p.text } }
        return @{ k = [string]$p.key }
    }
    $normStories = {
        param($x)
        return @(@($x | Where-Object { $_.role -eq 'story' } | Sort-Object position | ForEach-Object { [string]$_.key }))
    }

    $specA = & $normSpec $a
    $specB = & $normSpec $b
    $specEqual = (ConvertTo-JiraJsonValue $specA) -eq (ConvertTo-JiraJsonValue $specB)

    # @() wraps the CALL, not just the scriptblock's own return statement:
    # capturing a single-item (or empty) array from a scriptblock invocation
    # collapses it to a scalar (or $null) on the caller's side regardless of
    # how the callee wrapped it internally — the same collapse `designators`
    # in New-JiraSeedStateDocument hit, one level removed.
    $storiesA = @(& $normStories $a)
    $storiesB = @(& $normStories $b)
    $storiesEqual = ($storiesA.Count -eq $storiesB.Count)
    if ($storiesEqual) {
        for ($i = 0; $i -lt $storiesA.Count; $i++) {
            if ($storiesA[$i] -ne $storiesB[$i]) { $storiesEqual = $false; break }
        }
    }
    return ($specEqual -and $storiesEqual)
}

function Get-JiraSeedStatePlanDigest {
    <#
    .SYNOPSIS
      The digest FR-064 names, via this repo's one content-hash primitive.
      Mirror of seed_state_plan_digest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $RenderedPlanText)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8NoBom.GetBytes($RenderedPlanText)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        return (& git hash-object --no-filters $tmp 2>$null | Select-Object -First 1)
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

function Read-JiraSeedState {
    <#
    .SYNOPSIS
      The recorded document, or $null when absent, unreadable, or invalid.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath)
    $path = Get-JiraSeedStateResolvedPath -SpecPath $SpecPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $content = [System.IO.File]::ReadAllText($path) } catch { return $null }
    try { $null = $content | ConvertFrom-Json -Depth 100 } catch { return $null }
    return $content
}

function Save-JiraSeedState {
    <#
    .SYNOPSIS
      Write atomically to a sibling temp file, then rename onto the final
      name. Creates the state directory and its self-ignoring .gitignore if
      absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath, [Parameter(Mandatory)] [string] $DocumentJson)
    $path = Get-JiraSeedStatePath -SpecPath $SpecPath
    $stateDir = Split-Path -Parent $path

    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        try { New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop | Out-Null }
        catch {
            Write-JiraWarning "seed-state: could not create ${stateDir}; state not recorded"
            return
        }
    }
    $gitignore = Join-Path $stateDir '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignore -PathType Leaf)) {
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($gitignore, "*`n", $utf8NoBom)
        }
        catch { $null = $_ }
    }

    $tmp = "$path.tmp.$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try { [System.IO.File]::WriteAllText($tmp, $DocumentJson, $utf8NoBom) }
    catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-JiraWarning "seed-state: could not write ${tmp}; state not recorded"
        return
    }
    try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
    catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-JiraWarning "seed-state: could not rename onto ${path}; state not recorded"
    }
}

function Remove-JiraSeedState {
    <#
    .SYNOPSIS
      Delete the record (§4: deleted on success, not marked done). A no-op
      when absent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath)
    $path = Get-JiraSeedStateResolvedPath -SpecPath $SpecPath
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-JiraSeedStatePath, Get-JiraSeedStateRecordKey, Get-JiraSeedStateResolvedPath, `
    New-JiraSeedStateDocument, Read-JiraSeedState, `
    Save-JiraSeedState, Remove-JiraSeedState, Test-JiraSeedStateDesignatorsEqual, Get-JiraSeedStatePlanDigest
