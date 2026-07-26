# commands/Feature.psm1 — Ticket-first feature naming (002 US3, FR-013…FR-017).
# Mirror of commands/feature.sh.
#
# Invoke-JiraFeature is the deterministic step registered as the
# `before_specify` hook. It loads the committed `teams:` catalogue and the
# human-owned `.specify/jira/personal.yml` selection, resolves the effective
# team (honouring a cross-team `--use-team` confirmation), resolves the Jira
# ticket BEFORE naming (validate a mentioned key, else guarded-create one), and
# emits the branch name and flat folder short-name.
#
# Non-blocking by construction (FR-016/FR-017): no team selected ⇒
# {active:false}; Jira unreachable or a create refused ⇒ {active:false} plus one
# warning. The host specify flow then proceeds exactly as it does today.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../engine/Naming.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../sink/jira/Ticket.psm1') -Force

function Get-FeatProp {
    # StrictMode-safe optional property read: $null when the property is absent.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    }
    return $null
}

function Write-FeatResult {
    # Print the canonical result (JSON or prose). Mirror of _feat_emit.
    param([string] $Payload, [bool] $Json)
    if ($Json) {
        [Console]::Out.Write($Payload + "`n")
    }
    else {
        try { [Console]::Out.Write((ConvertTo-JiraSummaryProse -Json $Payload)) }
        catch { [Console]::Out.Write($Payload + "`n") }
    }
}

function Write-FeatFallback {
    # The FR-016 non-blocking fallback: {active:false} plus exactly one warning;
    # one WARNING: line on stderr; exit 0. Mirror of _feat_fallback.
    param([bool] $Json)
    $msg = 'could not resolve a ticket in Jira — proceeding without one (reconciliation will attach it later)'
    [Console]::Error.WriteLine("WARNING: $msg")
    $payload = ConvertTo-JiraJsonValue ([ordered]@{ active = $false; warnings = @($msg) })
    Write-FeatResult -Payload $payload -Json $Json
}

function Invoke-JiraFeature {
    <#
    .SYNOPSIS
      The feature-naming ceremony (contracts/feature-cli-contract.md). Writes
      the result via the [Console] streams and returns ONLY its numeric exit
      code (mirroring the Bash port's echo -> fd1, return -> status convention).
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

    $parsed = Invoke-JiraCliParse -Arguments $Arguments
    $state = @{}
    foreach ($line in ($parsed -split "`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
    }
    if ($state['exit'] -ne '0') {
        if ($state.ContainsKey('error') -and $state['error']) { [Console]::Error.WriteLine("feature: $($state['error'])") }
        return [int] $state['exit']
    }
    $json = $state['json'] -eq 'true'
    $dryRun = $state['dry_run'] -eq 'true'
    $useTeam = if ($state.ContainsKey('use_team')) { $state['use_team'] } else { '' }
    $argsLine = if ($state.ContainsKey('args')) { $state['args'] } else { '' }

    $dir = if ($env:JIRA_CONFIG_DIR) { $env:JIRA_CONFIG_DIR } else { '.specify/jira' }

    # (1) No committed catalogue at all ⇒ pass-through (FR-017).
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'config.yml'))) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }
    # The Bash twin silences this load's stderr (2>/dev/null): a failed read is
    # a silent pass-through, never a block.
    $errSink = [System.IO.StringWriter]::new()
    $origErr = [Console]::Error
    [Console]::SetError($errSink)
    try { $cfg = Import-JiraConfig -ConfigDir $dir }
    finally { [Console]::SetError($origErr) }
    if ($cfg.ExitCode -ne 0) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }
    $merged = $cfg.Json | ConvertFrom-Json -Depth 100
    $teams = @((Get-FeatProp $merged 'teams') | Where-Object { $null -ne $_ })
    if ($teams.Count -eq 0) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }

    # (2) Personal selection (human-owned; validated; never written). An invalid
    #     file fails closed with a located error (exit 4).
    $personal = Import-JiraPersonalConfig -ConfigDir $dir -MergedJson $cfg.Json
    if ($personal.ExitCode -ne 0) { return [int] $personal.ExitCode }
    $pObj = $personal.Json | ConvertFrom-Json -Depth 100
    $pActive = [bool](Get-FeatProp $pObj 'active')
    $pTeam = [string](Get-FeatProp $pObj 'team')
    $pOverride = Get-FeatProp $pObj 'override'

    # No selection and no cross-team answer ⇒ pass-through (FR-017).
    if (-not $pActive -and [string]::IsNullOrEmpty($useTeam)) {
        Write-FeatResult -Payload '{"active":false}' -Json $json
        return 0
    }

    # (3) Effective team resolution.
    $ids = @($teams | ForEach-Object { [string](Get-FeatProp $_ 'id') })
    $overrideUsed = $false
    $override = $null
    if (-not [string]::IsNullOrEmpty($useTeam)) {
        if ($ids -cnotcontains $useTeam) {
            [Console]::Error.WriteLine("feature: unknown team `"$useTeam`" — valid teams: $($ids -join ', ')")
            return (Get-JiraExitCode 'config')
        }
        $effId = $useTeam
    }
    else {
        $effId = $pTeam
        $override = $pOverride
        if ($null -ne $override) { $overrideUsed = $true }
    }

    # (4) Description is required once a team is in play (FR-013 precedes naming).
    #     The optional leading positional is a mentioned issue key.
    $words = @($argsLine -split ' ' | Where-Object { $_ -ne '' })
    $ticketKey = ''
    $desc = ''
    if ($words.Count -gt 0 -and $words[0] -cmatch '^[A-Z][A-Z0-9_]+-[0-9]+$') {
        $ticketKey = $words[0]
        $desc = ($words | Select-Object -Skip 1) -join ' '
    }
    else {
        $desc = $words -join ' '
    }
    if ([string]::IsNullOrEmpty($desc)) {
        [Console]::Error.WriteLine('feature: a feature description is required')
        return (Get-JiraExitCode 'usage')
    }

    # Resolve the effective team entry and its naming rule.
    $teamEntry = $teams | Where-Object { [string](Get-FeatProp $_ 'id') -ceq $effId } | Select-Object -First 1
    $effProject = [string](Get-FeatProp $teamEntry 'project')
    if ($null -ne $override) {
        $prefix = [string](Get-FeatProp $override 'folder_prefix')
        if ([string]::IsNullOrEmpty($prefix)) { $prefix = [string](Get-FeatProp $teamEntry 'folder_prefix') }
        $pattern = [string](Get-FeatProp $override 'branch_pattern')
        if ([string]::IsNullOrEmpty($pattern)) { $pattern = [string](Get-FeatProp $teamEntry 'branch_pattern') }
    }
    else {
        $prefix = [string](Get-FeatProp $teamEntry 'folder_prefix')
        $pattern = [string](Get-FeatProp $teamEntry 'branch_pattern')
    }

    $slug = Get-JiraFeatureSlug -Description $desc

    # (5) Ticket resolution BEFORE naming.
    if (-not [string]::IsNullOrEmpty($ticketKey)) {
        # Mentioned key: validate (read). A fail-closed read never falls back.
        $validated = Confirm-JiraTicket -Key $ticketKey
        if ($validated.ExitCode -ne 0) { return [int] $validated.ExitCode }
        $vObj = $validated.Json | ConvertFrom-Json -Depth 100
        $ticketProject = [string](Get-FeatProp $vObj 'project')
        $ticketTeam = ''
        foreach ($t in $teams) {
            if ([string](Get-FeatProp $t 'project') -ceq $ticketProject) { $ticketTeam = [string](Get-FeatProp $t 'id'); break }
        }

        # Cross-team confirmation (only when the operator did not answer it).
        if ([string]::IsNullOrEmpty($useTeam)) {
            if ([string]::IsNullOrEmpty($ticketTeam) -or $ticketTeam -cne $pTeam) {
                $tt = if ([string]::IsNullOrEmpty($ticketTeam)) { $null } else { $ticketTeam }
                $payload = ConvertTo-JiraJsonValue ([ordered]@{
                    active = $true
                    confirmation_required = [ordered]@{ ticket = $ticketKey; ticket_team = $tt; selected_team = $pTeam }
                })
                Write-FeatResult -Payload $payload -Json $json
                return 0
            }
        }

        $number = Get-JiraTicketNumber -Key $ticketKey
        $ticketKeyOut = $ticketKey
        $action = if ($dryRun) { 'would-attach' } else { 'attached' }
    }
    else {
        # No mentioned key: guarded create in the effective team's project.
        if ($dryRun) {
            # Predict only — zero Jira calls, no branch (no number yet).
            $shortDry = Get-JiraShortName -FolderPrefix $prefix -Slug $slug
            $payload = ConvertTo-JiraJsonValue ([ordered]@{
                active = $true; team = $effId
                ticket = [ordered]@{ key = $null; number = $null; action = 'would-create' }
                branch_name = $null; short_name = $shortDry; override_used = $overrideUsed; warnings = @()
            })
            Write-FeatResult -Payload $payload -Json $json
            return 0
        }

        $typeId = ''
        if ($env:SPEC_KIT_JIRA_PLAN_CONTEXT) {
            try { $typeId = [string](Get-FeatProp ($env:SPEC_KIT_JIRA_PLAN_CONTEXT | ConvertFrom-Json -Depth 100) 'story_type_id') }
            catch { $typeId = '' }
        }
        $repo = if ($env:SPEC_KIT_JIRA_REPO) { $env:SPEC_KIT_JIRA_REPO } else { 'local/repo' }
        $slugRef = if ($env:SPEC_KIT_JIRA_SPEC_SLUG) { $env:SPEC_KIT_JIRA_SPEC_SLUG } else { 'spec' }
        $specRef = '{"repo":' + (ConvertTo-JiraJsonString $repo) + ',"spec_slug":' + (ConvertTo-JiraJsonString $slugRef) + '}'

        if ([string]::IsNullOrEmpty($typeId) -or [string]::IsNullOrEmpty($env:SPEC_KIT_JIRA_BASE_URL)) {
            Write-FeatFallback -Json $json
            return 0
        }

        $created = New-JiraTicket -ProjectKey $effProject -Summary $desc -StoryTypeId $typeId -SpecRefJson $specRef
        if ($created.ExitCode -eq 9) { return 9 }
        if ($created.ExitCode -ne 0) {
            Write-FeatFallback -Json $json
            return 0
        }
        $createdKey = [string]((($created.Json) | ConvertFrom-Json -Depth 100).key)
        $number = Get-JiraTicketNumber -Key $createdKey
        $ticketKeyOut = $createdKey
        $action = 'created'
    }

    # (6) Naming (pure engine).
    $branchName = Expand-JiraBranchPattern -Pattern $pattern -Id $number -FeatureName $slug
    $shortName = Get-JiraShortName -FolderPrefix $prefix -Slug $slug

    $payload = ConvertTo-JiraJsonValue ([ordered]@{
        active = $true; team = $effId
        ticket = [ordered]@{ key = $ticketKeyOut; number = $number; action = $action }
        branch_name = $branchName; short_name = $shortName; override_used = $overrideUsed; warnings = @()
    })
    Write-FeatResult -Payload $payload -Json $json
    return 0
}

Export-ModuleMember -Function Invoke-JiraFeature
