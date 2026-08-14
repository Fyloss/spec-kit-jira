# lib/RunState.psm1 — The run-state short-circuit's document layer (FR-019…
# FR-028, contracts/run-state.md, data-model.md §1). Mirror of lib/run_state.sh.
#
# Every function here is a pure function of its arguments, like Config.psm1's
# Get-JiraExtensionVersion and Credentials.psm1's connection-value functions —
# never reads $env:JIRA_EMAIL or $env:SPEC_KIT_JIRA_BASE_URL itself. The
# hashing primitive is `git hash-object --no-filters`, the only content hash
# guaranteed present and identical on all three hosts (research R7).
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

# Not -Force: this module holds Config.psm1 in session scope, and -Force is a
# Remove-Module + Import-Module pair that would tear that copy out and
# re-attach it here (see the PowerShell import-force note in ReadmeBlock.psm1).
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')   # Get-JiraExtensionVersion
Import-Module (Join-Path $PSScriptRoot 'Output.psm1')   # ConvertTo-JiraJsonValue, Write-JiraWarning

# Shape version of the run-state document (data-model.md §1). A change to the
# *set* of recorded inputs bumps it, invalidating every existing file.
# 023, contracts/run-state-v2.md C1: 1 -> 2 for `hook_event` and `plan.md`.
$script:RunStateSchema = 2

function Get-JiraConfigDir {
    # Mirror of Credentials.psm1's private helper of the same name — every
    # consuming module inlines this rather than reaching across module
    # boundaries for an unexported getter (Config.psm1's own is private too).
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-JiraGitHash {
    # git hash-object --no-filters <path> — $null when it cannot be hashed.
    # Mirror of the bash port: emptiness of the captured output is the only
    # failure signal, not $LASTEXITCODE — reading $LASTEXITCODE from a
    # function called by another function trips a PowerShell strict-mode
    # scoping quirk ("cannot be retrieved because it has not been set") that
    # a direct top-level call never exhibits.
    param([Parameter(Mandatory)] [string] $Path)
    $hash = (& git hash-object --no-filters $Path 2>$null | Select-Object -First 1)
    if (-not $hash) { return $null }
    return $hash.Trim()
}

function Get-JiraRunStatePath {
    <#
    .SYNOPSIS
      The recorded document's path for the feature directory holding this spec.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SpecPath)
    $featureDir = Split-Path -Leaf (Split-Path -Parent $SpecPath)
    $stateDir = Join-Path (Get-JiraConfigDir) 'state'
    return (Join-Path $stateDir "$featureDir.json")
}

function New-JiraRunStateDocument {
    <#
    .SYNOPSIS
      Print the canonical JSON document (data-model.md §1) for the current
      inputs. Returns $null if any required input cannot be hashed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SpecPath,
        [Parameter(Mandatory)] [string] $BaseUrl,
        # [AllowEmptyString()]: a bare [Parameter(Mandatory)] on a [string]
        # rejects "" at bind time ("Cannot bind argument... it is an empty
        # string") even though a value WAS supplied — JIRA_EMAIL is legitimately
        # unset for scenarios that never reach a Jira call (e.g. a retired-key
        # refusal), and the bash port's run_state_matches tolerates "" fine.
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Email,
        [Parameter(Mandatory)] [string] $OnDrift,
        # 023, contracts/run-state-v2.md §2: an explicit argument, never read
        # from $env:SPEC_KIT_JIRA_HOOK_EVENT itself — keeps this module a pure
        # function of its arguments, like BaseUrl/Email/OnDrift/FieldValues.
        [AllowEmptyString()] [string] $HookEvent = '',
        [string] $FieldValues = ''
    )
    if (-not (Test-Path -LiteralPath $SpecPath -PathType Leaf)) { return $null }

    $extVersion = Get-JiraExtensionVersion
    if ($extVersion -isnot [string]) { return $null }

    $specHash = Get-JiraGitHash -Path $SpecPath
    if (-not $specHash) { return $null }

    $inputs = [ordered]@{ 'spec.md' = $specHash }

    $tasksPath = Join-Path (Split-Path -Parent $SpecPath) 'tasks.md'
    if (Test-Path -LiteralPath $tasksPath -PathType Leaf) {
        $hash = Get-JiraGitHash -Path $tasksPath
        if (-not $hash) { return $null }
        $inputs['tasks.md'] = $hash
    }

    # C3 (contracts/run-state-v2.md §1): plan.md is read on every run and
    # spliced onto the parent's description, so a change to it must
    # invalidate — the same "present when the file exists, key omitted
    # otherwise" rule tasks.md already has.
    $planPath = Join-Path (Split-Path -Parent $SpecPath) 'plan.md'
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $hash = Get-JiraGitHash -Path $planPath
        if (-not $hash) { return $null }
        $inputs['plan.md'] = $hash
    }

    $configDir = Get-JiraConfigDir
    foreach ($f in @('config.yml', 'config.local.yml', 'personal.yml')) {
        $p = Join-Path $configDir $f
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $hash = Get-JiraGitHash -Path $p
            if (-not $hash) { return $null }
            $inputs[$p] = $hash
        }
    }

    $doc = [ordered]@{
        schema            = $script:RunStateSchema
        extension_version = $extVersion
        base_url          = $BaseUrl
        email             = $Email
        on_drift          = $OnDrift
        hook_event        = $HookEvent
        field_values      = $FieldValues
        inputs            = $inputs
    }
    return (ConvertTo-JiraJsonValue $doc)
}

function Test-JiraRunStateMatch {
    <#
    .SYNOPSIS
      True only when a recorded document exists, is readable, is valid, and
      is byte-equal to a fresh compose of the same arguments. False in every
      other case, including every error — every doubt fails open.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SpecPath,
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Email,
        [Parameter(Mandatory)] [string] $OnDrift,
        [AllowEmptyString()] [string] $HookEvent = '',
        [string] $FieldValues = ''
    )
    $recordedPath = Get-JiraRunStatePath -SpecPath $SpecPath
    if (-not (Test-Path -LiteralPath $recordedPath -PathType Leaf)) { return $false }

    try {
        $recorded = [System.IO.File]::ReadAllText($recordedPath)
    }
    catch { return $false }

    try {
        $null = $recorded | ConvertFrom-Json -Depth 100
    }
    catch { return $false }

    $fresh = New-JiraRunStateDocument -SpecPath $SpecPath -BaseUrl $BaseUrl -Email $Email -OnDrift $OnDrift -HookEvent $HookEvent -FieldValues $FieldValues
    if (-not $fresh) { return $false }

    return [string]::Equals($recorded, $fresh, [System.StringComparison]::Ordinal)
}

function Save-JiraRunState {
    <#
    .SYNOPSIS
      Compose and write atomically to a sibling temp file, then rename onto
      the final name. Creates the state directory and its self-ignoring
      .gitignore if absent. Never fails the run: a write error is a warning,
      not an exception.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SpecPath,
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Email,
        [Parameter(Mandatory)] [string] $OnDrift,
        [AllowEmptyString()] [string] $HookEvent = '',
        [string] $FieldValues = ''
    )
    $recordedPath = Get-JiraRunStatePath -SpecPath $SpecPath
    $stateDir = Split-Path -Parent $recordedPath

    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-JiraWarning "run-state: could not create ${stateDir}; state not recorded"
            return
        }
    }

    $gitignore = Join-Path $stateDir '.gitignore'
    if (-not (Test-Path -LiteralPath $gitignore -PathType Leaf)) {
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($gitignore, "*`n", $utf8NoBom)
        }
        catch {
            # Non-fatal: the ignore attempt does not block state recording.
            $null = $_
        }
    }

    $doc = New-JiraRunStateDocument -SpecPath $SpecPath -BaseUrl $BaseUrl -Email $Email -OnDrift $OnDrift -HookEvent $HookEvent -FieldValues $FieldValues
    if (-not $doc) {
        Write-JiraWarning 'run-state: could not compose the state document; state not recorded'
        return
    }

    $tmp = "$recordedPath.tmp.$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmp, $doc, $utf8NoBom)
    }
    catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-JiraWarning "run-state: could not write ${tmp}; state not recorded"
        return
    }
    try {
        Move-Item -LiteralPath $tmp -Destination $recordedPath -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-JiraWarning "run-state: could not rename onto ${recordedPath}; state not recorded"
        return
    }
}

Export-ModuleMember -Function Get-JiraRunStatePath, New-JiraRunStateDocument, Test-JiraRunStateMatch, Save-JiraRunState
