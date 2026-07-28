# tests/conformance/InstallHarness.ps1 — T002: the PowerShell twin of
# install-harness.sh, function for function (Constitution VI).
#
# Install-time behaviour must be verifiable on Windows too: the seven events are
# registered by the host install there as well, and the "install touched nothing
# outside the repository" audit has a different surface on Windows (the profile
# paths, the user-scope install locations). Dot-source this file from Pester:
#
#   . "$PSScriptRoot/../../conformance/InstallHarness.ps1"
#   if (-not (Test-HarnessAvailable)) { Set-ItResult -Skipped -Because $script:HarnessSkipReason }
#   $repo = New-HarnessRepo
#   Set-HarnessRegistry -Repo $repo -Content '…'
#   Install-HarnessExtension -Repo $repo
#   Install-HarnessExtension -Repo $repo -Force
#   Get-HarnessRegistry -Repo $repo
#   Get-HarnessRegistryChecksum -Repo $repo
#   Remove-HarnessRepo -Repo $repo

Set-StrictMode -Version Latest

# The extension repository under test: two levels above tests/conformance/.
$script:HarnessExtensionRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

# The registry path inside a consuming repository.
$script:HarnessRegistryRel = '.specify/extensions.yml'

# Set by Test-HarnessAvailable when the harness cannot run.
$script:HarnessSkipReason = ''

function Test-HarnessAvailable {
    <#
    .SYNOPSIS
      $true when the `specify` CLI is available, $false otherwise with a clear
      reason in $script:HarnessSkipReason. Mirror of harness_require.
    #>
    $script:HarnessSkipReason = ''
    if (-not (Get-Command specify -ErrorAction SilentlyContinue)) {
        $script:HarnessSkipReason = "the 'specify' CLI is not installed — install it with: uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
        return $false
    }
    return $true
}

function Get-HarnessSkipReason { return $script:HarnessSkipReason }

function Get-HarnessExtensionRoot { return $script:HarnessExtensionRoot }

function New-HarnessRepo {
    <#
    .SYNOPSIS
      Create a scratch directory, run `specify init --here --integration claude`
      in it and return its absolute path. Mirror of harness_new_repo.

      `--force` because `git init` already made the directory non-empty and the
      CLI would otherwise stop for confirmation; `--ignore-agent-tools` because
      the agent binary is irrelevant to what this harness observes — the contents
      of `.specify/extensions.yml`.
    #>
    $repo = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Push-Location $repo
    try {
        & git init -q . 2>&1 | Out-Null
        & specify init --here --integration claude --force --ignore-agent-tools 2>&1 |
            Out-File -FilePath (Join-Path $repo '.harness-init.log')
    }
    finally { Pop-Location }
    return $repo
}

function Set-HarnessRegistry {
    <#
    .SYNOPSIS
      Place pre-existing registry content before the install runs. Mirror of
      harness_seed_registry.
    #>
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Content)
    $dir = Join-Path $Repo '.specify'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-HarnessRegistryPath -Repo $Repo), $Content + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Install-HarnessExtension {
    <#
    .SYNOPSIS
      Run `specify extension add --dev <root>` inside the repository. Mirror of
      harness_install.
    #>
    param([Parameter(Mandatory)] [string] $Repo, [switch] $Force)
    Push-Location $Repo
    try {
        $extra = @()
        if ($Force) { $extra += '--force' }
        & specify extension add --dev $script:HarnessExtensionRoot @extra 2>&1 |
            Out-File -FilePath (Join-Path $Repo '.harness-install.log')
    }
    finally { Pop-Location }
}

function Uninstall-HarnessExtension {
    # `--force` skips the interactive confirmation, which would otherwise hang a
    # test run. Mirror of harness_uninstall.
    param([Parameter(Mandatory)] [string] $Repo)
    Push-Location $Repo
    try { & specify extension remove jira --force 2>&1 | Out-File -FilePath (Join-Path $Repo '.harness-uninstall.log') }
    finally { Pop-Location }
}

function Get-HarnessRegistryPath {
    param([Parameter(Mandatory)] [string] $Repo)
    return (Join-Path $Repo $script:HarnessRegistryRel)
}

function Get-HarnessRegistry {
    <#
    .SYNOPSIS
      The registry's text, or '' when it does not exist. Mirror of harness_registry.
    #>
    param([Parameter(Mandatory)] [string] $Repo)
    $path = Get-HarnessRegistryPath -Repo $Repo
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-Content -Raw -LiteralPath $path)
}

function Get-HarnessRegistryChecksum {
    <#
    .SYNOPSIS
      A stable checksum over the registry file; '' when absent. Mirror of
      harness_registry_checksum.
    #>
    param([Parameter(Mandatory)] [string] $Repo)
    $path = Get-HarnessRegistryPath -Repo $Repo
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-HarnessEntriesFor {
    <#
    .SYNOPSIS
      One object per registry entry under the event, with Extension / Command /
      Enabled / Optional. Parsed with the extension's own reader, like the Bash
      twin. Mirror of harness_entries_for.
    #>
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $LifecycleEvent)
    $path = Get-HarnessRegistryPath -Repo $Repo
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    Import-Module (Join-Path $script:HarnessExtensionRoot 'scripts/powershell/lib/Config.psm1') -Force
    try { $json = ConvertFrom-JiraConfigYaml -Path $path } catch { return @() }
    $root = $json | ConvertFrom-Json -Depth 100
    $hooks = $null
    if ($root.PSObject.Properties['hooks']) { $hooks = $root.hooks }
    if ($null -eq $hooks -or -not $hooks.PSObject.Properties[$LifecycleEvent]) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($hooks.$LifecycleEvent)) {
        $out.Add([pscustomobject]@{
                Extension = if ($e.PSObject.Properties['extension']) { $e.extension } else { $null }
                Command   = if ($e.PSObject.Properties['command']) { $e.command } else { $null }
                Enabled   = if ($e.PSObject.Properties['enabled']) { $e.enabled } else { $null }
                Optional  = if ($e.PSObject.Properties['optional']) { $e.optional } else { $null }
            })
    }
    return $out.ToArray()
}

function Remove-HarnessRepo {
    param([Parameter(Mandatory)] [string] $Repo)
    if ($Repo -and (Test-Path -LiteralPath $Repo)) { Remove-Item -LiteralPath $Repo -Recurse -Force -ErrorAction SilentlyContinue }
}
