# tests/powershell/helpers/SecretStoreStub.psm1 — Pester twin of
# tests/bash/helpers/secret_store_stub.bash (030, contracts/credential-
# resolution.md C7.1 — repurposed, not deleted, from feature 021).
#
# Two stand-ins, two claims:
#
#   1. Install-JiraPatCommandStub COUNTS, and Resolve-JiraToken actually
#      REACHES it through $env:JIRA_PAT_COMMAND (C2.6 — at most once per run).
#      A REAL executable, exactly like the Bash twin, because the tests that
#      use it (C2.1-C2.5) exercise Get-JiraCredentialFromCommand's actual
#      process-spawning mechanics, not just Resolve-JiraToken's precedence.
#   2. Install-SecretStoreStub proves the deleted secret-manager rung stays
#      unreached (C1.3a): a `Get-Secret` shaped function existing in global
#      scope, as it would on a machine with SecretManagement installed, is
#      never consulted absent a declared command — the hardcoded probe this
#      feature deletes is gone, not merely bypassed.

Set-StrictMode -Version Latest

# Install-JiraPatCommandStub -BinDir <dir> -CounterFile <file> [-Token <str>] [-ExitCode <int>]
#
# Installs a REAL, counting executable and points $env:JIRA_PAT_COMMAND at it.
# Returns the program's absolute path. An empty/omitted -Token stands for
# C3.7 (exit 0, empty output — still a failure); a non-zero -ExitCode stands
# for C3.5, and the attempt still counts (a process was spawned).
function Install-JiraPatCommandStub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BinDir,
        [Parameter(Mandatory)][string] $CounterFile,
        [string] $Token = '',
        [int] $ExitCode = 0
    )
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    Set-Content -LiteralPath $CounterFile -Value $null -NoNewline

    if ($IsWindows) {
        $prog = Join-Path $BinDir 'spec-kit-jira-pat-helper.cmd'
        $lines = @('@echo off', "echo x>>""$CounterFile""")
        if ($Token) { $lines += "<nul set /p=""$Token""" }
        $lines += "exit /b $ExitCode"
        Set-Content -LiteralPath $prog -Value $lines
    } else {
        $prog = Join-Path $BinDir 'spec-kit-jira-pat-helper'
        $body = "#!/usr/bin/env bash`nprintf 'x\n' >> '$CounterFile'`n"
        if ($Token) { $body += "printf '%s' '$Token'`n" }
        $body += "exit $ExitCode`n"
        Set-Content -LiteralPath $prog -Value $body -NoNewline
        & chmod +x $prog
    }
    $env:JIRA_PAT_COMMAND = $prog
    return $prog
}

# Get-JiraPatCommandStubCount — how many times the retrieval command was
# actually executed. A missing file is 0.
function Get-JiraPatCommandStubCount {
    param([Parameter(Mandatory)][string] $CounterFile)
    if (-not (Test-Path -LiteralPath $CounterFile)) { return 0 }
    $content = Get-Content -Raw -LiteralPath $CounterFile -ErrorAction SilentlyContinue
    if (-not $content) { return 0 }
    @($content -split "`n" | Where-Object { $_.TrimEnd("`r").Length -gt 0 }).Count
}

# Install-SecretStoreStub — a global `Get-Secret` function that WOULD return a
# token if invoked. Used only to prove it is NOT invoked (C1.3a): the hardcoded
# probe this feature deletes used to call exactly this cmdlet name.
function Install-SecretStoreStub {
    param(
        [Parameter(Mandatory)][string] $CounterFile,
        [string] $Token = $null
    )
    Set-Content -LiteralPath $CounterFile -Value $null -NoNewline
    Set-Item -Path Function:\global:Get-Secret -Value {
        Add-Content -LiteralPath $CounterFile -Value 'secretmanager'
        return $Token
    }.GetNewClosure()
}

function Get-SecretStoreStubCount {
    param([Parameter(Mandatory)][string] $CounterFile)
    Get-JiraPatCommandStubCount -CounterFile $CounterFile
}

Export-ModuleMember -Function Install-JiraPatCommandStub, Get-JiraPatCommandStubCount, Install-SecretStoreStub, Get-SecretStoreStubCount
