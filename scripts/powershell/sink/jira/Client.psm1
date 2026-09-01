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
# Returns a result object { Status; Body; ErrorBody; ExitCode }. On failure Body
# is empty so a caller sees the empty result of a fail-closed read (zero writes,
# FR-032); ErrorBody always carries the raw response text (011, FR-019).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../lib/Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../lib/Credentials.psm1') -Force

# Total curl-equivalent attempts issued so far, including retries
# (contracts/timing-report.md §5). $script:-scoped rather than a bash-style
# global: a PowerShell module has no shared flat namespace for Timing.psm1 to
# reach into, so Get-JiraRequestCount is the accessor Reconcile.psm1 reads at
# each phase boundary and hands to Stop-JiraTimingPhase -RequestCount (T015).
# There is no subshell-undercount boundary to document here the way
# client.sh's comment does (contracts/timing-report.md §6, research R5) —
# PowerShell has no command-substitution equivalent that discards this state.
#
# 024, T046/T047 (2026-08-11): EVERY caller of this module — Recognition,
# PlanApply, Prefetch, Identity, Discovery, Ticket, DuplicateProbe — MUST
# import it WITHOUT -Force. `Import-Module X -Force` is `Remove-Module X` +
# `Import-Module X`: seven of those callers each did their own `-Force`
# nested import, so every one of them (loaded before the last one wins)
# ended up bound to its OWN orphaned $script:JiraRequestCount, incrementing
# independently of whichever instance Reconcile.psm1's own
# Get-JiraRequestCount calls happened to read. The measured symptom was every
# phase reporting 0 requests while `calls.log` showed 123 real ones — proven
# by temporarily logging each increment/read, which showed TWO interleaved,
# independently-accumulating counts within a single process. See project
# memory: powershell-import-force-clobbers-caller-scope. This is the same
# defect class, just with seven origin sites instead of one.
$script:JiraRequestCount = 0

function Get-JiraRequestCount {
    [CmdletBinding()]
    param()
    return $script:JiraRequestCount
}

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

function New-JiraMultipartContent {
    <#
    .SYNOPSIS
      Compose the multipart/form-data body for an artifact upload
      (036 contracts/artifact-publication.md C2.2).
    .DESCRIPTION
      Its own function, and exported, so the composition can be asserted
      without a network. The Bash port's equivalent assertion reads the `curl`
      config it builds; this is the same idea — check what we hand to the HTTP
      client, which IS what C2.2 specifies.

      Each part's filename is set EXPLICITLY from the flattened name. A
      FileInfo contributes its own basename by default, so `contracts/api.md`
      would arrive as `api.md` — exactly the collision the flattening exists to
      prevent. The ContentDispositionHeaderValue is built by hand because
      -Form offers no other way to override it.

      Part ORDER is the caller's order, unchanged, so both ports produce the
      same sequence for the same artifact set (Constitution VI).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $FormParts)

    $content = [System.Net.Http.MultipartFormDataContent]::new()
    foreach ($p in $FormParts) {
        $bytes = [System.IO.File]::ReadAllBytes($p.File)
        $part = [System.Net.Http.ByteArrayContent]::new($bytes)
        $disp = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new('form-data')
        $disp.Name = '"file"'
        $disp.FileName = '"' + $p.Name + '"'
        $part.Headers.ContentDisposition = $disp
        $content.Add($part)
    }
    # `, $content` — the comma is load-bearing and its absence is silent.
    #
    # MultipartFormDataContent implements IEnumerable<HttpContent>, so a plain
    # `return $content` makes PowerShell ENUMERATE it: the caller receives the
    # inner parts, not the container. With one artifact the body sent was that
    # artifact's raw bytes with no boundary and no Content-Disposition at all —
    # a request Jira would reject, from code that looked correct and threw
    # nothing. The comma operator wraps it so the container itself is returned.
    return , $content
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
        [string] $Email = $env:JIRA_EMAIL,
        # 036, contracts/artifact-publication.md C2.2 — multipart form parts,
        # one per artifact: @( @{ Name = <attachment name>; File = <abs path> } ).
        # Mirror of jira_request_multipart's <parts-json> in the Bash port.
        [object[]] $FormParts
    )

    $maxAttempts = if ($env:JIRA_MAX_ATTEMPTS) { [int] $env:JIRA_MAX_ATTEMPTS } else { 3 }

    # A resolution failure here (030, C6.2/C6.3) is reported to stderr —
    # byte-identical to the Bash port's cred_curl_config, which reports it
    # itself rather than leaving this call site to construct the message.
    # 032, C6.1 — the destination travels with the request so the producer can
    # refuse an unbound one. Passing it here is what makes the guarantee
    # structural rather than a convention every future call site must remember.
    $header = Get-JiraAuthHeader -Email $Email -Url $Url
    if (-not $header) {
        [Console]::Error.WriteLine((Get-JiraCredentialLastError))
        return [pscustomobject]@{ Status = 0; Body = ''; ExitCode = (Get-JiraExitCode 'auth') }
    }
    $header['Accept'] = 'application/json'

    $attempt = 1
    while ($true) {
        $status = 0
        $bodyText = ''
        $retryAfter = $null
        $networkFailed = $false

        $script:JiraRequestCount++
        try {
            $params = @{
                Uri                = $Url
                Method             = $Method
                Headers            = $header
                SkipHttpErrorCheck = $true
                ErrorAction        = 'Stop'
            }
            if ($FormParts) {
                # 036 C2.2. THREE things happen here and each is load-bearing:
                #
                #   * ContentType is NOT set. `-Form` makes PowerShell compose
                #     `multipart/form-data` and its boundary itself; setting one
                #     by hand produces a body PowerShell did not build. Passing
                #     both is an error, which is why the assignment moved out of
                #     the hashtable literal above rather than being overwritten.
                #   * The XSRF header Jira requires for an upload is added. It is
                #     the one endpoint in this codebase needing a header the
                #     transport does not already send.
                #   * Each part's filename is set EXPLICITLY from the flattened
                #     name. A FileInfo contributes its own basename by default,
                #     so `contracts/api.md` would arrive as `api.md` — exactly
                #     the collision the flattening exists to prevent. The
                #     ContentDispositionHeaderValue is built by hand because
                #     -Form offers no other way to override it.
                $header['X-Atlassian-Token'] = 'no-check'
                $params.Body = New-JiraMultipartContent -FormParts $FormParts
            }
            else {
                $params.ContentType = 'application/json'
                if ($Body) { $params.Body = $Body }
            }
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
            return [pscustomobject]@{ Status = 0; Body = ''; ErrorBody = ''; ExitCode = (Get-JiraExitCode 'fail_closed') }
        }
        if ($status -ge 200 -and $status -lt 300) {
            return [pscustomobject]@{ Status = $status; Body = $bodyText; ErrorBody = $bodyText; ExitCode = 0 }
        }
        if ($status -eq 401 -or $status -eq 403) {
            return [pscustomobject]@{ Status = $status; Body = ''; ErrorBody = $bodyText; ExitCode = (Get-JiraExitCode 'auth') }
        }
        if ($status -eq 429 -and $attempt -lt $maxAttempts) {
            Get-JiraTransportBackoff -RetryAfter $retryAfter -Attempt $attempt
            $attempt++
            continue
        }
        # 429 exhausted, 404, 5xx, anything else -> fail-closed. ErrorBody carries
        # the raw response (011, contract Sec3.7, FR-019) — never printed to a
        # human directly; a caller translates it before it reaches the summary.
        return [pscustomobject]@{ Status = $status; Body = ''; ErrorBody = $bodyText; ExitCode = (Get-JiraExitCode 'fail_closed') }
    }
}

Export-ModuleMember -Function Invoke-JiraRequest, Get-JiraRequestCount, New-JiraMultipartContent
