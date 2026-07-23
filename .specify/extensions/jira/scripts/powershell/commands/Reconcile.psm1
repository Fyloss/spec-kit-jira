# commands/Reconcile.psm1 — The reconcile command. Mirror of commands/reconcile.sh
# (US3, T059).
#
# Wires the neutral ENGINE to the Jira SINK: parse a specification into neutral
# content, assemble and schema-VALIDATE the neutral document (a validation failure
# blocks every write, Constitution VIII), plan the ordered action set, and apply
# it through the mandatory pre-write BLOCK guard (US11). Estimation is create-only
# (FR-018). Writes the run summary via the [Console] streams and returns ONLY its
# numeric exit code. Byte-identical to the Bash port (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/Parse.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/Interchange.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/PlanApply.psm1') -Force

$script:ReconcileExitConfig = 4

function Get-JiraReconcilePlanContext {
    # The plan context: base_url plus any caller overrides from
    # SPEC_KIT_JIRA_PLAN_CONTEXT (JSON). base_url always wins. Mirror of
    # _reconcile_plan_context.
    param([string] $BaseUrl)
    $extra = if ($env:SPEC_KIT_JIRA_PLAN_CONTEXT) { $env:SPEC_KIT_JIRA_PLAN_CONTEXT } else { '{}' }
    $obj = $extra | ConvertFrom-Json -Depth 100
    $map = [ordered]@{}
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    $map['base_url'] = $BaseUrl
    return (ConvertTo-JiraJsonValue $map)
}

function Invoke-JiraReconcile {
    <#
    .SYNOPSIS
      Reconcile one specification into its Jira project. Writes the run summary via
      the [Console] streams and returns ONLY its numeric exit code.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("reconcile: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'

    # The spec file is the first positional argument.
    $specFile = ''
    foreach ($a in $Arguments) {
        if ($a -eq 'reconcile' -or $a.StartsWith('-')) { continue }
        $specFile = $a; break
    }
    if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path -LiteralPath $specFile)) {
        [Console]::Error.WriteLine('reconcile: a readable spec file argument is required')
        return [int](Get-JiraExitCode 'usage')
    }

    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    if ([string]::IsNullOrEmpty($base)) {
        [Console]::Error.WriteLine('reconcile: SPEC_KIT_JIRA_BASE_URL is not set')
        return [int](Get-JiraExitCode 'fail_closed')
    }

    $folder = (Resolve-Path -LiteralPath (Split-Path -Parent $specFile)).Path
    $slug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { Split-Path -Leaf $folder }
    $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
    $projectKey = if ($env:SPEC_KIT_JIRA_PROJECT_KEY) { $env:SPEC_KIT_JIRA_PROJECT_KEY } else { 'PROJ' }
    $epicStrategy = if ($env:SPEC_KIT_JIRA_EPIC_STRATEGY) { $env:SPEC_KIT_JIRA_EPIC_STRATEGY } else { 'per_repo' }

    $specText = Get-Content -Raw -LiteralPath $specFile
    if ($null -eq $specText) { $specText = '' }

    # ENGINE: parse the spec into neutral content, then assemble + validate.
    $parse = Get-JiraParsedSpec -Text $specText -FolderSlug $slug
    $specRef = [ordered]@{ repo = $repo; spec_slug = $slug; folder = $folder }
    $ctx = ConvertTo-JiraJsonValue ([ordered]@{ spec_ref = $specRef; project_key = $projectKey; epic_strategy = $epicStrategy })
    $built = Build-JiraNeutralDocument -ParseJson $parse -ContextJson $ctx
    if (-not $built.Valid) {
        [Console]::Error.WriteLine('reconcile: the specification could not be assembled into a valid neutral document (zero writes)')
        return $script:ReconcileExitConfig
    }

    # SINK: plan the ordered action set (the --dry-run report is exactly this set).
    $planCtx = Get-JiraReconcilePlanContext -BaseUrl $base
    $actionsJson = Get-JiraPlanWriteSet -NeutralDocJson $built.Document -PlanContextJson $planCtx
    # A List keeps a single-element action set an ARRAY (a bare @() unwraps to an
    # object under ConvertTo-JiraJsonValue, diverging from the Bash port).
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($actionsJson | ConvertFrom-Json -Depth 100)) { $actions.Add($x) }

    $created = @($actions | Where-Object { $_.method -eq 'POST' }).Count
    $updated = @($actions | Where-Object { $_.method -eq 'PUT' }).Count

    $rc = 0
    if (-not $dryRun) {
        $rc = Invoke-JiraApplyWriteSet -ActionsJson $actionsJson
    }

    # Report the action set with the base URL stripped to a host-relative path:
    # the site host is a coordinate that must never appear in output
    # (Constitution IV), and it keeps the summary stable across the mock port.
    $disp = [System.Collections.Generic.List[object]]::new()
    foreach ($x in $actions) {
        $u = [string]$x.url
        if ($u.StartsWith($base)) { $x.url = $u.Substring($base.Length) }
        $disp.Add($x)
    }

    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'reconcile'
        dry_run        = [bool]$dryRun
        counts         = [ordered]@{ created = $created; updated = $updated; skipped = 0; warnings = 0; errors = 0 }
        actions        = $disp
        exit_code      = $rc
    }
    $summary = ConvertTo-JiraJsonValue $summaryObj

    if ($json) {
        [Console]::Out.Write($summary + "`n")
    }
    else {
        [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $summary))
    }
    return $rc
}

Export-ModuleMember -Function Invoke-JiraReconcile
