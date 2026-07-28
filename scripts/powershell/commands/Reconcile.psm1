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
Import-Module (Join-Path $PSScriptRoot '../hooks/RegisterHooks.psm1') -Force # hook health — READ ONLY (003 FR-022)
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force          # the operator disable record
Import-Module (Join-Path $PSScriptRoot '../lib/Prereq.psm1') -Force          # the bridge-unavailable cause

$script:ReconcileExitConfig = 4

function Test-JiraReconcileHeld {
    <#
    .SYNOPSIS
      $true when the operator disabled this lifecycle event. Mirror of
      _reconcile_is_held.

      Read at DISPATCH, before any prerequisite check and before any network
      work, so the decision holds even in the window between an install that
      re-enabled the registry entry and the next ceremony (003 FR-007, FR-020,
      research R5 step 2). The registry's own `enabled` field is deliberately NOT
      consulted here: the install rewrites it to `true` unconditionally, so it
      cannot carry the answer.
    #>
    param([string] $LifecycleEvent)
    if ([string]::IsNullOrEmpty($LifecycleEvent)) { return $false }
    $recorded = @((Get-JiraHooksDisabled) | ConvertFrom-Json)
    return ($recorded -ccontains $LifecycleEvent)
}

function Write-JiraReconcileNotice {
    # The SINGLE message a degraded run is allowed (FR-016). Everything goes to
    # stderr so it never contaminates a --json summary, and the caller emits it
    # exactly once per run. Mirror of _reconcile_notice.
    param([string[]] $Lines)
    foreach ($l in $Lines) { [Console]::Error.WriteLine($l) }
}

function Get-JiraReconcileFaultCode {
    <#
    .SYNOPSIS
      Report one bridge fault and return the code the caller should return.
      Mirror of _reconcile_fault.

      In HOOK CONTEXT that code is always 0: under `optional: false` the agent
      performs this step as part of the host command, and FR-015 admits no
      exception — a hook failure of ANY kind must leave the host command's outcome
      untouched. Every early-return failure path goes through here for that
      reason. The downgrade used to happen at one point near the end of the run,
      which meant the faults that returned early — an unparseable spec, an invalid
      lifecycle payload — still failed the host command. Outside hook context the
      mapped exit code is returned unchanged, so a direct invocation still fails
      closed (Constitution III).
    #>
    param([int] $Code, [string] $Message)
    [Console]::Error.WriteLine($Message)
    if ($env:SPEC_KIT_JIRA_HOOK_CONTEXT) { return 0 }
    return $Code
}

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

    # (0) DISPATCH GUARD — the operator's disable decision, honoured before any
    # prerequisite check, any config read and any network call (FR-020). The exit
    # is INERT: no Jira call, and no warning either. A warning here would be noise
    # on every single lifecycle command for an event the operator deliberately
    # turned off, which is precisely what FR-020 forbids.
    $hookEvent = if ($env:SPEC_KIT_JIRA_HOOK_EVENT) { $env:SPEC_KIT_JIRA_HOOK_EVENT } else { '' }
    if (Test-JiraReconcileHeld -LifecycleEvent $hookEvent) { return 0 }

    # The spec file is the first positional argument.
    $specFile = ''
    foreach ($a in $Arguments) {
        if ($a -eq 'reconcile' -or $a.StartsWith('-')) { continue }
        $specFile = $a; break
    }
    if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path -LiteralPath $specFile)) {
        return (Get-JiraReconcileFaultCode -Code ([int](Get-JiraExitCode 'usage')) -Message 'reconcile: a readable spec file argument is required')
    }

    # NOT YET CONFIGURED (FR-017 first cause, FR-019). This is the normal state of
    # a freshly installed repository, not an error: the lifecycle step behaves
    # exactly as it would without the extension, apart from one notice. At most
    # three lines, exit 0 — a hook must never turn "you haven't set this up yet"
    # into a failed spec-kit command.
    $base = if ($env:SPEC_KIT_JIRA_BASE_URL) { $env:SPEC_KIT_JIRA_BASE_URL } else { '' }
    if ([string]::IsNullOrEmpty($base)) {
        Write-JiraReconcileNotice -Lines @(
            'Jira mirror skipped: this repository is not bound to a Jira project yet.',
            'Nothing was mirrored, and this spec-kit command completed normally.',
            'To bind it, run /speckit.jira.config.')
        return 0
    }

    # BRIDGE UNAVAILABLE (FR-017 sixth cause, T090). Reported as its OWN cause and
    # never folded into "not configured" above or the generic prerequisite gate: a
    # missing entry point is an incomplete install with an install remedy. The
    # state where NEITHER port starts cannot be reported from here at all —
    # nothing of ours is running — which is why the command documents carry the
    # verbatim fallback block for it (FR-030).
    $bridgeMissing = Get-JiraMissingBridgeEntry
    if ($bridgeMissing) {
        Write-JiraReconcileNotice -Lines @(
            "Jira mirror skipped: the bridge entry point $bridgeMissing was not found or is not executable; the extension install is incomplete. This spec-kit command completed normally and nothing was mirrored to Jira. Restore it with: specify extension add --dev <path-to-spec-kit-jira> --force")
        return 0
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
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the specification could not be parsed (zero writes)')
    }
    $specRef = [ordered]@{ repo = $repo; spec_slug = $slug; folder = $folder }
    $ctx = ConvertTo-JiraJsonValue ([ordered]@{ spec_ref = $specRef; project_key = $projectKey; epic_strategy = $epicStrategy })
    $built = Build-JiraNeutralDocument -ParseJson $parse -ContextJson $ctx
    if (-not $built.Valid) {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the specification could not be assembled into a valid neutral document (zero writes)')
    }

    # SINK: plan the ordered action set (the --dry-run report is exactly this set).
    $planCtx = Get-JiraReconcilePlanContext -BaseUrl $base
    try { $actionsJson = Get-JiraPlanWriteSet -NeutralDocJson $built.Document -PlanContextJson $planCtx }
    catch {
        return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the write plan could not be assembled (zero writes)')
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
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: SPEC_KIT_JIRA_LIFECYCLE is not valid JSON (zero writes)')
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
            return (Get-JiraReconcileFaultCode -Code $script:ReconcileExitConfig -Message 'reconcile: the lifecycle plan could not be assembled (zero writes)')
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

    # Hook health is READ and reported on every run (FR-047). Nothing here writes
    # the registry, in any state — reading it is the extension's whole
    # relationship with that file (003 FR-022). The path is relative to the
    # repository root (cwd), overridable for tests.
    $extPath = if ($env:SPEC_KIT_JIRA_EXTENSIONS_YML) { $env:SPEC_KIT_JIRA_EXTENSIONS_YML } else { '.specify/extensions.yml' }
    $hooksHealth = Get-JiraHookHealth -Path $extPath -DisabledJson (Get-JiraHooksDisabled) | ConvertFrom-Json -Depth 100

    # FR-046 / 003 FR-015: in hook context a bridge failure NEVER fails the host
    # command — after surfacing a single actionable WARNING the exit is downgraded
    # to 0, so the mirror can fail without ever affecting the spec-kit command
    # that triggered it. The warning names the true cause and only commands that
    # can be run as spelled (FR-017, FR-018): `reconcile --repair-hooks` used to
    # be named here and no longer exists, because repairing the registry is a
    # write FR-022 forbids.
    if ($env:SPEC_KIT_JIRA_HOOK_CONTEXT -and $rc -ne 0) {
        $cause = switch ($rc) {
            2 { 'Jira could not be reached, or a read failed closed' }
            3 { 'Jira rejected the credentials' }
            4 { 'the configuration was refused' }
            5 { 'a prerequisite is missing' }
            9 { 'the privacy guard blocked the write' }
            default { 'the mirror did not complete' }
        }
        [Console]::Error.WriteLine("WARNING: Jira mirror not completed — $cause (exit $rc). This spec-kit command completed normally. Run /speckit.jira.config to re-check the binding.")
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
