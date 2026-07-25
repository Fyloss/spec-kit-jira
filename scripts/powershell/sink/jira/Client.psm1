# sink/jira/Client.psm1 — Jira Cloud REST v3 transport. Mirror of client.sh.
#
# The single HTTP conduit to Jira. Every request:
#   * carries the Authorization header IN-PROCESS via -Headers — no child process
#     ever sees the credential on a command line, and it is never written to the
#     verbose/log/error streams (NFR-3 / SC-007);
#   * retries a 429 with backoff honouring Retry-After up to JIRA_MAX_ATTEMPTS;
#   * maps outcomes to the shared, monotonic exit-code table (Constitution III):
#       2xx            -> 0        (Body carried on the result)
#       401 / 403      -> auth (3)
#       404 / 5xx / network / 429-exhausted -> fail_closed (2)  (empty Body)
#
# Returns a result object { Status; Body; ExitCode }. On failure Body is empty so
# a caller sees the empty result of a fail-closed read (zero writes, FR-032).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Credentials.psm1') -Force

function Get-JiraTransportBackoff {
    # Seconds to wait before the next retry: the response's Retry-After when it is
    # a plain integer, else exponential backoff. Suppress the real wait in tests.
    param([string] $RetryAfter, [int] $Attempt)
    $seconds = if ($RetryAfter -and ($RetryAfter -match '^\d+$')) {
        [int] $RetryAfter
    } else {
        [int] [math]::Pow(2, $Attempt - 1)
    }
    if (-not $env:JIRA_NO_SLEEP) { Start-Sleep -Seconds $seconds }
}

function Invoke-JiraRequest {
    <#
    .SYNOPSIS
      Perform a Jira REST v3 request with a credential-safe in-process header,
      429 retry/backoff, and monotonic exit-code mapping. Returns
      { Status; Body; ExitCode }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Url,
        [string] $Body,
        [string] $Email = $env:JIRA_EMAIL
    )

    $maxAttempts = if ($env:JIRA_MAX_ATTEMPTS) { [int] $env:JIRA_MAX_ATTEMPTS } else { 3 }

    $header = Get-JiraAuthHeader -Email $Email
    if (-not $header) {
        return [pscustomobject]@{ Status = 0; Body = ''; ExitCode = (Get-JiraExitCode 'auth') }
    }
    $header['Accept'] = 'application/json'

    $attempt = 1
    while ($true) {
        $status = 0
        $bodyText = ''
        $retryAfter = $null
        $networkFailed = $false

        try {
            $params = @{
                Uri                = $Url
                Method             = $Method
                Headers            = $header
                ContentType        = 'application/json'
                SkipHttpErrorCheck = $true
                ErrorAction        = 'Stop'
            }
            if ($Body) { $params.Body = $Body }
            $resp = Invoke-WebRequest @params
            $status = [int] $resp.StatusCode
            $bodyText = if ($null -ne $resp.Content) { [string] $resp.Content } else { '' }
            if ($resp.Headers -and $resp.Headers.ContainsKey('Retry-After')) {
                $retryAfter = @($resp.Headers['Retry-After'])[0]
            }
        }
        catch {
            # Network-level failure (dropped connection, DNS, timeout) -> fail-closed.
            $networkFailed = $true
        }

        if ($networkFailed) {
            return [pscustomobject]@{ Status = 0; Body = ''; ExitCode = (Get-JiraExitCode 'fail_closed') }
        }
        if ($status -ge 200 -and $status -lt 300) {
            return [pscustomobject]@{ Status = $status; Body = $bodyText; ExitCode = 0 }
        }
        if ($status -eq 401 -or $status -eq 403) {
            return [pscustomobject]@{ Status = $status; Body = ''; ExitCode = (Get-JiraExitCode 'auth') }
        }
        if ($status -eq 429 -and $attempt -lt $maxAttempts) {
            Get-JiraTransportBackoff -RetryAfter $retryAfter -Attempt $attempt
            $attempt++
            continue
        }
        # 429 exhausted, 404, 5xx, anything else -> fail-closed.
        return [pscustomobject]@{ Status = $status; Body = ''; ExitCode = (Get-JiraExitCode 'fail_closed') }
    }
}

Export-ModuleMember -Function Invoke-JiraRequest
