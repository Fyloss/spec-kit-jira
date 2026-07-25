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

    return 0
}

Export-ModuleMember -Function Test-JiraPrereq
