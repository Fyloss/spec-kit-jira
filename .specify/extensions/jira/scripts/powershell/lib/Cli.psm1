# lib/Cli.psm1 — CLI arg parsing + the shared exit-code table. Mirror of lib/cli.sh.
#
# Emits the same machine-readable key=value lines in the same fixed order as the
# Bash port so the two are byte-identical (NFR-1). Lines are LF-separated; parse
# never terminates the process (the dispatcher reads `exit=`).
#
# Port infrastructure only: NO Jira knowledge.

Set-StrictMode -Version Latest

# Exit-code table (monotonically escalating — Constitution III).
$script:ExitCodes = @{
    ok          = 0
    usage       = 1
    fail_closed = 2
    auth        = 3
    config      = 4
    prereq      = 5
    block       = 9
}

function Get-JiraExitCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Symbol)
    if (-not $script:ExitCodes.ContainsKey($Symbol)) {
        throw "unknown exit-code symbol: $Symbol"
    }
    return $script:ExitCodes[$Symbol]
}

function Invoke-JiraCliParse {
    [CmdletBinding()]
    param([string[]] $Arguments = @())

    $command = ''
    $dryRun = 'false'
    $json = 'false'
    $onDrift = 'abort'
    $verbose = 'false'
    $repairHooks = 'false'
    $help = 'false'
    $parseError = ''
    $positional = [System.Collections.Generic.List[string]]::new()

    foreach ($arg in $Arguments) {
        switch -Regex ($arg) {
            '^(config|reconcile|mention)$' {
                if ([string]::IsNullOrEmpty($command)) { $command = $arg } else { $positional.Add($arg) }
                break
            }
            '^--dry-run$' { $dryRun = 'true'; break }
            '^--json$' { $json = 'true'; break }
            '^--verbose$' { $verbose = 'true'; break }
            '^--repair-hooks$' { $repairHooks = 'true'; break }
            '^(--help|-h)$' { $help = 'true'; break }
            '^--on-drift=' {
                $onDrift = $arg.Substring($arg.IndexOf('=') + 1)
                if ($onDrift -ne 'abort' -and $onDrift -ne 'proceed') {
                    $parseError = "invalid --on-drift value: $onDrift (expected abort|proceed)"
                }
                break
            }
            '^--on-drift$' { $parseError = '--on-drift requires a value (--on-drift=abort|proceed)'; break }
            '^--' { $parseError = "unknown flag: $arg"; break }
            default { $positional.Add($arg); break }
        }
        if ($parseError) { break }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($parseError) {
        $lines.Add("exit=$($script:ExitCodes.usage)")
        $lines.Add("error=$parseError")
    }
    else {
        $lines.Add("command=$command")
        $lines.Add("dry_run=$dryRun")
        $lines.Add("json=$json")
        $lines.Add("on_drift=$onDrift")
        $lines.Add("verbose=$verbose")
        $lines.Add("repair_hooks=$repairHooks")
        $lines.Add("help=$help")
        $lines.Add("args=$($positional -join ' ')")
        $lines.Add("exit=$($script:ExitCodes.ok)")
    }
    # Return the LF-joined state (with a trailing LF). Callers that need real
    # stdout wrap this in [Console]::Out.Write; command substitution strips the
    # trailing newline on both ports so bytes match (NFR-1).
    return (($lines -join "`n") + "`n")
}

Export-ModuleMember -Function Get-JiraExitCode, Invoke-JiraCliParse
