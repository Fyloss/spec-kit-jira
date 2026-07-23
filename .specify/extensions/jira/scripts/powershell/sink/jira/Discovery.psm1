# sink/jira/Discovery.psm1 — Project metadata discovery. Mirror of discovery.sh.
#
# Get-JiraDiscoveryBinding(Result) assembles the neutral Project Binding for one
# project by LOGICAL name (Constitution VII). Style is DETECTED FIRST (research
# §1); the per-style scheme-based path follows (research §2/§3). The estimation
# field is RANKED not assumed, and the flagged field is discovered by shape
# (research §15). The emitted binding is byte-identical to the Bash port (NFR-1):
# arrays keep discovered order and ConvertTo-JiraJsonValue sorts object keys, so
# both runtimes converge to the same `jq -cS` bytes.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Client.psm1') -Force

function Get-DiscProp {
    # StrictMode-safe optional property read: $null when the property is absent.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    }
    elseif ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    return $null
}

function Get-JiraDiscoveryStyle {
    # Map the detected style to its logical value (research §1). next-gen /
    # simplified -> team_managed; classic -> company_managed; neither -> company.
    param($Project)
    $style = [string](Get-DiscProp $Project 'style')
    $simplified = Get-DiscProp $Project 'simplified'
    if ($style -eq 'next-gen' -or $simplified -eq $true) { return 'team_managed' }
    if ($style -eq 'classic' -or $simplified -eq $false) { return 'company_managed' }
    return 'company_managed'
}

function Get-JiraDiscoveryBindingResult {
    <#
    .SYNOPSIS
      Discover one project's Project Binding. Returns { ExitCode; Binding } where
      Binding is the canonical JSON string (empty on a fail-closed read). Mirrors
      discover_binding: nothing emitted on failure, the transport's mapped code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey)

    $base = $env:SPEC_KIT_JIRA_BASE_URL
    if (-not $base) {
        [Console]::Error.WriteLine('discovery: SPEC_KIT_JIRA_BASE_URL is not set')
        return [pscustomobject]@{ ExitCode = (Get-JiraExitCode 'fail_closed'); Binding = '' }
    }
    $api = "$base/rest/api/3"

    # A fail-closed read short-circuits the whole discovery: the sentinel carries
    # the transport's mapped exit code out through the catch (research §8).
    $get = {
        param($url)
        $r = Invoke-JiraRequest -Method GET -Url $url
        if ($r.ExitCode -ne 0) { throw ([pscustomobject]@{ FailClosed = $true; ExitCode = [int] $r.ExitCode }) }
        return ($r.Body | ConvertFrom-Json -Depth 100)
    }

    try {
        # (1) Style — the first Jira call.
        $proj = & $get "$api/project/$ProjectKey"
        $style = Get-JiraDiscoveryStyle $proj

        # (2) Issue types + hierarchy levels.
        $itypes = & $get "$api/issue/createmeta/$ProjectKey/issuetypes"
        $firstType = if (@($itypes.issueTypes).Count -gt 0) { $itypes.issueTypes[0].id } else { '' }

        # (3) Project field schema (estimation candidates + flagged field source).
        $meta = & $get "$api/issue/createmeta/$ProjectKey/issuetypes/$firstType"

        # (4) Statuses + statusCategory.
        $statusGroups = & $get "$api/project/$ProjectKey/statuses"

        # (5) Priorities.
        $priorities = & $get "$api/priority"

        # (6) Field catalogue.
        $fields = & $get "$api/field"
    }
    catch {
        $sentinel = $_.TargetObject
        if ($sentinel -is [pscustomobject] -and (Get-DiscProp $sentinel 'FailClosed')) {
            return [pscustomobject]@{ ExitCode = [int] $sentinel.ExitCode; Binding = '' }
        }
        throw
    }

    # --- Assemble the neutral binding (arrays in discovered order) --------------
    $issueTypes = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $itypes.issueTypes) {
        $issueTypes.Add([ordered]@{
            logical_name    = $t.name
            id              = $t.id
            subtask         = [bool] $t.subtask
            hierarchy_level = $t.hierarchyLevel
        })
    }

    $statuses = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($grp in $statusGroups) {
        foreach ($s in $grp.statuses) {
            if ($seen.Add([string] $s.id)) {
                $statuses.Add([ordered]@{
                    name            = $s.name
                    id              = $s.id
                    status_category = $s.statusCategory.key
                })
            }
        }
    }

    $prio = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $priorities) {
        $prio.Add([ordered]@{ logical_name = $p.name; id = $p.id })
    }

    $fieldList = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $fields) {
        $schema = Get-DiscProp $f 'schema'
        $fieldList.Add([ordered]@{
            logical_name = $f.name
            id           = $f.id
            schema_type  = (Get-DiscProp $schema 'type')
            custom       = $f.custom
        })
    }

    $cands = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $meta.fields) {
        $schema = Get-DiscProp $f 'schema'
        if ((Get-DiscProp $schema 'type') -ne 'number') { continue }
        $custom = [string](Get-DiscProp $schema 'custom')
        $score = 2
        if ($custom -imatch 'float|gh-sprint|story-point') { $score += 2 }
        if ([string] $f.name -imatch 'estimat|point|effort|story') { $score += 1 }
        $cands.Add([ordered]@{
            logical_name = $f.name
            id           = $f.fieldId
            schema_type  = (Get-DiscProp $schema 'type')
            score        = $score
        })
    }
    $sortedCands = @($cands | Sort-Object @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { [string] $_.id }; Descending = $false })

    $flagged = $null
    foreach ($f in $meta.fields) {
        if ([string] $f.name -imatch 'impediment|flag') {
            $flagged = [ordered]@{ logical_name = $f.name; id = $f.fieldId }
            break
        }
    }

    $binding = [ordered]@{
        style                 = $style
        issue_types           = $issueTypes
        statuses              = $statuses
        priorities            = $prio
        fields                = $fieldList
        estimation_candidates = [System.Collections.Generic.List[object]]::new($sortedCands)
        flagged_field         = $flagged
    }

    return [pscustomobject]@{ ExitCode = 0; Binding = (ConvertTo-JiraJsonValue $binding) }
}

function Get-JiraDiscoveryBinding {
    <#
    .SYNOPSIS
      Convenience wrapper returning just the canonical binding JSON string (empty
      on a fail-closed read). Use Get-JiraDiscoveryBindingResult for the exit code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectKey)
    return (Get-JiraDiscoveryBindingResult -ProjectKey $ProjectKey).Binding
}

Export-ModuleMember -Function Get-JiraDiscoveryBinding, Get-JiraDiscoveryBindingResult
