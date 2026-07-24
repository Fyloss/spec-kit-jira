# sink/jira/PrivacyGuard.psm1 — Privacy guard: BLOCK tier + WARN tier and allowlist.
# Mirror of privacy_guard.sh (US11, T048 + US12, T090).
#
# Two tiers, precision over recall. BLOCK (FR-052) — zero writes, dedicated exit 9 —
# on the ATATT token prefix, a real *.atlassian.net host, or a known site/project
# coordinate. WARN (FR-053) — surfaced, never gating — on generic shapes (emails,
# UUIDs). ALLOWLIST (FR-053): Confluence links/domains from `.extensionignore`
# (gitignore syntax) or `config.privacy.allowlist` are neutralised before either
# tier scans, so an allowlisted host never false-blocks; `.extensionignore` paths
# are excluded from parsing and scanning. The offending value is never echoed
# (NFR-3). Behaves identically to the Bash port (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force

function Get-JiraPrivacySanitized {
    # Remove every allowlisted entry (fixed-string) from a working copy of the
    # payload so neither tier scans it. Mirror of _privacy_sanitize.
    param([string] $Payload, [string] $AllowlistJson = '[]')
    $allow = @($AllowlistJson | ConvertFrom-Json -Depth 100)
    foreach ($e in $allow) {
        $es = [string] $e
        if ($es -ne '') { $Payload = $Payload.Replace($es, '') }
    }
    return $Payload
}

function Get-JiraPrivacyBlockReason {
    <#
    .SYNOPSIS
      Return the BLOCK reason for a write payload (empty when clear). The value is
      never included. Allowlisted substrings are neutralised first (FR-053). Mirror
      of privacy_guard_reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $KnownCoordinatesJson = '[]',
        [string] $AllowlistJson = '[]'
    )
    $scan = Get-JiraPrivacySanitized -Payload $Payload -AllowlistJson $AllowlistJson

    # (1) ATATT token prefix — require token characters after the prefix so the
    #     bare word "ATATT" in prose does not false-positive.
    if ($scan -cmatch 'ATATT[A-Za-z0-9._=+/-]{2,}') { return 'Atlassian API token (ATATT prefix)' }

    # (2) Real *.atlassian.net host (case-sensitive lowercase).
    if ($scan -cmatch '[a-z0-9][a-z0-9-]*\.atlassian\.net') { return 'Atlassian Cloud host' }

    # (3) Exact match of a known coordinate (fixed-string, precision).
    $coords = @($KnownCoordinatesJson | ConvertFrom-Json -Depth 100)
    foreach ($c in $coords) {
        $cs = [string] $c
        if (-not [string]::IsNullOrEmpty($cs) -and $scan.Contains($cs)) { return 'known coordinate' }
    }

    return ''
}

function Test-JiraPrivacyBlock {
    <#
    .SYNOPSIS
      The pre-write gate. Returns EXIT_BLOCK (9) with a located reason on stderr
      when the payload carries a BLOCKED shape (after neutralising the allowlist);
      returns 0 when clear. Mirror of privacy_guard_scan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $KnownCoordinatesJson = '[]',
        [string] $AllowlistJson = '[]'
    )
    $reason = Get-JiraPrivacyBlockReason -Payload $Payload -KnownCoordinatesJson $KnownCoordinatesJson -AllowlistJson $AllowlistJson
    if (-not [string]::IsNullOrEmpty($reason)) {
        [Console]::Error.WriteLine("privacy: BLOCK — $reason detected in a write payload; zero writes performed (FR-052)")
        return (Get-JiraExitCode 'block')
    }
    return 0
}

function Get-JiraPrivacyWarnReason {
    <#
    .SYNOPSIS
      Return the WARN reason for a generic shape (empty when clear). Allowlisted
      substrings are neutralised first (FR-053). WARN never gates a write. Mirror of
      privacy_guard_warn_reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $AllowlistJson = '[]'
    )
    $scan = Get-JiraPrivacySanitized -Payload $Payload -AllowlistJson $AllowlistJson

    if ($scan -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') { return 'email address' }
    if ($scan -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') { return 'UUID' }
    return ''
}

function Get-JiraPrivacyAllowlist {
    <#
    .SYNOPSIS
      Build the canonical allow-pattern array (FR-053): the non-empty, non-comment,
      trimmed lines of `.extensionignore` merged with the config's privacy.allowlist,
      de-duplicated. Mirror of privacy_allowlist_load.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IgnorePath, [string] $ConfigAllowlistJson = '[]')
    $lines = @()
    if (Test-Path -LiteralPath $IgnorePath) {
        foreach ($raw in (Get-Content -LiteralPath $IgnorePath)) {
            $line = ([string] $raw).Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $lines += $line
        }
    }
    $cfg = @($ConfigAllowlistJson | ConvertFrom-Json -Depth 100)
    $merged = @($lines + @($cfg | ForEach-Object { [string] $_ }) | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    return (ConvertTo-JiraJsonValue $merged)
}

function Test-JiraPrivacyPathExcluded {
    <#
    .SYNOPSIS
      True when the path is excluded from parsing and scanning by an
      `.extensionignore` rule (directory prefix, `*.ext` glob, or exact path).
      Mirror of privacy_path_excluded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $IgnorePath)
    if (-not (Test-Path -LiteralPath $IgnorePath)) { return $false }
    foreach ($raw in (Get-Content -LiteralPath $IgnorePath)) {
        $line = ([string] $raw).Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.EndsWith('/')) {
            if ($Path.StartsWith($line) -or $Path -eq $line.TrimEnd('/')) { return $true }
            continue
        }
        if ($line.StartsWith('*')) {
            $leaf = Split-Path -Leaf $Path
            if ($Path -like $line -or $leaf -like $line) { return $true }
            continue
        }
        if ($Path -eq $line -or $Path.StartsWith("$line/")) { return $true }
    }
    return $false
}

Export-ModuleMember -Function Get-JiraPrivacyBlockReason, Test-JiraPrivacyBlock, `
    Get-JiraPrivacyWarnReason, Get-JiraPrivacyAllowlist, Test-JiraPrivacyPathExcluded, `
    Get-JiraPrivacySanitized
