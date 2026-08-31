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
# 032 — the ceremony canonicalises the origin it reached before recording it
# (C3.2). Imported here explicitly: lib/Config.psm1's own import of this
# module does not make its functions visible in THIS module's scope, and the
# gap surfaced as a cross-port byte divergence in config.local.yml rather
# than as a load error.
Import-Module (Join-Path $PSScriptRoot '../lib/UrlOrigin.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force -Global # ConvertFrom-JiraConfigYaml must reach callers — a nested import here is not enough
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Hierarchy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Credentials.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../hooks/ReadmeBlock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/ManagedSection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/PlanApply.psm1') -Force

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
    # defaultable_fields (011, T012) gets the same treatment — a binding
    # written before this feature simply carries no such key.
    if ($b.PSObject.Properties.Match('defaultable_fields').Count -and @($b.defaultable_fields.PSObject.Properties).Count -gt 0) {
        $result['defaultable_fields'] = $b.defaultable_fields
    }
    return (ConvertTo-JiraJsonValue $result)
}

function Invoke-JiraConfigDegraded {
    <#
    .SYNOPSIS
      The degraded, report-only path (002 US2, FR-008/FR-009). Mirror of
      _config_degraded_run: branch-scan proposals marked provisional, exactly
      one warning naming the missing variables, re-run guidance, zero writes,
      exit 0. `hooks`, `gitignore` and `personal` report their TRUE status
      (030, research §R5): the fresh-setup case IS degraded mode, and it is
      exactly when personal.yml must be created and covered by the ignore
      rule. -CredReason (030, FR-038, C6.4-C6.6) is the located C3.x reason
      when JIRA_PAT_COMMAND was declared and failed — appended to the detail
      and already printed to stderr by the caller.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredReason', Justification = 'Holds a located, human-readable failure reason (C6.4-C6.6), never a token or secret; the name matches the rule''s naming heuristic, not its intent.')]
    [CmdletBinding()]
    param(
        [bool] $Json = $false,
        [bool] $DryRun = $false,
        [Parameter(Mandatory)] [string] $Missing,
        [string] $GitignoreStatus = 'skipped',
        [string] $PersonalStatus = 'skipped',
        [string] $PersonalDetail = '',
        [string] $CredReason = ''
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
    if ($CredReason) { $detail = "$detail; $CredReason" }
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'config'
        dry_run        = [bool]$DryRun
        counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = 1; errors = 0 }
        effects        = [ordered]@{
            discovery = [ordered]@{ status = 'skipped'; detail = $detail }
            # The gitignore and personal effects are reported even here: they
            # need no Jira at all, and the fresh-setup case IS degraded mode,
            # which is exactly when personal.yml must be created and covered by
            # the ignore rule (030, research R5). Reporting them "skipped" would
            # be a lie about work that was in fact performed.
            readme    = [ordered]@{ status = 'skipped'; detail = $detail }
            gitignore = [ordered]@{ status = $GitignoreStatus; detail = 'personal.yml gitignore coverage' }
            personal  = [ordered]@{ status = $PersonalStatus; detail = $PersonalDetail }
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

function Get-JiraDeclaredHierarchyFor {
    <#
    .SYNOPSIS
      The committed projects[].hierarchy mapping for one project (010,
      contract §2.1), or an empty map when the project declares none.
      Mirror of _config_declared_hierarchy_for.
    #>
    [CmdletBinding()]
    param($ProjectEntry)
    $h = Get-CmdProp $ProjectEntry 'hierarchy'
    $out = @{}
    if ($null -eq $h) { return $out }
    if ($h -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $h.PSObject.Properties) { $out[$p.Name] = [string]$p.Value }
    }
    elseif ($h -is [System.Collections.IDictionary]) {
        foreach ($k in $h.Keys) { $out[[string]$k] = [string]$h[$k] }
    }
    return $out
}

function Get-JiraOperatorRolesFor {
    <#
    .SYNOPSIS
      The operator's --issue-type / --child-type answers for one project,
      reduced to {role: name} (010, contract §2.2). IssueTypes is
      Invoke-JiraCliParse's merged, space-separated `KEY=role=name` stream
      (--child-type is already translated to role=story by lib/Cli.psm1);
      last occurrence per (KEY, role) wins. Mirror of
      _config_operator_roles_for.
    #>
    [CmdletBinding()]
    param([string] $ProjectKey, [string] $IssueTypes)
    $out = @{}
    foreach ($tok in ($IssueTypes -split ' ')) {
        if ([string]::IsNullOrEmpty($tok)) { continue }
        if (-not ($tok -clike "$ProjectKey=*")) { continue }
        $rest = $tok.Substring($tok.IndexOf('=') + 1)
        $eq = $rest.IndexOf('=')
        $role = $rest.Substring(0, $eq)
        $name = $rest.Substring($eq + 1)
        $out[$role] = $name
    }
    return $out
}

function Get-JiraFieldAnswersFor {
    <#
    .SYNOPSIS
      This run's --field-default answers for one project (011, contract
      §2.4), reduced to an array of {type; label; value} in argv order.
      FieldDefaults is Invoke-JiraCliParse's \x1f-joined stream (NOT
      space-joined — a field VALUE may itself contain spaces). A standalone
      copy of Cli.psm1's Get-JiraFieldAnswersFor rather than a delegate to
      it: importing lib/Cli.psm1 -Force from a module that is itself
      imported by a Pester BeforeAll can tear an already-imported lib module
      out of the caller's scope (order-dependent breakage seen before with
      lib/Config.psm1 — see the project memory on this). Duplicated on
      purpose; keep both copies in step if either changes.
    #>
    [CmdletBinding()]
    param([string] $ProjectKey, [string] $FieldDefaults)
    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($FieldDefaults)) { return (ConvertTo-JiraJsonValue $out) }
    $us = [char]0x1F
    foreach ($tok in $FieldDefaults.Split($us)) {
        if ([string]::IsNullOrEmpty($tok)) { continue }
        $parts = Get-JiraFieldFlagPart -Value $tok
        if ($null -eq $parts) { continue }
        if ($parts.ProjectKey -ne $ProjectKey) { continue }
        $out.Add([ordered]@{ type = $parts.IssueType; label = $parts.Label; value = $parts.Value })
    }
    return (ConvertTo-JiraJsonValue $out)
}

# Marker tokens for the field_defaults managed region (011, T045). Substrings,
# not full lines — mirrors $script:ReadmeBeginToken's convention.
$script:FieldDefaultsBeginToken = '# --- spec-kit-jira:field_defaults:begin ---'
$script:FieldDefaultsEndToken = '# --- spec-kit-jira:field_defaults:end ---'

function Get-JiraFieldDefaultsBlock {
    <#
    .SYNOPSIS
      The field_defaults region's full text (markers included), no trailing
      newline. Mirror of _config_field_defaults_block.
    #>
    [CmdletBinding()]
    param([string] $MapJson = '{}')
    if ([string]::IsNullOrEmpty($MapJson)) { $MapJson = '{}' }
    $yaml = Get-JiraFieldDefaultsYaml -MapJson $MapJson
    $lines = @(
        $script:FieldDefaultsBeginToken,
        '# Recorded defaults for custom fields on ticket creation (011), written by',
        '# `/speckit.jira-mirror.config`. Edit a value here by hand if you like — keep it',
        '# between these markers; an entry outside them is a duplicate top-level key',
        '# and the next read refuses it (exit 4).',
        $yaml,
        $script:FieldDefaultsEndToken
    )
    return ($lines -join "`n")
}

function Set-JiraFieldDefaultsBlock {
    <#
    .SYNOPSIS
      Splice the resolved field_defaults map into the team config through the
      existing managed-section engine. Returns { ExitCode; Status } where
      Status is created|written|unchanged|refused|inert. `inert` (research
      R6, FR-028): an empty map and a file that has never carried the region
      are left completely untouched. Mirror of _config_field_defaults_write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $MapJson = '{}',
        [bool] $DryRun = $false
    )
    if ([string]::IsNullOrEmpty($MapJson)) { $MapJson = '{}' }

    $existed = Test-Path -LiteralPath $Path
    $current = if ($existed) { [System.IO.File]::ReadAllText($Path) } else { '' }

    $mapObj = $MapJson | ConvertFrom-Json -Depth 100
    $isEmpty = (@($mapObj.PSObject.Properties)).Count -eq 0
    if ($isEmpty -and -not $current.Contains($script:FieldDefaultsBeginToken)) {
        return [pscustomobject]@{ ExitCode = 0; Status = 'inert' }
    }

    $block = Get-JiraFieldDefaultsBlock -MapJson $MapJson

    $r = Invoke-JiraManagedSectionSplice -Text $current -BeginToken $script:FieldDefaultsBeginToken `
        -EndToken $script:FieldDefaultsEndToken -NewBlock $block
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Status = 'refused' }
    }
    $new = $r.Content

    $status = if ($existed -and [System.String]::Equals($current, $new, [System.StringComparison]::Ordinal)) {
        'unchanged'
    }
    elseif (-not $existed) { 'created' }
    else { 'written' }

    if (-not $DryRun -and $status -ne 'unchanged') {
        if ($PSCmdlet.ShouldProcess($Path, 'write managed field_defaults block')) {
            [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Status = $status }
}

function Get-JiraTaskMirrorFlagFor {
    <#
    .SYNOPSIS
      The operator's --task-mirror answer for one project (last occurrence
      wins), or '' when none was given this run (022, contract §4). Mirror
      of _config_task_mirror_flag_for.
    #>
    param([string] $ProjectKey, [string] $TaskMirrors)
    $out = ''
    foreach ($tok in ($TaskMirrors -split ' ')) {
        if ($tok -clike "$ProjectKey=*") { $out = $tok.Substring($tok.IndexOf('=') + 1) }
    }
    return $out
}

function Get-JiraTaskMirrorQuestion {
    <#
    .SYNOPSIS
      The closed question line (022, contract §5 "Asked"), reported per
      project when nothing is recorded for it, whether or not a task role is
      declared (FR-005/FR-008).
    #>
    param([string] $ProjectKey)
    return "config: project ${ProjectKey}: how should tasks be mirrored — choose one of: subtask, checklist (answer with --task-mirror '${ProjectKey}=checklist'). Recording nothing keeps today's behaviour: one sub-task per task when a task role is declared, and no task tier otherwise."
}

function Get-JiraTaskMirrorFr012Note {
    <#
    .SYNOPSIS
      Reported at config time (022, contract §5 "FR-012 check") when the
      recorded value is 'subtask' and no sub-task issue type can be resolved
      for the project.
    #>
    param([string] $ProjectKey)
    return "config: project ${ProjectKey}: task_mirror is 'subtask' but no sub-task issue type is resolved for this project — declare hierarchy.task, or switch with --task-mirror '${ProjectKey}=checklist'"
}

function Get-JiraTaskMirrorEffectLine {
    <#
    .SYNOPSIS
      The ceremony's per-project effect line (022, contract §6), reported
      alongside the effects the run already reports separately (FR-013).
    #>
    param([string] $ProjectKey, [string] $Effective, [string] $Status)
    if ([string]::IsNullOrEmpty($Effective)) {
        return "Task mirror: ${ProjectKey} — not recorded; today's behaviour applies"
    }
    return "Task mirror: ${ProjectKey} — $Effective ($Status)"
}

# Marker tokens for the task_mirror managed region (022, contract §3).
$script:TaskMirrorBeginToken = '# --- spec-kit-jira:task_mirror:begin ---'
$script:TaskMirrorEndToken = '# --- spec-kit-jira:task_mirror:end ---'

function Get-JiraTaskMirrorBlock {
    <#
    .SYNOPSIS
      The task_mirror region's full text (markers included), no trailing
      newline. Mirror of _config_task_mirror_block.
    #>
    [CmdletBinding()]
    param([string] $MapJson = '{}')
    if ([string]::IsNullOrEmpty($MapJson)) { $MapJson = '{}' }
    $yaml = Get-JiraTaskMirrorYaml -MapJson $MapJson
    $lines = @(
        $script:TaskMirrorBeginToken,
        '# How each project''s task list reaches Jira (022), written by',
        '# `/speckit.jira-mirror.config`. `subtask` creates one sub-task per task;',
        '# `checklist` writes one checklist into each story instead. Edit a value',
        '# here by hand if you like — keep it between these markers; an entry outside',
        '# them is a duplicate top-level key and the next read refuses it (exit 4).',
        $yaml,
        $script:TaskMirrorEndToken
    )
    return ($lines -join "`n")
}

function Set-JiraTaskMirrorBlock {
    <#
    .SYNOPSIS
      Splice the resolved task_mirror map into the team config through the
      existing managed-section engine. Returns { ExitCode; Status } where
      Status is created|written|unchanged|refused|inert. Mirror of
      _config_task_mirror_write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $MapJson = '{}',
        [bool] $DryRun = $false
    )
    if ([string]::IsNullOrEmpty($MapJson)) { $MapJson = '{}' }

    $existed = Test-Path -LiteralPath $Path
    $current = if ($existed) { [System.IO.File]::ReadAllText($Path) } else { '' }

    $mapObj = $MapJson | ConvertFrom-Json -Depth 100
    $isEmpty = (@($mapObj.PSObject.Properties)).Count -eq 0
    if ($isEmpty -and -not $current.Contains($script:TaskMirrorBeginToken)) {
        return [pscustomobject]@{ ExitCode = 0; Status = 'inert' }
    }

    $block = Get-JiraTaskMirrorBlock -MapJson $MapJson

    $r = Invoke-JiraManagedSectionSplice -Text $current -BeginToken $script:TaskMirrorBeginToken `
        -EndToken $script:TaskMirrorEndToken -NewBlock $block
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ ExitCode = $script:ExitConfig; Status = 'refused' }
    }
    $new = $r.Content

    $status = if ($existed -and [System.String]::Equals($current, $new, [System.StringComparison]::Ordinal)) {
        'unchanged'
    }
    elseif (-not $existed) { 'created' }
    else { 'written' }

    if (-not $DryRun -and $status -ne 'unchanged') {
        if ($PSCmdlet.ShouldProcess($Path, 'write managed task_mirror block')) {
            [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Status = $status }
}

function Get-JiraFieldDefaultAnswerProblem {
    <#
    .SYNOPSIS
      Every §2.4 refusal a THIS-RUN answer produces: unknown issue-type name
      (listing the discovered types), unknown field label (listing that
      type's defaultable fields), a field whose shape cannot be defaulted
      (naming its undefaultable_reason, US3 scenario 3), an empty value, a
      value outside allowed_values, or a credential-shaped value (Principle
      IV — the value itself is never in the problem). Batched, never one
      refusal per answer. Mirror of _config_field_default_answer_problems.
    #>
    [CmdletBinding()]
    param(
        [string] $IssueTypesJson = '[]',
        [string] $DefaultableFieldsByTypeJson = '{}',
        [string] $AnswersJson = '[]'
    )
    if ([string]::IsNullOrEmpty($IssueTypesJson)) { $IssueTypesJson = '[]' }
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($AnswersJson)) { $AnswersJson = '[]' }

    $itypes = @($IssueTypesJson | ConvertFrom-Json -Depth 100)
    $df = $DefaultableFieldsByTypeJson | ConvertFrom-Json -Depth 100
    $ans = @($AnswersJson | ConvertFrom-Json -Depth 100)

    function Resolve-DfdTypeId([string] $Name) {
        foreach ($t in $itypes) { if ([string]$t.logical_name -eq $Name) { return [string]$t.id } }
        return $null
    }
    function Resolve-DfdField([string] $TypeId, [string] $Label) {
        $listProp = $df.PSObject.Properties[$TypeId]
        if ($null -eq $listProp) { return $null }
        foreach ($f in @($listProp.Value)) { if ([string]$f.logical_name -eq $Label) { return $f } }
        return $null
    }

    $problems = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $ans) {
        $t = [string]$a.type; $l = [string]$a.label; $v = [string]$a.value
        $tid = Resolve-DfdTypeId $t
        if ($null -eq $tid) {
            $problems.Add([ordered]@{ kind = 'unknown_type'; type = $t; label = $l; candidates = @($itypes | ForEach-Object { [string]$_.logical_name }) })
            continue
        }
        $f = Resolve-DfdField $tid $l
        if ($null -eq $f) {
            $listProp = $df.PSObject.Properties[$tid]
            $cands = if ($null -eq $listProp) { @() } else { @($listProp.Value | ForEach-Object { [string]$_.logical_name }) }
            $problems.Add([ordered]@{ kind = 'unknown_label'; type = $t; label = $l; candidates = $cands })
            continue
        }
        if ($f.defaultable -ne $true) {
            $problems.Add([ordered]@{ kind = 'undefaultable'; type = $t; label = $l; reason = $f.undefaultable_reason })
            continue
        }
        if ($v -eq '') {
            $problems.Add([ordered]@{ kind = 'empty_value'; type = $t; label = $l })
            continue
        }
        $allowed = @($f.allowed_values)
        if ($allowed.Count -gt 0 -and -not ($allowed -contains $v)) {
            $problems.Add([ordered]@{ kind = 'outside_allowed'; type = $t; label = $l; candidates = $allowed })
            continue
        }
        $shapeErrors = @(Get-JiraConfigCredentialError -Object ([ordered]@{ value = $v }))
        if ($shapeErrors.Count -gt 0) {
            $shape = ($shapeErrors[0] -split ': ', 2)[1]
            $problems.Add([ordered]@{ kind = 'credential'; type = $t; label = $l; shape = $shape })
        }
    }
    return (ConvertTo-JiraJsonValue $problems)
}

function Merge-JiraFieldDefault {
    <#
    .SYNOPSIS
      The union of §2.6: the project's recorded entry (minus `ask`)
      re-emitted, with each THIS-RUN answer overwriting the matching (type,
      label) entry; every other entry carries forward unchanged. Pure
      structural merge — validation is Get-JiraFieldDefaultAnswerProblem's
      job. Mirror of _config_field_default_merge.
    #>
    [CmdletBinding()]
    param([string] $RecordedJson = '{}', [string] $AnswersJson = '[]')
    if ([string]::IsNullOrEmpty($RecordedJson)) { $RecordedJson = '{}' }
    if ([string]::IsNullOrEmpty($AnswersJson)) { $AnswersJson = '[]' }
    $rec = $RecordedJson | ConvertFrom-Json -Depth 100
    $ans = @($AnswersJson | ConvertFrom-Json -Depth 100)

    $merged = [ordered]@{}
    foreach ($p in $rec.PSObject.Properties) {
        if ($p.Name -eq 'ask') { continue }
        $entry = [ordered]@{}
        foreach ($fp in $p.Value.PSObject.Properties) { $entry[$fp.Name] = $fp.Value }
        $merged[$p.Name] = $entry
    }
    foreach ($a in $ans) {
        $t = [string]$a.type; $l = [string]$a.label
        if (-not $merged.Contains($t)) { $merged[$t] = [ordered]@{} }
        $merged[$t][$l] = $a.value
    }
    return (ConvertTo-JiraJsonValue $merged)
}

function Get-JiraFieldDefaultsReport {
    <#
    .SYNOPSIS
      Three non-blocking reports plus one refusal trigger, computed over the
      merged (already-valid) field_defaults entry: orphaned (a recorded type
      or field label the project no longer offers, §2.8/FR-008);
      not_yet_consumed (a recorded type the bridge does not write, §2.8/
      FR-027); undefaultable_required (a required field whose shape cannot
      be defaulted, reported once, §2.3 — the pre-existing mandatory gate
      still refuses it, US3 scenario 3); pending (a required, defaultable
      field of an in-scope type with neither a recorded value nor a
      this-run answer — the ceremony's own refusal trigger); outside_allowed
      (015, research R5, contract §6, data-model.md §7 — a merged entry
      whose value is not one of its field's allowed_values, examined only
      when the type resolves, the label resolves to a defaultable field of
      that type, that field's allowed_values is non-empty, and the recorded
      value is a string — FR-006's escape hatch keeps a hand-written
      structured value out of the check; a refusal trigger, like pending;
      the recorded value itself never appears in the entry). Mirror of
      _config_field_default_report.
    #>
    [CmdletBinding()]
    param(
        [string] $IssueTypesJson = '[]',
        [string] $DefaultableFieldsByTypeJson = '{}',
        [string] $AskTypesJson = '[]',
        [string] $MergedJson = '{}',
        [string] $BridgeTypeIdsJson = '[]'
    )
    if ([string]::IsNullOrEmpty($IssueTypesJson)) { $IssueTypesJson = '[]' }
    if ([string]::IsNullOrEmpty($DefaultableFieldsByTypeJson)) { $DefaultableFieldsByTypeJson = '{}' }
    if ([string]::IsNullOrEmpty($AskTypesJson)) { $AskTypesJson = '[]' }
    if ([string]::IsNullOrEmpty($MergedJson)) { $MergedJson = '{}' }
    if ([string]::IsNullOrEmpty($BridgeTypeIdsJson)) { $BridgeTypeIdsJson = '[]' }

    $itypes = @($IssueTypesJson | ConvertFrom-Json -Depth 100)
    $df = $DefaultableFieldsByTypeJson | ConvertFrom-Json -Depth 100
    $askTypes = @($AskTypesJson | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })
    $merged = $MergedJson | ConvertFrom-Json -Depth 100
    $bridge = @($BridgeTypeIdsJson | ConvertFrom-Json -Depth 100 | ForEach-Object { [string]$_ })

    function Resolve-RepTypeId([string] $Name) {
        foreach ($t in $itypes) { if ([string]$t.logical_name -eq $Name) { return [string]$t.id } }
        return $null
    }
    function Get-DfdFieldsFor([string] $TypeId) {
        $listProp = $df.PSObject.Properties[$TypeId]
        if ($null -eq $listProp) { return @() }
        return @($listProp.Value)
    }

    $orphaned = [System.Collections.Generic.List[object]]::new()
    $notYetConsumed = [System.Collections.Generic.List[object]]::new()
    $outsideAllowed = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $merged.PSObject.Properties) {
        $tname = $p.Name
        $tid = Resolve-RepTypeId $tname
        if ($null -eq $tid) {
            $orphaned.Add([ordered]@{ kind = 'orphaned_type'; type = $tname })
            continue
        }
        $fields = Get-DfdFieldsFor $tid
        foreach ($fp in $p.Value.PSObject.Properties) {
            $match = $null
            foreach ($f in $fields) { if ([string]$f.logical_name -eq $fp.Name) { $match = $f; break } }
            if ($null -eq $match) {
                $orphaned.Add([ordered]@{ kind = 'orphaned_label'; type = $tname; label = $fp.Name })
                continue
            }
            # The leading comma is load-bearing: without it, an `if/else`
            # expression whose chosen branch is an empty array enumerates
            # zero objects into the assignment, collapsing $allowed to $null
            # rather than @() — a real PowerShell array-unwrapping gotcha,
            # not a hypothetical one (it reproduces with a genuinely empty
            # allowed_values, e.g. a `user`-typed field).
            $allowed = if ($null -eq $match.allowed_values) { , @() } else { , @($match.allowed_values) }
            # A string recorded value only (FR-006's escape hatch): a value an
            # operator wrote as an object or an array is the shape the bridge
            # does not derive, obeyed literally, and it can never be a member
            # of an allowed_values list that holds option labels — checking it
            # would refuse exactly the value the spec promises to pass through.
            if ($fp.Value -is [string] -and $allowed.Count -gt 0 -and -not ($allowed -contains $fp.Value)) {
                $outsideAllowed.Add([ordered]@{ type = $tname; label = $fp.Name; candidates = $allowed })
            }
        }
        if (-not ($bridge -contains $tid)) { $notYetConsumed.Add([ordered]@{ kind = 'not_yet_consumed'; type = $tname }) }
    }

    $undefaultableRequired = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($tname in $askTypes) {
        $tid = Resolve-RepTypeId $tname
        foreach ($f in (Get-DfdFieldsFor $tid)) {
            if ($f.required -ne $true) { continue }
            if ($f.defaultable -eq $false) {
                $undefaultableRequired.Add([ordered]@{ type = $tname; label = $f.logical_name; reason = $f.undefaultable_reason })
                continue
            }
            $typeProp = $merged.PSObject.Properties[$tname]
            $hasValue = $false
            if ($null -ne $typeProp) {
                $fieldProp = $typeProp.Value.PSObject.Properties[$f.logical_name]
                if ($null -ne $fieldProp -and $null -ne $fieldProp.Value) { $hasValue = $true }
            }
            if (-not $hasValue) {
                $allowed = if ($null -eq $f.allowed_values) { @() } else { @($f.allowed_values) }
                $pending.Add([ordered]@{ type = $tname; label = $f.logical_name; allowed_values = $allowed })
            }
        }
    }

    return (ConvertTo-JiraJsonValue ([ordered]@{
        orphaned               = $orphaned
        not_yet_consumed       = $notYetConsumed
        undefaultable_required = $undefaultableRequired
        pending                = $pending
        outside_allowed        = $outsideAllowed
    }))
}

function Write-JiraFieldDefaultProblemsReport {
    <#
    .SYNOPSIS
      Refuse this run's --field-default answers (contract §2.4): one message
      per problem to stderr, plus a structured block on stdout in --json
      mode. Mirror of _config_report_field_default_problems.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)][string] $ProblemsJson, [bool] $Json = $false)
    $problems = @($ProblemsJson | ConvertFrom-Json -Depth 100)
    foreach ($p in $problems) {
        $type = [string]$p.type; $label = [string]$p.label
        switch ([string]$p.kind) {
            'unknown_type' {
                [Console]::Error.WriteLine("config: project $ProjectKey`: --field-default names an issue type this project does not offer: $type (discovered types: $((@($p.candidates)) -join ', '))")
            }
            'unknown_label' {
                [Console]::Error.WriteLine("config: project $ProjectKey`: issue type $type has no field named $label (defaultable fields: $((@($p.candidates)) -join ', '))")
            }
            'undefaultable' {
                [Console]::Error.WriteLine("config: project $ProjectKey`: $label ($type) cannot be defaulted — $($p.reason)")
            }
            'empty_value' {
                [Console]::Error.WriteLine("config: project $ProjectKey`: $label ($type) — a default may not be empty")
            }
            'outside_allowed' {
                [Console]::Error.WriteLine("config: project $ProjectKey`: $label ($type) must be one of: $((@($p.candidates)) -join ', ')")
            }
            'credential' {
                [Console]::Error.WriteLine("config: project $ProjectKey`: $label ($type) looks like a $($p.shape) and is refused — it never becomes a recorded default")
            }
        }
        [Console]::Error.WriteLine('')
    }
    if ($Json) {
        [Console]::Out.Write((ConvertTo-JiraJsonValue ([ordered]@{ field_default_problems = $problems })) + "`n")
    }
}

function Get-JiraFieldDefaultNote {
    <#
    .SYNOPSIS
      The three non-blocking field-defaults reports (contract §2.8, §2.3),
      newline-joined, empty when there is nothing to report. Never a
      warning, never a refusal — mirrors role notes. Mirror of
      _config_field_default_notes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectKey, [Parameter(Mandatory)][string] $ReportJson)
    $report = $ReportJson | ConvertFrom-Json -Depth 100
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($o in @($report.orphaned)) {
        if ([string]$o.kind -eq 'orphaned_type') {
            $lines.Add("config: project ${ProjectKey}: field_defaults records issue type '$($o.type)', which the project no longer offers — remove it (orphaned entry, FR-008)")
        }
        else {
            $lines.Add("config: project $ProjectKey, type $($o.type): field_defaults records '$($o.label)', which the type no longer offers — remove it (orphaned entry, FR-008)")
        }
    }
    foreach ($n in @($report.not_yet_consumed)) {
        $lines.Add("config: project ${ProjectKey}: field_defaults records issue type '$($n.type)', which the bridge does not write yet — recorded, not yet consumed (FR-027)")
    }
    foreach ($u in @($report.undefaultable_required)) {
        $lines.Add("config: project $ProjectKey, type $($u.type): $($u.label) cannot be defaulted — $($u.reason) (the pre-existing mandatory-field refusal applies unchanged)")
    }
    foreach ($q in @($report.pending)) {
        $allowed = @($q.allowed_values) -join ', '
        if ($allowed) {
            $lines.Add("config: project $ProjectKey, type $($q.type) requires a value for $($q.label) — choose one of: $allowed (answer with --field-default '$ProjectKey=$($q.type)=$($q.label)=<value>')")
        }
        else {
            $lines.Add("config: project $ProjectKey, type $($q.type) requires a value for $($q.label) (answer with --field-default '$ProjectKey=$($q.type)=$($q.label)=<value>')")
        }
    }
    return ($lines -join "`n")
}

function Write-JiraRoleProblemsReport {
    <#
    .SYNOPSIS
      Render every problem Resolve-JiraRoleMapping found (010, contract §6):
      one block per unresolved role in role order, then unknown/duplicate/
      subtask-misuse/task-misuse/no-parent-level — all to stderr — plus, in
      --json mode, the structured `unresolved_roles` block on stdout (§6.2).
      Mirror of _config_report_role_problems.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProjectKey,
        [Parameter(Mandatory)] $Result,
        [bool] $Json = $false
    )
    foreach ($u in @($Result.Unresolved)) {
        [Console]::Error.WriteLine((Get-JiraRoleUnresolvedMessage -ProjectKey $ProjectKey -Role $u.role -Level $u.level -Candidates $u.candidates))
        [Console]::Error.WriteLine('')
    }
    foreach ($u in @($Result.Unknown)) {
        [Console]::Error.WriteLine((Get-JiraRoleUnknownTypeMessage -ProjectKey $ProjectKey -Role $u.role -Name $u.name -Candidates $u.candidates))
        [Console]::Error.WriteLine('')
    }
    foreach ($d in @($Result.Duplicate)) {
        [Console]::Error.WriteLine((Get-JiraRoleDuplicateMessage -ProjectKey $ProjectKey -Role $d.role -Name $d.name -Level $d.level))
        [Console]::Error.WriteLine('')
    }
    foreach ($s in @($Result.SubtaskMisuse)) {
        [Console]::Error.WriteLine((Get-JiraRoleSubtaskMisuseMessage -ProjectKey $ProjectKey -Role $s.role -Name $s.name))
        [Console]::Error.WriteLine('')
    }
    foreach ($t in @($Result.TaskMisuse)) {
        [Console]::Error.WriteLine((Get-JiraRoleTaskMisuseMessage -ProjectKey $ProjectKey -Name $t.name -Candidates $t.candidates))
        [Console]::Error.WriteLine('')
    }
    if ($Result.NoParentLevel) {
        [Console]::Error.WriteLine($Result.NoParentLevel)
    }

    if ($Json -and @($Result.Unresolved).Count -gt 0) {
        $block = ConvertTo-JiraRoleUnresolvedJson -Result $Result -ProjectKey $ProjectKey
        [Console]::Out.Write((ConvertTo-JiraJsonValue ([ordered]@{ unresolved_roles = $block })) + "`n")
    }
}

function Set-JiraConfigGitignore {
    <#
    .SYNOPSIS
      Enforce gitignore coverage of the gitignored config layer (002 US3,
      FR-019): config.local.yml and personal.yml. Mirror of
      _config_gitignore_effect. Only missing exact lines are appended,
      idempotently; an absent file is created with the three lines. Returns the
      effect status (created|written|unchanged); a dry-run computes the status
      without touching the file.

      `.env` stays in the rule set too, but it is no longer part of that
      gitignored config LAYER (030, personal-config-creation.md §5, C5.3): the
      bridge does not read that file any more (credential-resolution.md C1.2).
      The rule is kept for an installation that predates this feature and
      still has one on disk holding a real token — retiring the reader must
      not be the thing that un-ignores, and so commits, a leftover secret. It
      costs one line and guards a file this tool will never create again.
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
# The personal.yml effect (030, US3, contracts/personal-config-creation.md)
# =============================================================================

function Get-JiraConfigPersonalContent {
    <#
    .SYNOPSIS
      The byte-identical content of a created personal.yml (§2, data-model.md
      §6). Mirror of _config_personal_content. An empty -EmailValue yields a
      commented placeholder; an empty -Ids yields the "no teams declared"
      wording rather than an empty list (US3 AC4). `team` is ALWAYS commented
      out (FR-026) — the ceremony never selects one, even when the catalogue
      offers exactly one.
    #>
    param([string] $EmailValue = '', [string] $Ids = '')
    $emailLine = if ($EmailValue) { "email: $EmailValue" } else { '# email: dev@example.com' }
    $idsLine = if ($Ids) { $Ids } else { '(the catalogue declares no teams)' }
    $lines = @(
        '# .specify/jira/personal.yml — your personal settings. Never committed.'
        ''
        '# Your Jira account email, used for authentication.'
        $emailLine
        ''
        '# Your team, from the catalogue in config.yml. Optional — leave it commented'
        '# out to work without a team selection.'
        "# Available: $idsLine"
        '# team: alpha'
    )
    return ($lines -join "`n") + "`n"
}

function Set-JiraConfigPersonal {
    <#
    .SYNOPSIS
      Create .specify/jira/personal.yml when absent (030, US3, FR-024-FR-031).
      Mirror of _config_personal_effect. Runs AFTER Resolve-JiraConnection (the
      chokepoint), so the outstanding-settings detail reflects the RESOLVED
      state (env or file), not the file alone. Returns { Status; Detail }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ConfigDir,
        [string] $CfgJson = '{}',
        [bool] $DryRun = $false
    )
    $pf = Join-Path $ConfigDir 'personal.yml'
    $outstanding = [System.Collections.Generic.List[string]]::new()
    if (-not $env:SPEC_KIT_JIRA_BASE_URL) { $outstanding.Add('base_url is not set — add it to config.yml (or export SPEC_KIT_JIRA_BASE_URL)') }
    if (-not $env:JIRA_EMAIL) { $outstanding.Add('email is not set — add it to personal.yml (or export JIRA_EMAIL)') }
    $detail = if ($outstanding.Count -gt 0) { $outstanding -join '; ' } else { 'nothing outstanding' }

    if (Test-Path -LiteralPath $pf) {
        return [pscustomobject]@{ Status = 'unchanged'; Detail = $detail }
    }
    if ($DryRun) {
        return [pscustomobject]@{ Status = 'would_create'; Detail = $detail }
    }

    $ids = [System.Collections.Generic.List[string]]::new()
    $cfgObj = $CfgJson | ConvertFrom-Json -Depth 100
    if ($cfgObj.PSObject.Properties['teams'] -and $null -ne $cfgObj.teams) {
        foreach ($t in @($cfgObj.teams)) { if ($t.PSObject.Properties['id']) { $ids.Add([string]$t.id) } }
    }
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    $content = Get-JiraConfigPersonalContent -EmailValue $env:JIRA_EMAIL -Ids ($ids -join ', ')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($pf, $content, $utf8)
    return [pscustomobject]@{ Status = 'created'; Detail = $detail }
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
    $issueTypes = if ($state.ContainsKey('issue_types')) { $state['issue_types'] } else { '' }
    $fieldDefaults = if ($state.ContainsKey('field_defaults')) { $state['field_defaults'] } else { '' }
    $taskMirrors = if ($state.ContainsKey('task_mirrors')) { $state['task_mirrors'] } else { '' }
    $acceptSite = if ($state.ContainsKey('accept_site')) { $state['accept_site'] } else { '' }

    $configdir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }

    # Config read: load and validate the committed team config (US4).
    $cfg = Import-JiraConfig -ConfigDir $configdir
    if ($cfg.ExitCode -ne 0) { return [int] $cfg.ExitCode }
    $cfgObj = $cfg.Json | ConvertFrom-Json -Depth 100

    # The resolution chokepoint (030, plan.md §Key design decision): seed
    # SPEC_KIT_JIRA_BASE_URL / JIRA_EMAIL from config.yml / personal.yml,
    # environment first. Runs before anything below reads either variable.
    # 032, C3.1 — -Binding opts this ceremony out of the destination pin. It is
    # the command that ESTABLISHES the record, so gating it would mean nothing
    # could ever be bound. The opt-out is passed explicitly rather than detected
    # inside the chokepoint: a gate that decides for itself who is exempt is one
    # refactor away from exempting the wrong caller.
    $chokepointRc = Resolve-JiraConnection -ConfigDir $configdir -MergedJson $cfg.Json -Binding
    if ($chokepointRc -ne 0) { return [int] $chokepointRc }

    # 032, C3.7/C3.8 — the ceremony's own gate, BEFORE discovery. It knows the
    # declared destination and the recorded one already; there is nothing to
    # learn from the network first. Refusing here rather than at the write site
    # means a redirected ceremony issues zero requests instead of discovering
    # first and saying no afterwards.
    if (-not (Test-JiraCeremonyPin -ConfigDir $configdir -Declared ([string] $env:SPEC_KIT_JIRA_BASE_URL) -AcceptSite $acceptSite)) {
        return [int] $script:ExitConfig
    }

    # Gitignore + personal effects (030, research §R5) — moved AHEAD of the
    # degraded-mode early return below. The fresh-setup case IS degraded mode
    # (no base URL, no token yet), which is exactly when personal.yml must be
    # created and covered by the ignore rule; an operator would otherwise need
    # working Jira credentials to obtain the file in which they declare them.
    $gitignoreRoot = Get-CmdParentPath (Get-CmdParentPath $configdir)
    $gitignoreStatus = Set-JiraConfigGitignore -RepoRoot $gitignoreRoot -DryRun ([bool]$dryRun)
    $personalEffect = Set-JiraConfigPersonal -ConfigDir $configdir -CfgJson $cfg.Json -DryRun ([bool]$dryRun)
    $personalStatus = $personalEffect.Status
    $personalDetail = $personalEffect.Detail

    # Degraded-mode trigger (002 US2, FR-008) — tested BEFORE any Jira call and
    # ONLY on ABSENT connection parameters (research §4).
    #
    # 030, FR-038, contracts/credential-resolution.md C6.4-C6.6: a token
    # failure is SILENT here when nothing was declared (unchanged), but
    # REPORTED — on stderr and in the degraded run's detail — when
    # JIRA_PAT_COMMAND was declared and failed. Refusing here would deny the
    # operator the very file in which they declare their settings, so the run
    # still completes degraded.
    $missing = [System.Collections.Generic.List[string]]::new()
    if (-not $env:SPEC_KIT_JIRA_BASE_URL) { $missing.Add('SPEC_KIT_JIRA_BASE_URL') }
    $credDeclared = [bool]$env:JIRA_PAT_COMMAND
    $credReason = ''
    if (-not (Resolve-JiraToken)) {
        $missing.Add('JIRA_API_TOKEN')
        if ($credDeclared) {
            $credReason = Get-JiraCredentialLastError
            [Console]::Error.WriteLine("config: $credReason")
        }
    }
    if ($missing.Count -gt 0) {
        return [int](Invoke-JiraConfigDegraded -Json $json -DryRun $dryRun -Missing ($missing -join ', ') `
                -GitignoreStatus $gitignoreStatus -PersonalStatus $personalStatus -PersonalDetail $personalDetail `
                -CredReason $credReason)
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
    $projRoles = [ordered]@{}
    $roleNotes = [System.Collections.Generic.List[string]]::new()
    $projFieldDefaults = [ordered]@{}
    $fdNotes = [System.Collections.Generic.List[string]]::new()
    $projTaskMirror = [ordered]@{}
    $tmNotes = [System.Collections.Generic.List[string]]::new()
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

        # Role mapping (010, contracts/role-mapping.md): one resolver call
        # per project, over all three roles — declared -> operator ->
        # derived, evaluating every role before refusing (contract §3.2).
        # Replaces the two separate 008 calls (Get-JiraHierarchyDerivation
        # then Resolve-JiraChildType) that made the specification tier's
        # refusal hide the story tier's (research R1).
        $itypesRaw = Get-CmdProp $bindingObj 'issue_types'
        $itypes = if ($null -ne $itypesRaw) { @($itypesRaw) } else { @() }
        $declaredH = Get-JiraDeclaredHierarchyFor -ProjectEntry $p
        $operatorH = Get-JiraOperatorRolesFor -ProjectKey $pkey -IssueTypes $issueTypes
        $result = Resolve-JiraRoleMapping -ProjectKey $pkey -IssueTypes $itypes -Declared $declaredH -Operator $operatorH
        if (Test-JiraRoleMappingHasProblems -Result $result) {
            Write-JiraRoleProblemsReport -ProjectKey $pkey -Result $result -Json $json
            return $script:ExitConfig
        }

        $orderingMessage = $null
        if (-not (Test-JiraRoleMapping -ProjectKey $pkey -Roles $result.Roles -Message ([ref]$orderingMessage))) {
            [Console]::Error.WriteLine($orderingMessage)
            return $script:ExitConfig
        }

        # Task-mirror ceremony (022, contract §5/§6): resolve this
        # project's effective value (this run's --task-mirror answer, else
        # whatever is already recorded), report the closed question when
        # nothing ends up recorded, the FR-012 remedy when 'subtask' has no
        # resolvable sub-task type, and the per-project effect line —
        # always, in every case.
        $tmRecorded = Get-JiraTaskMirrorFor -ProjectKey $pkey -ConfigJson $cfg.Json
        $tmFlag = Get-JiraTaskMirrorFlagFor -ProjectKey $pkey -TaskMirrors $taskMirrors
        $tmEffective = if ($tmFlag) { $tmFlag } else { $tmRecorded }
        if ([string]::IsNullOrEmpty($tmEffective)) {
            $tmNotes.Add((Get-JiraTaskMirrorQuestion -ProjectKey $pkey))
        }
        if ($tmEffective -eq 'subtask') {
            $tmTaskRoleId = if ($result.Roles.Contains('task')) { [string]$result.Roles['task'].id } else { '' }
            if ([string]::IsNullOrEmpty($tmTaskRoleId)) {
                $tmNotes.Add((Get-JiraTaskMirrorFr012Note -ProjectKey $pkey))
            }
        }
        $tmStatus = ''
        if (-not [string]::IsNullOrEmpty($tmEffective)) {
            $tmStatus = if ($tmEffective -ne $tmRecorded) { 'recorded' } else { 'unchanged' }
            $projTaskMirror[$pkey] = $tmEffective
        }
        $tmNotes.Add((Get-JiraTaskMirrorEffectLine -ProjectKey $pkey -Effective $tmEffective -Status $tmStatus))

        # Fetch required_fields / parent_link_available for every role id the
        # resolver selected that the initial discovery did not already cover
        # (T050/T051) — the ordinary case once a mapping is declared or
        # answered rather than derived from a single-candidate level.
        $rfMap = [ordered]@{}
        if ($rids.Contains('required_fields') -and $null -ne $rids['required_fields']) {
            foreach ($prop in $rids['required_fields'].PSObject.Properties) { $rfMap[$prop.Name] = $prop.Value }
        }
        $plaMap = [ordered]@{}
        if ($rids.Contains('parent_link_available') -and $null -ne $rids['parent_link_available']) {
            foreach ($prop in $rids['parent_link_available'].PSObject.Properties) { $plaMap[$prop.Name] = $prop.Value }
        }
        $dfMap = [ordered]@{}
        if ($rids.Contains('defaultable_fields') -and $null -ne $rids['defaultable_fields']) {
            foreach ($prop in $rids['defaultable_fields'].PSObject.Properties) { $dfMap[$prop.Name] = $prop.Value }
        }
        foreach ($roleKey in @('specification', 'story', 'task')) {
            if (-not $result.Roles.Contains($roleKey)) { continue }
            $roleId = [string]$result.Roles[$roleKey].id
            if ([string]::IsNullOrEmpty($roleId)) { continue }
            if ($rfMap.Contains($roleId)) { continue }
            $tm = Get-JiraDiscoveryTypeMetadataResult -ProjectKey $pkey -TypeId $roleId
            if ($tm.ExitCode -ne 0) { return [int] $tm.ExitCode }
            $rfMap[$roleId] = $tm.RequiredFields
            $plaMap[$roleId] = $tm.ParentLinkAvailable
            $dfMap[$roleId] = $tm.DefaultableFields
        }
        $rids['required_fields'] = $rfMap
        $rids['parent_link_available'] = $plaMap
        if ($dfMap.Count -gt 0) { $rids['defaultable_fields'] = $dfMap }
        $rids['roles'] = $result.Roles
        if ($result.Roles.Contains('story')) {
            $storyRole = $result.Roles['story']
            $rids['child_type'] = [ordered]@{ logical_name = $storyRole.logical_name; id = $storyRole.id; source = $storyRole.source }
        }
        if ($result.Roles.Contains('specification')) {
            $specRole = $result.Roles['specification']
            $rids['parent_type'] = [ordered]@{ logical_name = $specRole.logical_name; id = $specRole.id; source = $specRole.source }
        }

        # Field-defaults ceremony (011, contract §2): validate this run's
        # --field-default answers for this project (§2.4), merge them with
        # the project's recorded entry (§2.6), ask about any
        # required+defaultable field of an in-scope type still unanswered
        # (§2.1-§2.3, research R4), and collect the three non-blocking
        # reports (§2.8). In scope: the specification and story roles, plus
        # any type an answer names this run (FR-026).
        $itypesJson = ConvertTo-JiraJsonValue $itypes
        $dfMapJson = ConvertTo-JiraJsonValue $dfMap
        $fdAnswersJson = Get-JiraFieldAnswersFor -ProjectKey $pkey -FieldDefaults $fieldDefaults
        $fdRecordedJson = Get-JiraFieldDefaultsFor -ProjectKey $pkey -ConfigJson $cfg.Json
        $fdProblemsJson = Get-JiraFieldDefaultAnswerProblem -IssueTypesJson $itypesJson -DefaultableFieldsByTypeJson $dfMapJson -AnswersJson $fdAnswersJson
        $fdProblems = @($fdProblemsJson | ConvertFrom-Json -Depth 100)
        if ($fdProblems.Count -gt 0) {
            Write-JiraFieldDefaultProblemsReport -ProjectKey $pkey -ProblemsJson $fdProblemsJson -Json $json
            return $script:ExitConfig
        }

        $fdMergedJson = Merge-JiraFieldDefault -RecordedJson $fdRecordedJson -AnswersJson $fdAnswersJson
        # 012: the task role joins the specification and story types on the
        # same closed-question terms — a declared sub-task role's own
        # required field is asked about too (FR-035).
        $askTypeNames = [System.Collections.Generic.List[string]]::new()
        if ($result.Roles.Contains('specification')) { $askTypeNames.Add([string]$result.Roles['specification'].logical_name) }
        if ($result.Roles.Contains('story')) { $askTypeNames.Add([string]$result.Roles['story'].logical_name) }
        if ($result.Roles.Contains('task')) { $askTypeNames.Add([string]$result.Roles['task'].logical_name) }
        foreach ($a in @($fdAnswersJson | ConvertFrom-Json -Depth 100)) { $askTypeNames.Add([string]$a.type) }
        $fdAskTypesJson = ConvertTo-JiraJsonValue (@($askTypeNames | Select-Object -Unique))
        $bridgeIds = [System.Collections.Generic.List[string]]::new()
        if ($result.Roles.Contains('specification')) { $bridgeIds.Add([string]$result.Roles['specification'].id) }
        if ($result.Roles.Contains('story')) { $bridgeIds.Add([string]$result.Roles['story'].id) }
        # 012: the task role joins the bridge-written set now that the tier
        # ships — a recorded field default for the sub-task type is
        # consumed, not merely recorded (FR-012).
        if ($result.Roles.Contains('task')) { $bridgeIds.Add([string]$result.Roles['task'].id) }
        $fdBridgeIdsJson = ConvertTo-JiraJsonValue (@($bridgeIds))
        $fdReportJson = Get-JiraFieldDefaultsReport -IssueTypesJson $itypesJson -DefaultableFieldsByTypeJson $dfMapJson `
            -AskTypesJson $fdAskTypesJson -MergedJson $fdMergedJson -BridgeTypeIdsJson $fdBridgeIdsJson
        # 015, research R5, contract §6.3: a recorded value outside its
        # field's allowed_values refuses HERE, at configuration time — the
        # whole point of US4 is that this check no longer waits for a hook
        # to fire mid-task. Reuses the flag path's own "outside_allowed"
        # message and exit code (Write-JiraFieldDefaultProblemsReport), so a
        # refusal from the file is indistinguishable from one from a flag;
        # the recorded value itself never reaches the message or any
        # structured output. Zero writes: this runs before this loop's own
        # config.yml/local.yml write, below.
        $fdReport = $fdReportJson | ConvertFrom-Json -Depth 100
        $fdOutsideAllowed = [System.Collections.Generic.List[object]]::new()
        foreach ($oa in @($fdReport.outside_allowed)) {
            $fdOutsideAllowed.Add([ordered]@{ kind = 'outside_allowed'; type = $oa.type; label = $oa.label; candidates = @($oa.candidates) })
        }
        if ($fdOutsideAllowed.Count -gt 0) {
            Write-JiraFieldDefaultProblemsReport -ProjectKey $pkey -ProblemsJson (ConvertTo-JiraJsonValue $fdOutsideAllowed) -Json $json
            return $script:ExitConfig
        }
        # A pending question (contract §6: "consolidated question pending | 0
        # — not a failure") is NON-BLOCKING at config time — see the mirror
        # comment on the same change in commands/config.sh. Reconcile's own
        # ask/refuse gate (Phase 4/5) is where reachability is judged;
        # Get-JiraFieldDefaultNote reports every pending field by its
        # remedy line below.
        $fdNote = Get-JiraFieldDefaultNote -ProjectKey $pkey -ReportJson $fdReportJson
        if ($fdNote) { $fdNotes.Add($fdNote) }
        $fdMerged = $fdMergedJson | ConvertFrom-Json -Depth 100
        # Absence is the off switch (research R6, FR-028): a project with
        # nothing recorded and no this-run answer must never gain a bare
        # {ask: $true} entry it never had. A project that ALREADY carries an
        # entry is carried forward even if the merge is now empty (an
        # operator's hand-edit removing the last field, §5.2).
        $fdHadEntry = $false
        $cfgFdProp = $cfgObj.PSObject.Properties['field_defaults']
        if ($null -ne $cfgFdProp -and $null -ne $cfgFdProp.Value) {
            $fdHadEntry = $cfgFdProp.Value.PSObject.Properties.Match($pkey).Count -gt 0
        }
        if (@($fdMerged.PSObject.Properties).Count -gt 0 -or $fdHadEntry) {
            $fdEntry = [ordered]@{ ask = ($fdRecordedJson | ConvertFrom-Json -Depth 100).ask }
            foreach ($p in $fdMerged.PSObject.Properties) { $fdEntry[$p.Name] = $p.Value }
            $projFieldDefaults[$pkey] = $fdEntry
        }

        # Mandatory-field / parent-link gate, pulled to configuration time
        # (T050/T051, contract §4 checks 5/6): the same existing gate, run
        # over the roles this mapping just selected — including one
        # derivation would never have chosen. (011, research R5): a field
        # with a recorded default or a this-run answer is now satisfiable; a
        # required field whose shape cannot be defaulted still refuses here,
        # unchanged (US3 scenario 3).
        $fdDefaultsByType = (Get-JiraPlanResolveFieldDefault -IssueTypesJson $itypesJson -DefaultableFieldsByTypeJson $dfMapJson `
                -RecordedJson $fdMergedJson -AnswersJson '[]' | ConvertFrom-Json -Depth 100).field_defaults
        $gateBinding = (ConvertTo-JiraJsonValue $rids) | ConvertFrom-Json -Depth 100
        $gateResult = Get-JiraHierarchyMandatoryGate -Binding $gateBinding -ProjectKey $pkey -DefaultsByType $fdDefaultsByType
        if ($gateResult.status -ne 'ok') {
            [Console]::Error.WriteLine($gateResult.message)
            return $script:ExitConfig
        }

        # §7.2/§7.3 notes: supersession (a committed declaration overriding
        # a recorded operator answer) and promotion (any role resolved from
        # an operator answer this run). §7.4's "task recorded, not yet
        # mirrored" status line stopped firing (012, FR-012): the task tier
        # ships now.
        $priorRoles = $null
        if ($existing -is [System.Management.Automation.PSCustomObject]) {
            $existingResolvedIds = Get-CmdProp $existing 'resolved_ids'
            if ($null -ne $existingResolvedIds) {
                $priorProj = Get-CmdProp $existingResolvedIds $pkey
                if ($null -ne $priorProj) { $priorRoles = Get-CmdProp $priorProj 'roles' }
            }
        }
        foreach ($roleKey in @('specification', 'story', 'task')) {
            if (-not $result.Roles.Contains($roleKey)) { continue }
            $newEntry = $result.Roles[$roleKey]
            $newSource = [string]$newEntry.source
            $newName = [string]$newEntry.logical_name
            if ($newSource -eq 'declared') {
                $priorEntry = Get-CmdProp $priorRoles $roleKey
                $priorSource = [string](Get-CmdProp $priorEntry 'source')
                if ($priorSource -eq 'operator') {
                    $priorName = [string](Get-CmdProp $priorEntry 'logical_name')
                    if ($priorName -ne $newName) {
                        $roleNotes.Add((Get-JiraRoleSupersessionNote -ProjectKey $pkey -Role $roleKey -DeclaredName $newName -LocalName $priorName))
                    }
                }
            }
            if ($newSource -eq 'operator') {
                $roleNotes.Add((Get-JiraRolePromotionNote -ProjectKey $pkey -Role $roleKey -Name $newName))
            }
        }
        $projRoles[$pkey] = $result.Roles

        $resolved[$pkey] = $rids
        $projStyles[$pkey] = [ordered]@{ style = $sr.Style; style_source = $sr.Source }
        $nproj++
    }

    # The three non-blocking field-defaults reports (§2.8, §2.3): never a
    # warning, never a refusal — printed alongside the role notes.
    if ($fdNotes.Count -gt 0) { [Console]::Error.WriteLine(($fdNotes -join "`n")) }

    # Field-defaults write (011, T042/T044): the union of every processed
    # project's resolved entry, overlaid onto whatever the committed config
    # already held for OTHER projects this run did not touch. Absence is
    # the off switch (research R6, FR-028): Set-JiraFieldDefaultsBlock never
    # introduces the key when there is nothing to record and the region has
    # never existed.
    $fdBase = [ordered]@{}
    $cfgFieldDefaults = Get-CmdProp $cfgObj 'field_defaults'
    if ($null -ne $cfgFieldDefaults) {
        foreach ($p in $cfgFieldDefaults.PSObject.Properties) { $fdBase[$p.Name] = $p.Value }
    }
    foreach ($k in $projFieldDefaults.Keys) { $fdBase[$k] = $projFieldDefaults[$k] }
    $teamConfigPath = Join-Path $configdir 'config.yml'
    $fdWriteResult = Set-JiraFieldDefaultsBlock -Path $teamConfigPath -MapJson (ConvertTo-JiraJsonValue $fdBase) -DryRun ([bool]$dryRun)
    if ($fdWriteResult.ExitCode -ne 0) { return [int] $fdWriteResult.ExitCode }
    $fdWriteStatus = $fdWriteResult.Status

    # The task-mirror ceremony's per-project notes (022, contract §5/§6):
    # never a warning, never a refusal — printed alongside the
    # field-defaults and role notes.
    if ($tmNotes.Count -gt 0) { [Console]::Error.WriteLine(($tmNotes -join "`n")) }

    # Task-mirror write (022, contract §3): the union of every processed
    # project's resolved value, overlaid onto whatever the committed config
    # already held for OTHER projects this run did not touch. Absence is
    # the off switch (FR-002, FR-011): Set-JiraTaskMirrorBlock never
    # introduces the key when there is nothing to record and the region has
    # never existed.
    $tmBase = [ordered]@{}
    $cfgTaskMirror = Get-CmdProp $cfgObj 'task_mirror'
    if ($null -ne $cfgTaskMirror) {
        foreach ($p in $cfgTaskMirror.PSObject.Properties) { $tmBase[$p.Name] = $p.Value }
    }
    foreach ($k in $projTaskMirror.Keys) { $tmBase[$k] = $projTaskMirror[$k] }
    $tmWriteResult = Set-JiraTaskMirrorBlock -Path $teamConfigPath -MapJson (ConvertTo-JiraJsonValue $tmBase) -DryRun ([bool]$dryRun)
    if ($tmWriteResult.ExitCode -ne 0) { return [int] $tmWriteResult.ExitCode }
    $tmWriteStatus = $tmWriteResult.Status

    # Merge the resolved-id table into the machine-owned local layer, preserving
    # the operator's site_alias / overrides, and emit deterministic canonical YAML.
    $existingMap = [ordered]@{}
    if ($existing -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $existing.PSObject.Properties) { $existingMap[$prop.Name] = $prop.Value }
    }
    $existingMap['resolved_ids'] = $resolved
    # 032, C3.2 — record the destination this ceremony actually reached, in the
    # SAME serialize-and-write that persists resolved_ids, so no partial state
    # can exist. Normalised at write time (C1.9), not only at compare time: two
    # runs differing only in the declared spelling must produce byte-identical
    # files or Constitution II's zero-churn proof fails. Everything above this
    # point returns early on refusal, so a ceremony that did not complete
    # discovery never reaches here (C3.3), and a degraded run returns long
    # before (C3.4).
    # Recorded ONLY when the destination came from config.yml. FR-011 exempts
    # an environment-supplied destination from the comparison and equally
    # forbids recording it: the environment is per-shell and per-invocation,
    # so a record made from it binds the checkout to whatever happened to be
    # exported once.
    # The record itself. The CHECK that guards a changed destination now runs
    # before discovery (Test-JiraCeremonyPin); by the time execution reaches
    # here the destination is either unchanged, freshly bound, or explicitly
    # accepted by name — and it has actually been reached.
    if (-not (Get-JiraPinEnvSupplied)) {
        $boundSite = Get-JiraUrlOriginCanonical -Url ([string] $env:SPEC_KIT_JIRA_BASE_URL)
        if ($null -ne $boundSite) {
            $existingMap['bound_site'] = $boundSite
        }
    }
    # ConvertTo-JiraConfigYaml throws when the document cannot be represented
    # (research R3/R5); caught here and turned into the Bash port's contract —
    # a plain stderr message and EXIT_CONFIG, not a default exception trace.
    try {
        $yaml = ConvertTo-JiraConfigYaml -Json (ConvertTo-JiraJsonValue $existingMap)
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        return [int] $script:ExitConfig
    }

    # Discovery-effect status: created / unchanged / written.
    $discStatus = 'written'
    if (-not (Test-Path -LiteralPath $localf)) {
        $discStatus = 'created'
    }
    # The [string] cast is load-bearing, not decoration. `Get-Content -Raw` on an
    # EMPTY file returns $null, and `$null -replace …` evaluates to an empty
    # System.Object[] rather than to a string — so `.TrimEnd()` then throws
    # "[System.Object[]] does not contain method named 'TrimEnd'" and the whole
    # ceremony dies. The Bash port compares the same case as an empty string and
    # proceeds, so this was a silent cross-port divergence on any installation
    # whose config.local.yml exists but is empty.
    elseif (((([string](Get-Content -Raw -LiteralPath $localf))) -replace "`r`n", "`n").TrimEnd("`n") -eq $yaml) {
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

    # The per-role provenance audit (010, contract §7.1) merges into each
    # project's discovery entry — `roles: {role: {logical_name, source}}` —
    # alongside style/style_source.
    foreach ($pk in $projRoles.Keys) {
        $rolesForProj = [ordered]@{}
        foreach ($rk in $projRoles[$pk].Keys) {
            $entry = $projRoles[$pk][$rk]
            $rolesForProj[$rk] = [ordered]@{ logical_name = $entry.logical_name; source = $entry.source }
        }
        if (-not $projStyles.Contains($pk)) { $projStyles[$pk] = [ordered]@{} }
        $projStyles[$pk]['roles'] = $rolesForProj
    }

    # Build the effects summary (FR-054), byte-identical to the Bash port: each
    # effect this ceremony performs is reported as its own named section. 034
    # removed the `hooks` entry along with the registry reader that produced it —
    # this command no longer opens `.specify/extensions.yml` for any purpose.
    $effects = [ordered]@{
        discovery      = [ordered]@{ status = $discStatus; detail = "$nproj project(s) discovered"; projects = $projStyles }
        readme         = [ordered]@{ status = $readmeStatus; detail = $readmeDetail }
        gitignore      = [ordered]@{ status = $gitignoreStatus; detail = 'personal.yml gitignore coverage' }
        personal       = [ordered]@{ status = $personalStatus; detail = $personalDetail }
        field_defaults = [ordered]@{ status = $fdWriteStatus; detail = 'recorded field defaults in config.yml' }
        task_mirror    = [ordered]@{ status = $tmWriteStatus; detail = 'recorded task mirror mode in config.yml' }
    }

    # §7.2/§7.3 notes (supersession, promotion): never a warning, never a
    # non-zero exit — the run succeeded.
    foreach ($note in $roleNotes) { [Console]::Error.WriteLine($note) }

    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'config'
        dry_run        = [bool]$dryRun
        counts         = [ordered]@{ created = 0; updated = 0; skipped = 0; warnings = $runWarnings; errors = 0 }
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
    Get-JiraResolvedIdMap, Get-JiraDeclaredHierarchyFor, Get-JiraOperatorRolesFor, `
    Write-JiraRoleProblemsReport, Invoke-JiraConfig, `
    Get-JiraConfigPersonalContent, Set-JiraConfigPersonal, `
    Get-JiraFieldAnswersFor, Get-JiraFieldDefaultsBlock, Set-JiraFieldDefaultsBlock, `
    Get-JiraFieldDefaultAnswerProblem, Merge-JiraFieldDefault, Get-JiraFieldDefaultsReport, `
    Write-JiraFieldDefaultProblemsReport, Get-JiraFieldDefaultNote, `
    Get-JiraTaskMirrorFlagFor, Get-JiraTaskMirrorQuestion, Get-JiraTaskMirrorFr012Note, `
    Get-JiraTaskMirrorEffectLine, Get-JiraTaskMirrorBlock, Set-JiraTaskMirrorBlock
