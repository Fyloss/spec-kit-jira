# lib/Prereq.psm1 — Prerequisite checks (NFR-4). Mirror of lib/prereq.sh.
#
# Runs BEFORE any Jira interaction. PowerShell 7+ is required and git must be
# present. Any failure returns 5 (EXIT_PREREQ) so the dispatcher never
# touches Jira. Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

# Exit code shared across the port; 5 = prerequisite failure.
$script:ExitPrereq = 5

# Commands the PowerShell port requires at runtime. Unlike the Bash port, pwsh
# uses built-in Invoke-RestMethod / ConvertTo-Json, so curl and jq are not needed
# — only git.
$script:RequiredCommands = @('git')

# The bridge's repository-relative entry points, per port (003 FR-014, R6). The
# install copies the extension into `.specify/extensions/jira/` and puts NOTHING
# on PATH, so these paths — not a bare executable name — are what "the bridge"
# means in every message.
$script:PrereqBridgeBash = '.specify/extensions/jira/scripts/bash/spec-kit-jira.sh'
$script:PrereqBridgePwsh = '.specify/extensions/jira/scripts/powershell/spec-kit-jira.ps1'

function Get-JiraMissingBridgeEntry {
    <#
    .SYNOPSIS
      The entry point that is absent, or '' when both ports are intact.
      Mirror of prereq_bridge_missing.

      This is the SIXTH degraded cause (003 FR-017), and it is the only one the
      bridge cannot report on from inside a run that never started. What it CAN
      detect is the half-broken install: this port running while its twin is
      missing. Reporting that as its own cause — rather than folding it into
      "not configured" or the generic prerequisite gate — is what FR-017 and
      T090 require. The state where NEITHER port starts is covered by the
      verbatim fallback block in the command documents (FR-030), because there is
      no code of ours left running to say anything.
    #>
    [CmdletBinding()]
    param([string] $ExtensionRoot = '')

    $root = $ExtensionRoot
    if (-not $root) { $root = $env:SPEC_KIT_JIRA_EXTENSION_ROOT }
    if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }

    if (-not (Test-Path -LiteralPath (Join-Path $root 'scripts/bash/spec-kit-jira.sh'))) {
        return $script:PrereqBridgeBash
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'scripts/powershell/spec-kit-jira.ps1'))) {
        return $script:PrereqBridgePwsh
    }
    return ''
}

function Test-JiraPrereq {
    [CmdletBinding()]
    param(
        # Override the detected PowerShell major version (tests simulate an old host).
        [int] $PwshMajorOverride = $PSVersionTable.PSVersion.Major,

        # Commands to treat as absent (tests simulate a missing tool).
        [string[]] $ForceMissing = @()
    )

    if ($PwshMajorOverride -lt 7) {
        Write-Warning ("spec-kit-jira: PowerShell 7+ required (found major version {0}). Install PowerShell 7 (pwsh) and re-run." -f $PwshMajorOverride)
        return $script:ExitPrereq
    }

    $missing = foreach ($cmd in $script:RequiredCommands) {
        if ($ForceMissing -contains $cmd) {
            $cmd
        }
        elseif (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $cmd
        }
    }

    if ($missing) {
        Write-Warning ("spec-kit-jira: missing required command(s): {0}. Install them and re-run." -f ($missing -join ' '))
        return $script:ExitPrereq
    }

    # The bridge's own entry points, reported as their OWN cause and never folded
    # into the generic "missing required command(s)" line above (003 FR-017,
    # T090): a lost file is an install problem with an install remedy, not a
    # missing tool the operator should go and install.
    $bridge = Get-JiraMissingBridgeEntry
    if ($bridge) {
        Write-Warning ("spec-kit-jira: the bridge entry point {0} was not found — the extension install is incomplete. Restore it with: {1}" -f $bridge, 'specify extension add --dev <path-to-spec-kit-jira> --force')
        return $script:ExitPrereq
    }

    return 0
}

Export-ModuleMember -Function Test-JiraPrereq, Get-JiraMissingBridgeEntry
