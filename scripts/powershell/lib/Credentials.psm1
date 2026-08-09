# lib/Credentials.psm1 — Credential resolution (ELIMINATORY NFR-3 / SC-007).
# Mirror of lib/credentials.sh.
#
# Resolution order: environment -> OS secret manager -> gitignored .env.
# The token stays IN-PROCESS: it is delivered to Invoke-RestMethod via -Headers,
# so no child process ever sees it on a command line, and it is never written to
# the verbose/log/error streams.
#
# Port infrastructure only: NO Jira knowledge (Basic auth over HTTP is generic).

Set-StrictMode -Version Latest

# Per-process credential cache (021, US3, contracts/credential-cache.md).
# Filled at most once, on first miss inside Resolve-JiraToken — no priming
# function is needed here: PowerShell has no subshell to lose the cache to,
# so module scope persists for the whole process. Confirmed no module in the
# dependency chain re-imports this one with -Force after Invoke-JiraReconcile
# begins running (every such re-import is part of the static module-load
# cascade, which completes before any credential is ever resolved).
$script:CredCacheState = 'unset' # unset | resolved | unresolved
$script:CredCacheToken = $null

function Get-JiraConfigDir {
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-JiraSecretManagerToken {
    # Test-overridable via $env:_CRED_SECRET_TOKEN, which keeps precedence over
    # a real vault so no test needs one (contracts/credential-cache.md §5). On
    # Windows this reads the registered SecretManagement default vault; every
    # failure — module absent, no vault registered, no entry named
    # spec-kit-jira, or a locked vault unable to prompt — is swallowed into
    # $null, silently and without waiting (Constitution IV, v1.3.0).
    if ($env:_CRED_SECRET_TOKEN) { return $env:_CRED_SECRET_TOKEN }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) { return $null }
    try {
        Get-Secret -Name 'spec-kit-jira' -AsPlainText -ErrorAction Stop
    } catch {
        $null
    }
}

function Get-JiraEnvFileToken {
    # Follows the dotenv conventions a user will actually write: an optional
    # `export ` prefix, one pair of surrounding quotes, and CRLF line endings —
    # none of which may leak into the token (a corrupted token turns into an
    # unexplained 401). Mirror of _cred_from_env_file.
    $envFile = Join-Path (Get-JiraConfigDir) '.env'
    if (-not (Test-Path -LiteralPath $envFile)) { return $null }
    foreach ($line in Get-Content -LiteralPath $envFile) {
        $t = ([string]$line).TrimEnd("`r").TrimStart()
        $t = $t -creplace '^export\s+', ''
        if (-not $t.StartsWith('JIRA_API_TOKEN=')) { continue }
        $val = $t.Substring('JIRA_API_TOKEN='.Length)
        if ($val.Length -ge 2 -and
            (($val.StartsWith('"') -and $val.EndsWith('"')) -or
             ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        return $val
    }
    return $null
}

function Resolve-JiraToken {
    <#
    .SYNOPSIS
      Resolve the API token: env -> secret manager -> gitignored .env. Returns
      $null when no source provides one. Never writes the token to any stream.
      Reads the cache when filled; otherwise resolves and fills it — a failed
      resolution caches as 'unresolved', a state distinct from an empty token,
      so a token-less run still consults its sources only once.
    #>
    [CmdletBinding()]
    param()
    if ($script:CredCacheState -eq 'resolved') { return $script:CredCacheToken }
    if ($script:CredCacheState -eq 'unresolved') { return $null }
    $token = $null
    if ($env:JIRA_API_TOKEN) {
        $token = $env:JIRA_API_TOKEN
    } else {
        $secret = Get-JiraSecretManagerToken
        if ($secret) { $token = $secret } else { $token = Get-JiraEnvFileToken }
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
      port's. Returns $null when no token is available.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Email)
    $token = Resolve-JiraToken
    if (-not $token) { return $null }
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${Email}:$token"))
    return @{ Authorization = "Basic $basic" }
}

Export-ModuleMember -Function Resolve-JiraToken, Get-JiraAuthHeader, Get-JiraConfigDir
