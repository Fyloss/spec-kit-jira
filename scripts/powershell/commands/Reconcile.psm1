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
Import-Module (Join-Path $PSScriptRoot '../hooks/RegisterHooks.psm1') -Force # hook health + repair (US9)

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
    $onDrift = if ($state.ContainsKey('on_drift') -and $state['on_drift']) { $state['on_drift'] } else { 'abort' }
    $repairHooks = $state['repair_hooks'] -eq 'true'

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

    # Split-Path -Parent yields '' for a bare filename and for a root-level path,
    # where the Bash port's dirname yields '.' and '/' — map those the same way
    # so both ports resolve the folder (NFR-1) instead of failing the schema.
    $specParent = Split-Path -Parent $specFile
    if ([string]::IsNullOrEmpty($specParent)) {
        $specParent = if ($specFile.StartsWith('/')) { '/' } else { '.' }
    }
    $folder = (Resolve-Path -LiteralPath $specParent).Path
    $slug = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { Split-Path -Leaf $folder }
    $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
    $projectKey = if ($env:SPEC_KIT_JIRA_PROJECT_KEY) { $env:SPEC_KIT_JIRA_PROJECT_KEY } else { 'PROJ' }
    $epicStrategy = if ($env:SPEC_KIT_JIRA_EPIC_STRATEGY) { $env:SPEC_KIT_JIRA_EPIC_STRATEGY } else { 'per_repo' }

    $specText = Get-Content -Raw -LiteralPath $specFile
    if ($null -eq $specText) { $specText = '' }

    # ENGINE: parse the spec into neutral content, then assemble + validate. Every
    # step is GUARDED so a failure surfaces the mapped error path — never a raw
    # unhandled exception (FR-032: mapped exits, zero writes; mirrors the Bash
    # port's guarded substitutions).
    try { $parse = Get-JiraParsedSpec -Text $specText -FolderSlug $slug }
    catch {
        [Console]::Error.WriteLine('reconcile: the specification could not be parsed (zero writes)')
        return $script:ReconcileExitConfig
    }
    $specRef = [ordered]@{ repo = $repo; spec_slug = $slug; folder = $folder }
    $ctx = ConvertTo-JiraJsonValue ([ordered]@{ spec_ref = $specRef; project_key = $projectKey; epic_strategy = $epicStrategy })
    $built = Build-JiraNeutralDocument -ParseJson $parse -ContextJson $ctx
    if (-not $built.Valid) {
        [Console]::Error.WriteLine('reconcile: the specification could not be assembled into a valid neutral document (zero writes)')
        return $script:ReconcileExitConfig
    }

    # SINK: plan the ordered action set (the --dry-run report is exactly this set).
    $planCtx = Get-JiraReconcilePlanContext -BaseUrl $base
    try { $actionsJson = Get-JiraPlanWriteSet -NeutralDocJson $built.Document -PlanContextJson $planCtx }
    catch {
        [Console]::Error.WriteLine('reconcile: the write plan could not be assembled (zero writes)')
        return $script:ReconcileExitConfig
    }

    # US6 lifecycle safety: when the current-Jira facts are supplied (the seam the
    # config/discovery integration fills from a fail-closed read), fold in
    # zero-churn idempotency, status-category drift, Flagged withholding, and the
    # blocker note. Runs in BOTH dry-run and real mode so the --dry-run report
    # equals the real run's action set exactly (FR-033). Mirror of reconcile.sh.
    $warnsJson = '[]'
    $notesJson = '[]'
    $hasLifecycle = $false
    if ($env:SPEC_KIT_JIRA_LIFECYCLE) {
        $hasLifecycle = $true
        try { $lcObj = $env:SPEC_KIT_JIRA_LIFECYCLE | ConvertFrom-Json -Depth 100 }
        catch {
            [Console]::Error.WriteLine('reconcile: SPEC_KIT_JIRA_LIFECYCLE is not valid JSON (zero writes)')
            return $script:ReconcileExitConfig
        }
        $lcMap = [ordered]@{}
        if ($lcObj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $lcObj.PSObject.Properties) { $lcMap[$p.Name] = $p.Value }
        }
        $lcMap['base_url'] = $base
        $lcMap['on_drift'] = $onDrift
        $lcJson = ConvertTo-JiraJsonValue $lcMap
        try { $lresult = Get-JiraLifecyclePlan -ContentActionsJson $actionsJson -NeutralDocJson $built.Document -LifecycleContextJson $lcJson | ConvertFrom-Json -Depth 100 }
        catch {
            [Console]::Error.WriteLine('reconcile: the lifecycle plan could not be assembled (zero writes)')
            return $script:ReconcileExitConfig
        }
        $actionsJson = ConvertTo-JiraJsonValue $lresult.actions
        $warnsJson = ConvertTo-JiraJsonValue $lresult.warnings
        $notesJson = ConvertTo-JiraJsonValue $lresult.notes
    }

    # A List keeps a single-element action set an ARRAY (a bare @() unwraps to an
    # object under ConvertTo-JiraJsonValue, diverging from the Bash port).
    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($x in @($actionsJson | ConvertFrom-Json -Depth 100)) { $actions.Add($x) }

    # created counts only create-endpoint POSTs; a transition is also a POST but is
    # not a ticket creation, so it is excluded from the created tally.
    $created = @($actions | Where-Object { $_.method -eq 'POST' -and ([string]$_.url).EndsWith('/issue') }).Count
    $updated = @($actions | Where-Object { $_.method -eq 'PUT' }).Count
    $warnCount = @($warnsJson | ConvertFrom-Json -Depth 100).Count

    $rc = 0
    if (-not $dryRun) {
        $rc = Invoke-JiraApplyWriteSet -ActionsJson $actionsJson
    }

    # US9 self-healing: --repair-hooks performs the one-command hook repair reachable
    # from any run (FR-047); every run then reports hook health in the summary. The
    # path is relative to the repository root (cwd), overridable for tests.
    $extPath = if ($env:SPEC_KIT_JIRA_EXTENSIONS_YML) { $env:SPEC_KIT_JIRA_EXTENSIONS_YML } else { '.specify/extensions.yml' }
    if ($repairHooks) { [void](Set-JiraHookRegistration -Path $extPath -DryRun ([bool]$dryRun)) }
    $hooksHealth = Get-JiraHookHealth -Path $extPath | ConvertFrom-Json -Depth 100

    # FR-046: in hook context a bridge failure NEVER fails the host command — after
    # surfacing a single actionable WARNING the exit is downgraded to 0, so the mirror
    # can fail without ever affecting the spec-kit command that triggered it.
    if ($env:SPEC_KIT_JIRA_HOOK_CONTEXT -and $rc -ne 0) {
        [Console]::Error.WriteLine("WARNING: the Jira mirror did not complete (exit $rc); the host command is unaffected. Run reconcile --repair-hooks or /speckit.jira.config to recover.")
        $rc = 0
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

    # The warnings/notes keys appear only when the lifecycle facts were supplied,
    # so the content-only reconcile (US3) summary is byte-for-byte unchanged.
    $summaryObj = [ordered]@{
        schema_version = '1.0'
        command        = 'reconcile'
        dry_run        = [bool]$dryRun
        counts         = [ordered]@{ created = $created; updated = $updated; skipped = 0; warnings = $warnCount; errors = 0 }
        actions        = $disp
    }
    if ($hasLifecycle) {
        $summaryObj['warnings'] = @($warnsJson | ConvertFrom-Json -Depth 100)
        $summaryObj['notes'] = @($notesJson | ConvertFrom-Json -Depth 100)
    }
    $summaryObj['hook_health'] = $hooksHealth
    $summaryObj['exit_code'] = $rc
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
