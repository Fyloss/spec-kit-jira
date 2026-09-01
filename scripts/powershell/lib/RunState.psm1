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
$script:RunStateSchema = 3

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
    # The leaf is DERIVED with the primitives and that is correct — the result
    # is a bare directory name carrying no separator of its own. The join is a
    # different job: this string is printed to stdout as `state_file`, so it is
    # spelled here, from the caller's own bytes, exactly as the Bash twin's
    # `printf '%s/state/%s.json'` spells it (lib/run_state.sh:31).
    #
    # Join-Path renormalises to `\` on Windows and collapses a duplicated
    # separator on every host, which is neither what the twin writes nor what
    # the operator handed us — the same rule already recorded twelve lines
    # below for the recorded `inputs` keys, and quirk 8 of
    # docs/10-windows-portability.md. Nine conformance scenarios diverged on
    # this alone (#46).
    $featureDir = Split-Path -Leaf (Split-Path -Parent $SpecPath)
    return "$(Get-JiraConfigDir)/state/$featureDir.json"
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
        [string] $FieldValues = '',
        # 036, contracts/run-state-v3.md C2/C3: the ARTIFACT SET — every
        # publishable file of the feature directory, already carrying the
        # `git hash-object --no-filters --stdin-paths` hashes the engine
        # computed in ONE call (C3.4). Passed in rather than built here: this
        # module is `lib/` and the set is built in `engine/`, which is the
        # wrong direction to import, and the reconcile already holds it.
        [AllowEmptyString()] [string] $ArtifactSetJson = '[]'
    )
    if (-not (Test-Path -LiteralPath $SpecPath -PathType Leaf)) { return $null }

    $extVersion = Get-JiraExtensionVersion
    if ($extVersion -isnot [string]) { return $null }

    # C3.1/C3.3: the key set IS the artifact set's paths — relative to the
    # feature directory and `/`-separated on every host, because this document
    # is byte-compared across ports and machines. No hashing happens here: the
    # set arrives hashed, which is what makes C5's bounded budget hold.
    #
    # Under schema 2 this recorded three fixed documents, and a run fired after
    # only `research.md` changed found all three hashes matching and
    # short-circuited with zero Jira calls — leaving the artifact unpublished
    # forever (C4). That is the whole reason for the bump.
    $inputs = [ordered]@{}
    try {
        foreach ($a in @($ArtifactSetJson | ConvertFrom-Json)) {
            $inputs[[string] $a.path] = [string] $a.hash
        }
    }
    catch { return $null }

    $configDir = Get-JiraConfigDir
    # C3.2's "an absent file is not in the set" rule covers the feature
    # directory. It does NOT cover the three configuration files below: they
    # live outside it, they are read on every run, and a change to any of them
    # changes what the run would write. Dropping them would silently weaken the
    # short-circuit into ignoring a re-pointed project — so they keep both
    # their hashing and v2's "key omitted when absent" rule.
    foreach ($f in @('config.yml', 'config.local.yml', 'personal.yml')) {
        # Two spellings on purpose. Join-Path is the right way to REACH the
        # file, and $p keeps that job. The recorded key is a different thing:
        # it lands in a written document the Bash twin also writes, where that
        # twin spells "${JIRA_CONFIG_DIR}/${f}" with a forward slash on every
        # host (lib/run_state.sh). Join-Path renormalises to `\` on Windows, so
        # using $p as the key made the two ports write different state files —
        # the divergence the conformance corpus reported on `windows-latest`
        # for sc008-deleted-managed-region-restored (byte 138, bash=2f
        # pwsh=5c), the first run in which that step ever executed there.
        # Same rule as the target guard's <sibling> and AGENTS.md: a provider
        # primitive reaches the filesystem, it never spells a path into output.
        $p = Join-Path $configDir $f
        $key = "$configDir/$f"
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $hash = Get-JiraGitHash -Path $p
            if (-not $hash) { return $null }
            $inputs[$key] = $hash
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
        [string] $FieldValues = '',
        [AllowEmptyString()] [string] $ArtifactSetJson = '[]'
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

    $fresh = New-JiraRunStateDocument -SpecPath $SpecPath -BaseUrl $BaseUrl -Email $Email -OnDrift $OnDrift -HookEvent $HookEvent -FieldValues $FieldValues -ArtifactSetJson $ArtifactSetJson
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
        [string] $FieldValues = '',
        [AllowEmptyString()] [string] $ArtifactSetJson = '[]'
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

    $doc = New-JiraRunStateDocument -SpecPath $SpecPath -BaseUrl $BaseUrl -Email $Email -OnDrift $OnDrift -HookEvent $HookEvent -FieldValues $FieldValues -ArtifactSetJson $ArtifactSetJson
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
