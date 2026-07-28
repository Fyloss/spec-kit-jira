# T008 — PowerShell helper for the mocked Jira double.
#
# Imported by Pester suites (and the conformance harness) to start/stop the mock
# server and read its recorded call sequence. Mirror of lib.sh so both ports
# drive the identical mock over HTTP.
#
# The config object is passed through verbatim, so every field the server knows is
# available here — including the 003 `issues` corpus (per-key labels / parent /
# project) the JQL label search and the per-issue context read are served from,
# and the `identity` markers the claim read consumes. `-ConfigJson` seeds the
# same object inline, which is how a suite builds a candidate corpus without
# committing a config file; lib.sh's mock_start_json is its twin.

Set-StrictMode -Version Latest

function Start-JiraMock {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$ConfigJson,
        [string]$FixtureDir
    )
    $mockDir = $PSScriptRoot
    if (-not $FixtureDir) { $FixtureDir = Join-Path $mockDir 'fixtures' }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $callLog = Join-Path $tmp 'calls.log'
    $ready = Join-Path $tmp 'ready'
    New-Item -ItemType File -Path $callLog | Out-Null

    if ($ConfigJson) {
        $ConfigPath = Join-Path $tmp 'config.json'
        [System.IO.File]::WriteAllText($ConfigPath, $ConfigJson, [System.Text.UTF8Encoding]::new($false))
    }

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

Export-ModuleMember -Function Start-JiraMock, Stop-JiraMock, Get-JiraMockCallLog
