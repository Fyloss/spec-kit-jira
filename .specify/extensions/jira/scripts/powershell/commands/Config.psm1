# commands/Config.psm1 — The config command. Mirror of config.sh.
#
# Invoke-JiraConfig (US1) orchestrates the deterministic install ceremony: read
# the committed team config, discover each project's metadata (US2), persist the
# resolved-id table into config.local.yml with a DETERMINISTIC canonical
# serialisation (byte-identical on re-run, FR-003), and report the run's THREE
# effects separately (FR-054). Only the discovery effect writes this increment;
# hooks (T085) and README (T065) land later and already appear as sections here.
# The PowerShell port emits byte-identical output to the Bash port (NFR-1).
#
# Mapping validation refuses an impossible mapping at config time (FR-007): a
# team-managed project supports only an Epic parent and Sub-task children
# (research §3). The Epic tier is identified from the DISCOVERED binding (the top
# non-subtask hierarchy level), never a compiled-in name (Constitution VII).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../hooks/ReadmeBlock.psm1') -Force

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

function Get-JiraResolvedIdMap {
    <#
    .SYNOPSIS
      Reshape a discovered project binding into the resolved-id lookup table:
      logical name -> id for issue types, priorities, and statuses. Returns the
      canonical JSON object. Mirror of config_resolved_ids_for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BindingJson)
    $b = $BindingJson | ConvertFrom-Json -Depth 100
    $issue = [ordered]@{}; foreach ($t in @($b.issue_types)) { $issue[[string]$t.logical_name] = [string]$t.id }
    $prio = [ordered]@{}; foreach ($p in @($b.priorities)) { $prio[[string]$p.logical_name] = [string]$p.id }
    $stat = [ordered]@{}; foreach ($s in @($b.statuses)) { $stat[[string]$s.name] = [string]$s.id }
    return (ConvertTo-JiraJsonValue ([ordered]@{ issue_types = $issue; priorities = $prio; statuses = $stat }))
}

function Invoke-JiraConfig {
    <#
    .SYNOPSIS
      The deterministic install ceremony (US1). Writes the run summary via the
      [Console] streams and returns ONLY its numeric exit code (mirroring the Bash
      port's echo -> fd1, return -> status convention).
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    # Parse flags (config-read, no model judgement).
    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("config: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'

    $configdir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }

    # Config read: load and validate the committed team config (US4).
    $cfg = Import-JiraConfig -ConfigDir $configdir
    if ($cfg.ExitCode -ne 0) { return [int] $cfg.ExitCode }
    $cfgObj = $cfg.Json | ConvertFrom-Json -Depth 100

    # API reads: discover each project and build the resolved-id table.
    $resolved = [ordered]@{}
    $nproj = 0
    $projects = @()
    if ($cfgObj.PSObject.Properties.Name -contains 'projects') { $projects = @($cfgObj.projects) }
    foreach ($p in $projects) {
        $pkey = [string]$p.key
        if ([string]::IsNullOrEmpty($pkey)) { continue }
        $r = Get-JiraDiscoveryBindingResult -ProjectKey $pkey
        if ($r.ExitCode -ne 0) { return [int] $r.ExitCode }
        $resolved[$pkey] = ((Get-JiraResolvedIdMap -BindingJson $r.Binding) | ConvertFrom-Json -Depth 100)
        $nproj++
    }

    # Merge the resolved-id table into the machine-owned local layer, preserving
    # the operator's site_alias / overrides, and emit deterministic canonical YAML.
    $localf = Join-Path $configdir 'config.local.yml'
    $existing = if (Test-Path -LiteralPath $localf) {
        (ConvertFrom-JiraConfigYaml -Path $localf) | ConvertFrom-Json -Depth 100
    } else { [pscustomobject]@{} }
    $existingMap = [ordered]@{}
    if ($existing -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $existing.PSObject.Properties) { $existingMap[$prop.Name] = $prop.Value }
    }
    $existingMap['resolved_ids'] = $resolved
    $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $existingMap)

    # Discovery-effect status: created / unchanged / written.
    $discStatus = 'written'
    if (-not (Test-Path -LiteralPath $localf)) {
        $discStatus = 'created'
    }
    elseif (((Get-Content -Raw -LiteralPath $localf) -replace "`r`n", "`n").TrimEnd("`n") -eq $yaml) {
        $discStatus = 'unchanged'
    }
    if (-not $dryRun) {
        [System.IO.File]::WriteAllText($localf, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }

    # README effect (US5, T065): splice the version-marked managed block into the
    # consuming repository's README. The path derives from the config dir's repo
    # root (the parent of .specify), overridable via SPEC_KIT_JIRA_README.
    $repoRoot = Split-Path -Parent (Split-Path -Parent $configdir)
    if ([string]::IsNullOrEmpty($repoRoot)) { $repoRoot = '.' }
    $readmePath = if ($env:SPEC_KIT_JIRA_README) { $env:SPEC_KIT_JIRA_README } else { Join-Path $repoRoot 'README.md' }
    $readmeResult = Set-JiraReadmeBlock -Path $readmePath -DryRun ([bool]$dryRun)
    $readmeStatus = $readmeResult.Status
    $readmeDetail = switch ($readmeStatus) {
        'created' { 'managed README block created' }
        'written' { 'managed README block updated' }
        'unchanged' { 'managed README block unchanged' }
        'refused' { 'README markers malformed; block not written' }
        default { $readmeStatus }
    }

    # Build the three-effect summary (FR-054), byte-identical to the Bash port.
    # Discovery and README write this phase; hook registration (T085) lands later.
    $effects = [ordered]@{
        discovery = [ordered]@{ status = $discStatus; detail = "$nproj project(s) discovered" }
        hooks     = [ordered]@{ status = 'skipped'; detail = 'hook registration wired in a later increment' }
        readme    = [ordered]@{ status = $readmeStatus; detail = $readmeDetail }
    }
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'config'
        dry_run        = [bool]$dryRun
        counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = 0; errors = 0 }
        effects        = $effects
        exit_code      = 0
    }
    $summary = ConvertTo-JiraJsonValue $summaryObj

    if ($json) {
        [Console]::Out.Write($summary + "`n")
    }
    else {
        [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $summary))
    }
    return 0
}

Export-ModuleMember -Function Test-JiraMappingValidity, New-JiraProjectMapping, `
    Get-JiraResolvedIdMap, Invoke-JiraConfig
