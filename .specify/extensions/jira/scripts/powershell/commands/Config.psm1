# commands/Config.psm1 — Config-command building blocks. Mirror of config.sh.
#
# US2 lands mapping validation + strategy persistence; the full Invoke-JiraConfig
# entry point (the deterministic ceremony) is authored in US1 (T044/T045).
#
# Mapping validation refuses an impossible mapping at config time (FR-007): a
# team-managed project supports only an Epic parent and Sub-task children
# (research §3). The Epic tier is identified from the DISCOVERED binding (the top
# non-subtask hierarchy level), never a compiled-in name (Constitution VII).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force

$script:ExitConfig = 4

function Test-JiraMappingValidity {
    <#
    .SYNOPSIS
      Refuse a team-managed hierarchy level above the discovered Epic tier
      (FR-007). Returns 4 (with a located error on stderr) when invalid, else 0.
      Company-managed projects carry no such restriction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Style,
        [Parameter(Mandatory)] [string] $HierarchyJson,
        [Parameter(Mandatory)] [string] $BindingJson
    )
    if ($Style -ne 'team_managed') { return 0 }

    $binding = $BindingJson | ConvertFrom-Json -Depth 100
    $hierarchy = @($HierarchyJson | ConvertFrom-Json -Depth 100)

    $parents = @($binding.issue_types | Where-Object { -not $_.subtask })
    $top = ($parents | Sort-Object -Property hierarchy_level -Descending | Select-Object -First 1).logical_name

    $topIndex = [array]::IndexOf($hierarchy, $top)
    if ($topIndex -lt 0) { return 0 }

    if ($topIndex -gt 0) {
        $first = $hierarchy[0]
        [Console]::Error.WriteLine("mapping: hierarchy level '$first' sits above $top; team-managed projects support only an $top parent and Sub-task children (project style: team_managed)")
        return $script:ExitConfig
    }
    return 0
}

function New-JiraProjectMapping {
    <#
    .SYNOPSIS
      Build the canonical project mapping entry by logical name. linked_story
      requires a LinkType (FR-009); its absence returns exit 4. Returns
      { ExitCode; Json } — the same asymmetric-shape convention as the client.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Style,
        [Parameter(Mandatory)] [string] $EpicStrategy,
        [Parameter(Mandatory)] [string] $TaskStrategy,
        [string] $LinkType = ''
    )
    if ($TaskStrategy -eq 'linked_story' -and [string]::IsNullOrEmpty($LinkType)) {
        [Console]::Error.WriteLine('mapping: task_strategy=linked_story requires a link_type (FR-009)')
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Json = '' }
    }

    $entry = [ordered]@{
        key           = $Key
        style         = $Style
        epic_strategy = $EpicStrategy
        task_strategy = $TaskStrategy
    }
    if (-not [string]::IsNullOrEmpty($LinkType)) { $entry['link_type'] = $LinkType }

    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $entry) }
}

Export-ModuleMember -Function Test-JiraMappingValidity, New-JiraProjectMapping
