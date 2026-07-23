#!/usr/bin/env pwsh
# T008 — Mocked Jira Cloud REST v3 double.
#
# A single-threaded loopback HTTP server both ports' transports target via base
# URL. Implemented over a raw System.Net.Sockets.TcpListener (NOT HttpListener)
# so it needs no admin rights or urlacl reservation on Windows and no Python.
#
# Serves canned company-managed + team-managed discovery responses (non-default
# metadata, Constitution VII) and injects 401 / 404 / 429-exhausted / network
# faults keyed by project. Every request (method + target, query included) is
# appended LF-terminated to the call log so callers can assert the exact Jira
# API call sequence for byte-identical cross-port comparison (NFR-1).
#
# Startup: picks a free ephemeral port (Port 0), writes the chosen port to
# ReadyFile once listening, then serves until the process is killed.

[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$ConfigPath,
    [string]$FixtureDir = (Join-Path $PSScriptRoot 'fixtures'),
    [Parameter(Mandatory)][string]$CallLogPath,
    [Parameter(Mandatory)][string]$ReadyFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $FixtureDir)) {
    throw "fixture directory not found: $FixtureDir"
}

$ReasonPhrase = @{
    200 = 'OK'; 201 = 'Created'; 401 = 'Unauthorized'; 404 = 'Not Found'
    429 = 'Too Many Requests'; 500 = 'Internal Server Error'
}

# --- Config -----------------------------------------------------------------

$cfg = if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -AsHashtable
} else { @{} }
$Projects   = if ($cfg.ContainsKey('projects')) { $cfg.projects } else { @{} }
$Faults     = if ($cfg.ContainsKey('faults'))   { $cfg.faults }   else { @{} }
$GlobalFault = if ($cfg.ContainsKey('fault'))   { $cfg.fault }    else { $null }

# --- Helpers ----------------------------------------------------------------

function Get-Style {
    param([string]$Path)
    foreach ($key in $Projects.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|$)") { return $Projects[$key] }
    }
    return 'company'
}

function Get-Fault {
    param([string]$Path)
    foreach ($key in $Faults.Keys) {
        if ($Path -match "/$([regex]::Escape($key))(/|-|$)") { return $Faults[$key] }
    }
    return $GlobalFault
}

function Read-FixtureBody {
    param([string]$Name)
    $file = Join-Path $FixtureDir "$Name.json"
    if (-not (Test-Path -LiteralPath $file)) {
        return @{ status = 500; body = "{`"error`":`"missing fixture $Name`"}" }
    }
    return @{ status = 200; body = (Get-Content -Raw -LiteralPath $file) }
}

function Resolve-Route {
    param([string]$Method, [string]$Path)
    $style = Get-Style -Path $Path
    switch -regex ($Path) {
        '^/__mock/health$'                                           { return @{ status = 200; body = '{"ok":true}' } }
        '^/rest/api/3/project/[^/]+/statuses$'                        { return (Read-FixtureBody "statuses-$style") }
        '^/rest/api/3/project/[^/]+$'                                 { return (Read-FixtureBody "project-$style") }
        '^/rest/api/3/issue/createmeta/[^/]+/issuetypes/[^/]+$'       { return (Read-FixtureBody "createmeta-fields-$style") }
        '^/rest/api/3/issue/createmeta/[^/]+/issuetypes$'            { return (Read-FixtureBody "createmeta-issuetypes-$style") }
        '^/rest/api/3/priority$'                                      { return (Read-FixtureBody 'priority') }
        '^/rest/api/3/field$'                                         { return (Read-FixtureBody 'field') }
        '^/rest/api/3/issue$'                                         { if ($Method -eq 'POST') { $b = Read-FixtureBody 'issue-created'; $b.status = 201; return $b } }
        '^/rest/api/3/issue/[^/]+/properties/[^/]+$' {
            if ($Method -eq 'PUT') { return @{ status = 204; body = '' } }
            if ($Method -eq 'GET') {
                $b = Read-FixtureBody 'issue-property'
                if ($b.status -eq 500) { return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' } }
                return $b
            }
        }
        default { }
    }
    return @{ status = 404; body = '{"errorMessages":["not found"],"errors":{}}' }
}

function Write-Response {
    param([System.IO.Stream]$Stream, [int]$Status, [string]$Body, [hashtable]$Extra = @{})
    $bodyBytes = $Utf8NoBom.GetBytes($Body)
    $reason = if ($ReasonPhrase.ContainsKey($Status)) { $ReasonPhrase[$Status] } else { 'Unknown' }
    $head = "HTTP/1.1 $Status $reason`r`n"
    $head += "Content-Type: application/json`r`n"
    $head += "Content-Length: $($bodyBytes.Length)`r`n"
    foreach ($k in $Extra.Keys) { $head += "$k`: $($Extra[$k])`r`n" }
    $head += "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}

function Read-RequestLine {
    param([System.IO.Stream]$Stream)
    # Read bytes until CRLFCRLF (end of headers); we only need the request line.
    $bytes = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($bytes.Count -lt 65536) {
        $n = $Stream.Read($one, 0, 1)
        if ($n -le 0) { break }
        $bytes.Add($one[0])
        $c = $bytes.Count
        if ($c -ge 4 -and $bytes[$c - 4] -eq 13 -and $bytes[$c - 3] -eq 10 -and $bytes[$c - 2] -eq 13 -and $bytes[$c - 1] -eq 10) { break }
    }
    if ($bytes.Count -eq 0) { return $null }
    $text = [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
    return ($text -split "`r`n")[0]
}

# --- Listen -----------------------------------------------------------------

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$actualPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
[System.IO.File]::WriteAllText($ReadyFile, "$actualPort", $Utf8NoBom)

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $line = Read-RequestLine -Stream $stream
            if (-not $line) { continue }
            $parts = $line -split ' '
            $method = $parts[0]
            $target = if ($parts.Count -ge 2) { $parts[1] } else { '/' }
            $path = ($target -split '\?')[0]

            [System.IO.File]::AppendAllText($CallLogPath, "$method $target`n", $Utf8NoBom)

            $fault = Get-Fault -Path $path
            if ($fault) {
                if ($fault.ContainsKey('network') -and $fault.network) {
                    # Simulate a dropped connection: close without responding.
                    continue
                }
                $status = [int]$fault.status
                $extra = @{}
                if ($fault.ContainsKey('retryAfter')) { $extra['Retry-After'] = "$($fault.retryAfter)" }
                Write-Response -Stream $stream -Status $status -Body "{`"errorMessages`":[`"injected fault $status`"]}" -Extra $extra
                continue
            }

            $route = Resolve-Route -Method $method -Path $path
            Write-Response -Stream $stream -Status ([int]$route.status) -Body ([string]$route.body)
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
