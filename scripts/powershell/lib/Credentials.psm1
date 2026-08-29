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
# 032 — compare the request's origin against the pinned one (C6.1).
Import-Module (Join-Path $PSScriptRoot 'UrlOrigin.psm1')

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'The bound-exceeded path races the process''s own exit: Kill(), the reaping WaitForExit(), and the two stream drains all throw if it already exited or its pipes are already closed — the outcome being sought, not a fault to report.')]
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
    try {
        # Async reads started BEFORE the bounded wait — a synchronous ReadToEnd()
        # after WaitForExit would deadlock a command whose output fills the OS
        # pipe buffer before it exits (the watchdog's counterpart to the Bash
        # port's file-redirected background process, research §R3).
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($script:CredBoundSeconds * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            # Reap the killed child and let its redirected reads settle before
            # returning — the counterpart of the Bash port's `wait "${pid}"`.
            # Kill() only requests termination: without this the function can
            # return while the child is still dying and both read tasks are
            # still pending on its pipes. Every wait here is BOUNDED, and the
            # argument-less WaitForExit() is deliberately not used: both it and
            # an unbounded task wait block until the pipes close, which a
            # grandchild the command left behind holds open indefinitely —
            # trading a leaked handle for a hung run.
            try { [void]$proc.WaitForExit(1000) } catch { }
            try { [void]$outTask.Wait(500) } catch { }
            try { [void]$errTask.Wait(500) } catch { }
            $script:CredLastError = "credential resolution failed: JIRA_PAT_COMMAND '$CommandLine' exceeded the $($script:CredBoundSeconds)s bound — see docs/CREDENTIALS.md"
            return $null
        }
        # Ensure the redirected streams have fully drained (.NET's own guidance
        # for the WaitForExit(int)-then-WaitForExit() pairing).
        $proc.WaitForExit()
        $out = $outTask.GetAwaiter().GetResult()
        $err = $errTask.GetAwaiter().GetResult()
        $rc = $proc.ExitCode
    } finally {
        # Every path — success, non-zero exit, bound exceeded — releases the
        # process handle and BOTH redirected pipe ends here; a long-lived host
        # (Pester, a reconcile run) would otherwise hold two descriptors per
        # resolution attempt until the finalizer happened to run. The readers
        # are disposed explicitly because $proc.Dispose() alone leaves them
        # open — measured, not assumed (tests/powershell/lib/Credentials.Tests.ps1,
        # 'Child-process hygiene on the bound-exceeded path'). Disposing a
        # reader with its ReadToEndAsync still pending is also what unblocks
        # that read when a grandchild is holding the pipe open.
        try { $proc.StandardOutput.Dispose() } catch { }
        try { $proc.StandardError.Dispose() } catch { }
        $proc.Dispose()
    }

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

# 032, C6.1-C6.4 — the destination this process verified, canonical. Owned
# HERE rather than read out of lib/Config.psm1, so the dependency runs
# Config -> Credentials and never the other way: this module is the one that
# must be able to refuse, and a producer that reaches into its caller for
# permission is a producer that can be bypassed by a caller that forgets.
#
# Module-scoped, never an environment variable (C6.3): a spawned child must not
# inherit it, the same rule the credential cache states for itself.
#
# Empty means the gate never ran for this process. The producer then refuses:
# a call site that reached the transport without passing the gate does not get
# a credential (C6.4).
$script:PinnedOrigin = ''

function Set-JiraCredentialPinnedOrigin {
    <#
    .SYNOPSIS
      Record the verified destination. Called once by the connection
      chokepoint; a second call with a different value is accepted, because the
      ceremony legitimately rebinds within one process. Mirror of
      cred_pin_origin.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Origin)
    $script:PinnedOrigin = $Origin
}

function Get-JiraAuthHeader {
    <#
    .SYNOPSIS
      Build the in-process Authorization header (Basic email:token, base64) for
      Invoke-RestMethod -Headers. The base64 value is byte-identical to the Bash
      port's. Returns $null when no token is available — the located reason is
      then in Get-JiraCredentialLastError (C6.2, C6.3).
    .NOTES
      032, C6.1/C6.4: refuses to produce a value for a destination this process
      did not verify. Defence in depth, not the gate — the gate at the
      connection chokepoint already refused once, with a located message. What
      this adds is that a FUTURE call site building its own URL cannot get a
      credential by forgetting to ask. Two string comparisons against state the
      gate already computed: no re-read, no re-parse, no spawn (C6.2).

      A caller that passes no -Url keeps the old behaviour, so the check cannot
      break a call site that has not been taught about it yet; every such site
      is still covered by the gate itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Email,
        [string] $Url = ''
    )
    if ($Url) {
        $pinned = $script:PinnedOrigin
        if ([string]::IsNullOrEmpty($pinned) -and $env:SPEC_KIT_JIRA_BASE_URL) {
            # No chokepoint ran in this process, but the destination came from
            # the environment — the case FR-011 declares exempt, and for which
            # the chokepoint itself would have pinned exactly this origin.
            # Deriving it here keeps a directly-driven sink working without
            # weakening anything: the attack this feature exists to stop is a
            # destination declared in config.yml, and config.yml is read ONLY by
            # the chokepoint. If no chokepoint ran, no file-supplied destination
            # can be in play.
            $c = Get-JiraUrlOriginCanonical -Url ([string] $env:SPEC_KIT_JIRA_BASE_URL)
            if ($null -ne $c) { $pinned = $c }
        }
        if ([string]::IsNullOrEmpty($pinned)) {
            $script:CredLastError = "credential withheld: this run verified no Jira destination, so no request may carry the operator's credential"
            return $null
        }
        if (-not (Test-JiraUrlOriginEqual -First $Url -Second $pinned)) {
            $script:CredLastError = 'credential withheld: this request targets a destination this checkout is not bound to'
            return $null
        }
    }
    $token = Resolve-JiraToken
    if (-not $token) { return $null }
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${Email}:$token"))
    return @{ Authorization = "Basic $basic" }
}

Export-ModuleMember -Function Resolve-JiraToken, Get-JiraAuthHeader, Get-JiraConfigDir, Get-JiraCredentialFromCommand, Get-JiraCredentialLastError, Set-JiraCredentialPinnedOrigin
