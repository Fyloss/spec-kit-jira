# tests/powershell/helpers/CallsLog.psm1 — Pester twin of tests/bash/helpers/calls_log.bash.
#
# Same rationale as the Bash original: feature 021 asserts request COUNTS, and
# calls.log — one line per request the mock actually received, written by
# mock-server.ps1 ([System.IO.File]::AppendAllText($CallLogPath, "$method $target`n", …))
# — is the one source no subshell or scope on the caller's side can lose a line
# from. A missing or empty file reads as zero requests, not as an error: a
# scenario that short-circuits before touching the network must read as zero.

Set-StrictMode -Version Latest

function Get-CallsLogLines {
    <#
    .SYNOPSIS
      Read <path>, stripping a single trailing CR and dropping blank lines.
    #>
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return @() }
    $lines |
        ForEach-Object { $_.TrimEnd("`r") } |
        Where-Object { $_.Length -gt 0 }
}

function Get-CallsLogTotal {
    <#
    .SYNOPSIS
      How many requests the scenario issued. Missing or empty log is 0.
    #>
    param([Parameter(Mandatory)][string] $Path)
    @(Get-CallsLogLines -Path $Path).Count
}

function Get-CallsLogMatchCount {
    <#
    .SYNOPSIS
      How many requests carry <Substring> anywhere in their "METHOD target" line.
    #>
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Substring)
    @(Get-CallsLogLines -Path $Path | Where-Object { $_.Contains($Substring) }).Count
}

function Get-CallsLogByPath {
    <#
    .SYNOPSIS
      A per-target tabulation: one "<count>`t<METHOD target>" string per distinct
      request, sorted by target (ordinal, matching the Bash twin's `LC_ALL=C
      sort`) so two runs of the same scenario produce byte-identical output.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $counts = [ordered]@{}
    foreach ($line in Get-CallsLogLines -Path $Path) {
        if ($counts.Contains($line)) { $counts[$line] = $counts[$line] + 1 } else { $counts[$line] = 1 }
    }
    $keys = [string[]]$counts.Keys
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    foreach ($key in $keys) {
        "{0}`t{1}" -f $counts[$key], $key
    }
}

Export-ModuleMember -Function Get-CallsLogTotal, Get-CallsLogMatchCount, Get-CallsLogByPath
