# Invoked with NO trailing argv tokens on its own command line: git-bash
# (MSYS) on Windows translates a bash argv array into a single Windows
# command line when spawning the native pwsh.exe, and has been observed to
# lose or mangle trailing simple-word arguments in that translation. The real
# entry point and its argv arrive through a file instead, so this script's own
# command line never carries more than its own path.
#
# Deliberately NO Set-StrictMode and NO $ErrorActionPreference = 'Stop': this
# is a transparent shim, and either one can turn a benign condition here into
# a terminating error that replaces the child's real exit code with 1.
param()

$entryPath = Get-Content -LiteralPath $env:SPEC_KIT_JIRA_HARNESS_ENTRYFILE -Raw
$entryPath = $entryPath.Trim()

$argv = @()
$argvFile = $env:SPEC_KIT_JIRA_HARNESS_ARGVFILE
if ($argvFile -and (Test-Path -LiteralPath $argvFile)) {
    # One argument per line. Split CRLF-safely — a checkout or a shell can
    # turn the LF this file is written with into CRLF, and a trailing "`r"
    # rides into the argument itself ("--json`r" matches no flag pattern).
    $raw = Get-Content -LiteralPath $argvFile -Raw
    if ($null -ne $raw -and $raw.Length -gt 0) {
        $argv = @($raw -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    }
}

# $LASTEXITCODE is the only place the child's real code survives: `& <script>`
# collapses a nested `exit N` to 1 in THIS process's own exit code. Seed it so
# the read below can never hit an unset variable.
$global:LASTEXITCODE = 0
& $entryPath @argv
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code
