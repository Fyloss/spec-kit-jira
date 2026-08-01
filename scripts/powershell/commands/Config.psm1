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
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Hierarchy.psm1') -Force
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
      Build the canonical project mapping entry by logical name. Returns
      { ExitCode; Json } — the same asymmetric-shape convention as the client.
      Three keys and their linked-story requirement are retired (008 T028).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Style
    )
    $entry = [ordered]@{ key = $Key; style = $Style }
    return [pscustomobject]@{ ExitCode = 0; Json = (ConvertTo-JiraJsonValue $entry) }
}

function Get-JiraResolvedIdMap {
    <#
    .SYNOPSIS
      Reshape a discovered project binding into the resolved-id table the
      reconcile path consumes. Issue types keep hierarchy_level and subtask
      as a LIST, in discovered order (data-model.md §3, R5) — a name-to-id map
      discarded both the moment they became durable. Priorities and statuses
      are unaffected. hierarchy_level is carried as a string like every other
      identifier here — the YAML writer has no number type. Mirror of
      config_resolved_ids_for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $BindingJson)
    $b = $BindingJson | ConvertFrom-Json -Depth 100
    $issue = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @($b.issue_types)) {
        $issue.Add([ordered]@{
            logical_name    = [string]$t.logical_name
            id              = [string]$t.id
            hierarchy_level = [string]$t.hierarchy_level
            subtask         = [bool]$t.subtask
        })
    }
    $prio = [ordered]@{}; foreach ($p in @($b.priorities)) { $prio[[string]$p.logical_name] = [string]$p.id }
    $stat = [ordered]@{}; foreach ($s in @($b.statuses)) { $stat[[string]$s.name] = [string]$s.id }
    $result = [ordered]@{ issue_types = $issue.ToArray(); priorities = $prio; statuses = $stat }
    # required_fields and parent_link_available (T017-T020) carry straight
    # through — discovery already shapes them keyed by issue-type id — and
    # are omitted rather than emitted empty when discovery resolved neither
    # type (the ambiguous-child case).
    if ($b.PSObject.Properties.Match('required_fields').Count -and @($b.required_fields.PSObject.Properties).Count -gt 0) {
        $result['required_fields'] = $b.required_fields
    }
    if ($b.PSObject.Properties.Match('parent_link_available').Count -and @($b.parent_link_available.PSObject.Properties).Count -gt 0) {
        $result['parent_link_available'] = $b.parent_link_available
    }
    return (ConvertTo-JiraJsonValue $result)
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
        [Parameter(Mandatory)] [string] $Missing,
        [string] $HooksStatus = 'skipped',
        [string] $HooksDetail = ''
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
    $rerun = "define $Missing, then re-run: $(Get-JiraBridgeInvocation config)"

    $detail = 'degraded mode: Jira connection parameters undefined'
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'config'
        dry_run        = [bool]$DryRun
        counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = 1; errors = 0 }
        effects        = [ordered]@{
            discovery = [ordered]@{ status = 'skipped'; detail = $detail }
            # The hooks effect is reported even here. It needs no Jira at all — it
            # reads two local files — and an operator running the ceremony to
            # release a held event with --enable-hook is very likely to be doing it
            # before the credentials are in place. Reporting it "skipped" would
            # have been a lie about work that was in fact performed.
            hooks     = [ordered]@{ status = $HooksStatus; detail = $HooksDetail }
            readme    = [ordered]@{ status = 'skipped'; detail = $detail }
            gitignore = [ordered]@{ status = 'skipped'; detail = $detail }
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

function Get-CmdParentPath {
    # Mirror of bash dirname: the parent of a single-component relative path is
    # '.', never the empty string — Split-Path -Parent '' throws downstream,
    # before any IsNullOrEmpty guard can run.
    param([string] $Path)
    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrEmpty($parent)) { return '.' }
    return $parent
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

function Get-JiraChildTypeFlagFor {
    # The operator's --child-type answer for one project (last occurrence
    # wins), or '' when none was given. Mirror of _config_child_type_flag_for.
    param([string] $ProjectKey, [string] $ChildTypes)
    $out = ''
    foreach ($tok in ($ChildTypes -split ' ')) {
        if ($tok -clike "$ProjectKey=*") { $out = $tok.Substring($tok.IndexOf('=') + 1) }
    }
    return $out
}

function Resolve-JiraChildType {
    <#
    .SYNOPSIS
      The child TYPE (research R1/R2, contract §2): derived when the child
      hierarchy level holds exactly one non-sub-task candidate; otherwise the
      operator's --child-type answer; otherwise exit 4 naming the level and
      every candidate. Mirror of _config_resolve_child_type. Returns
      { ExitCode; Entry } where Entry is [ordered]@{logical_name;id;source}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectKey,
        [Parameter(Mandatory)] $IssueTypes,
        [string] $Flag = ''
    )
    $childLevel = Get-JiraHierarchyChildLevel -IssueTypes $IssueTypes
    if ($null -eq $childLevel) {
        [Console]::Error.WriteLine("config: project ${ProjectKey}: the discovered project declares no issue types at all")
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Entry = $null }
    }
    $candidates = @($IssueTypes | Where-Object { (-not [bool]$_.subtask) -and ([int]$_.hierarchy_level -eq $childLevel) })
    if ($candidates.Count -eq 1) {
        $entry = [ordered]@{ logical_name = $candidates[0].logical_name; id = $candidates[0].id; source = 'derived' }
        return [pscustomobject]@{ ExitCode = 0; Entry = $entry }
    }
    if ($Flag) {
        $match = $candidates | Where-Object { $_.logical_name -eq $Flag } | Select-Object -First 1
        if ($match) {
            $entry = [ordered]@{ logical_name = $match.logical_name; id = $match.id; source = 'operator' }
            return [pscustomobject]@{ ExitCode = 0; Entry = $entry }
        }
        [Console]::Error.WriteLine("config: project ${ProjectKey}: --child-type $Flag names no candidate at the child level")
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Entry = $null }
    }
    $list = ($candidates | ForEach-Object { $_.logical_name }) -join ', '
    [Console]::Error.WriteLine("config: project ${ProjectKey}: the child level holds more than one issue type ($list); pass --child-type $ProjectKey=<one of them>")
    return [pscustomobject]@{ ExitCode = $script:ExitConfig; Entry = $null }
}

function Set-JiraConfigGitignore {
    <#
    .SYNOPSIS
      Enforce gitignore coverage of the gitignored config layer (002 US3,
      FR-019): config.local.yml, .env, and personal.yml. Mirror of
      _config_gitignore_effect. Only missing exact lines are appended,
      idempotently; an absent file is created with the three lines. Returns the
      effect status (created|written|unchanged); a dry-run computes the status
      without touching the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [bool] $DryRun = $false
    )
    $gi = if ($env:SPEC_KIT_JIRA_GITIGNORE) { $env:SPEC_KIT_JIRA_GITIGNORE } else { Join-Path $RepoRoot '.gitignore' }
    $lines = @(
        '.specify/jira/config.local.yml'
        '.specify/jira/.env'
        '.specify/jira/personal.yml'
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path -LiteralPath $gi)) {
        if (-not $DryRun) {
            [System.IO.File]::WriteAllText($gi, (($lines -join "`n") + "`n"), $utf8)
        }
        return 'created'
    }
    $content = [System.IO.File]::ReadAllText($gi)
    $existing = $content -split "`r?`n"
    $missing = @($lines | Where-Object { $existing -cnotcontains $_ })
    if ($missing.Count -eq 0) { return 'unchanged' }
    if (-not $DryRun) {
        # Guarantee a trailing newline before appending the missing lines.
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += "`n" }
        $content += (($missing -join "`n") + "`n")
        [System.IO.File]::WriteAllText($gi, $content, $utf8)
    }
    return 'written'
}

# =============================================================================
# The hooks effect (003 US6, FR-021 – FR-025, FR-028, FR-029).
# Mirror of _config_hooks_effect in commands/config.sh.
# =============================================================================

function Get-JiraConfigHooksEffect {
    <#
    .SYNOPSIS
      Read the hook registry, classify every declared event, record what needs
      recording in OUR file, and return { Status; Detail; Health }. The registry
      itself is never opened for writing — in any state, including this one
      (FR-022).

      Two writes happen here, and both are to the gitignored local binding, never
      to the registry:
        * an entry the registry shows as `enabled: false` is RECORDED, so the
          operator's decision survives the next `specify extension add`, which
          rewrites `enabled: true` unconditionally (research R5 step 1);
        * each `--enable-hook <event>` clears one recorded event (FR-029).
      The health classification itself writes nothing anywhere; the ceremony
      performs the write, on the same terms as its other writes — predicted by
      --dry-run, never performed by it (Constitution XI).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RegistryPath,
        [Parameter(Mandatory)] [string] $ConfigDir,
        [bool] $DryRun = $false,
        [string] $EnableHooks = ''
    )

    # The operator's explicit releases come FIRST, so a release and the report
    # that names it cannot disagree within one run.
    $released = [System.Collections.Generic.List[string]]::new()
    foreach ($ev in ($EnableHooks -split ' ')) {
        if ([string]::IsNullOrEmpty($ev)) { continue }
        if ((Remove-JiraHooksDisabled -LifecycleEvent $ev -ConfigDir $ConfigDir -DryRun $DryRun) -eq 'released') {
            $released.Add($ev)
        }
    }

    $health = Get-JiraHookHealth -Path $RegistryPath -DisabledJson (Get-JiraHooksDisabled -ConfigDir $ConfigDir)
    $h = $health | ConvertFrom-Json -Depth 100

    if ($h.unreadable) {
        return [pscustomobject]@{ Status = 'unreadable'; Detail = $h.repair_hint; Health = $health }
    }

    # Record every entry the registry shows as disabled. This is the capture the
    # whole disable record depends on: the extension only ever learns of the
    # operator's decision by reading the file, and the next install erases the
    # evidence (data-model § Operator disable record, Capture window).
    foreach ($ev in @($h.disabled)) {
        $null = Add-JiraHooksDisabled -LifecycleEvent $ev -ConfigDir $ConfigDir -DryRun $DryRun
    }

    # Re-read so the reported health reflects what this run just recorded.
    $health = Get-JiraHookHealth -Path $RegistryPath -DisabledJson (Get-JiraHooksDisabled -ConfigDir $ConfigDir)
    $h = $health | ConvertFrom-Json -Depth 100

    $heldAll = [System.Collections.Generic.List[string]]::new()
    foreach ($x in (@($h.disabled) + @($h.held_disabled))) { if (-not $heldAll.Contains($x)) { $heldAll.Add($x) } }
    $hint = if ($h.PSObject.Properties['repair_hint']) { $h.repair_hint } else { '' }

    # One status token, chosen by severity: a missing entry means the mirror is
    # not wired at all, a leftover means the next install will duplicate it, and a
    # held event is a deliberate operator choice rather than a fault. The detail
    # carries every applicable clause, so nothing is hidden by the precedence.
    $status =
        if (@($h.missing).Count -gt 0) { 'incomplete' }
        elseif (@($h.duplicated).Count -gt 0) { 'duplicated' }
        elseif ($heldAll.Count -gt 0) { 'held_disabled' }
        else { 'healthy' }

    $detail = if ($status -eq 'healthy') {
        'all seven lifecycle hooks present and enabled; the registry was not modified'
    }
    else { $hint }
    if ($released.Count -gt 0) { $detail = "$detail; released: $($released -join ', ')" }

    return [pscustomobject]@{ Status = $status; Detail = $detail; Health = $health }
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
    $childTypes = if ($state.ContainsKey('child_types')) { $state['child_types'] } else { '' }
    $enableHooks = if ($state.ContainsKey('enable_hooks')) { $state['enable_hooks'] } else { '' }

    $configdir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }

    # Hooks effect (003 US6): computed UP FRONT, because it needs no Jira and no
    # committed config — it reads the registry and the local binding, and nothing
    # else. Computing it here means the report is truthful in the degraded run too,
    # and that `--enable-hook` works in a repository that is not yet connected,
    # which is exactly where an operator is most likely to reach for it.
    $extPath = if ($env:SPEC_KIT_JIRA_EXTENSIONS_YML) { $env:SPEC_KIT_JIRA_EXTENSIONS_YML } else { Join-Path (Get-CmdParentPath $configdir) 'extensions.yml' }
    $hooksEffect = Get-JiraConfigHooksEffect -RegistryPath $extPath -ConfigDir $configdir -DryRun $dryRun -EnableHooks $enableHooks
    $hooksStatus = $hooksEffect.Status
    $hooksDetail = $hooksEffect.Detail
    $hooksHealth = $hooksEffect.Health

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
        return [int](Invoke-JiraConfigDegraded -Json $json -DryRun $dryRun -Missing ($missing -join ', ') `
                -HooksStatus $hooksStatus -HooksDetail $hooksDetail)
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
        [Console]::Error.WriteLine("config: accessible projects (closed question — choose one and re-run: $(Get-JiraBridgeInvocation 'config <KEY>')):")
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

        # Hierarchy derivation (008 T042/T044/T045, research R1/R2, contract
        # §2/§3): the parent TYPE is derived; the child TYPE is a recorded
        # operator/derived answer, resolved here and persisted with its
        # provenance beside style/style_source.
        $itypesRaw = Get-CmdProp $bindingObj 'issue_types'
        $itypes = if ($null -ne $itypesRaw) { @($itypesRaw) } else { @() }
        $derivation = Get-JiraHierarchyDerivation -ProjectKey $pkey -IssueTypes $itypes
        if ($derivation.Status -ne 'ok') {
            [Console]::Error.WriteLine($derivation.Message)
            return $script:ExitConfig
        }
        $childFlag = Get-JiraChildTypeFlagFor -ProjectKey $pkey -ChildTypes $childTypes
        $childResolved = Resolve-JiraChildType -ProjectKey $pkey -IssueTypes $itypes -Flag $childFlag
        if ($childResolved.ExitCode -ne 0) { return [int] $childResolved.ExitCode }
        $rids['child_type'] = $childResolved.Entry
        $rids['parent_type'] = [ordered]@{ logical_name = $derivation.Parent.logical_name; id = $derivation.Parent.id; source = 'derived' }

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

    # Connected-run mismatch surfacing (002 US2, FR-009): when the committed config
    # declares a `teams:` catalogue, check each declared team's project against the
    # accessible-projects list and warn (never block) for any team whose project is
    # not visible. Without a catalogue no extra read is performed.
    $runWarnings = 0
    $teams = @((Get-CmdProp $cfgObj 'teams') | Where-Object { $null -ne $_ })
    if ($teams.Count -gt 0) {
        # The Bash twin silences this read's stderr (2>/dev/null): a failed list
        # skips the check without extra output.
        $errSink = [System.IO.StringWriter]::new()
        $origErr = [Console]::Error
        [Console]::SetError($errSink)
        try { $accessible = Get-JiraDiscoveryProjectList }
        finally { [Console]::SetError($origErr) }
        if ($accessible.ExitCode -eq 0) {
            $accessibleKeys = @(($accessible.List | ConvertFrom-Json -Depth 100) | ForEach-Object { [string]$_.key })
            foreach ($t in $teams) {
                $tid = [string](Get-CmdProp $t 'id')
                if ([string]::IsNullOrEmpty($tid)) { continue }
                $tproj = [string](Get-CmdProp $t 'project')
                if ($accessibleKeys -cnotcontains $tproj) {
                    Write-JiraWarning "team '$tid': project $tproj matches no accessible Jira project — a provisional, branch-derived value may have been accepted into the catalogue; verify or fix config.yml"
                    $runWarnings++
                }
            }
        }
    }

    # Gitignore effect (002 US3, FR-019): ensure the repository .gitignore covers the
    # gitignored config layer (config.local.yml, .env, personal.yml). Repo root is
    # the parent of the .specify directory (overridable via SPEC_KIT_JIRA_GITIGNORE).
    $gitignoreRoot = Get-CmdParentPath (Get-CmdParentPath $configdir)
    $gitignoreStatus = Set-JiraConfigGitignore -RepoRoot $gitignoreRoot -DryRun ([bool]$dryRun)

    # README effect (US5, T065): splice the version-marked managed block into the
    # consuming repository's README. The path derives from the config dir's repo
    # root (the parent of .specify), overridable via SPEC_KIT_JIRA_README.
    $repoRoot = Get-CmdParentPath (Get-CmdParentPath $configdir)
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

    # Build the effects summary (FR-054), byte-identical to the Bash port:
    # discovery, hooks, README and gitignore each reported as a distinct section.
    # The hooks effect was computed up front and is a READ-ONLY verification —
    # nothing in this command writes the hook registry (003 FR-022).
    $effects = [ordered]@{
        discovery = [ordered]@{ status = $discStatus; detail = "$nproj project(s) discovered"; projects = $projStyles }
        hooks     = [ordered]@{ status = $hooksStatus; detail = $hooksDetail }
        readme    = [ordered]@{ status = $readmeStatus; detail = $readmeDetail }
        gitignore = [ordered]@{ status = $gitignoreStatus; detail = 'personal.yml gitignore coverage' }
    }
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'config'
        dry_run        = [bool]$dryRun
        counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = $runWarnings; errors = 0 }
        effects        = $effects
        hook_health    = ($hooksHealth | ConvertFrom-Json -Depth 100)
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
