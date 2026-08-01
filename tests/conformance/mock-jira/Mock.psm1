# T008 — PowerShell helper for the mocked Jira double.
#
# Imported by Pester suites (and the conformance harness) to start/stop the mock
# server and read its recorded call sequence. Mirror of lib.sh so both ports
# drive the identical mock over HTTP.

Set-StrictMode -Version Latest

function Start-JiraMock {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$FixtureDir
    )
    $mockDir = $PSScriptRoot
    if (-not $FixtureDir) { $FixtureDir = Join-Path $mockDir 'fixtures' }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $callLog = Join-Path $tmp 'calls.log'
    $ready = Join-Path $tmp 'ready'
    New-Item -ItemType File -Path $callLog | Out-Null

    $server = Join-Path $mockDir 'mock-server.ps1'
    $argList = @('-NoProfile', '-File', $server, '-CallLogPath', $callLog, '-ReadyFile', $ready, '-FixtureDir', $FixtureDir)
    if ($ConfigPath) { $argList += @('-ConfigPath', $ConfigPath) }

    $pwshPath = (Get-Process -Id $PID).Path
    $proc = Start-Process -FilePath $pwshPath -ArgumentList $argList -PassThru -NoNewWindow

    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ready) -or (Get-Item -LiteralPath $ready).Length -eq 0) {
        if ($proc.HasExited) { throw 'mock process exited before ready' }
        if ((Get-Date) -gt $deadline) { throw 'mock failed to become ready' }
        Start-Sleep -Milliseconds 50
    }
    $port = (Get-Content -Raw -LiteralPath $ready).Trim()

    [pscustomobject]@{
        Process = $proc
        BaseUrl = "http://127.0.0.1:$port"
        CallLog = $callLog
        TempDir = $tmp
    }
}

function Stop-JiraMock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mock)
    if ($Mock.Process -and -not $Mock.Process.HasExited) {
        $Mock.Process.Kill()
    }
}

function Get-JiraMockCallLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mock)
    if (Test-Path -LiteralPath $Mock.CallLog) { Get-Content -LiteralPath $Mock.CallLog } else { @() }
}

function Write-JiraMockConfig {
    # Writes an ad hoc mock config (e.g. per-issue-type createmeta overrides
    # via "createmetaFields") to a temp file and returns its path (T003),
    # mirroring lib.sh's mock_write_config.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $f = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    Set-Content -LiteralPath $f -Value $Json -NoNewline
    return $f
}

function Get-JiraMockIssueField {
    # Reads back a field of an issue the mock already holds, e.g.
    # "fields.parent.key", for parent-link assertions (T002/T003).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mock, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Path)
    $issue = Invoke-RestMethod -Uri "$($Mock.BaseUrl)/rest/api/3/issue/$Key"
    $cursor = $issue
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $cursor) { return $null }
        if ($cursor -isnot [System.Collections.IDictionary] -and -not ($cursor.PSObject.Properties.Match($segment).Count)) { return $null }
        $cursor = $cursor.$segment
    }
    return $cursor
}

Export-ModuleMember -Function Start-JiraMock, Stop-JiraMock, Get-JiraMockCallLog, Write-JiraMockConfig, Get-JiraMockIssueField
