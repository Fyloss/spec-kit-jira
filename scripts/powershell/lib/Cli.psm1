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
    $onDriftSet = $false
    $verbose = 'false'
    $repairHooks = 'false'
    $help = 'false'
    $parseError = ''
    $useTeam = ''
    $yes = 'false'
    $positional = [System.Collections.Generic.List[string]]::new()
    $styles = [System.Collections.Generic.List[string]]::new()
    $binds = [System.Collections.Generic.List[string]]::new()
    $specs = [System.Collections.Generic.List[string]]::new()

    for ($idx = 0; $idx -lt $Arguments.Count; $idx++) {
        $arg = $Arguments[$idx]
        switch -Regex ($arg) {
            '^(config|reconcile|mention|feature|adopt)$' {
                if ([string]::IsNullOrEmpty($command)) { $command = $arg } else { $positional.Add($arg) }
                break
            }
            '^--dry-run$' { $dryRun = 'true'; break }
            '^--json$' { $json = 'true'; break }
            '^--verbose$' { $verbose = 'true'; break }
            '^--repair-hooks$' { $repairHooks = 'true'; break }
            # `adopt` pre-confirms the apply phase with --yes (003 research §6).
            '^--yes$' { $yes = 'true'; break }
            '^--bind$' {
                # Repeatable explicit binding (003 US4): <folder>[:us<N>]=<KEY>.
                # Only the STRUCTURE is checked here; the key's SHAPE is
                # validated in the sink (research §9).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--bind requires a value (--bind <folder>[:us<N>]=<KEY>)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    $eq = $v.IndexOf('=')
                    if ($eq -gt 0 -and $eq -lt ($v.Length - 1)) { $binds.Add($v) }
                    else { $parseError = "invalid --bind value: $v (expected <folder>[:us<N>]=<KEY>)" }
                }
                break
            }
            '^--spec$' {
                # Repeatable adoption scope (003 US6).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--spec requires a value (--spec <folder>)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if (-not [string]::IsNullOrEmpty($v)) { $specs.Add($v) }
                    else { $parseError = '--spec requires a non-empty folder name' }
                }
                break
            }
            '^(--help|-h)$' { $help = 'true'; break }
            '^--style$' {
                # Repeatable operator answer to the closed style question (002 US1).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--style requires a value (--style KEY=VALUE)'
                }
                else {
                    $idx++
                    $v = $Arguments[$idx]
                    if ($v -cmatch '^[A-Z][A-Z0-9_]+=(company_managed|team_managed)$') { $styles.Add($v) }
                    else { $parseError = "invalid --style value: $v (expected <PROJECT_KEY>=company_managed|team_managed)" }
                }
                break
            }
            '^--use-team$' {
                # The answer to the cross-team closed confirmation (002 US3, FR-014).
                if ($idx + 1 -ge $Arguments.Count) {
                    $parseError = '--use-team requires a value (--use-team <id>)'
                }
                else {
                    $idx++
                    $useTeam = $Arguments[$idx]
                }
                break
            }
            '^--on-drift=' {
                $onDrift = $arg.Substring($arg.IndexOf('=') + 1)
                $onDriftSet = $true
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

    # `adopt` performs no transition and reads no status, so drift has no meaning
    # for it. Checked after the loop because the command may follow the flag.
    if (-not $parseError -and $command -eq 'adopt' -and $onDriftSet) {
        $parseError = '--on-drift is not accepted by adopt (adoption performs no transition)'
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
        $lines.Add("styles=$($styles -join ' ')")
        $lines.Add("use_team=$useTeam")
        $lines.Add("yes=$yes")
        $lines.Add("binds=$($binds -join ' ')")
        $lines.Add("specs=$($specs -join ' ')")
        $lines.Add("args=$($positional -join ' ')")
        $lines.Add("exit=$($script:ExitCodes.ok)")
    }
    # Return the LF-joined state (with a trailing LF). Callers that need real
    # stdout wrap this in [Console]::Out.Write; command substitution strips the
    # trailing newline on both ports so bytes match (NFR-1).
    return (($lines -join "`n") + "`n")
}

Export-ModuleMember -Function Get-JiraExitCode, Invoke-JiraCliParse
