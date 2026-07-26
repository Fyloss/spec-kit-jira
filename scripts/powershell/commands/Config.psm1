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
Import-Module (Join-Path $PSScriptRoot '../lib/Credentials.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../hooks/ReadmeBlock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../hooks/RegisterHooks.psm1') -Force

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

function Invoke-JiraConfigDegraded {
    <#
    .SYNOPSIS
      The degraded, report-only path (002 US2, FR-008/FR-009). Mirror of
      _config_degraded_run: branch-scan proposals marked provisional, exactly
      one warning naming the missing variables, re-run guidance, zero writes,
      every effect skipped, exit 0.
    #>
    [CmdletBinding()]
    param(
        [bool] $Json = $false,
        [bool] $DryRun = $false,
        [Parameter(Mandatory)] [string] $Missing
    )
    $branches = @()
    try { $branches = @(git for-each-ref refs/heads --format='%(refname:short)' 2> $null) }
    catch { $branches = @() }
    $prefixes = [System.Collections.Generic.List[string]]::new()
    foreach ($b in $branches) {
        if ([string]$b -cmatch '^([a-z0-9][a-z0-9-]*)-[0-9]+/') { $prefixes.Add($Matches[1]) }
    }
    $arr = [string[]]@($prefixes | Select-Object -Unique)
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    $proposals = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $arr) { $proposals.Add([ordered]@{ team_prefix = $p; provisional = $true }) }

    [Console]::Error.WriteLine("WARNING: degraded mode — Jira introspection is unavailable (undefined: $Missing); team-name proposals are provisional and nothing was written")
    $rerun = "define $Missing, then re-run: spec-kit-jira config"

    $detail = 'degraded mode: Jira connection parameters undefined'
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'config'
        dry_run        = [bool]$DryRun
        counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = 1; errors = 0 }
        effects        = [ordered]@{
            discovery = [ordered]@{ status = 'skipped'; detail = $detail }
            hooks     = [ordered]@{ status = 'skipped'; detail = $detail }
            readme    = [ordered]@{ status = 'skipped'; detail = $detail }
        }
        provisional    = $proposals
        rerun_guidance = $rerun
        exit_code      = 0
    }
    $summary = ConvertTo-JiraJsonValue $summaryObj
    if ($Json) { [Console]::Out.Write($summary + "`n") }
    else { [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $summary)) }
    return 0
}

function Get-CmdProp {
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

function Get-JiraStyleFlagFor {
    # The operator's --style answer for one project (last occurrence wins), or
    # '' when none was given. Mirror of _config_style_flag_for.
    param([string] $ProjectKey, [string] $Styles)
    $out = ''
    foreach ($tok in ($Styles -split ' ')) {
        if ($tok -clike "$ProjectKey=*") { $out = $tok.Substring($tok.IndexOf('=') + 1) }
    }
    return $out
}

function Resolve-JiraProjectStyle {
    <#
    .SYNOPSIS
      Per-project style resolution (002 US1, FR-001/FR-002). Mirror of
      _config_resolve_style: api signal (agreeing with any committed
      declaration) -> "api"; the --style answer or, absent an API signal, the
      committed declaration -> "operator"; otherwise exit 4 with the located
      stderr. Returns { ExitCode; Style; Source }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectKey,
        [string] $ApiStyle = '',
        [string] $Committed = '',
        [string] $Flag = ''
    )
    if ($ApiStyle -and (-not $Committed -or $Committed -eq $ApiStyle)) {
        return [pscustomobject]@{ ExitCode = 0; Style = $ApiStyle; Source = 'api' }
    }
    if ($Flag) {
        return [pscustomobject]@{ ExitCode = 0; Style = $Flag; Source = 'operator' }
    }
    if (-not $ApiStyle -and $Committed) {
        return [pscustomobject]@{ ExitCode = 0; Style = $Committed; Source = 'operator' }
    }
    $reason = if ($ApiStyle) { 'the committed style conflicts with the API signal' }
    else { 'no unambiguous style signal in the discovery payload' }
    [Console]::Error.WriteLine("config: project ${ProjectKey}: style is ambiguous ($reason); pass --style $ProjectKey=company_managed or --style $ProjectKey=team_managed")
    return [pscustomobject]@{ ExitCode = $script:ExitConfig; Style = ''; Source = '' }
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
    $styles = if ($state.ContainsKey('styles')) { $state['styles'] } else { '' }

    $configdir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }

    # Config read: load and validate the committed team config (US4).
    $cfg = Import-JiraConfig -ConfigDir $configdir
    if ($cfg.ExitCode -ne 0) { return [int] $cfg.ExitCode }
    $cfgObj = $cfg.Json | ConvertFrom-Json -Depth 100

    # Degraded-mode trigger (002 US2, FR-008) — tested BEFORE any Jira call and
    # ONLY on ABSENT connection parameters (research §4).
    $missing = [System.Collections.Generic.List[string]]::new()
    if (-not $env:SPEC_KIT_JIRA_BASE_URL) { $missing.Add('SPEC_KIT_JIRA_BASE_URL') }
    if (-not (Resolve-JiraToken)) { $missing.Add('JIRA_API_TOKEN') }
    if ($missing.Count -gt 0) {
        return [int](Invoke-JiraConfigDegraded -Json $json -DryRun $dryRun -Missing ($missing -join ', '))
    }

    # Project-key sourcing (002 US2, FR-004/FR-005): positional argument ->
    # committed non-placeholder keys -> the closed question over the discovered
    # accessible-projects list (unattended: exit 4). Git state plays no role.
    $argsLine = if ($state.ContainsKey('args')) { $state['args'] } else { '' }
    $argKey = ($argsLine -split ' ')[0]

    # Read the machine-owned local layer up front: its prior resolved-id table seeds
    # this run so re-running only (re)binds the currently configured projects while
    # every previously-bound project's mapping is preserved untouched — the config
    # command is incrementally re-runnable (FR-043). Each project's ids land under
    # its own key, so distinct projects never share a namespace (FR-044).
    $localf = Join-Path $configdir 'config.local.yml'
    $existing = if (Test-Path -LiteralPath $localf) {
        (ConvertFrom-JiraConfigYaml -Path $localf) | ConvertFrom-Json -Depth 100
    } else { [pscustomobject]@{} }

    # API reads: discover each project and (re)build its resolved-id entry, seeded
    # from the existing table so unconfigured-but-previously-bound projects survive.
    # Enumerate properties directly (never `.PSObject.Properties.Name` — that throws
    # under StrictMode when the object is empty, e.g. a first run with no local file).
    $resolved = [ordered]@{}
    if ($existing -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $existing.PSObject.Properties) {
            if ($prop.Name -eq 'resolved_ids' -and $null -ne $prop.Value) {
                foreach ($e in $prop.Value.PSObject.Properties) { $resolved[$e.Name] = $e.Value }
            }
        }
    }
    $nproj = 0
    $projects = @()
    if ($cfgObj.PSObject.Properties.Name -contains 'projects') { $projects = @($cfgObj.projects) }

    # Effective key list: argument, or the committed non-placeholder keys.
    $keys = [System.Collections.Generic.List[string]]::new()
    if ($argKey) {
        $keys.Add($argKey)
    }
    else {
        foreach ($p in $projects) {
            $ckey = [string](Get-CmdProp $p 'key')
            if ([string]::IsNullOrEmpty($ckey)) { continue }
            if (Test-JiraPlaceholderKey -Key $ckey) { continue }
            $keys.Add($ckey)
        }
    }
    if ($keys.Count -eq 0) {
        $lr = Get-JiraDiscoveryProjectList
        if ($lr.ExitCode -ne 0) { return [int] $lr.ExitCode }
        $placeholder = Get-JiraPlaceholderKey
        [Console]::Error.WriteLine("config: no usable project key — config.yml holds no bound key (the $placeholder placeholder counts as unset) and no key argument was given")
        [Console]::Error.WriteLine('config: accessible projects (closed question — choose one and re-run: spec-kit-jira config <KEY>):')
        foreach ($entry in @($lr.List | ConvertFrom-Json -Depth 100)) {
            $styleText = if ($null -eq $entry.style) { 'style unknown' } else { [string]$entry.style }
            [Console]::Error.WriteLine("config:   $($entry.key) — $($entry.name) ($styleText)")
        }
        return $script:ExitConfig
    }

    $projStyles = [ordered]@{}
    foreach ($pkey in $keys) {
        $p = $null
        foreach ($cand in $projects) {
            if ([string](Get-CmdProp $cand 'key') -ceq $pkey) { $p = $cand; break }
        }
        $r = Get-JiraDiscoveryBindingResult -ProjectKey $pkey
        if ($r.ExitCode -ne 0) { return [int] $r.ExitCode }
        # Style resolution (002 US1): api signal -> operator answer/declaration
        # -> fail closed. An ambiguous project refuses BEFORE any write.
        $bindingObj = $r.Binding | ConvertFrom-Json -Depth 100
        $apiStyle = [string](Get-CmdProp $bindingObj 'style')
        $committed = [string](Get-CmdProp $p 'style')
        $flag = Get-JiraStyleFlagFor -ProjectKey $pkey -Styles $styles
        $sr = Resolve-JiraProjectStyle -ProjectKey $pkey -ApiStyle $apiStyle -Committed $committed -Flag $flag
        if ($sr.ExitCode -ne 0) { return [int] $sr.ExitCode }
        $rids = [ordered]@{}
        foreach ($prop in ((Get-JiraResolvedIdMap -BindingJson $r.Binding) | ConvertFrom-Json -Depth 100).PSObject.Properties) {
            $rids[$prop.Name] = $prop.Value
        }
        $rids['style'] = $sr.Style
        $rids['style_source'] = $sr.Source
        $resolved[$pkey] = $rids
        $projStyles[$pkey] = [ordered]@{ style = $sr.Style; style_source = $sr.Source }
        $nproj++
    }

    # Merge the resolved-id table into the machine-owned local layer, preserving
    # the operator's site_alias / overrides, and emit deterministic canonical YAML.
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

    # Hooks effect (US9, T085): register the after_* lifecycle hooks idempotently in
    # .specify/extensions.yml (FR-054) — the same self-healing write reachable from a
    # run via reconcile --repair-hooks. The path derives from the config dir's parent
    # (.specify), overridable via SPEC_KIT_JIRA_EXTENSIONS_YML.
    $extPath = if ($env:SPEC_KIT_JIRA_EXTENSIONS_YML) { $env:SPEC_KIT_JIRA_EXTENSIONS_YML } else { Join-Path (Split-Path -Parent $configdir) 'extensions.yml' }
    $hooksResult = Set-JiraHookRegistration -Path $extPath -DryRun ([bool]$dryRun)
    $hooksStatus = $hooksResult.Status
    $hooksDetail = switch ($hooksStatus) {
        'created' { 'after_* lifecycle hooks registered' }
        'repaired' { 'missing lifecycle hooks repaired' }
        'unchanged' { 'lifecycle hooks already registered' }
        'refused' { 'extensions.yml markers malformed; hooks not registered' }
        default { $hooksStatus }
    }

    # Build the three-effect summary (FR-054), byte-identical to the Bash port:
    # discovery, hooks, and README each reported as a distinct section.
    $effects = [ordered]@{
        discovery = [ordered]@{ status = $discStatus; detail = "$nproj project(s) discovered"; projects = $projStyles }
        hooks     = [ordered]@{ status = $hooksStatus; detail = $hooksDetail }
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
