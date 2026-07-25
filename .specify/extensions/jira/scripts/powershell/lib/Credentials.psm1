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

function Get-JiraConfigDir {
    if ($env:JIRA_CONFIG_DIR) { return $env:JIRA_CONFIG_DIR }
    return '.specify/jira'
}

function Get-JiraSecretManagerToken {
    # Test-overridable via $env:_CRED_SECRET_TOKEN. On Windows, the Credential
    # Manager / SecretManagement vault would be queried here; absence is non-fatal.
    if ($env:_CRED_SECRET_TOKEN) { return $env:_CRED_SECRET_TOKEN }
    return $null
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
    #>
    [CmdletBinding()]
    param()
    if ($env:JIRA_API_TOKEN) { return $env:JIRA_API_TOKEN }
    $secret = Get-JiraSecretManagerToken
    if ($secret) { return $secret }
    $fromFile = Get-JiraEnvFileToken
    if ($fromFile) { return $fromFile }
    return $null
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
