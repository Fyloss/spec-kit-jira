# sink/jira/PlanApply.psm1 — The Jira write path. Mirror of plan_apply.sh.
#
# Invoke-JiraApplyWriteSet executes an ordered action set against Jira. Its FIRST
# responsibility (US11, T049) is the mandatory pre-write privacy gate: every
# action's content payload is scanned through the BLOCK guard BEFORE any write is
# performed. A single blocked payload aborts the whole apply with exit 9 and ZERO
# writes — no gap through which a leak could reach Jira (Constitution IV, FR-052).
#
# US3 (T058) fleshes out the richer action set; this module owns the invariant
# guard-then-write ordering. Only the content `body` is scanned (the URL targets
# the real host and is not content).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PrivacyGuard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force

function Get-JiraApplyKnownCoordinate {
    # The known-coordinate set: the real site host from SPEC_KIT_JIRA_BASE_URL plus
    # any caller extras. Mirror of _apply_known_coords.
    param([string] $ExtraJson = '[]')
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    $host0 = $base -replace '^[a-zA-Z]+://', '' -replace '/.*$', '' -replace ':[0-9]+$', ''
    $coords = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($ExtraJson | ConvertFrom-Json -Depth 100)) { $coords.Add([string]$e) }
    if (-not [string]::IsNullOrEmpty($host0)) { $coords.Add($host0) }
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($c in ($coords | Sort-Object -Unique)) { $unique.Add($c) }
    return (ConvertTo-Json -InputObject $unique.ToArray() -Compress -Depth 5)
}

function Invoke-JiraApplyWriteSet {
    <#
    .SYNOPSIS
      Guard every payload, then perform the writes in order. Returns exit 9 with
      zero writes if any payload is blocked; otherwise the worst (highest)
      transport exit code. Mirror of apply_writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ActionsJson,
        [string] $ExtraKnownCoordinatesJson = '[]'
    )
    $coords = Get-JiraApplyKnownCoordinate -ExtraJson $ExtraKnownCoordinatesJson
    $actions = @($ActionsJson | ConvertFrom-Json -Depth 100)

    # (1) Pre-write gate — scan every content payload before writing anything.
    foreach ($a in $actions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        $bodyText = if ($null -eq $bodyObj) { '{}' } else { ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100 }
        $code = Test-JiraPrivacyBlock -Payload $bodyText -KnownCoordinatesJson $coords
        if ($code -ne 0) { return [int]$code }
    }

    # (2) Write pass — all payloads cleared; perform each write in order.
    $worst = 0
    foreach ($a in $actions) {
        $bodyObj = if ($a.PSObject.Properties.Name -contains 'body') { $a.body } else { $null }
        if ($null -ne $bodyObj) {
            $bodyText = ConvertTo-Json -InputObject $bodyObj -Compress -Depth 100
            $r = Invoke-JiraRequest -Method $a.method -Url $a.url -Body $bodyText
        }
        else {
            $r = Invoke-JiraRequest -Method $a.method -Url $a.url
        }
        if ([int]$r.ExitCode -gt $worst) { $worst = [int]$r.ExitCode }
    }
    return $worst
}

Export-ModuleMember -Function Get-JiraApplyKnownCoordinate, Invoke-JiraApplyWriteSet
