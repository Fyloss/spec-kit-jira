# lib/Credentials.psm1 — Credential resolution (030, contracts/credential-resolution.md).
# Mirror of lib/credentials.sh.
#
# Resolution order: environment variable -> operator-declared retrieval command
# (JIRA_PAT_COMMAND). No .env, no hardcoded secret-manager probe — a store is
# reached only through a command the operator declares. The resolved token
# stays IN-PROCESS: it is delivered to Invoke-RestMethod via -Headers, so no
# child process ever sees it on a command line, and it is never written to the
# verbose/log/error streams.
#
# Port infrastructure only: NO Jira knowledge (Basic auth over HTTP is generic).

Set-StrictMode -Version Latest

# The retrieval command's execution bound (C2.5, C7's R3): 5 seconds, the same
# literal in both ports, not configurable — the failure message names it
# (SC-003), so a "sensible default per port" would be a conformance divergence.
$script:CredBoundSeconds = 5

# Per-process credential cache (021, US3, contracts/credential-cache.md).
# Filled at most once, on first miss inside Resolve-JiraToken — no priming
# function is needed here: PowerShell has no subshell to lose the cache to,
# so module scope persists for the whole process.
$script:CredCacheState = 'unset' # unset | resolved | unresolved
$script:CredCacheToken = $null

# $script:CredLastError — set by Resolve-JiraToken on failure to the located
# reason (C3.3-C3.7), consumed by both call sites (C6.1-C6.3) and by the
# config ceremony's degraded-mode trigger (C6.4-C6.6). NEVER contains anything
# the retrieval command wrote to stdout (C4.4) — only the command's own
# stderr, and only for the "declared and failed" class.
$script:CredLastError = ''

function Get-JiraCredentialLastError {
    <#
    .SYNOPSIS
      The located reason set by the most recent failing Resolve-JiraToken call.
    #>
    return $script:CredLastError
}

function Get-JiraConfigDir {
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-JiraCredentialFromCommand {
    <#
    .SYNOPSIS
      Execute JIRA_PAT_COMMAND's value as a tokenized argument vector (C2.1: no
      shell, no eval — a pipe or `$(...)`-shaped value arrives as a literal,
      inert argument, C2.2), bounded at $script:CredBoundSeconds (C2.5).
      Returns the trimmed stdout (C2.3) on success; on any failure sets
      $script:CredLastError to the located reason (never echoing the command's
      own stdout, C4.4) and returns $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $CommandLine)

    $argv = @($CommandLine.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($argv.Count -eq 0) {
        $script:CredLastError = 'credential resolution failed: JIRA_PAT_COMMAND is empty — see docs/CREDENTIALS.md'
        return $null
    }
    if (-not (Get-Command -Name $argv[0] -ErrorAction SilentlyContinue)) {
        $script:CredLastError = "credential resolution failed: JIRA_PAT_COMMAND '$CommandLine' could not be executed — see docs/CREDENTIALS.md"
        return $null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $argv[0]
    for ($i = 1; $i -lt $argv.Count; $i++) { [void]$psi.ArgumentList.Add($argv[$i]) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Async reads started BEFORE the bounded wait — a synchronous ReadToEnd()
    # after WaitForExit would deadlock a command whose output fills the OS
    # pipe buffer before it exits (the watchdog's counterpart to the Bash
    # port's file-redirected background process, research §R3).
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($script:CredBoundSeconds * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch { }
        $script:CredLastError = "credential resolution failed: JIRA_PAT_COMMAND '$CommandLine' exceeded the $($script:CredBoundSeconds)s bound — see docs/CREDENTIALS.md"
        return $null
    }
    # Ensure the redirected streams have fully drained (.NET's own guidance
    # for the WaitForExit(int)-then-WaitForExit() pairing).
    $proc.WaitForExit()
    $out = $outTask.GetAwaiter().GetResult()
    $err = $errTask.GetAwaiter().GetResult()
    $rc = $proc.ExitCode

    if ($rc -ne 0) {
        $script:CredLastError = "credential resolution failed: JIRA_PAT_COMMAND '$CommandLine' exited with status $rc — see docs/CREDENTIALS.md"
        $errTrimmed = $err.Trim()
        if ($errTrimmed) { $script:CredLastError = "$($script:CredLastError) (stderr: $errTrimmed)" }
        return $null
    }

    $trimmed = $out.Trim()
    if (-not $trimmed) {
        $script:CredLastError = "credential resolution failed: JIRA_PAT_COMMAND '$CommandLine' produced no output — see docs/CREDENTIALS.md"
        return $null
    }
    return $trimmed
}

function Resolve-JiraToken {
    <#
    .SYNOPSIS
      Resolve the API token: environment variable -> operator-declared
      retrieval command. Returns $null when no source provides one, setting
      $script:CredLastError to the located reason (C3.3-C3.7). Reads the cache
      when filled; otherwise resolves and fills it — a failed resolution
      caches as 'unresolved', a state distinct from an empty token, so a
      token-less run still consults its sources only once.
    #>
    [CmdletBinding()]
    param()
    if ($script:CredCacheState -eq 'resolved') { return $script:CredCacheToken }
    if ($script:CredCacheState -eq 'unresolved') { return $null }

    $token = $null
    if ($env:JIRA_API_TOKEN) {
        $token = $env:JIRA_API_TOKEN
    } elseif ($env:_CRED_SECRET_TOKEN) {
        # Test override (C1.5): stands in for a successful retrieval-command
        # run, so no test needs a real command. Keeps precedence over
        # actually executing JIRA_PAT_COMMAND.
        $token = $env:_CRED_SECRET_TOKEN
    } elseif ($env:JIRA_PAT_COMMAND) {
        $token = Get-JiraCredentialFromCommand -CommandLine $env:JIRA_PAT_COMMAND
    } else {
        $script:CredLastError = 'credential resolution failed: neither JIRA_API_TOKEN nor JIRA_PAT_COMMAND is set — see docs/CREDENTIALS.md'
    }

    if ($token) {
        $script:CredCacheState = 'resolved'
        $script:CredCacheToken = $token
    } else {
        $script:CredCacheState = 'unresolved'
    }
    return $token
}

function Get-JiraAuthHeader {
    <#
    .SYNOPSIS
      Build the in-process Authorization header (Basic email:token, base64) for
      Invoke-RestMethod -Headers. The base64 value is byte-identical to the Bash
      port's. Returns $null when no token is available — the located reason is
      then in Get-JiraCredentialLastError (C6.2, C6.3).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Email)
    $token = Resolve-JiraToken
    if (-not $token) { return $null }
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${Email}:$token"))
    return @{ Authorization = "Basic $basic" }
}

Export-ModuleMember -Function Resolve-JiraToken, Get-JiraAuthHeader, Get-JiraConfigDir, Get-JiraCredentialFromCommand, Get-JiraCredentialLastError
