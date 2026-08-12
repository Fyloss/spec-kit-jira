# sink/jira/DuplicateProbe.psm1 — User Story 4 (017, contracts/duplicate-probe.md).
# Mirror of sink/jira/duplicate_probe.sh.
#
# A best-effort, read-only check for tickets already labelled with this
# specification's provenance label, consulted only before CREATING a parent
# the specification holds no marker for. It queries the same eventually
# consistent index Recognition.psm1 deliberately never reads (feature 005
# removed search from recognition for exactly this reason) — its false
# negative leaves today's behaviour unchanged, and its true positive
# prevents a write, so it can only fail to help. SC-001 rests on the marker
# line, not on this.
#
# THIS IS THE DROPPABLE SLICE (contract §0): delete this file, its bash
# twin, and the three call-site lines in Reconcile.psm1 to remove User
# Story 4 entirely — nothing else depends on it.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Client.psm1')    # No -Force — see project memory: powershell-import-force-clobbers-caller-scope
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force

function Get-JiraDuplicateProbeResult {
    <#
    .SYNOPSIS
      Contract §3's query, issued through the existing Invoke-JiraRequest
      transport (same credentials, same retry policy, same base-URL
      stripping). Returns a hashtable {Verdict; Keys}: Verdict is
      "clear" | "hit" | "unavailable"; Keys is populated (sorted) only for
      "hit". Never throws: any non-2xx (contract §4 — ANY non-2xx, not only
      a network failure) folds into "unavailable" rather than propagating
      as a transport error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] [string] $Label
    )
    $jql = "project = `"$ProjectKey`" AND labels = `"$Label`""
    $encoded = ConvertTo-JiraUriComponent $jql
    $url = "$BaseUrl/rest/api/3/search/jql?jql=$encoded&fields=key&maxResults=50"
    # A missing credential throws at PARAMETER BINDING (Get-JiraAuthHeader's
    # -Email is Mandatory), never a graceful non-2xx, unlike the bash port's
    # cred_curl_config which returns a plain failure exit code. The contract
    # treats every failure mode of this read the same way (any non-2xx ->
    # unavailable), so catch broadly here rather than let a credential gap
    # surface as an unhandled exception through a caller that has never had
    # to expect one from a dry-run creation path before this probe existed.
    try {
        $r = Invoke-JiraRequest -Method GET -Url $url
    }
    catch {
        return @{ Verdict = 'unavailable'; Keys = @() }
    }
    if ([int]$r.ExitCode -ne 0) {
        return @{ Verdict = 'unavailable'; Keys = @() }
    }
    $body = $r.Body | ConvertFrom-Json -Depth 100
    $issues = @($body.issues)
    $keys = [string[]]@($issues | ForEach-Object { [string]$_.key })
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    if ($keys.Count -eq 0) {
        return @{ Verdict = 'clear'; Keys = @() }
    }
    return @{ Verdict = 'hit'; Keys = $keys }
}

Export-ModuleMember -Function Get-JiraDuplicateProbeResult
