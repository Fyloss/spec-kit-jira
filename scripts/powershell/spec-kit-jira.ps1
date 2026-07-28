#!/usr/bin/env pwsh
# spec-kit-jira.ps1 — entry-point dispatcher (PowerShell port). Mirror of
# spec-kit-jira.sh.
#
# In order:
#   1. Run prerequisite checks (NFR-4) — no Jira interaction before they pass; a
#      failure exits 5. Overrides are read from _PREREQ_* env vars so the gate is
#      exercisable identically to the Bash port.
#   2. Parse the CLI into machine-readable state (byte-identical to Bash); a usage
#      error exits 1; --help prints usage and exits 0.
#   3. Route the selected command to its Invoke-Jira<Name> entry, imported on
#      demand from the commands directory (overridable via
#      SPEC_KIT_JIRA_COMMANDS_DIR).
#
# Command modules (commands/<Name>.psm1) export Invoke-Jira<Name> and receive the
# raw argv. Each writes user output via the [Console] streams (bypassing the
# pipeline) and returns ONLY its numeric exit code — mirroring the Bash port
# (echo -> fd1, return -> status). Until a command is built its module is absent
# and the dispatcher reports a usage error rather than routing.

[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments = @())

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# `pwsh -File <script> … --verbose` binds that token to the ENGINE's -Verbose
# common parameter. That does two harmful things the Bash port cannot do:
#   1. it streams every module load and export to stdout, corrupting a --json
#      summary, and
#   2. it CONSUMES the token, so the extension's own --verbose never reaches the
#      parser and the two ports disagree on the parsed state.
# So the engine stream is silenced unconditionally, and the flag is handed back
# to the arguments it was taken from (NFR-1).
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
if ($PSBoundParameters.ContainsKey('Verbose') -and ($Arguments -cnotcontains '--verbose')) {
    $Arguments = @($Arguments) + '--verbose'
}

$EntryDir = $PSScriptRoot
Import-Module (Join-Path $EntryDir 'lib/Cli.psm1') -Force
Import-Module (Join-Path $EntryDir 'lib/Prereq.psm1') -Force

$CommandsDir = if ($env:SPEC_KIT_JIRA_COMMANDS_DIR) {
    $env:SPEC_KIT_JIRA_COMMANDS_DIR
} else {
    Join-Path $EntryDir 'commands'
}

# Usage block emitted with explicit LF so both ports produce byte-identical bytes
# regardless of host line-ending conventions (NFR-1).
$UsageLines = @(
    'usage: spec-kit-jira <config|reconcile|mention|feature|adopt> [options]'
    '  --dry-run                 predict actions without writing'
    '  --json                    machine-readable run summary'
    '  --on-drift=abort|proceed  drift handling (default: abort)'
    '  --verbose                 verbose diagnostics'
    '  --repair-hooks            repair lifecycle hook registration'
    '  -h, --help                show this help'
)
$UsageText = ($UsageLines -join "`n") + "`n"

# (1) Prerequisites gate every path. Overrides come from env (Bash-symmetric).
$prereqParams = @{}
if ($env:_PREREQ_PWSH_MAJOR) { $prereqParams.PwshMajorOverride = [int] $env:_PREREQ_PWSH_MAJOR }
if ($env:_PREREQ_FORCE_MISSING) { $prereqParams.ForceMissing = @($env:_PREREQ_FORCE_MISSING -split '\s+') }
$prereq = Test-JiraPrereq @prereqParams
if ($prereq -ne 0) { exit $prereq }

# (2) Parse into key=value state lines.
$parsed = Invoke-JiraCliParse -Arguments $Arguments
$state = @{}
foreach ($line in ($parsed -split "`n")) {
    if ($line -match '^([^=]+)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
}

if ($state['exit'] -ne '0') {
    if ($state.ContainsKey('error') -and $state['error']) {
        [Console]::Error.WriteLine("spec-kit-jira: $($state['error'])")
    }
    [Console]::Error.Write($UsageText)
    exit ([int] $state['exit'])
}

if ($state['help'] -eq 'true') {
    [Console]::Out.Write($UsageText)
    exit 0
}

$command = $state['command']
if ([string]::IsNullOrEmpty($command)) {
    [Console]::Error.WriteLine('spec-kit-jira: a command is required (config|reconcile|mention|feature|adopt)')
    [Console]::Error.Write($UsageText)
    exit (Get-JiraExitCode 'usage')
}

# (3) Route to the command's on-demand module.
$title = (Get-Culture).TextInfo.ToTitleCase($command)
$cmdFile = Join-Path $CommandsDir "$title.psm1"
if (-not (Test-Path -LiteralPath $cmdFile)) {
    [Console]::Error.WriteLine("spec-kit-jira: command not available: $command")
    exit (Get-JiraExitCode 'usage')
}
Import-Module $cmdFile -Force
$fn = "Invoke-Jira$title"
if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("spec-kit-jira: command entry missing: $fn")
    exit (Get-JiraExitCode 'usage')
}
$code = & $fn -Arguments $Arguments
exit ([int] $code)
