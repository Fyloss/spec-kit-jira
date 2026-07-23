# sink/jira/PrivacyGuard.psm1 — Privacy guard BLOCK tier. Mirror of privacy_guard.sh.
#
# The pre-write guard that runs before EVERY Jira write (Constitution IV/IX,
# FR-052). It blocks — zero writes, dedicated exit 9 — on an exact match of the
# ATATT token prefix, a real *.atlassian.net host, or a known site/project
# coordinate. PRECISION OVER RECALL: only these high-confidence shapes block; the
# generic email/UUID shapes are the P3 WARN tier (US12) and never block here. The
# offending value is never echoed (NFR-3). Blocks identically to the Bash port.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force

function Get-JiraPrivacyBlockReason {
    <#
    .SYNOPSIS
      Return the BLOCK reason for a write payload (empty when clear). The value
      itself is never included. Mirror of privacy_guard_reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $KnownCoordinatesJson = '[]'
    )

    # (1) ATATT token prefix — require token characters after the prefix so the
    #     bare word "ATATT" in prose does not false-positive.
    if ($Payload -cmatch 'ATATT[A-Za-z0-9._=+/-]{2,}') { return 'Atlassian API token (ATATT prefix)' }

    # (2) Real *.atlassian.net host (case-sensitive lowercase).
    if ($Payload -cmatch '[a-z0-9][a-z0-9-]*\.atlassian\.net') { return 'Atlassian Cloud host' }

    # (3) Exact match of a known coordinate (fixed-string, precision).
    $coords = @($KnownCoordinatesJson | ConvertFrom-Json -Depth 100)
    foreach ($c in $coords) {
        $cs = [string]$c
        if (-not [string]::IsNullOrEmpty($cs) -and $Payload.Contains($cs)) { return 'known coordinate' }
    }

    return ''
}

function Test-JiraPrivacyBlock {
    <#
    .SYNOPSIS
      The pre-write gate. Returns EXIT_BLOCK (9) with a located reason on stderr
      when the payload carries a blocked shape; returns 0 when clear. Mirror of
      privacy_guard_scan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Payload,
        [string] $KnownCoordinatesJson = '[]'
    )
    $reason = Get-JiraPrivacyBlockReason -Payload $Payload -KnownCoordinatesJson $KnownCoordinatesJson
    if (-not [string]::IsNullOrEmpty($reason)) {
        [Console]::Error.WriteLine("privacy: BLOCK — $reason detected in a write payload; zero writes performed (FR-052)")
        return (Get-JiraExitCode 'block')
    }
    return 0
}

Export-ModuleMember -Function Get-JiraPrivacyBlockReason, Test-JiraPrivacyBlock
