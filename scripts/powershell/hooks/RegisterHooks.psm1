# hooks/RegisterHooks.psm1 — Idempotent after_* lifecycle-hook registration (US9).
# Mirror of hooks/register_hooks.sh.
#
# Registers a non-blocking Jira reconcile under every spec-kit lifecycle event in
# .specify/extensions.yml (FR-045). Registration is SET-not-append and idempotent
# (FR-047): our reconcile hook appears at most once per event, a re-run rewrites
# byte-identical bytes, and an operator-disabled hook is preserved and never
# re-enabled (FR-048). Every existing entry survives; only a genuinely missing
# reconcile hook is added. Reuses the deterministic YAML reader/writer from
# lib/Config.psm1 (no yq). Emits byte-identical output to the Bash port (NFR-1).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../lib/Config.psm1') -Force # YAML reader/writer
Import-Module (Join-Path $PSScriptRoot '../lib/Output.psm1') -Force # canonical serialiser

$script:HookCommand = 'speckit.jira.reconcile'
$script:HookEvents = @('after_specify', 'after_clarify', 'after_plan', 'after_tasks', 'after_implement', 'after_analyze')
$script:HookExitConfig = 4

function Get-JiraHookEntry {
    # The canonical desired entry for our reconcile hook. `optional = true` makes it
    # non-blocking: a bridge failure never fails the host command (FR-046).
    return [ordered]@{
        command     = $script:HookCommand
        description = 'Mirror the updated spec-kit artifacts into Jira Cloud (non-blocking).'
        enabled     = $true
        optional    = $true
    }
}

function Get-JiraHookMerged {
    <#
    .SYNOPSIS
      Ensure our reconcile hook is present under every lifecycle event, set-not-
      append (FR-047), never disturbing an entry the operator already placed or
      disabled (FR-048). Returns the canonical merged JSON. Mirror of
      _register_hooks_merge.
    #>
    param([Parameter(Mandatory)] [string] $ExistingJson)
    $root = $ExistingJson | ConvertFrom-Json -Depth 100

    # Copy the whole root into an ordered map so foreign top-level keys survive.
    $rootMap = [ordered]@{}
    if ($root -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $root.PSObject.Properties) { $rootMap[$prop.Name] = $prop.Value }
    }

    $hooksMap = [ordered]@{}
    if ($rootMap.Contains('hooks') -and ($rootMap['hooks'] -is [System.Management.Automation.PSCustomObject])) {
        foreach ($prop in $rootMap['hooks'].PSObject.Properties) { $hooksMap[$prop.Name] = $prop.Value }
    }

    foreach ($e in $script:HookEvents) {
        $cur = [System.Collections.Generic.List[object]]::new()
        if ($hooksMap.Contains($e) -and $null -ne $hooksMap[$e]) {
            foreach ($x in @($hooksMap[$e])) { $cur.Add($x) }
        }
        $present = $false
        foreach ($x in $cur) {
            if ((Get-JiraHookProp $x 'command') -eq $script:HookCommand) { $present = $true; break }
        }
        if (-not $present) { $cur.Add((Get-JiraHookEntry)) }
        $hooksMap[$e] = $cur.ToArray()
    }
    $rootMap['hooks'] = $hooksMap

    return (ConvertTo-JiraJsonValue $rootMap)
}

function Get-JiraHookProp {
    # $null-safe property read (an entry may be any shape).
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    }
    return $null
}

function Get-JiraHookHealth {
    <#
    .SYNOPSIS
      READ-ONLY hook-health check for the run summary (FR-047). Returns the
      canonical hook_health object of run-summary.schema.json:
      { present; missing; disabled; repair_hint? }. `missing` lists lifecycle
      events with no reconcile hook at all; an operator-disabled hook is listed
      under `disabled` (never "missing"), so it is never re-added (FR-048).
      `repair_hint` appears only when a hook is missing. A malformed file reports
      every event missing. Mirror of register_hooks_health.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $existingJson = '{}'
    if (Test-Path -LiteralPath $Path) {
        try { $existingJson = ConvertFrom-JiraConfigYaml -Path $Path }
        catch {
            return (ConvertTo-JiraJsonValue ([ordered]@{
                        present     = @()
                        missing     = @($script:HookEvents)
                        disabled    = @()
                        repair_hint = 'extensions.yml is not valid YAML — fix it, then run /speckit.jira.config or reconcile --repair-hooks'
                    }))
        }
    }
    $root = $existingJson | ConvertFrom-Json -Depth 100
    $hooks = Get-JiraHookProp $root 'hooks'

    $present = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $disabled = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $script:HookEvents) {
        $ours = [System.Collections.Generic.List[object]]::new()
        foreach ($x in @(Get-JiraHookProp $hooks $e)) {
            if ((Get-JiraHookProp $x 'command') -eq $script:HookCommand) { $ours.Add($x) }
        }
        if ($ours.Count -eq 0) { $missing.Add($e); continue }
        $enabled = $false
        foreach ($x in $ours) {
            $en = Get-JiraHookProp $x 'enabled'
            if (-not ($en -is [bool] -and $en -eq $false)) { $enabled = $true; break }
        }
        if ($enabled) { $present.Add($e) } else { $disabled.Add($e) }
    }

    $out = [ordered]@{ present = $present.ToArray(); missing = $missing.ToArray(); disabled = $disabled.ToArray() }
    if ($missing.Count -gt 0) { $out['repair_hint'] = 'run /speckit.jira.config or reconcile --repair-hooks' }
    return (ConvertTo-JiraJsonValue $out)
}

function Set-JiraHookRegistration {
    <#
    .SYNOPSIS
      Idempotently register the reconcile hook under every lifecycle event, creating
      the file (and its directory) if absent. Returns { ExitCode; Status } where
      Status is created | repaired | unchanged | refused. In dry-run the status is
      computed but no file is touched. Mirror of register_hooks_write.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path, [bool] $DryRun = $false)

    $existingJson = '{}'
    $existed = $false
    if (Test-Path -LiteralPath $Path) {
        $existed = $true
        try { $existingJson = ConvertFrom-JiraConfigYaml -Path $Path }
        catch { return [pscustomobject]@{ ExitCode = $script:HookExitConfig; Status = 'refused' } }
    }

    $merged = Get-JiraHookMerged -ExistingJson $existingJson
    $yaml = ConvertTo-JiraConfigYaml -Json $merged

    $status = 'repaired'
    if (-not $existed) {
        $status = 'created'
    }
    elseif (((Get-Content -Raw -LiteralPath $Path) -replace "`r`n", "`n").TrimEnd("`n") -eq $yaml) {
        $status = 'unchanged'
    }

    if (-not $DryRun -and $status -ne 'unchanged') {
        if ($PSCmdlet.ShouldProcess($Path, 'register hooks')) {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.File]::WriteAllText($Path, $yaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Status = $status }
}

Export-ModuleMember -Function Get-JiraHookHealth, Set-JiraHookRegistration
